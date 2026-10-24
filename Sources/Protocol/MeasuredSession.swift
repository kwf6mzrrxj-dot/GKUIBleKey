import Foundation
import Combine

/// 消息编号 —— **照原 App `-[IBMessageManager analyzeMessage:]` 的分发表**。
///
/// 反汇编证据（`InBlue.framework`，`0x10174`–`0x10290`）：
/// ```objc
/// switch (msg.command) {
///   case 2:  setLastPacket:2;  responseMessageWithData:;      break;  // 自动生成 03
///   case 4:  setLastPacket:4;  checkResultMessage:;           break;  // 检查结果
///   case 5:  setLastPacket:5;                                 break;  // 只记录
///   case 14: setLastPacket:14; saveKeysData:;
///            callDidPairingSuccess;                           break;  // 密钥 + 配对成功
///   case 15: setLastPacket:15; parseDeviceNames:;
///            callDidSendCommandSuccess;                       break;  // 设备名列表
///   default: callDidSendCommandFailed("Invalid Message type", 699);
/// }
/// ```
///
/// 真机抓包（2026-10-04）实测到的字节值与上表**完全吻合**。
public enum IBCommand: UInt8, Sendable {
    case authStart    = 0x01   // 手机 → 车：鉴权首条
    case response     = 0x02   // 车 → 手机：响应（App 收到后自动生成 03）
    case command      = 0x03   // 手机 → 车：操作请求（末尾控制码）
    case result       = 0x04   // 车 → 手机：结果（checkResultMessage:）
    case status       = 0x05   // 车 → 手机：状态（只记录）
    case pairingReq   = 0x0D   // 手机 → 车：配对请求（"Sending message 13"）
    case keyData      = 0x0E   // 车 → 手机：★ 密钥（"Key received" → saveKeysData:）
    case deviceNames  = 0x0F   // 车 → 手机：设备名列表（"Message 15 received"）

    public var label: String {
        switch self {
        case .authStart:   return "鉴权1"
        case .response:    return "响应"
        case .command:     return "操作"
        case .result:      return "结果"
        case .status:      return "状态"
        case .pairingReq:  return "配对请求"
        case .keyData:     return "密钥"
        case .deviceNames: return "设备名"
        }
    }
}

// MARK: - 车辆状态

/// `05` 帧的原始载荷容器。
///
/// ## 为什么这里**没有** `isLocked` 之类的语义字段
///
/// 原 App 收到 `05` 只做一件事：
/// `-[IBMessageManager performActionBasedOnPayloadType:andData:]` @`0x101a0`
/// ```objc
/// case 5:
///     NSLog(@"Message 5 received");
///     break;                    // ← 只打日志，不解包
/// ```
/// `IBVehicle.isLocked` 等属性由 `-[IBDevice parseStatus:]` 设置，
/// 而它只被 `parseBroadcastData:`（广播解密）调用 —— 与 `05` 帧无关。
///
/// 所以我们也不对 `05` 的字节赋予含义，只保留原始 19 字节。
/// 界面上"锁/未锁"改由**最近一次成功动作**表达，这是有证据的。
public struct IBVehicleState: Sendable, Equatable {
    /// 原始载荷（不含命令号）
    public var raw: [UInt8] = []

    public init() {}

    public init(payload: [UInt8]) {
        raw = payload
    }

    /// 整帧的十六进制展开（19 字节）
    public var hexDescription: String { FrameCodec.hexString(raw) }
    public var isEmpty: Bool { raw.isEmpty }
    public var byteCount: Int { raw.count }
}

// MARK: - 帧编解码

/// 实测帧格式：`[命令号(1B)] [payload]`
public enum MeasuredFrame {
    public static func encode(cmd: UInt8, payload: [UInt8] = []) -> [UInt8] {
        [cmd] + payload
    }
    public static func decode(_ bytes: [UInt8]) -> (cmd: UInt8, payload: [UInt8])? {
        guard let cmd = bytes.first else { return nil }
        return (cmd, Array(bytes.dropFirst()))
    }
}

// MARK: - 会话

