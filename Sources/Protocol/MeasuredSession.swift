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
/// 早期录制的真机广播样本与上表吻合（仅作样例，不构成协议结论依据）。
public enum IBCommand: UInt8, Sendable {
    /// `0x00` —— 原 App 白名单 `0x4007` 含 bit0（`analyzeMessage:` @`0xfc64`）
    case unknown      = 0x00
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
        case .unknown:     return "未知0"
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

    /// 载荷的十六进制展开（不含命令号）
    public var hexDescription: String { FrameCodec.hexString(raw) }
    public var isEmpty: Bool { raw.isEmpty }
}

// MARK: - 帧编解码

/// 实测帧格式：`[命令号(1B)] [payload]`
public enum MeasuredFrame {
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
        /// `callDidSendCommandFailedWithMessage:code:` —— 原 App 错误码（0x2BB=699 / 0x278=632）
        ///
        /// 用 `UInt16`：原 App 的 code 是 16 位（`0x2BB` / `0x278`），
        /// `UInt8` 存不下 699。车端 04 帧里的「结果字节」单独保存在 `lastStatusCode`。
        case refused(UInt16)
        /// `0x0D` 场景：04 只表示「受理」，真正的结果在 `0x0F`
        case acceptedAwaitingNames
        /// `0x0E` 密钥落库完成 —— 对应 `callDidPairingSuccess` @`0x6d6c`
        case paired
        /// 命令超时（`closeConnexionForCommand` @`0x62dc`，code 690）
        case timedOut
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
    /// `status` 最后一次被广播刷新的时刻。
    ///
    /// 车机广播**不是实时流**（实测间隔从 10 秒到十几分钟不等），所以界面上的
    /// 「已锁 / 门关 / 未启动」本质是**最后一次收到的快照**，不是当前实况。
    /// 没有这个时间戳，用户会误以为看到的是实时状态 —— 人离开车辆后
    /// 界面照样稳稳显示「已锁」，这比 RSSI 假值更容易造成误判。
    @Published public private(set) var statusUpdatedAt: Date?
    /// ★ `0x0E` 下发的密钥数据（原 App 在此调 `saveKeysData:`）
    @Published public private(set) var receivedKeyData: [UInt8] = []
    /// ★ `0x0F` 的设备名列表（原 App 在此调 `parseDeviceNames:`）
    @Published public private(set) var pairedDeviceNames: [String] = []
    /// 是否正在查询车端名册（`0x0D` 查询进行中）。
    ///
    /// 依据：`-[IBVehicle requestPairedDevicesNames]` @`0xa30c` →
    /// `openConnexionForCommand:0x0D`，走完整 `01/02/03` 鉴权，
    /// `03` 帧末尾 command = `0x0D`，车端回 `0x04`（受理）+ `0x0F`（名册）。
    /// 所以这个查询**必须连接**，不能离线读。
    public var isQueryingDeviceNames: Bool { pendingAction == .requestPairedDevices }
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

    /// ★ 消息序号状态机 —— 照 `-[IBMessageManager analyzeMessage:]` @`0xfc64`：
    /// 收到的命令号必须 **严格大于** `lastPacket`，否则判
    /// `"Protocol failed. Message %d received or the last message is %d"`。
    ///
    /// 反汇编里找不到显式的 `setLastPacket:0`，但多轮鉴权（01→02→03→04 反复）
    /// 必然要求每轮开始清零 —— 否则第二轮 02 会因 `2 < 4` 直接判失败。
    /// 因此每轮发起前由 `resetPacketCounter()` 清零（等价 `formatCommand:toDevice:` 的会话重置）。
    private var lastPacket: UInt8 = 0

    /// 每轮命令开始时清零消息序号（对应 `formatCommand:toDevice:` 的会话重置）。
    public func resetPacketCounter() {
        lastPacket = 0
    }

