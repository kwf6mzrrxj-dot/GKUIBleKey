import Foundation

/// 车辆状态解析。
///
/// ## ⚠️ 先纠正一个前提
/// 原 App 对 `05` 帧**不做解析** —— `-[IBMessageManager analyzeMessage:]` 的
/// `case 5:` 只有 `setLastPacket:5`。
/// 真正的状态来自**广播解密**（`parseBroadcastData:`，见下方 `Broadcast`）。
///
/// 本结构体因此分两用途：
/// 1. `Broadcast` / `decryptBroadcast` —— **原 App 的真实路径**，语义已确认；
/// 2. `VehicleStatus(payload:)` —— 对 `05` 帧的**推测映射**（原 App 不解它），
///    用于界面展示，判断依据是「`05` 的 19 字节若与广播明文同构」这一假设。
///    **不要用它做安全判断**（例如「已锁」不能据此确认）。
///
/// ## 位序（`hexToBinary:` @`0x112c0` 高位在前）
/// `substringWithRange:(7,1)` = **该字节的 bit0**，`(6,1)` = bit1，依此类推。
/// 所以「loc 7/6/5/4/3」读作「bit0/1/2/3/4」，不是位掩码 `0x40`。
public struct VehicleStatus: Sendable, Equatable {

    /// 原始载荷（`05` 帧去掉命令号后的 19 字节）
    public var raw: [UInt8]
    /// 整帧的二进制串（高位在前），等于原 App 的 `hexToBinary:` 结果
    public var bits: [Bool]

    // ── `parseStatus:` 已确认的字段 ─────────────────────────────
    /// bit 7（首字节 bit0）
    public var isLocked: Bool
    /// bit 6（首字节 bit1）
    public var isDoorClosed: Bool
    /// bit 5（首字节 bit2）
    public var isTrunkLocked: Bool
    /// bit 4（首字节 bit3）
    public var isTrunkClosed: Bool
    /// bit 3（首字节 bit4）
    public var isIgnitionOn: Bool
    /// bit 1（首字节 bit6）
    public var isEngineRunning: Bool
    /// `parseStatus:` 里 loc 未取到的一位（夹在 ignition 与 engine 之间）
    public var reservedBit2: Bool

    public init(payload: [UInt8]) {
        raw = payload
        bits = Self.toBits(payload)

        // ★ 严格照 `-[IBDevice parseStatus:]` @`0x4de4` 反汇编：
        //   bin = hexToBinary(hexString(data))
        //   isLocked = bin[7]  →  **首字节 bit0**
        //
        // ⚠️ 适用范围：`parseStatus:` 只被 `parseBroadcastData:`（广播解密）调用，
        // **不是 `05` 帧的解析器**。原 App 收到 `05` 只 NSLog（case 5）。
        isLocked = ((payload.first ?? 0) & Self.lockMask) != 0

        // 其余字段：`parseStatus:` 反汇编里 loc 6/5/4/3/1 依次取 bit1/2/3/4/6，
        // 但广播数据在本车上只有 19 字节（需要 ≥36 字节才有 broadcastData），
        // 这条路径实际走不到，因此不做语义断言。
        isDoorClosed = false
        isTrunkLocked = false
        isTrunkClosed = false
        isIgnitionOn = false
        isEngineRunning = false
        reservedBit2 = false
    }

    /// 锁车位：`parseStatus:` 取 `bin[7]`，即首字节 **bit0**（掩码 `0x01`）
    public static let lockMask: UInt8 = 0x01

    /// `hexString:` → `hexToBinary:` 的等价实现：**高位在前**
    public static func toBits(_ bytes: [UInt8]) -> [Bool] {
        var out: [Bool] = []
        out.reserveCapacity(bytes.count * 8)
        for b in bytes {
            for i in stride(from: 7, through: 0, by: -1) {
                out.append((b >> UInt8(i)) & 1 == 1)
            }
        }
        return out
    }

    /// 位串的十六进制展开（便于真车对照）
    public var bitString: String {
        bits.map { $0 ? "1" : "0" }.joined()
    }

