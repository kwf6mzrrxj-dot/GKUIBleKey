import Foundation

/// 字节/十六进制转换工具。
///
/// ## 2026-10-24 精简
/// 这里原本还有一整套 `FE 01` 帧的编解码（`DKFrame`/`encode`/`decode`/
/// `tryExtractFrame` + CRC16）。那套协议基于早期假设，**实测链路从不使用**：
/// 真实帧是 InBlue 的 `[cmdId][payload]`，没有帧头、没有 CRC。
///
/// 那些函数已随 `CRC16.swift`、`DKCommand`、`FrameLayout` 一并删除。
/// 保留本枚举只因为它提供两个被全项目依赖的转换函数。
public enum FrameCodec {

    /// 字节 → 大写十六进制（默认空格分隔）
    public static func hexString(_ bytes: [UInt8], separator: String = " ") -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: separator)
    }

    /// 十六进制字符串 → 字节。容错：忽略空格与 `0x`。
    ///
    /// 与 `+[IBNSString stringToData:]` @`0x111c0` 等价（每 2 字符 `strtoul` 一次）。
    public static func bytes(fromHex hex: String) -> [UInt8] {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "")
        var result: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let b = UInt8(cleaned[idx..<next], radix: 16) { result.append(b) }
            idx = next
        }
        return result
    }
}
