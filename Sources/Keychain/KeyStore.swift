import Foundation
import Security
#if os(iOS)
import UIKit
#endif

/// 密钥与凭据的持久化。
///
/// ## 逆向依据
/// - iOS 侧 Keychain 键名复用了原 App（`GLBLEAuthSDK`）的字符串，
///   如 `com.glble.sdk.communication.key` / `com.glble.sdk.core`。
/// - Keychain 封装方法：`VKsave:data:` / `VKgetKeychainQuery:` / `VKdelete:`
/// - **重要**：`GLBLEStorageManager` 走的是 `NSUserDefaults`（`+[GLBLEStorageManager
///   saveStorage:forKey:]` → `[NSUserDefaults standardUserDefaults] setObject:forKey:`），
///   只存普通配置；**密钥必须走 Keychain**。
///
/// ## IDFV（mobileId）
/// 原 App 用 `VKsaveIdfvToKeyChain:` 把 IDFV 存进 Keychain（`VKKeychainIDFV`），
/// 作为 `mobileID` 使用。本 App 采用同样的持久化策略：首次取
/// `identifierForVendor` 后写入 Keychain，之后一律读 Keychain —— 这样即使
/// 卸载重装（IDFV 会被系统重置）也不会变。
///
/// **适用范围（重要，避免误判）**：
/// - `mobileID` 属于 **GLBLEAuthSDK / 云端接口**层的设备标识
///   （对应 `error_sdk_50003 数字钥匙校验mobileId错误`）；
/// - **BLE 协议帧里没有这个字段** —— `0x0D` = `命令 + sidpu(16) + 名称(20)`，
///   `0x01` = `sd+ed+RndTRx+RND1+rights` 五段，都不含 mobileId。
///
/// 因此本 App 的 `idfvDisplay` 目前**只用于界面展示**，不参与任何 BLE 交互；
/// 「IDFV 与原 App 不同」不会影响配对或控车的 BLE 链路。
public final class KeyStore {

    public nonisolated(unsafe) static let shared = KeyStore()
    private init() {}

    // MARK: - Keychain 键名（与原 App 保持一致，便于从旧 App 迁移）

    public enum Key: String, CaseIterable {
        // ★ 复用了原 App（GLBLEAuthSDK）的键名：communicationKey 存 CkTRxSP、
        //   core 存完整密钥帧（InBlue 密钥体系的字段）。
        case communicationKey = "com.glble.sdk.communication.key"
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
            // ★ 删除/更新时匹配「任意同步状态」的旧记录（同步项 + 本地项），
            //   否则旧的 ThisDeviceOnly 记录删不掉 → SecItemAdd 报 duplicate。
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
        attrs[kSecAttrSynchronizable as String] = kCFBooleanTrue as CFBoolean
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // 已存在（可能是旧的 ThisDeviceOnly 记录）→ 直接更新
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecAttrSynchronizable as String: kCFBooleanTrue as CFBoolean,
            ]
            // ★ 更新时用「任意同步状态」匹配，确保能命中旧的非同步项
            var updateQuery = query
            updateQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, update as CFDictionary)
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

    // MARK: - 原 App 兼容存储（`IBSavedKeys` + NSKeyedArchiver）

    /// 以与原 App **完全相同**的格式写一份密钥字典。
    ///
    /// ## 反汇编依据
    /// `-[VCLSManager saveKeysData:]` @`0x12660` 末尾：
    /// ```asm
    /// 0x12a2c: adr x3, #0x212e8     ; CFSTR "IBSavedKeys"
    /// 0x12a28: bl  ... storeDictionary:toKeychainWithKey:
    /// ```
    /// `+[IBKeyChainManager storeDictionary:toKeychainWithKey:]` @`0x131b4`：
    /// ```objc
    /// NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:dictionary];
    /// [self deleteFromKeychainWithKey:key];            // 先删旧值
    /// SecItemAdd(@{ kSecClass:      kSecClassGenericPassword,
    ///               kSecAttrService: key,
    ///               kSecAttrAccount: key,
    ///               kSecValueData:  archived }, NULL);
    /// ```
    ///
    /// ## 结构
    /// `saveKeysData:` 里 `setObject:forKey:` 的两个参数是
    /// `x2 = 七元子字典`、`x3 = hexString(frame[0x2E,0x10])`，因此外层是
    /// `{ "<cidpu32hex>" : { Dk1, sd, ed, RndTRx, rights, keyType, CkTRxSP } }`，
    /// 7 个值**全部是 hex 字符串**（`hexString:` 转换，非原始字节）。
    ///
    /// ## 为什么双写
    /// 本 App 的主存储是「一字段一 Keychain 项」（`service = com.glble.sdk.core`），
    /// 这套格式已稳定工作，**不替换**；这里额外写一份 `IBSavedKeys` 归档，
    /// 好处是：抓包/比对原 App 行为时可直接读出同构数据，且将来若需迁移不用再改协议层。
    public func setIBSavedKeysArchive(_ keysData: [String: [String: String]]) {
        guard let archived = try? NSKeyedArchiver.archivedData(
            withRootObject: keysData, requiringSecureCoding: false
        ) else {
            NSLog("[KeyStore] IBSavedKeys 归档失败")
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "IBSavedKeys",
            kSecAttrAccount as String: "IBSavedKeys",
        ]
        // 原 App 先 delete 再 add，保持一致
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData as String] = archived
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[KeyStore] IBSavedKeys 写入失败: \(status)")
        }
    }

    public func getString(_ key: Key) -> String? {
        get(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - mobileID（= IDFV）

    /// 用于界面展示的 IDFV 原文。
    @MainActor
    public var idfvDisplay: String {
        if let s = getString(.idfv) { return s }
        // watchOS 没有 UIDevice（UIKit 里这个类被裁剪掉了），
        // 手表端不需要 IDFV 上送，给个固定占位即可。
        #if os(iOS)
        let s = UIDevice.current.identifierForVendor?.uuidString ?? "未知"
        #else
        let s = "watch"
        #endif
        setString(s, for: .idfv)
        return s
    }

    // MARK: - 便捷访问

    // `self.get(...)` —— 必须显式写 self，否则 `get` 会被解析为 getter 关键字
    public var communicationKey: [UInt8]? { self.get(.communicationKey).map { Array($0) } }
    /// ★ 16 字节通信密钥材料（`saveKeysData:` 的 `CkTRxSP` 字段）
    public var ckTRxSP: [UInt8]? { self.get(.ckTRxSP).map { Array($0) } }

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
