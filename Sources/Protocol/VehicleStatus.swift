import Foundation

/// 车辆状态解析 —— 照原 App `InBlue.framework` 反汇编逐字段还原。
///
/// ## 状态来源（反汇编权威，2026-10-24 二次复核）
/// 车辆状态**确实通过 BLE 下发并解析**，链路：
/// ```
/// -[IBDevice parseBroadcastData:] @0x4bc0
///   key   = stringToData(cidpu)              ; cidpu 16B 作 AES key
///   plain = VSSecurity.decryptData:withKey:  ; AES-CBC / IV=0
///   randomNumber   = plain[0,4)
///   parseStatus:      plain[4]   → 8 个字段（门锁/车门/后备箱/上电/发动机/引擎盖/ACC）
///   oemID          = plain[5]
///   parseDoorsStatus: plain[6]   → 四门独立状态
///   parsePowerStatus: plain[7]   → ACC 电源
///   additionalData = plain[8,16)
/// ```
///
/// ## 位序（`hexToBinary:` @`0x112c0` 高位在前）
/// `hexToBinary:` 是标准 hex→4 位二进制（`'0'→"0000"` … `'a'→"1010"`），**MSB 在前**。
/// 因此 `substringWithRange:(7,1)` 取 8 位串的最后一个字符 = **bit0（LSB）**，
/// `(6,1)` = bit1，依此类推。三个 `parseXxxStatus:` 各只吃 1 字节，
/// 所以它们内部的 `(loc,1)` 都是「该字节的第 loc 位（0-based，从 LSB 起）」。
public struct VehicleStatus: Sendable, Equatable {

    /// 原始解密明文（16 字节）
    public var raw: [UInt8]
    /// 明文二进制串（高位在前），等于原 App `hexToBinary:` 结果
    public var bits: [Bool]

    // ── `parseStatus:`（plain[4]）8 个字段 ─────────────────────
    /// bit0 —— `_isLocked`（门锁）
    public var isLocked: Bool
    /// bit1 —— `_isDoorClosed`（车门关闭）
    public var isDoorClosed: Bool
    /// bit2 —— `_isTruckLocked`（后备箱锁）
    public var isTrunkLocked: Bool
    /// bit3 —— `_isTruckClosed`（后备箱关闭）
    public var isTrunkClosed: Bool
    /// bit4 —— `_isIgnitionOn`（上电 / 点火开关）
    public var isIgnitionOn: Bool
    /// bit5 —— `_isEnginRunning`（发动机运行）
    public var isEngineRunning: Bool
    /// bit6 —— `_isHoodClosed`（引擎盖关闭）
    public var isHoodClosed: Bool
    /// bit7 —— 未在 `parseStatus:` 取值（MSB）
    public var reservedBit7: Bool

    // ── `parseDoorsStatus:`（plain[6]）四门 ────────────────────
    /// 前左门关闭
    public var isFLDoorClosed: Bool
    /// 前右门关闭
    public var isFRDoorClosed: Bool
    /// 后左门关闭
    public var isRLDoorClosed: Bool
    /// 后右门关闭
    public var isRRDoorClosed: Bool

    // ── `parsePowerStatus:`（plain[7]）电源 ────────────────────
    /// ACC 电源（bit0）
    public var isAccOn: Bool

    // ── 其他切分 ───────────────────────────────────────────────
    /// plain[0,4) 随机数
    public var randomNumber: [UInt8]
    /// plain[5] OEM ID
    public var oemID: UInt8
    /// plain[8,16) 附加数据
    public var additionalData: [UInt8]

    /// 是否有有效状态（解密成功过）
    public var isValid: Bool { !raw.isEmpty }

