import Foundation
import CryptoKit
import CommonCrypto

/// 协议用到的密码学原语集合。
///
/// ## 逆向依据（全部来自 iOS `GLBLEAuthSDK` / `InBlue` 反汇编）
/// - **AES-128**：`+[GLAlgorithmManager aes_encrypt:plainData:iv:key:]` @`0x8650`
///   取 `plainData.length` / `iv.length` / `key.length` → `_malloc` → `dataWithBytes:length:`，
///   **未调用 CCCrypt/OpenSSL**，是框架自实现；ID 2 中 `sessionKey` = 16 字节 → **AES-128**；
///   因 `iv` 为独立入参且被使用，**非 ECB**（CBC 可能性最大）。
/// - **HMAC-SHA256**：`-[VCLSManager sha256HMacWithData:withKey:]` @`0x12c6c`
///   反汇编为 `CCHmacInit(kCCHmacAlgSHA256)` / `CCHmacUpdate` / `CCHmacFinal`。
/// - **SHA-256**：`-[NSData sha256]`（ID 1 确认帧用）。
///
/// ## ⚠️ 待实测确认
/// ID 2 里 `aes_encrypt` 的第 1 个参数为 `2`，语义未定（推测为模式/填充选项）。
/// 这里抽象成 `AESMode`，默认 `.cbcPKCS7`，实测后可切换。
public enum AESMode: String, Sendable, CaseIterable, Codable {
    case cbcPKCS7
    case cbcNoPadding
    case ecbPKCS7
    case ecbNoPadding
}

public enum CryptoBox {

    // MARK: - SHA-256

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    // MARK: - HMAC-SHA256

    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let k = SymmetricKey(data: Data(key))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(data), using: k)
        return Array(mac)
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(hmacSHA256(key: Array(key), data: Array(data)))
    }

    /// 直接走 CommonCrypto，和为逆向一致（`CCHmacInit/Update/Final`）。
    public static func hmacSHA256CommonCrypto(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        var ctx = CCHmacContext()
        key.withUnsafeBufferPointer { kp in
            CCHmacInit(&ctx, CCHmacAlgorithm(kCCHmacAlgSHA256), kp.baseAddress, key.count)
        }
        data.withUnsafeBufferPointer { dp in
            CCHmacUpdate(&ctx, dp.baseAddress, data.count)
        }
        CCHmacFinal(&ctx, &out)
        return out
    }

    // MARK: - AES

    /// AES 加/解密。密钥长度 16 → AES-128。
    public static func aes(
        _ mode: AESMode,
        encrypt: Bool,
        key: [UInt8],
        iv: [UInt8],
        input: [UInt8]
    ) throws -> [UInt8] {
        let algorithm: CCAlgorithm = CCAlgorithm(kCCAlgorithmAES)
        var options = CCOptions(0)
        switch mode {
        case .cbcPKCS7:
            options = CCOptions(kCCOptionPKCS7Padding)
        case .cbcNoPadding:
            options = 0
        case .ecbPKCS7:
            options = CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding)
        case .ecbNoPadding:
            options = CCOptions(kCCOptionECBMode)
        }

        let op: CCOperation = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)
        let outCapacity = input.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outCapacity)
        var moved = 0

        let status: CCCryptorStatus = key.withUnsafeBufferPointer { kp in
            iv.withUnsafeBufferPointer { ivp in
                input.withUnsafeBufferPointer { ip in
                    out.withUnsafeMutableBufferPointer { op_ in
                        CCCrypt(
                            op, algorithm, options,
                            kp.baseAddress, key.count,
                            mode.rawValue.hasPrefix("ecb") ? nil : ivp.baseAddress,
                            ip.baseAddress, input.count,
                            op_.baseAddress, outCapacity,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.aesFailed(status: Int32(status))
        }
        return Array(out[0..<moved])
    }

    public static func aesEncrypt(
        _ mode: AESMode = .cbcPKCS7, key: [UInt8], iv: [UInt8], plain: [UInt8]
    ) throws -> [UInt8] {
        try aes(mode, encrypt: true, key: key, iv: iv, input: plain)
    }

    public static func aesDecrypt(
        _ mode: AESMode = .cbcPKCS7, key: [UInt8], iv: [UInt8], cipher: [UInt8]
    ) throws -> [UInt8] {
        try aes(mode, encrypt: false, key: key, iv: iv, input: cipher)
    }

    // MARK: - 随机数

    /// 与框架一致：`arc4random`（`createANewKeyWithCidpu:` 内部就是它）。
    public static func randomBytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count { out[i] = UInt8.random(in: 0...255) }
        return out
    }

    public static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &out)
        if status != errSecSuccess {
            return randomBytes(count)
        }
        return out
    }
}

public enum CryptoError: Error, CustomStringConvertible {
    case aesFailed(status: Int32)
    case badKeyLength(Int)
    case notImplemented(String)

    public var description: String {
        switch self {
        case .aesFailed(let s): return "AES 操作失败 (CCCrypt status=\(s))"
        case .badKeyLength(let n): return "密钥长度不合法: \(n) 字节"
        case .notImplemented(let s): return "尚未实现: \(s)"
        }
    }
}