    // MARK: - ★ 原 App 的真实状态入口（广播解密）

    /// `-[IBDevice parseBroadcastData:]` @`0x4bc0` 的完整切分：
    /// ```objc
    /// key   = [IBNSString stringToData:self.cidpu];        // hex → 16B
    /// plain = [VSSecurity decryptData:data withKey:key];  // AES-CBC / IV=0
    /// self.randomNumber   = [plain subdataWithRange:NSMakeRange(0, 4)];
    /// [self parseStatus:      [plain subdataWithRange:NSMakeRange(4, 1)]];  // ← 只 1 字节
    /// self.oemID          = [plain subdataWithRange:NSMakeRange(5, 1)];
    /// [self parseDoorsStatus: [plain subdataWithRange:NSMakeRange(6, 1)]];  // ← 只 1 字节
    /// [self parsePowerStatus: [plain subdataWithRange:NSMakeRange(7, 1)]];  // ← 只 1 字节
    /// self.additionalData = [plain subdataWithRange:NSMakeRange(8, 8)];
    /// ```
    /// 关键：三个 `parseXxxStatus:` **各只吃 1 个字节**，
    /// 所以它们内部的 `substringWithRange:(7,1)` 都是「同一字节的 bit0」。
    ///
    /// 输入密文来自 `VCBAdvertisingData.broadcastData`：
    /// Gen02 是 `[6,7)`（1B，太短、无法解密），Gen03 是 `[19,35)`（16B，**只有当厂商数据 ≥36B** 才有）。
    public struct Broadcast: Sendable {
        public var randomNumber: [UInt8]   // [0,4)
        public var statusRaw: UInt8        // [4]
        public var oemID: UInt8            // [5]
        public var doorsRaw: UInt8         // [6]
        public var powerRaw: UInt8         // [7]
        public var additionalData: [UInt8] // [8,16)
    }

    /// 解密并切分广播载荷。`cipher` 必须是 16 字节。
    public static func decryptBroadcast(
        cipher: [UInt8], cidpuHex: String
    ) -> (plain: [UInt8], parsed: Broadcast)? {
        guard cipher.count == 16 else { return nil }
        guard let key = ValeoAdvMatch.cidpuAESKey(cidpuHex) else { return nil }
        guard let plain = try? CryptoBox.aesDecrypt(
            .cbcNoPadding, key: key,
            iv: [UInt8](repeating: 0, count: 16), cipher: cipher)
        else { return nil }
        guard plain.count == 16 else { return nil }
        return (plain, Broadcast(
            randomNumber: Array(plain[0..<4]),
            statusRaw: plain[4],
            oemID: plain[5],
            doorsRaw: plain[6],
            powerRaw: plain[7],
            additionalData: Array(plain[8..<16])))
    }

    /// `parseStatus:` 的单字节位映射（bit 序号按 `hexToBinary` 的字符索引）。
    public static func decodeStatusByte(_ b: UInt8) -> [String: Bool] {
        func bit(_ i: Int) -> Bool { (b >> UInt8(i)) & 1 == 1 }
        return [
            "isLocked": bit(0),        // loc 7
            "isDoorClosed": bit(1),    // loc 6
            "isTrunkLocked": bit(2),   // loc 5
            "isTrunkClosed": bit(3),   // loc 4
            "isIgnitionOn": bit(4),    // loc 3
            "reserved2": bit(5),       // loc 2
            "isEngineRunning": bit(6), // loc 1
        ]
    }

    /// `parseDoorsStatus:` 的单字节位映射（loc 7…1 ⇒ bit0…bit6）
    public static func decodeDoorsByte(_ b: UInt8) -> [String: Bool] {
        func bit(_ i: Int) -> Bool { (b >> UInt8(i)) & 1 == 1 }
        return [
            "isFLDoorClosed": bit(0), "isFRDoorClosed": bit(1),
            "isRLDoorClosed": bit(2), "isRRDoorClosed": bit(3),
            "isFLDoorLocked": bit(4), "isFRDoorLocked": bit(5),
            "isRLDoorLocked": bit(6),
        ]
    }