    /// 从**解密后的 16 字节明文**构造完整状态。
    /// 对应 `parseBroadcastData:` 解密后的切分 + 三个 `parseXxxStatus:`。
    public init(decryptedPlain plain: [UInt8]) {
        raw = plain
        bits = Self.toBits(plain)

        let statusByte = plain.count > 4 ? plain[4] : 0
        let doorsByte  = plain.count > 6 ? plain[6] : 0
        let powerByte  = plain.count > 7 ? plain[7] : 0

        let s = Self.decodeStatusByte(statusByte)
        let d = Self.decodeDoorsByte(doorsByte)
        let p = Self.decodePowerByte(powerByte)

        isLocked        = s["isLocked"] ?? false
        isDoorClosed    = s["isDoorClosed"] ?? false
        isTrunkLocked   = s["isTrunkLocked"] ?? false
        isTrunkClosed   = s["isTrunkClosed"] ?? false
        isIgnitionOn    = s["isIgnitionOn"] ?? false
        isEngineRunning = s["isEngineRunning"] ?? false
        isHoodClosed    = s["isHoodClosed"] ?? false
        reservedBit7    = s["reservedBit7"] ?? false

        isFLDoorClosed  = d["isFLDoorClosed"] ?? false
        isFRDoorClosed  = d["isFRDoorClosed"] ?? false
        isRLDoorClosed  = d["isRLDoorClosed"] ?? false
        isRRDoorClosed  = d["isRRDoorClosed"] ?? false

        isAccOn         = p["isAccOn"] ?? false

        randomNumber    = plain.count >= 4 ? Array(plain[0..<4]) : []
        oemID           = plain.count > 5 ? plain[5] : 0
        additionalData  = plain.count >= 16 ? Array(plain[8..<16]) : []
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

    /// `-[IBDevice parseBroadcastData:]` @`0x4bc0` 的完整切分。
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

    /// `parseStatus:` @`0x4de4` 的单字节位映射。
    ///
    /// 反汇编：`substringWithRange:(7,1)`→`_isLocked`、`(6,1)`→`_isDoorClosed`、
    /// `(5,1)`→`_isTruckLocked`、`(4,1)`→`_isTruckClosed`、`(3,1)`→`_isIgnitionOn`、
    /// `(2,1)`→`_isEnginRunning`、`(1,1)`→`_isHoodClosed`。
    /// 因 `hexToBinary` 高位在前，`(loc,1)` 即 **bit(loc)**（LSB=0）。
    public static func decodeStatusByte(_ b: UInt8) -> [String: Bool] {
        func bit(_ i: Int) -> Bool { (b >> UInt8(i)) & 1 == 1 }
        return [
            "isLocked": bit(0),        // loc 7 → bit0
            "isDoorClosed": bit(1),    // loc 6 → bit1
            "isTrunkLocked": bit(2),   // loc 5 → bit2
            "isTrunkClosed": bit(3),   // loc 4 → bit3
            "isIgnitionOn": bit(4),    // loc 3 → bit4
            "isEngineRunning": bit(5), // loc 2 → bit5
            "isHoodClosed": bit(6),    // loc 1 → bit6
            "reservedBit7": bit(7),    // loc 0 → bit7（未取值）
        ]
    }

    /// `parseDoorsStatus:` @`0x5274` 的单字节位映射。
    ///
    /// 反汇编：`(7,1)`→`_isFLDoorClosed`、`(6,1)`→`_isFRDoorClosed`、
    /// `(5,1)`→`_isRLDoorClosed`、`(4,1)`→`_isRRDoorClosed`。
    public static func decodeDoorsByte(_ b: UInt8) -> [String: Bool] {
        func bit(_ i: Int) -> Bool { (b >> UInt8(i)) & 1 == 1 }
        return [
            "isFLDoorClosed": bit(0), "isFRDoorClosed": bit(1),
            "isRLDoorClosed": bit(2), "isRRDoorClosed": bit(3),
        ]
    }

    /// `parsePowerStatus:` @`0x517c` 的单字节位映射（`(7,1)`→`_isAccOn`）。
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

    /// 已知字段的可读摘要
    public var summary: String {
        var parts: [String] = []
        parts.append(isLocked ? "已锁" : "未锁")
        parts.append(isIgnitionOn ? "上电" : "未上电")
        parts.append(isEngineRunning ? "发动机运行" : "发动机停")
        parts.append(isAccOn ? "ACC开" : "ACC关")
        if !isTrunkClosed { parts.append("后备箱开") }
        return parts.joined(separator: " · ")
    }

    public var hex: String { FrameCodec.hexString(raw) }

    /// 逐字段可读明细（全部字段，来自反汇编）
    public var fullDescription: String {
        var lines: [String] = ["原始明文：\(hex)"]
        lines.append("门锁=\(isLocked) 车门关=\(isDoorClosed) 后备箱锁=\(isTrunkLocked) 后备箱关=\(isTrunkClosed)")
        lines.append("上电=\(isIgnitionOn) 发动机=\(isEngineRunning) 引擎盖关=\(isHoodClosed) ACC=\(isAccOn)")
        lines.append("四门：FL=\(isFLDoorClosed) FR=\(isFRDoorClosed) RL=\(isRLDoorClosed) RR=\(isRRDoorClosed)")
        lines.append("oemID=\(String(format: "%02X", oemID)) randomNumber=\(FrameCodec.hexString(randomNumber))")
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
