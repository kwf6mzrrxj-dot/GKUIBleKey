import Foundation
import Security
import UIKit

/// 密钥与凭据的持久化。
///
/// ## 逆向依据
/// - iOS 侧 Keychain 键名（`GLBLEAuthSDK` 字符串）：
///   `com.glble.sdk.communication.key` / `com.glble.sdk.auth.key` /
///   `com.glble.sdk.ID.key` / `com.glble.sdk.core`
/// - Keychain 封装方法：`VKsave:data:` / `VKgetKeychainQuery:` / `VKdelete:`
/// - **重要**：`GLBLEStorageManager` 走的是 `NSUserDefaults`（`+[GLBLEStorageManager
///   saveStorage:forKey:]` → `[NSUserDefaults standardUserDefaults] setObject:forKey:`），
///   只存普通配置；**密钥必须走 Keychain**。
///
/// ## mobileID = IDFV
/// `+[GLBLEKeyManager mobileID]`（`0xba54`）反汇编：
/// ```
/// ba70  ldr x1, VKKeychainIDFV
/// ba74  bl  +[UIDevice VKKeychainIDFV]      ; 取 IDFV
/// ba88  dataUsingEncoding:
/// baa4  subdataWithRange:                   ; 截取一段
/// ```
/// 且 IDFV 本身也被 `VKsaveIdfvToKeyChain:` 存进 Keychain。
/// **IDFV 对「同一开发者签名 + 同一设备」稳定** —— 因此重写 App 必须保持
/// **相同 bundle id 与相同签名证书（Team）**，否则 `mobileId` 变化会导致
/// 车端返回 `error_sdk_50003 数字钥匙校验mobileId错误`。
public final class KeyStore {

    public nonisolated(unsafe) static let shared = KeyStore()
    private init() {}

    // MARK: - Keychain 键名（与原 App 保持一致，便于从旧 App 迁移）

    public enum Key: String, CaseIterable {
        // ★ 原 App（GLBLEAuthSDK）真实存在的 4 个键名，保留以便从旧 App 迁移。
        case communicationKey = "com.glble.sdk.communication.key"
        case authKey = "com.glble.sdk.auth.key"
        case idKey = "com.glble.sdk.ID.key"
        case core = "com.glble.sdk.core"
        /// IDFV（原 App 用 `VKKeychainIDFV` 存放）
        case idfv = "com.glble.sdk.idfv"

        // ★★ 以下来自 `-[VCLSManager saveKeysData:]` @0x12660 的字段切分。
        //    原 App 把这 7 个字段（Dk1/sd/ed/RndTRx/rights/keyType/CkTRxSP）
        //    分别存进 Keychain，另加 tail（[46,62) 的 16 字节）与 CIDPU。
        /// 起始标识（反汇编 location=17, length=4）
        case sd = "com.glble.sdk.sd"
        /// 结束标识（反汇编 location=21, length=4）
        case ed = "com.glble.sdk.ed"
        /// 通信密钥材料（反汇编 location=30, length=16 —— `01` 帧的 AES 密钥）
        case ckTRxSP = "com.glble.sdk.cktrxsp"
        /// 车端随机数（反汇编 location=25, length=3）
        case rndTRx = "com.glble.sdk.rndtrx"
        /// 数字钥匙（反汇编 location=1, length=16 —— `03` 帧派生临时密钥的根）
        case dk1 = "com.glble.sdk.dk1"
        /// 权限位（反汇编 location=28, length=1）
        case rights1 = "com.glble.sdk.rights1"
        /// 钥匙类型（反汇编 location=29, length=1）
        case keyType = "com.glble.sdk.keytype"
        /// 密钥帧偏移 46..62 的尾部 16 字节（末 4 字节是 CIDPU）
        case keyTail = "com.glble.sdk.keytail"
        /// 配对后确定的 CIDPU（32 hex 字符串，`keysData` 的字典键）
        case pairedCIDPU = "com.glble.sdk.paired.cidpu"
        /// 密钥指纹（用于检测本地密钥被篡改）
        case integrityFingerprint = "com.glble.sdk.integrity.fingerprint"
    }

    private let service = "com.glble.sdk.core"

    // MARK: - 基础读写

