import Foundation

/// **广播数据解析** —— 照 `-[IBDevice parseBroadcastData:]` 反汇编实现。
///
/// ## 反汇编证据（2026-10-24 二次复核，段偏移已取到）
/// `InBlue.framework`，`-[IBDevice parseBroadcastData:]` @`0x4bc0`：
/// ```objc
/// key   = [IBNSString stringToData:self.cidpu];        // hex 字符串 → 16 字节
/// plain = [VSSecurity decryptData:data withKey:key];  // AES-CBC / IV=0
/// randomNumber   = [plain subdataWithRange:NSMakeRange(0, 4)];
/// [self parseStatus:      [plain subdataWithRange:NSMakeRange(4, 1)]];  // 1 字节
/// oemID          = [plain subdataWithRange:NSMakeRange(5, 1)];
/// [self parseDoorsStatus: [plain subdataWithRange:NSMakeRange(6, 1)]];  // 1 字节
/// [self parsePowerStatus: [plain subdataWithRange:NSMakeRange(7, 1)]];  // 1 字节
/// additionalData = [plain subdataWithRange:NSMakeRange(8, 8)];
/// ```
/// 解密结果必然是 **16 字节**（一个 AES 块），故切分全部落在单块内。
///
/// ## ⚠️ 旧注释里有两处已被推翻，不要照着理解
/// 1. ~~"`01` 帧的 16 字节从广播解密得到"~~ —— 错。`01` 帧是
///    `AES(明文, CkTRxSP)`，与广播无关（见 `InBlueAuth`）。
/// 2. ~~"cidpu 是 4 字节"~~ —— 错。AES key 需 16 字节，完整值见
///    `KeyStore.cidpuFullHex`（= 密钥帧 `[46,62)`）。
public enum BroadcastParser {

    /// CIDPU 的完整值（32 hex = 16 字节）。
    ///
    /// 来源优先级见 `KeyStore.cidpuFullHex`；旧版本只存 4 字节时，
    /// 这里会退回到从密钥帧 `[46,62)` 补全。
    public static func cidpuFromStoredKey() -> String? {
        KeyStore.shared.cidpuFullHex
    }

    /// 从广播名解析尾部标识（**兜底展示用，不可用于密码学**）。
    ///
    /// `InBlue3f26c66ac89ad4` → 去掉 `INBLUE` 前缀后取**后 6 个 hex（3 字节）**。
    /// 这 3 字节是完整 `cidpu` 末 3 字节（已验证，`c89ad4` 与车辆详情页 CIDPU
    /// 末位一致），但**缺前 13 字节**，因此拿它当 AES key 必然失败 ——
    /// 只用于未配对时的界面提示。
    public static func parseCidpu(from name: String) -> String? {
        let upper = name.uppercased()
        guard upper.hasPrefix("INBLUE") else { return nil }
        let tail = String(upper.dropFirst(6))
        guard tail.count >= 6 else { return nil }
        return String(tail.suffix(6)).lowercased()
    }

    /// 用 cidpu 解密广播载荷，返回明文（失败返回空数组）。
    ///
    /// - 算法：**AES-CBC，无 padding**（`options = 0`）
    /// - IV：**全零**
    /// - key：`hexDecode(cidpu)`，必须 16 字节
    ///
    /// ⚠️ 旧实现用 `cidpu.data(using: .utf8)`（把 hex 字符的 ASCII 当 key），
    /// 导致解密必然失败 —— 已修正为 `FrameCodec.bytes(fromHex:)`。
    public static func parse(_ encrypted: [UInt8], cidpu: String) -> [UInt8] {
        guard !cidpu.isEmpty else { return [] }
        guard encrypted.count >= 16, encrypted.count % 16 == 0 else { return [] }
        guard let key = ValeoAdvMatch.cidpuAESKey(cidpu), key.count == 16 else { return [] }

        let iv = [UInt8](repeating: 0, count: 16)
        return (try? CryptoBox.aesDecrypt(.cbcNoPadding, key: key,
                                          iv: iv, cipher: encrypted)) ?? []
    }

    /// 把解密结果按"可能的"结构做一次宽松展示（诊断用）。
    ///
    /// ⚠️ 明文的**确切切分尚未从反汇编取到**（`subdataWithRange:` 的几个 range
    /// 是在运行时算的）。所以这里只做**只读展示**，不臆造字段含义 ——
    /// 先看清明文长什么样，再决定怎么切。
    public static func describe(_ plain: [UInt8]) -> String {
        guard !plain.isEmpty else { return "（解密失败或为空）" }
        let hex = plain.map { String(format: "%02X", $0) }.joined(separator: " ")
        var lines = ["明文长度 \(plain.count)B", hex]
        // 若含可打印 ASCII，顺便显示出来（设备名/ID 等常是 ASCII）
        let ascii = String(bytes: plain.map { ($0 >= 0x20 && $0 < 0x7F) ? $0 : 0x2E },
                           encoding: .ascii) ?? ""
        lines.append("ASCII: \(ascii)")
        return lines.joined(separator: "\n")
    }
}