    /// 用广播解密出的明文更新车辆状态（照原 App `parseBroadcastData:`）。
    ///
    /// - Parameter plain: 解密后的 16 字节明文（`parseBroadcastData:` 的 `decryptData:withKey:` 结果）
    public func updateVehicleStatus(plain: [UInt8]) {
        guard plain.count >= 8 else { return }
        let s = VehicleStatus(decryptedPlain: plain)
        status = s
        statusUpdatedAt = Date()
        // 带完整明文 + 状态字节二进制，实测时可逐位核对
        // （区分「车端没报这个字段」与「我们位映射错了」）
        append("车辆状态更新：\(s.summary)｜plain=\(s.hex)")
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
        pendingAction = nil
        controlCode = 0x0C
        append("准备预认证（控制码 0x0C，对应 openConnectionWithPassiveStart）")
    }

    // MARK: - 车辆有效性（照 `-[IBVehicle isValid]` @0x9cb4）

    /// 车辆是否有效 —— 原 App 在 `openConnexionForCommand:` 开头就会查它，
    /// 不通过则**直接返回、一帧都不发**，并报 `"Vehicle is not valid. cidpu : (null)"`。
    ///
    /// 反汇编判定逻辑（@`0x9cd8` ~ @`0x9d64`）：
    /// ```objc
    /// - (BOOL)isValid {
    ///     if ([IBNSString isNullOrEmpty:self.key])   return NO;  // key 对象存在
    ///     if ([IBNSString isNullOrEmpty:self.cidpu]) return NO;  // cidpu 非空
    ///     return [self.cidpu length] == 0x20;                    // 32 个 hex 字符
    /// }
    /// ```
    /// 其中 `key` 是 `createANewKeyWithCidpu:` 建出的车辆对象（由 cidpu 派生），
    /// 不是配对密钥 —— 所以配对阶段（还没拿到 0E）也能通过这项校验。
    public var isVehicleValid: Bool {
        guard let c = KeyStore.shared.cidpuFullHex, !c.isEmpty else { return false }
        return c.count == 0x20
    }

    // MARK: - 构建 01

