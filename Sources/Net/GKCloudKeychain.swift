import Foundation
import Security

/// 云端通道的机密存储（Keychain）。
///
/// ## 为什么单独一个文件
///
/// 密码的 MD5 与 access/refresh token 属于「拿了就能动车」的东西：
///
/// - 密码 MD5 可以离线撞库（明文强度未知，但 MD5 无盐会让字典攻击便宜很多）
/// - token 直接就是车控接口的通行证
///
/// 它们之前都躺在 `UserDefaults` 里 —— 会随 iCloud / iTunes 备份一起外流，
/// 任何能读到 App 沙盒的工具都能直接拿出来。注释里写着"存 Keychain"，
/// 但代码从来没这么做过（2026-11-04 审查发现）。
///
/// ## 可访问性为什么是 `AfterFirstUnlockThisDeviceOnly`
///
/// - `AfterFirstUnlock`：设备第一次解锁后可用，重启后未解锁时不可读。
///   选它而不是 `WhenUnlocked`，是因为车控请求可能在后台唤醒时发生，
///   而锁屏状态下 `WhenUnlocked` 会让请求失败。
/// - `ThisDeviceOnly`：**不进 iCloud / iTunes 备份**（2026-11-04 第二轮审查 M5）。
///
/// 少了 `ThisDeviceOnly` 的条目会随加密备份外流 —— 而本文件存在的全部理由
/// 就是"别让这两样东西离开设备"。之前这里只有 `AfterFirstUnlock`，
/// 等于把刚从 UserDefaults 搬出来的机密又交给了备份。
///
/// 代价：换机时不会自动带过去，用户要重新登录一次。这个交换是值得的。
/// ## 与 `KeyStore` 的分工（2026-11-04 第二轮审查 M17）
///
/// 项目里有两套 Keychain 封装，边界是：
///
/// | 封装 | 存什么 | 谁用 |
/// |---|---|---|
/// | `KeyStore`（Sources/Keychain） | **蓝牙钥匙**的长期密钥、配对信息 | 手机 + 手表（手表端已改纯云端后不再用） |
/// | `GKCloudKeychain`（本文件） | **云端账号**的密码 MD5、token | 手机 + 手表 |
///
/// 为什么没合并：两边的 service 名、可访问性策略、生命周期都不一样，
/// 强行抽一个通用层只会多一层间接。真正的风险不是"两套并存"，
/// 而是"改了一处以为另一处跟着变" —— 所以在这里把边界写死。
enum GKCloudKeychain {

    private static let service = "com.mmxisme.gkuiblekey.gkcloud"

    /// 账号名（同 service 下的区分键）
    enum Account: String {
        /// 密码 MD5
        case passMD5 = "passMD5"
        /// access + refresh + 过期时间（打包成一段 JSON）
        case token = "token"
    }

    /// 写入。**返回是否成功** —— 失败必须让调用方知道（2026-11-04 第二轮审查 M4）。
    ///
    /// 之前这里把 `SecItemAdd` 的返回值直接丢掉，`SecItemUpdate` 除了
    /// `errSecItemNotFound` 之外的错误码也不处理。结果是：写失败时静默，
    /// 用户以为密码存好了，下次冷启动却要重配，而且日志里一条线索都没有。
    @discardableResult
    static func set(_ value: String, for account: Account) -> Bool {
        guard let data = value.data(using: .utf8) else {
            FileLogger.shared.error("Keychain 写入失败：\(account.rawValue) 无法编码为 UTF-8",
                                    module: "KEYCHAIN")
            return false
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else {
            logFailure("update", account, updateStatus)
            return false
        }

        var add = query
        add.merge(attrs) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logFailure("add", account, addStatus)
            return false
        }
        return true
    }

    /// Keychain 的错误码是数字，日志里不翻译基本没法查
    private static func logFailure(_ op: String, _ account: Account, _ status: OSStatus) {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        FileLogger.shared.error(
            "Keychain \(op) 失败：\(account.rawValue) status=\(status) (\(detail))",
            module: "KEYCHAIN")
    }

    static func string(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
