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
}
