import Foundation

/// **Tbox 广播码解析** —— 照 `-[XXX isTboxBluetoothBroadcastWithBroadcastCode:]` 反汇编。
///
/// ## ⚠️ 状态：**已从主链路移除，仅保留诊断**
///
/// 它产出的 `broadcastRandom`（`code[17..25)`）曾被当作 `01` 帧的第一段。
/// 2026-10-24 复核推翻了这个用法：
/// `01` 帧是 `AES(明文, CkTRxSP)`（见 `InBlueAuth`），**不含 broadcastRandom 字段**。
/// 因此本文件现在只在「广播」日志里输出原始码，不参与任何帧构造。
///
/// 保留原因：`code[17..25)` 这 8 字节在实测里确实存在且恒定，可能是另一条
/// （旧版 / 另一车型）链路的材料，留作后续比对。
///
/// ## 反汇编证据
/// 调用方是 `-[XXX centralManager:didDiscoverPeripheral:advertisementData:RSSI:]`：
/// ```objc
/// [self state]
/// if (state != 2) return;
/// data = advertisementData[@"kCBAdvDataManufacturerData"]   // ★ 厂商数据
/// [viewModel isTboxBluetoothBroadcastWithBroadcastCode:data]
/// ```
///
/// `isTboxBluetoothBroadcastWithBroadcastCode:` 内部（`0x101198350`）：
/// ```asm
/// [x0 length]
/// cmp  x0, #0x19                 ; ★ 长度必须正好 25 字节
/// b.ne 跳过                       ;   否则整段逻辑不执行
/// ...
/// [x0 communicateKey]
/// cmp  x26, #0x20                ; communicateKey 字符串 = 32 字符
/// ...
/// sub  x2, x0, #0x8              ; location = 25 - 8 = 17
/// orr  w3, wzr, #0x8             ; length = 8
/// subdataWithRange:              ; ★ broadcastRandom = code[17..25)
/// mutableCopy
/// [x0 setBroadcastRandom:]
/// sub  x2, x0, #0xc              ; location = 25 - 12 = 13
/// orr  w3, wzr, #0x4             ; length = 4
/// subdataWithRange:              ; 另一字段 = code[13..17)
/// ```
///
/// ## 结论
/// | 字段 | 位置 | 长度 |
/// |---|---|---|
/// | **`broadcastRandom`** | `code[17..25)` | **8** |
/// | 另一字段（未命名）| `code[13..17)` | 4 |
///
/// ⚠️ **实测厂商数据只有 19 字节**，而这里要求 **25** —— 缺 6 字节。
/// 缺少部分来源未确认（怀疑在 `kCBAdvDataServiceData`，但无证据）。
/// 这是本文件**唯一的不确定项**，且已不影响主链路。
public enum TboxBroadcastCode {

    /// 广播码的期望总长度（反汇编 `cmp x0, #0x19`）
    public static let expectedLength = 25

    /// 解析结果
    public struct Parsed: Sendable {
        /// `code[17..25)`，8 字节 —— `01` 帧第一段的来源
        public let broadcastRandom: [UInt8]
        /// `code[13..17)`，4 字节
        public let trailing: [UInt8]
        /// 原始广播码
        public let raw: [UInt8]
    }

    /// 解析广播码。
    ///
    /// **严格要求 25 字节**（与反汇编一致）—— 长度不符时返回 `nil`，
    /// **不猜测、不补零**，因为车端也是这么判断的。
    public static func parse(_ code: [UInt8]) -> Parsed? {
        guard code.count == expectedLength else { return nil }
        return Parsed(broadcastRandom: Array(code[17..<25]),
                      trailing: Array(code[13..<17]),
                      raw: code)
    }

    /// 尝试用「厂商数据 + Service 数据」拼出 25 字节的广播码。
    ///
    /// - Returns: 拼够 25 字节时返回广播码；否则返回空数组（**不猜**）。
    public static func assemble(manufacturer: [UInt8], service: [UInt8]) -> [UInt8] {
        // ① 厂商数据本身就够
        if manufacturer.count == expectedLength { return manufacturer }
        // ② 厂商 + Service 拼接
        let combined = manufacturer + service
        if combined.count == expectedLength { return combined }
        // ③ Service 在前、厂商在后（有些实现顺序相反）
        let reversed = service + manufacturer
        if reversed.count == expectedLength { return reversed }
        return []
    }

    /// 诊断用：把候选拼接方式的可读描述打出来
    public static func describeCandidates(manufacturer: [UInt8], service: [UInt8]) -> String {
        func hex(_ b: [UInt8]) -> String {
            b.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        return """
        厂商=\u{200B}\(manufacturer.count)B  Service=\(service.count)B  合计=\(manufacturer.count + service.count)B（需要 \(expectedLength)B）
          mfg           : \(hex(manufacturer))
          svc           : \(hex(service))
          mfg+svc       : \(hex(manufacturer + service))
        """
    }
}