/// 实测协议会话 —— 照原 App 的 `IBMessageManager` 状态机实现。
///
/// 现在载荷生成全部走 `InBlueAuth`（反汇编还原的 AES 链路），
/// 不再有「随机数凑字段」的猜测逻辑。
@MainActor
public final class MeasuredSession: ObservableObject {

    public enum Phase: String, Sendable {
        case idle        = "空闲"
        case sentAuth1   = "已发鉴权1"
        case gotAuth2    = "收到挑战2"
        case sentAuth3   = "已发操作3"
        case verified    = "操作成功"
        case failed      = "失败"
    }

    /// 一次动作的最终结果（对应原 App 的三个回调）
    public enum ActionResult: Sendable, Equatable {
        /// `callDidSendCommandSuccess`
        case success
        /// `callDidSendCommandFailedWithMessage:code:` —— 车端拒绝（699 / 0x2BB）
        case refused(UInt8)
        /// `0x0D` 场景：04 只表示「受理」，真正的结果在 `0x0F`
        case acceptedAwaitingNames
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var log: [String] = []
    /// `04` 的结果码（`00` = 成功）
    @Published public private(set) var lastStatusCode: UInt8?
    /// ★ 最近一次动作的最终结果
    @Published public private(set) var lastResult: ActionResult?
    /// ★ 最近一次成功执行的动作（供界面显示"上一动作"）
    @Published public private(set) var lastSucceededAction: IBCommandType?
    /// ★ `05` 原始状态包（原 App 不解析，仅记录）
    @Published public private(set) var vehicleState = IBVehicleState()
    /// ★ 广播解密得到的完整位级状态（`parseBroadcastData:` → `parseStatus:` 等）
    @Published public private(set) var status: VehicleStatus?
    /// ★ `0x0E` 下发的密钥数据（原 App 在此调 `saveKeysData:`）
    @Published public private(set) var receivedKeyData: [UInt8] = []
    /// ★ `0x0F` 的设备名列表（原 App 在此调 `parseDeviceNames:`）
    @Published public private(set) var pairedDeviceNames: [String] = []
    /// ★ 当前可用的密钥材料（配对后写入，启动时从 Keychain 恢复）
    @Published public private(set) var keys: InBlueAuth.Keys?
    /// 最近一次挑战的自校验结果（`nil` = 还没收到过 02）
    @Published public private(set) var challengeVerified: Bool?

    // ── 可调参数 ────────────────────────────────────────────────
    /// `03` 末尾的控制码 —— 由 `perform(_:)` 设置，等于 `IBCommandType.rawValue`。
    /// 默认 `0x0C` 是预认证（`openConnectionWithPassiveStart`，日志字面量
    /// `"send prehauthentification command"`），不是用户动作；
    /// 未显式指定动作时沿用它，行为与原 App 一致。
    public var controlCode: UInt8 = 0x0C
    /// 调试开关：置 false 时收到 02 也不回 03（只观测）
    public var sendAuth3 = true

    private var rnd1: [UInt8] = []
    /// 是否处于「配对（0x55）」流程 —— 配对时无密钥，`01` 帧用全零占位构造。
    private var isPairing = false

    /// 兼容字段：广播随机数不参与 `01` 帧。
    public var broadcastRandom: [UInt8] = []

    public func updateBroadcastRandom(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        broadcastRandom = Array(bytes.prefix(16))
        append("广播码（仅展示，不参与 01 帧）：" + FrameCodec.hexString(broadcastRandom))
    }

    /// 用广播解密出的明文更新车辆状态（照原 App `parseBroadcastData:`）。
    ///
    /// - Parameter plain: 解密后的 16 字节明文（`parseBroadcastData:` 的 `decryptData:withKey:` 结果）
    public func updateVehicleStatus(plain: [UInt8]) {
        guard plain.count >= 8 else { return }
        let s = VehicleStatus(decryptedPlain: plain)
        status = s
        append("车辆状态更新：\(s.summary)")
    }

    public init() {
        keys = Self.loadKeysFromStore()
    }

    // MARK: - 动作

    /// 当前准备执行的动作（决定 `03` 帧末字节）
    @Published public private(set) var pendingAction: IBCommandType?