    public func set(_ data: Data, for key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        SecItemDelete(query as CFDictionary)

        var attrs = query
        attrs[kSecValueData as String] = data
        // ★★★ 可访问性 + 同步策略 —— 直接决定"重装/换机后密钥还在不在"。
        //
        // 之前用的是 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，
        // 后缀 `ThisDeviceOnly` 表示**不参与 iCloud Keychain 同步、也不进备份**，
        // 所以：
        //   - 卸载重装 → 密钥丢失，必须重新配对
        //   - 换手机     → 密钥丢失
        //
        // 现在改成：
        //   1. `kSecAttrAccessibleAfterFirstUnlock`（去掉 ThisDeviceOnly）→ 可进备份
        //   2. `kSecAttrSynchronizable = true` → 通过 iCloud Keychain 同步到同账号设备
        //
        // 这样**升级/重装 App 后密钥仍在**，不必重新配对。
        // ⚠️ 前提：用户的「iCloud 钥匙串」是开启的。
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attrs[kSecAttrSynchronizable as String] = kCFBooleanTrue as CFBoolean
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // 已存在（可能是旧的 ThisDeviceOnly 记录）→ 直接更新
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: kCFBooleanTrue as CFBoolean,
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus != errSecSuccess {
                NSLog("[KeyStore] 更新失败 \(key.rawValue): \(updateStatus)")
            }
            return
        }
        if status != errSecSuccess {
            NSLog("[KeyStore] 写入失败 \(key.rawValue): \(status)")
        }
    }

    public func get(_ key: Key) -> Data? {
        // ★ 查询必须同时覆盖「同步项」与「本地项」：
        //   kSecAttrSynchronizable = kSecAttrSynchronizableAny 才能两者都查到，
        //   否则用 true 查会漏掉升级前写入的本地项，用 false 查会漏掉同步项。
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    public func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func setString(_ value: String, for key: Key) {
        set(Data(value.utf8), for: key)
    }

    public func getString(_ key: Key) -> String? {
        get(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setUInt32(_ value: UInt32, for key: Key) {
        var v = value.littleEndian
        set(Data(bytes: &v, count: 4), for: key)
    }

    public func getUInt32(_ key: Key) -> UInt32? {
        guard let d = get(key), d.count == 4 else { return nil }
        return d.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    // MARK: - mobileID（= IDFV）

    /// 取 mobileID。优先用 Keychain 里缓存的 IDFV
    /// （与原 App 行为一致：IDFV 会被 `VKsaveIdfvToKeyChain:` 存起来）。
    @MainActor
    public func mobileID() -> Data {
        if let cached = getString(.idfv), let d = cached.data(using: .utf8) {
            // 原 App 做了 subdataWithRange 截取；这里保持一致：取前 16 字节
            return d.count >= 16 ? Data(d.prefix(16)) : d
        }
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        setString(idfv, for: .idfv)
        let d = Data(idfv.utf8)
        return d.count >= 16 ? Data(d.prefix(16)) : d
    }

    /// 用于界面展示的 IDFV 原文。
    @MainActor
    public var idfvDisplay: String {
        if let s = getString(.idfv) { return s }
        let s = UIDevice.current.identifierForVendor?.uuidString ?? "未知"
        setString(s, for: .idfv)
        return s
    }

    // MARK: - 便捷访问

    // `self.get(...)` —— 必须显式写 self，否则 `get` 会被解析为 getter 关键字
    public var communicationKey: [UInt8]? { self.get(.communicationKey).map { Array($0) } }
    /// ★ 16 字节通信密钥材料（`saveKeysData:` 的 `CkTRxSP` 字段）
    public var ckTRxSP: [UInt8]? { self.get(.ckTRxSP).map { Array($0) } }
    public var identityKey: [UInt8]? { self.get(.idKey).map { Array($0) } }
    public var isPaired: Bool { self.get(.communicationKey) != nil }

    /// ★ 完整的 CIDPU（32 hex = 16 字节）—— `checkCryptedID` 的 AES key。
    ///
    /// 来源优先级：
    /// 1. `pairedCIDPU`（新版本按 tail 存了 32 hex）
    /// 2. `keyTail`（旧版本只存了 4 字节，用密钥帧 [46,62) 补全）
    ///
    /// 三条独立来源能互证同一串：
    /// `tail = 01 91 8D 11 30 D9 B8 75 E5 3F 26 C6 6A C8 9A D4`
    /// - 末 4 字节 `6ac89ad4` = 车辆详情页显示值
    /// - `[9,16)` = `3f26c66ac89ad4` = 设备名后缀
    public var cidpuFullHex: String? {
        if let s = getString(.pairedCIDPU), s.count >= 32 {
            return String(s.prefix(32)).lowercased()
        }
        if let tail = get(.keyTail).map({ Array($0) }), tail.count == 16 {
            return tail.map { String(format: "%02x", $0) }.joined()
        }
        if let s = getString(.pairedCIDPU), !s.isEmpty {
            return s.lowercased()        // 旧格式（8 hex），仅用于显示
        }
        return nil
    }

    /// 界面显示用的短 CIDPU（后 8 位）
    public var cidpuDisplayHex: String? {
        cidpuFullHex.map { String($0.suffix(8)) }
    }

    public func clearAll() {
        for k in Key.allCases { delete(k) }
    }

    // MARK: - ★ 备份 / 恢复（升级或换机时保住密钥）

    /// 导出全部密钥为一段可保存的文本（Base64）。
    ///
    /// 用途：**iCloud 钥匙串没开、或要换手机**时的兜底备份。
    /// 把它复制到备忘录/文件里保存，重装 App 后粘贴回来即可恢复，
    /// **不必重新配对**。
    public func exportBackup() -> String {
        var payload: [String: String] = [:]
        for k in Key.allCases {
            if let d = self.get(k), !d.isEmpty {
                payload[k.rawValue] = d.base64EncodedString()
            }
        }
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return "" }
        return json.base64EncodedString()
    }

    /// 从 `exportBackup()` 的文本恢复。返回成功写入的条目数。
    @discardableResult
    public func importBackup(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = Data(base64Encoded: trimmed),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: String]
        else { return 0 }

        var n = 0
        for (name, b64) in obj {
            guard let key = Key(rawValue: name),
                  let data = Data(base64Encoded: b64), !data.isEmpty else { continue }
            set(data, for: key)
            n += 1
        }
        return n
    }

    /// 备份文本的条目数（供界面显示"已备份几项"）
    public var backupItemCount: Int {
        Key.allCases.reduce(0) { acc, k in
            acc + ((self.get(k)?.isEmpty == false) ? 1 : 0)
        }
    }
}
