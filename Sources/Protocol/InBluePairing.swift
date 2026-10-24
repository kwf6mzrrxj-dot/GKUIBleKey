import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// InBlue 配对流程（首次绑定）。
///
/// ## 两条配对路径（原 App 反汇编）
///
/// 原 App 里「配对」有**两条独立路径**，不能混为一谈：
///
/// | 路径 | 方法 | 命令 | 行为 |
/// |---|---|---|---|
/// | **登记帧** | `generatePairingMessage` @`0xfecc` → `pairingMessage` @`0x13afc` | `0x0D` | 直发 37B 登记帧，日志 "Sending message 13" |
/// | **配对鉴权链** | `startPairing` @`0xa350` → `openConnexionForCommand:0x55` | `0x55` | 走 `01→02→03(0x55)→0x0E` 完整鉴权链 |
///
/// 本类保留的是 **`0x0D` 登记帧**路径（对应 `generatePairingMessage`）。
/// 主配对入口 `startFullPairing` 走的是 **`0x55` 鉴权链**（见 `MeasuredSession.preparePairing`）。
///
/// ## `0x0D` 登记帧格式
/// ```
/// 手机 → 0D <nonce 15B> <字符数> <手机名 UTF-8> <补零>   共 37B
/// 模块 → 0E <7 字段密钥载荷 + 16B CIDPU>                共 62B
/// ```
/// 车端收到 `0D` 后直接下发密钥，**没有挑战-响应**，也不需要在手机上算任何东西。
///
/// ## 2026-10-24 清理
/// 旧版本里还有 `buildDerivationParametersMessage` / `calculateResponse` /
/// `buildResponseMessage` 三个方法（HMAC-SHA256 那套）。它们来自对
/// `GLBLEAuthSDK`（另一套五步协议）的假设，**InBlue 链路不存在这一步**，已删除。
///
/// 另外 `IBMessageFactory` 的命名有误导：
/// `derivationParametersMessageWithCidpu:` 其实是 **`01` 帧**、
/// `responseMessageWithCommand:randomData:cidpu:` 其实是 **`03` 帧**，
/// 真正的实现见 `InBlueAuth`。
@MainActor
public final class InBluePairing: ObservableObject {

    public enum State: String, Sendable {
        case idle = "空闲"
        case requestingPairing = "发送配对请求"
        case awaitingConfirmation = "等待车端下发密钥"
        case succeeded = "配对成功"
        case failed = "配对失败"
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var log: [String] = []
    /// 车端在 `0x0E` 里回的原始载荷
    @Published public private(set) var rawResponse: [UInt8] = []
    /// 车端响应里解析出的字段（来自 `InBlueAuth.parseKeyFrame`）
    @Published public private(set) var parsedFields: [String: String] = [:]
    @Published public private(set) var lastError: String?

    /// 配对帧固定补零到 37 字节（实测）
    public static let frameLength = 37
    /// nonce 15 字节（实测）
    public static let nonceLength = 15
    /// 命令号
    public static let command: UInt8 = 0x0D

    public init() {}

    // MARK: - 构造 0D

    /// 构造配对帧 —— 对应 `+[IBMessageFactory pairingMessage]` @`0x13afc`。
    ///
    /// ```
    /// 0D | <nonce 15B> | <字符数 1B> | <手机名 UTF-8> | 补零到 37
    /// ```
    /// **字符数**是 `String.count`（字符个数），不是 UTF-8 字节数 ——
    /// 实测 `"小米手机"` → `04`（4 个汉字，12 字节）。
    public func buildPairingMessage(deviceName: String? = nil) -> [UInt8] {
        let name = deviceName ?? Self.currentDeviceName()
        let nameBytes = Array(name.utf8)

        var out: [UInt8] = [Self.command]
        out.append(contentsOf: CryptoBox.secureRandomBytes(Self.nonceLength))
        out.append(UInt8(min(name.count, 255)))
        out.append(contentsOf: nameBytes)
        if Self.frameLength > out.count {
            out.append(contentsOf: [UInt8](repeating: 0, count: Self.frameLength - out.count))
        }

        state = .requestingPairing
        append("配对请求：名=\(name)（\(name.count)字）nonce=\(Self.nonceLength)B → 共 \(out.count) 字节")
        append("  原始: \(FrameCodec.hexString(out))")
        return out
    }

    // MARK: - 接收 0E

    /// 接收车端的 `0x0E` 载荷：原样保存 + 按反汇编切分展示。
    public func acceptRawResponse(_ payload: [UInt8]) {
        rawResponse = payload
        state = .succeeded
        append("收到车端配对响应：\(payload.count)B")
        append("   \(FrameCodec.hexString(payload))")

        parsedFields = [:]
        if let k = InBlueAuth.parseKeyFrame(payload) {
            parsedFields["Dk1"] = FrameCodec.hexString(k.dk1)
            parsedFields["sd"] = FrameCodec.hexString(k.sd)
            parsedFields["ed"] = FrameCodec.hexString(k.ed)
            parsedFields["RndTRx"] = FrameCodec.hexString(k.rndTRx)
            parsedFields["rights"] = FrameCodec.hexString(k.rights)
            parsedFields["keyType"] = FrameCodec.hexString(k.keyType)
            parsedFields["CkTRxSP"] = FrameCodec.hexString(k.ckTRxSP)
            parsedFields["cidpu(16B)"] = FrameCodec.hexString(k.tail)
        } else {
            parsedFields["状态"] = "帧长 \(payload.count)B，不足 62B 无法切分"
        }
    }

    public func appendExternal(_ line: String) { append(line) }

    public func resetForNewAttempt() {
        state = .idle
        rawResponse = []
        parsedFields = [:]
        lastError = nil
        append("═══ 新的配对尝试 ═══")
    }

    public func fail(_ message: String) {
        state = .failed
        lastError = message
        append("❌ \(message)")
    }

    // MARK: - 辅助

    private func append(_ s: String) {
        let ts = Self.formatter.string(from: Date())
        log.append("[\(ts)] \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
        FileLogger.shared.append(s, tag: "配对")
    }

    public static func currentDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "iPhone"
        #endif
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
