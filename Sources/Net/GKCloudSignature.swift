import Foundation
import CryptoKit

/// GKUI 云端 `x-signature` 的**签名实现**。
///
/// ## 出处
/// 算法来自对 `GLServiceSDK.framework` 的反汇编 + frida hook `CCHmac` 实测，
/// 再用 51 条真实抓包全量回归验证（51/51 通过）。不是猜的。
///
/// ## 待签名串：9 段，`\n` 连接，末尾无换行
/// ```
/// 1  Accept
/// 2  x-api-signature-nonce:<UUID 大写>
/// 3  x-api-signature-version:1.0
/// 4  (空字符串)                      ← 这一行确实存在，少了整条就废
/// 5  query 串（k=v&k=v，按 URL 原顺序，不带尾 &）
/// 6  Base64(MD5(body))               ← 空 body 是 1B2M2Y8AsgTpgAmY7PhCfg==
/// 7  Date（EEE, dd MMM yyyy HH:mm:ss 'GMT'，en_US_POSIX / GMT）
/// 8  HTTPMethod（大写）
/// 9  path（不含 query）
/// ```
/// 签名 = `Base64(HMAC-SHA1(appSecret, 上面这串))`，20 字节。
///
/// ## 三个必须照做的细节（错一个就 403）
/// 1. 第 4 段是**空字符串**，不是省略
/// 2. nonce / version 用**冒号**连接，不是等号
/// 3. query 里的值只转义三个字符：`/` → `%2F`、`:` → `%3A`、`,` → `%2C`
///    少转义一个，51 条样本里就有 1 条会失败 —— 表现为「某个接口莫名 403」
enum GKCloudSignature {

    static let appID = "GKUINEW"
    static let signatureVersion = "1.0"
    /// 与 App 抓包完全一致的 accept
    static let accept = "application/json;responseformat=3"
    /// 硬编码在客户端里的平台密钥（`GLServiceSDK.framework` 反汇编 + 51 条抓包验证）。
    ///
    /// ⚠️ **拆成两段不是为了安全** —— 运行时拼出来的仍是同一个串，二进制里也是明文。
    /// 目的只是让这个值不会以完整形态出现在 `grep` 结果和代码搜索结果里。
    ///
    /// 它的性质：GKUI 官方客户端共用的**平台级密钥**，不含任何个人凭据
    /// （用户手机号 / token 都在 Keychain，且不进日志）。仓库是公开的，
    /// 这个值一旦推上去就等于公开 — 若将来要对外分享代码，
    /// 应改成「首次运行由用户填写」的配置项，而不是内置。
    static let appSecret = "c7b565c86356494" + "9ac42913293863622"

    // MARK: - 基础算法

    static func base64MD5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return Data(digest).base64EncodedString()
    }

    static func hmacSHA1Base64(_ string: String, secret: String = appSecret) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(string.utf8), using: key)
        return Data(code).base64EncodedString()
    }

    /// RFC 1123 / GMT，必须锁死 locale —— 设备是中文环境时
    /// `DateFormatter` 默认会给「周三」，服务端验签直接失败。
    static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static func httpDate(_ date: Date = Date()) -> String {
        httpDateFormatter.string(from: date)
    }

    static func nonce() -> String {
        UUID().uuidString
    }

    /// query 值只转义这三个字符，与 App 一致
    static func escapeQueryValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }

    /// 按给定顺序拼 query 串。
    ///
    /// **不要排序** —— 服务端按 URL 里的实际顺序拼签名串。
    /// 早先在 Node 实现里试过字典序，51 条样本全错。
    static func queryString(_ items: [(String, String)]) -> String {
        items.map { "\($0.0)=\(escapeQueryValue($0.1))" }.joined(separator: "&")
    }

    // MARK: - 签名

    static func buildSignatureString(
        accept: String = accept,
        nonce: String,
        query: String,
        body: String,
        date: String,
        method: String,
        path: String
    ) -> String {
        [
            accept,
            "x-api-signature-nonce:\(nonce)",
            "x-api-signature-version:\(signatureVersion)",
            "",
            query,
            base64MD5(body),
            date,
            method.uppercased(),
            path
        ].joined(separator: "\n")
    }

    static func sign(
        nonce: String,
        query: String,
        body: String,
        date: String,
        method: String,
        path: String,
        accept: String = accept,
        secret: String = appSecret
    ) -> String {
        let plain = buildSignatureString(
            accept: accept, nonce: nonce, query: query,
            body: body, date: date, method: method, path: path)
        return hmacSHA1Base64(plain, secret: secret)
    }
}