    /// 设定本次要执行的动作。`03` 帧末尾直接写 `action.controlCode`。
    ///
    /// 原 App 的对应物是 `-[IBDevice openConnexionForCommand:]` 里的 `setCommand:`：
    /// `01` 连接确认 → `02` 挑战 → `03`（末字节 = command）→ `04` 结果。
    /// 也就是说**每个动作都是一次完整的鉴权往返**，不存在"先鉴权一次、再连续发命令"。
    public func perform(_ action: IBCommandType) {
        isPairing = false   // ★ 正常控车永远走真实密钥，清掉配对占位标志（防配对失败残留）
        pendingAction = action
        controlCode = action.controlCode
        append("准备执行：\(action.label)（控制码 0x\(String(format: "%02X", action.rawValue))）")
    }

    /// 准备一次**预认证**（`0x0C`）。
    ///
    /// 依据：`-[IBVehicle openConnectionWithPassiveStart]` @`0xb5a8`
    /// → `openConnexionForCommand:0x0C`，日志字符串
    /// `"send prehauthentification command to cidpu : %@"`。
    ///
    /// 必须显式清掉 `pendingAction` —— 否则定时触发时会沿用上一次的
    /// `unlock`/`lock`，预认证就变成一次真实控车（危险）。
    public func preparePreAuthentication() {
        isPairing = false
        pendingAction = nil
        controlCode = 0x0C
        append("准备预认证（控制码 0x0C，对应 openConnectionWithPassiveStart）")
    }

    /// 准备一次**配对**（`0x55`）。
    ///
    /// 依据：`-[IBVehicle startPairing]` @`0xa350` → `openConnexionForCommand:0x55`，
    /// `-[IBDevice openConnexionForCommand:]` @`0x4988` 里 `cmp #0x55` 特判：
    /// `closeConnexionForCommand`（关旧连接）+ 30 秒超时；
    /// `-[VCLSManager formatCommand:toDevice:]` @`0xfb48` 里 `cmp #0x55 → b.eq`
    /// **跳过 cidpu 检查**（配对时还没有密钥）→ `generateFirstMessage:`。
    ///
    /// 配对走完整鉴权链 `01 → 02 → 03(末字节 0x55) → 0x0E(Key received)`，
    /// 收到 `0x0E` 后 `saveKeysData:` + `callDidPairingSuccess`。
    public func preparePairing() {
        isPairing = true
        pendingAction = .pairing
        controlCode = 0x55
        append("准备配对（控制码 0x55，对应 startPairing → openConnexionForCommand:0x55）")
    }

    // MARK: - 构建 01

    /// 构建 `01` 帧（33 字节）。
    ///
    /// 走 `InBlueAuth.buildFirstMessage`：两段 AES，密钥都是 `CkTRxSP`。
    /// **配对（`isPairing`）时无密钥，改用全零占位 + 随机 RND1**（对应原 App
    /// 在 `formatCommand:toDevice:` 里 `cmp 0x55` 跳过 cidpu 检查后仍构造 01）。
    /// 失败时返回空数组，并在日志里说明缺什么。
    public func buildAuth1() -> [UInt8] {
        if isPairing {
            do {
                let m = try InBlueAuth.buildPairingFirstMessage()
                rnd1 = m.rnd1
                phase = .sentAuth1
                append("→ 01 鉴权1（配对占位：全零 sd|ed|RndTRx|rights + 随机 RND1，AES 密钥全零）")
                append("   RND1=\(FrameCodec.hexString(m.rnd1))")
                append("   明文=\(FrameCodec.hexString(m.plain))")
                append("   段1=\(FrameCodec.hexString(m.segment1))")
                append("   段2=\(FrameCodec.hexString(m.segment2))（全零密钥下恒定）")
                append("   \(FrameCodec.hexString(m.frame))")
                return m.frame
            } catch {
                append("❌ 构造配对 01 失败：\(error)")
                phase = .failed
                return []
            }
        }
        guard let k = keys else {
            append("❌ 还没有密钥材料（需要先配对拿到 0E）")
            phase = .failed
            return []
        }
        do {
            let m = try InBlueAuth.buildFirstMessage(keys: k)
            rnd1 = m.rnd1
            phase = .sentAuth1
            append("→ 01 鉴权1（明文 sd|ed|RndTRx|RND1|rights）")
            append("   RND1=\(FrameCodec.hexString(m.rnd1))")
            append("   明文=\(FrameCodec.hexString(m.plain))")
            append("   段1=\(FrameCodec.hexString(m.segment1))")
            append("   段2=\(FrameCodec.hexString(m.segment2))（同一把钥匙下恒定）")
            append("   \(FrameCodec.hexString(m.frame))")
            return m.frame
        } catch {
            append("❌ 构造 01 失败：\(error)")
            phase = .failed
            return []
        }
    }