    /// 构建 `01` 帧（33 字节）。
    ///
    /// 走 `InBlueAuth.buildFirstMessage`：两段 AES，密钥都是 `CkTRxSP`。
    /// 失败时返回空数组，并在日志里说明缺什么。
    public func buildAuth1() -> [UInt8] {
        // ★ 照原 App `openConnexionForCommand:` @0x4988 的第一道闸：
        //   `if (![device isValid]) { NSLog("Vehicle is not valid..."); return; }`
        //   不通过就一帧都不发 —— 这样失败原因会立刻暴露成「车辆无效」，
        //   而不是白白等 30 秒超时（我们之前缺这道校验，全是 690 超时）。
        guard isVehicleValid else {
            let c = KeyStore.shared.cidpuFullHex ?? "(null)"
            append("❌ 车辆无效（Vehicle is not valid）：cidpu=\(c)")
            append("   原 App 此时直接返回、不发任何帧；请先扫描到本车以确定 cidpu")
            phase = .failed
            return []
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
    public func buildAuth3(challenge: [UInt8]) -> [UInt8] {
        guard let k = keys else {
            append("❌ 构造 03 失败：缺少密钥材料")
            phase = .failed
            return []
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
                append("   ❌ 挑战自校验失败：算出 \(FrameCodec.hexString(m.computed))，车端期望 \(FrameCodec.hexString(m.expected))")
                append("      自校验用的 RND1/enc1 与 01 帧同源，失败说明 01 占位或 RND1 处理有错（"
                       + "2026-10-25 曾因配对占位 RND1 错位 2 字节导致此处必失败 + 车端秒断）")
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

        // ★★ 照 `-[IBMessageManager analyzeMessage:]` @`0xfc64` 的双重校验（H2）
        //
        // ① 命令白名单：原 App 用 `1 << cmd & 0x4007`（{0,1,2,14}）+ 扩展分支，
        //    落到本实现即「必须是 IBCommand 里已定义、且我们确实处理的命令」。
        // ② 单调性：`cmd` 必须 **严格大于** `lastPacket`，否则原 App 判
        //    "Protocol failed. Message %d received or the last message is %d
        //     or vehicle is not valid"。
        guard let cmd = IBCommand(rawValue: cmdRaw) else {
            append("❌ 协议失败：非法命令 0x\(String(format: "%02X", cmdRaw))（Invalid Message type）")
            lastResult = .refused(0x2BB)          // 原 App：code 699
            phase = .failed
            return nil
        }
        guard cmdRaw > lastPacket else {
            append("❌ 协议失败：收到 0x\(String(format: "%02X", cmdRaw))，"
                 + "但上一帧序号已是 0x\(String(format: "%02X", lastPacket))（乱序或重复）")
            lastResult = .refused(0x2BB)
            phase = .failed
            return nil
        }
        lastPacket = cmdRaw

        switch cmd {

        case .response:                       // case 2 → responseMessageWithData:
            // ★ 照 `responseMessageWithData:` @`0x104b4`：
            //   `if ([data length] <= 0x10)` → 直接判 "Wrong challenge"（0x278），
            //   只有 >16 字节才取 `[1,16]` 参与响应计算（H3）。
            //
            // ⚠️ 这里的 `data` 是**整帧**（17 字节），不是 payload。
            //   `payload = bytes.dropFirst()` 只有 16 字节，用 `payload.count > 16`
            //   判断会恒为 false → 每一帧 `0x02` 都被误判成 Wrong challenge。
            //   这是 v3.3 之前一直存在的 bug，因为配对流程（0x0D→0x0E）不走 0x02，
            //   所以从未被触发；一旦开始发 `0x01` 鉴权就会立刻撞上。
            guard bytes.count > 16 else {
                phase = .failed
                append("❌ 02 挑战帧长度 \(bytes.count)B ≤ 16 —— "
                     + "Authentification is insufficient. Wrong challenge（0x278）")
                lastResult = .refused(0x278)      // Wrong challenge（原 App code 0x278=632）
                challengeVerified = false
                return nil
            }
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
                append("   车端拒绝执行「\(pendingAction?.label ?? "未知动作")」"
                     + " —— Send command failed. The vehicle refused the command（0x2BB）")
                // ★ 原 App 失败码固定 0x2BB(699)，不是车端回的那个字节（L1）
                lastResult = .refused(0x2BB)
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
            guard saveKeyData(payload) else {
                // ★ 切分失败 ≠ 配对成功（2026-10-29 修复）。
                //   原来无条件往下跑，把「帧长不符」也报成「✅ 配对成功」。
                phase = .failed
                lastResult = .refused(0x2BB)
                append("❌ 0x0E 密钥帧无法解析，**配对失败**（未写入任何密钥）")
                return nil
            }
            // ★ 照 `performActionBasedOnPayloadType:` case 14 @`0x101b0`：
            //   `saveKeysData:` 之后立刻 `callDidPairingSuccess`（M1）。
            //   这里给出显式成功态，而不是只靠上层改写 statusLine。
            phase = .verified
            lastResult = .paired
            append("✅ 配对成功（callDidPairingSuccess：resetCommandTimeout + startScan）")
            return nil

        case .deviceNames:                    // case 15 → parseDeviceNames: + 成功回调
            pairedDeviceNames = Self.parseDeviceNames(payload)
            append("← 0F 设备名列表：\(pairedDeviceNames.isEmpty ? "(未解析出)" : pairedDeviceNames.joined(separator: ", "))")
            append("   \(hex)")
            // ★ 照 case 15 @`0x10184`：`parseDeviceNames:` 之后
            //   `callDidSendCommandSuccess`（M4）。
            phase = .verified
            lastResult = .success
            if pendingAction == .requestPairedDevices {
                lastSucceededAction = .requestPairedDevices
            }
            return nil

        default:
            // ★ 照原 App `default: callDidSendCommandFailed("Invalid Message type", 699)`（L2）
            append("❌ 未处理的命令 0x\(String(format: "%02X", cmdRaw))（Invalid Message type）：\(hex)")
            lastResult = .refused(0x2BB)
            phase = .failed
            return nil
        }
    }

    /// ★ 命令超时 —— 照 `-[IBDevice closeConnexionForCommand]` @`0x62dc` 的
    /// `didNeedReconnect == NO` 分支（反汇编确认全库无 `setDidNeedReconnect:YES`）：
    ///
    /// ```objc
    /// [self setDidNeedReconnect:NO];
    /// NSLog(@"Timeout to send command is reached.");
    /// [self callDidSendCommandFailedWithMessage:@"Timeout to send command is reached."
    ///                                      code:690];
    /// ```
    ///
    /// 即 **只报错、不断开、不重连**（原 App 真实行为，不是"断开重连"）。
    public func commandTimedOut() {
        phase = .failed
        lastResult = .timedOut
        lastStatusCode = 0x00
        append("❌ 命令超时：Timeout to send command is reached. code 690")
        append("   原 App 此时只回报失败，不断开连接（closeConnexionForCommand 的 didNeedReconnect=false 分支）")
    }

    // MARK: - 密钥保存（照 saveKeysData:）

    /// `-[VCLSManager saveKeysData:]` @`0x12660` —— 6 个字段按绝对偏移切开。
    ///
    /// 反汇编给出的 location 全部以「含命令号 `0x0E` 的帧头」为基准：
    /// `Dk1`=[1,17)、`sd`=[17,21)、`ed`=[21,25)、`RndTRx`=[25,28)、
    /// `rights`=[28,29)、`keyType`=[29,30)、`CkTRxSP`=[30,46)、尾部 16B=[46,62)。
    /// 保存 `0x0E` 下发的密钥帧（照 `saveKeysData:` @`0x12660`）。
    ///
    /// - Returns: 是否**真的按反汇编切分并落库**。返回 `false` 时只留了原始
    ///   `core`，调用方**不能**报「配对成功」。
    ///
    /// 原来这里是 `Void`，帧长不足时静默 return，而上层无条件设
    /// `lastResult = .paired` 并打印「✅ 配对成功」——用户看到成功、
    /// 主界面却仍是「尚未绑定车辆」（`keys == nil`）。典型的假成功。
    @discardableResult
    private func saveKeyData(_ payload: [UInt8]) -> Bool {
        let frame: [UInt8] = payload.first == 0x0E ? payload : [0x0E] + payload
        append("   密钥帧长度 \(frame.count)B（标准 \(InBlueAuth.keyFrameLength)B）")

        guard let k = InBlueAuth.parseKeyFrame(frame) else {
            append("   ❌ 帧长不足 \(InBlueAuth.keyFrameLength)B，无法按反汇编切分")
            append("      仅原样留存 core（\(frame.count)B），**未写入任何密钥字段**")
            KeyStore.shared.set(Data(frame), for: .core)
            return false
        }

        keys = k
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

        // ★ 对齐原 App：整个 `keysData` 字典 → NSKeyedArchiver → Keychain("IBSavedKeys")
        //
        // 反汇编 `-[VCLSManager saveKeysData:]` @`0x12660` 末尾：
        //   `0x129a4` subdataWithRange:(46,16) → hexString → 作为外层字典键（cidpu）
        //   `0x12a2c` CFSTR "IBSavedKeys" → `storeDictionary:toKeychainWithKey:`
        // 详见 `KeyStore.setIBSavedKeysArchive` 的注释。
        // 内层 7 个值**全部是 hex 字符串**（原 App `hexString:`，小写、无分隔符）。
        func lowerHex(_ b: [UInt8]) -> String {
            b.map { String(format: "%02x", $0) }.joined()
        }
        store.setIBSavedKeysArchive([
            k.cidpuHex: [
                "Dk1":     lowerHex(k.dk1),
                "sd":      lowerHex(k.sd),
                "ed":      lowerHex(k.ed),
                "RndTRx":  lowerHex(k.rndTRx),
                "rights":  lowerHex(k.rights),
                "keyType": lowerHex(k.keyType),
                "CkTRxSP": lowerHex(k.ckTRxSP),
            ]
        ])

        append("   \(k.summary)")
        append("   tail=[46..62)=\(FrameCodec.hexString(k.tail))")
        append("   ✅ CIDPU(16B)=\(k.cidpuHex) —— keysData 的字典键")
        append("   ✅ cidpu(完整 16B)=\(FrameCodec.hexString(k.tail))")
        append("   ✅ 已写入 Keychain：dk1/sd/ed/rndTRx/rights/keyType/CkTRxSP/tail/core")
        append("   ✅ 已写入 IBSavedKeys（原 App 同构：NSKeyedArchiver 归档字典）")
        return true
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
        resetCommandOnly()
        // 只有「完整复位」（用户主动断开/解绑）才清这些业务展示数据
        receivedKeyData = []
        pairedDeviceNames = []
        status = nil
        statusUpdatedAt = nil
        vehicleState = IBVehicleState()
    }

    /// **解绑专用**：抹掉内存里的密钥副本，让 `keys` 与 Keychain 重新一致。
    ///
    /// 不能塞进 `reset()` —— `reset()` 也服务于「用户主动断开」，
    /// 那种场景 Keychain 里还有密钥，必须保留内存副本，
    /// 否则断开一下主界面就变成「尚未绑定车辆」。
    ///
    /// 解绑是全项目**唯一**需要抹掉内存副本的场景：
    /// 调用方必须先 `KeyStore.clearAll()` 再调本方法，两步都做完才是真的未配对。
    public func forgetKeys() {
        keys = nil
        append("已清除内存中的密钥副本（解绑）")
    }

    /// ★ 只复位「本次命令」相关状态 —— 对应原 App `resetCommandTimeout`
    ///   （@`0x64f4`：只 invalidate 定时器）+ 每轮会话起点。
    ///
    /// **不清** `receivedKeyData` / `status` / `vehicleState`：
    /// 原 App 的 `resetCommandTimeout` 并不动业务数据；而配对成功收尾
    /// （`callDidPairingSuccess` → `disconnect` @`0x6588`）也只做
    /// `resetCommandTimeout + startScan`，若把刚收到的密钥帧/车辆状态清掉，
    /// 会让「收到密钥」「车辆状态」在成功后瞬间消失（M2）。
    public func resetCommandOnly() {
        phase = .idle
        rnd1 = []
        lastStatusCode = nil
        lastResult = nil
        pendingAction = nil
        challengeVerified = nil
        lastPacket = 0
    }

    /// 供外部（AppModel）往会话日志里追加一行。
    public func recordNote(_ line: String) { append("· \(line)") }

    private func append(_ s: String) {
        log.append("[\(Self.timestampFormatter.string(from: Date()))] \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
        // ★ 同时落盘：重装/重启后仍能查（覆盖安装不清沙盒）
        //
        // 按内容标记分级（协议栈事件天然带 ✅/⚠️/❌）：
        //   ❌ → error、⚠️ → warning、其余 → info
        if s.contains("❌") {
            FileLogger.shared.error(s, module: "DK")
        } else if s.contains("⚠️") {
            FileLogger.shared.warning(s, module: "DK")
        } else {
            FileLogger.shared.info(s, module: "DK")
        }
    }

    /// 时间戳格式器（复用，避免每次日志都新建 DateFormatter）
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