    /// `parsePowerStatus:` 的单字节位映射
    public static func decodePowerByte(_ b: UInt8) -> [String: Bool] {
        func bit(_ i: Int) -> Bool { (b >> UInt8(i)) & 1 == 1 }
        return ["isAccOn": bit(0)]
    }

    /// 按 8 位分组，方便逐字节比对
    public var bitStringGrouped: String {
        stride(from: 0, to: bits.count, by: 8).map { start in
            let end = min(start + 8, bits.count)
            return bits[start..<end].map { $0 ? "1" : "0" }.joined()
        }.joined(separator: " ")
    }

    /// 已知字段的可读摘要（**只陈述有证据的部分**）
    public var summary: String {
        isLocked ? "已锁车" : "未锁车"
    }

    public var hex: String { FrameCodec.hexString(raw) }

    /// 逐位明细（全部 152 位，供反推未确认字段）
    public var fullDescription: String {
        var lines: [String] = ["原始：\(hex)", "位串：\(bitStringGrouped)"]
        lines.append("已确认：锁=\(isLocked) 门关=\(isDoorClosed) 尾门锁=\(isTrunkLocked) "
                     + "尾门关=\(isTrunkClosed) 点火=\(isIgnitionOn) 发动机=\(isEngineRunning)")
        return lines.joined(separator: "\n")
    }
}

/// 协议错误码 —— 照原 App 的 `callDidSendCommandFailedWithMessage:code:` 调用点。
///
/// | code | 文案 | 出处 |
/// |---|---|---|
/// | `0x276` = 630 | `CIDPU is nil.` | `formatCommand:toDevice:` @`0xfc18` |
/// | `0x277` = 631 | `Derivation parameter is nil` | `generateDerivationParametersMessage:` @`0xfea4` |
/// | `0x278` = 632 | `Authentification is insufficient. Wrong challenge` | `responseMessageWithData:` @`0x10548` |
/// | `699` | `Invalid Message type` | `analyzeMessage:` default 分支 |
/// | `40001` | 控车指令重发次数已满 | 主 App `ExBluetoothMessageHandle` |
public enum ProtocolErrorCode: Int, Sendable {
    case cidpuNil = 0x276
    case derivationParamNil = 0x277
    case wrongChallenge = 0x278
    case invalidMessageType = 699
    case resendExhausted = 40001

    public var message: String {
        switch self {
        case .cidpuNil:            return "CIDPU 为空（还没拿到钥匙的车辆标识）"
        case .derivationParamNil:  return "派生参数为空（车端没下发 sd/ed/RndTRx）"
        case .wrongChallenge:      return "挑战校验失败（Dk1 / RND1 不匹配）"
        case .invalidMessageType:  return "不支持的消息类型"
        case .resendExhausted:     return "重发次数已满"
        }
    }

    /// 是否值得立刻重试。
    ///
    /// 原 App 只有 `40001` 会终止（`_kRetryTimes = 5`），其余都是一次性失败；
    /// 这里按「能否自愈」分类：密钥/挑战类重试也没用，必须重新配对。
    public var isRetryable: Bool {
        switch self {
        case .cidpuNil, .derivationParamNil, .wrongChallenge: return false
        case .invalidMessageType: return false
        case .resendExhausted:    return true
        }
    }

    /// 对应 `04` 帧的结果码语义 —— 委托给 `ErrorCodeTable`。
    ///
    /// ⚠️ **只有 `0x00`（成功）有依据**（抓包 20:49–20:57 每次控车都回 `04 00`）。
    /// 原 App 的 `Localizable.strings` 里虽然有一大堆 `error_20xx`，
    /// 但那些是 4 位业务码，**与 `04` 的单字节之间没有找到映射代码**，
    /// 所以这里不再给 `0x01`/`0x02` 等编"执行中/条件不满足"的猜测文案。
    public static func describeResultCode(_ code: UInt8) -> String {
        ErrorCodeTable.describeResultByte(code)
    }
}