    // MARK: - 构建 03

    /// 构建 `03` 帧（18 字节）—— 对应 `calculateResponseforCidpu:randomData:command:`。
    ///
    /// **配对（`isPairing`）时无密钥**，`Dk1` 用全零占位派生临时密钥 `enc1` ——
    /// 与 `01` 帧的全零占位一致，车端识别配对命令后不校验密钥内容。
    public func buildAuth3(challenge: [UInt8]) -> [UInt8] {
        let k: InBlueAuth.Keys
        if isPairing {
            k = InBlueAuth.Keys(
                dk1: [UInt8](repeating: 0, count: 16),
                sd: [UInt8](repeating: 0, count: 4),
                ed: [UInt8](repeating: 0, count: 4),
                rndTRx: [UInt8](repeating: 0, count: 3),
                rights: [UInt8](repeating: 0, count: 1),
                keyType: [UInt8](repeating: 0, count: 1),
                ckTRxSP: [UInt8](repeating: 0, count: 16),
                tail: [UInt8](repeating: 0, count: 16),
                cidpu: [UInt8](repeating: 0, count: 16)
            )
        } else {
            guard let kk = keys else {
                append("❌ 构造 03 失败：缺少密钥材料")
                phase = .failed
                return []
            }
            k = kk
        }
        guard rnd1.count == 4 else {
            append("❌ 构造 03 失败：RND1 缺失（需要先发 01）")
            phase = .failed
            return []
        }
        do {
            let m = try InBlueAuth.buildResponse(
                challenge: challenge, command: controlCode, rnd1: rnd1, keys: k
            )
            challengeVerified = m.challengeVerified
            phase = .sentAuth3
            append("→ 03 操作（控制码 0x\(String(format: "%02X", controlCode))）")
            append("   挑战=\(FrameCodec.hexString(challenge))")
            append("   enc1(临时密钥)=\(FrameCodec.hexString(m.enc1))")
            if m.challengeVerified {
                append("   ✅ 挑战自校验通过（\(FrameCodec.hexString(m.computed)) == \(FrameCodec.hexString(m.expected))）")
            } else {
                append("   ⚠️ 挑战自校验失败：算出 \(FrameCodec.hexString(m.computed))，车端期望 \(FrameCodec.hexString(m.expected))")
                append("      配对占位（全零 Dk1）时此校验本就不匹配，属预期；原 App 配对也走这条")
            }
            append("   \(FrameCodec.hexString(m.frame))")
            return m.frame
        } catch {
            append("❌ 构造 03 失败：\(error)")
            phase = .failed
            return []
        }
    }

    // MARK: - 接收（照 analyzeMessage: 的分发表）

