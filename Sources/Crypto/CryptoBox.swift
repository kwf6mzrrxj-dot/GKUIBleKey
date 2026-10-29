import Foundation
import CryptoKit
import CommonCrypto

/// 协议用到的密码学原语集合。
///
/// ## 逆向依据
/// - **AES**：InBlue 的 `+[IBAESData AES128WithData:withKey:encrypt:cbc:option:]` @`0x10cac`
///   反汇编为 `CCCrypt(op, kCCAlgorithmAES, options=0, iv=NULL)` —— 即
///   **AES-128-CBC / IV 全零 / 无 padding**（`options=0`）。这是 InBlue 协议
///   （`01`/`03` 帧、广播解密、归属校验）唯一使用的 AES 模式。
/// - **HMAC-SHA256**：`-[VCLSManager sha256HMacWithData:withKey:]` @`0x12c6c`
///   反汇编为 `CCHmacInit(kCCHmacAlgSHA256)` / `CCHmacUpdate` / `CCHmacFinal`。
/// - **SHA-256**：`-[NSData sha256]`（ID 1 确认帧用）。
///
/// ⚠️ 早期的「GLBLEAuthSDK 自实现 AES / 默认 cbcPKCS7」是旧结论，已作废：
/// 实际协议全部走 InBlue 的 `CCCrypt` CBC 无 padding，调用点已显式传 `.cbcNoPadding`。
public enum AESMode: String, Sendable, CaseIterable, Codable {
    case cbcPKCS7
    case cbcNoPadding
    case ecbNoPadding
}

public enum CryptoBox {

    // MARK: - SHA-256

    public static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }

    // MARK: - HMAC-SHA256

    public static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let k = SymmetricKey(data: Data(key))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(data), using: k)
        return Array(mac)
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

    /// 非安全随机数（用系统 `UInt8.random`），仅作兜底。
    /// 协议关键随机数请用 `secureRandomBytes`（SecRandomCopyBytes）。
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

    public var description: String {
        switch self {
        case .aesFailed(let s): return "AES 操作失败 (CCCrypt status=\(s))"
        }
    }
}