    /// 处理一帧下行。返回「接下来该发什么」——`nil` 表示等车端。
    @discardableResult
    public func handle(_ bytes: [UInt8]) -> [UInt8]? {
        guard let (cmdRaw, payload) = MeasuredFrame.decode(bytes) else { return nil }
        let hex = FrameCodec.hexString(bytes)

        switch IBCommand(rawValue: cmdRaw) {

        case .response:                       // case 2 → responseMessageWithData:
            phase = .gotAuth2
            append("← 02 挑战：\(payload.count)B")
            append("   \(hex)")
            guard sendAuth3 else { phase = .verified; return nil }
            let frame = buildAuth3(challenge: payload)
            return frame.isEmpty ? nil : frame

        case .result:                         // case 4 → checkResultMessage: @0x107d4
            // 原实现（反汇编逐行还原）：
            //   result = data[1]                     ; 取第 2 字节
            //   if (result != 0)  → 失败，code = 0x2BB (699)
            //                        "Send command failed. The vehicle refused the command"
            //   else if (command == 0x0D) → 直接 return（等 0x0F 带设备名回来才算完）
            //   else → callDidSendCommandSuccess
            let code = payload.first ?? 0xFF
            lastStatusCode = code
            if code != 0x00 {
                phase = .failed
                append("← 04 结果：失败（\(String(format: "%02X", code))）")
                append("   车端拒绝执行「\(pendingAction?.label ?? "未知动作")」")
                lastResult = .refused(code)
            } else if pendingAction == .requestPairedDevices {
                // 0x0D 的成功回执是 0x0F 帧，不是 04；这里先不判成功
                append("← 04 结果：已受理（等待 0x0F 携带设备名）")
                phase = .verified
                lastResult = .acceptedAwaitingNames
            } else {
                phase = .verified
                // 校准（pendingAction == nil）不覆盖"上次成功动作"
                if let a = pendingAction { lastSucceededAction = a }
                append("← 04 结果：成功（00）「\(pendingAction?.label ?? "周期校准")」")
                lastResult = .success
            }
            return nil

        case .status:                         // case 5 → 原 App 只 NSLog，不解析
            // `-[IBMessageManager performActionBasedOnPayloadType:andData:]` @0x101a0：
            //   case 5: NSLog(@"Message 5 received"); 然后直接 break
            // 即：**05 帧在原 App 里只记录，不参与任何状态判断**。
            // 因此这里同样只保留原始字节，不对首字节做语义断言。
            vehicleState = IBVehicleState(payload: payload)
            append("← 05 状态包（原 App 不解析，仅记录）：\(FrameCodec.hexString(payload))")
            return nil

        case .keyData:                        // case 14 → saveKeysData: + 配对成功
            receivedKeyData = payload
            append("← 0E 收到密钥：\(payload.count)B（原 App 在此 saveKeysData:）")
            append("   \(hex)")
            saveKeyData(payload)
            return nil

        case .deviceNames:                    // case 15 → parseDeviceNames:
            pairedDeviceNames = Self.parseDeviceNames(payload)
            append("← 0F 设备名列表：\(pairedDeviceNames.isEmpty ? "(未解析出)" : pairedDeviceNames.joined(separator: ", "))")
            append("   \(hex)")
            return nil

        default:
            append("← 未知命令 0x\(String(format: "%02X", cmdRaw))：\(hex)")
            return nil
        }
    }

    // MARK: - 密钥保存（照 saveKeysData:）

    /// `-[VCLSManager saveKeysData:]` @`0x12660` —— 6 个字段按绝对偏移切开。
    ///
    /// 反汇编给出的 location 全部以「含命令号 `0x0E` 的帧头」为基准：
    /// `Dk1`=[1,17)、`sd`=[17,21)、`ed`=[21,25)、`RndTRx`=[25,28)、
    /// `rights`=[28,29)、`keyType`=[29,30)、`CkTRxSP`=[30,46)、尾部 16B=[46,62)。
    private func saveKeyData(_ payload: [UInt8]) {
        let frame: [UInt8] = payload.first == 0x0E ? payload : [0x0E] + payload
        append("   密钥帧长度 \(frame.count)B（标准 \(InBlueAuth.keyFrameLength)B）")

        guard let k = InBlueAuth.parseKeyFrame(frame) else {
            append("   ⚠️ 帧长不足 \(InBlueAuth.keyFrameLength)B，无法按反汇编切分，先原样留存")
            KeyStore.shared.set(Data(frame), for: .core)
            return
        }

        keys = k
        isPairing = false   // ★ 配对完成，密钥已落地，后续正常控车不再走全零占位
        let store = KeyStore.shared
        store.set(Data(k.dk1), for: .dk1)
        store.set(Data(k.sd), for: .sd)
        store.set(Data(k.ed), for: .ed)
        store.set(Data(k.rndTRx), for: .rndTRx)
        store.set(Data(k.rights), for: .rights1)
        store.set(Data(k.keyType), for: .keyType)
        store.set(Data(k.ckTRxSP), for: .ckTRxSP)
        store.set(Data(k.tail), for: .keyTail)
        // 兼容既有读取路径
        store.set(Data(k.ckTRxSP), for: .communicationKey)
        store.set(Data(frame), for: .core)

        // ★ CIDPU = 密钥帧 `[46,62)` 的 16 字节（hexString 后 32 字符）。
        //
        // 依据（`-[VCLSManager saveKeysData:]` @`0x12660`）：
        //   `0x129a4: mov w2,#0x2e ; mov w3,#0x10`  → subdataWithRange:(46,16)
        //   `0x129d0: [IBNSData hexString:]`         → 转成 hex 字符串
        //   `0x129f4: setObject:子字典 forKey:该字符串`
        // 即这个 16 字节的 hex 串就是 `keysData` 的键，也就是 CIDPU。
        //
        // 交叉印证：末 4 字节 `6AC89AD4` 与车辆详情页显示的 `6ac89ad4` 一致；
        // `[9,16)` = `3F26C66AC89AD4` 与设备名后缀一致。
        store.setString(k.cidpuHex, for: .pairedCIDPU)

        append("   \(k.summary)")
        append("   tail=[46..62)=\(FrameCodec.hexString(k.tail))")
        append("   ✅ CIDPU(16B)=\(k.cidpuHex) —— keysData 的字典键")
        append("   ✅ cidpu(完整 16B)=\(FrameCodec.hexString(k.tail))")
        append("   ✅ 已写入 Keychain：dk1/sd/ed/rndTRx/rights/keyType/CkTRxSP/tail/core")
    }

    // MARK: - 从 Keychain 恢复

    private static func loadKeysFromStore() -> InBlueAuth.Keys? {
        let s = KeyStore.shared
        guard let dk1 = s.get(.dk1).map({ Array($0) }), dk1.count == 16,
              let ck = s.get(.ckTRxSP).map({ Array($0) }), ck.count == 16
        else { return nil }

        let sd = s.get(.sd).map { Array($0) } ?? []
        let ed = s.get(.ed).map { Array($0) } ?? []
        let rndTRx = s.get(.rndTRx).map { Array($0) } ?? []
        let rights = s.get(.rights1).map { Array($0) } ?? []
        let keyType = s.get(.keyType).map { Array($0) } ?? []
        let tail = s.get(.keyTail).map { Array($0) } ?? []
        guard sd.count == 4, ed.count == 4, rndTRx.count == 3, rights.count == 1 else {
            return nil
        }

        return InBlueAuth.Keys(
            dk1: dk1, sd: sd, ed: ed, rndTRx: rndTRx,
            rights: rights, keyType: keyType, ckTRxSP: ck,
            tail: tail, cidpu: tail
        )
    }

    /// 手动重载（配对/恢复备份后调用）
    public func reloadKeys() {
        keys = Self.loadKeysFromStore()
        if let k = keys {
            append("已从 Keychain 载入密钥：\(k.summary)")
        } else {
            append("Keychain 里没有完整密钥（需要先配对）")
        }
    }

    /// 解析 `0x0F` 里的设备名列表（对应原 App `parseDeviceNames:`）。
    public static func parseDeviceNames(_ payload: [UInt8]) -> [String] {
        var out: [String] = []
        var current: [UInt8] = []
        for b in payload {
            if b >= 0x20 && b < 0x7F || b >= 0x80 {
                current.append(b)
            } else {
                if current.count >= 2,
                   let s = String(bytes: current, encoding: .utf8), !s.isEmpty {
                    out.append(s)
                }
                current = []
            }
        }
        if current.count >= 2, let s = String(bytes: current, encoding: .utf8), !s.isEmpty {
            out.append(s)
        }
        return out
    }

    // MARK: - 辅助

    public func reset() {
        phase = .idle
        rnd1 = []
        lastStatusCode = nil
        lastResult = nil
        pendingAction = nil
        receivedKeyData = []
        pairedDeviceNames = []
        challengeVerified = nil
        status = nil
        vehicleState = IBVehicleState()
    }

    /// 供外部（AppModel）往会话日志里追加一行。
    public func recordNote(_ line: String) { append("· \(line)") }

    private func append(_ s: String) {
        log.append("[\(Self.timestampFormatter.string(from: Date()))] \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
        // ★ 同时落盘：重装/重启后仍能查（覆盖安装不清沙盒）
        FileLogger.shared.append(s, tag: "DK")
    }

    /// 时间戳格式器（复用，避免每次日志都新建 DateFormatter）
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
