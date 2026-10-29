import Foundation

/// InBlue 鉴权算法（`01` / `03` 帧）—— 逐条对照反汇编还原。
///
/// ## 证据链（`InBlue.framework`，符号表完整，`cryptid=0`）
///
/// | 函数 | 地址 | 作用 |
/// |---|---|---|
/// | `+[IBMessageFactory derivationParametersMessageWithCidpu:]` | `0x13794` | `01` 帧外壳 = `[0x01] + 32B` |
/// | `+[IBMessageFactory responseMessageWithCommand:randomData:cidpu:]` | `0x13904` | `03` 帧外壳 = `[0x03] + 16B + cmd` |
/// | `-[VCLSManager requestParametersforCidpu:]` | `0x11bec` | `01` 的 32 字节载荷 |
/// | `-[VCLSManager calculateResponseforCidpu:randomData:command:]` | `0x12050` | `03` 的 16 字节载荷 |
/// | `-[VCLSManager saveKeysData:]` | `0x12660` | `0x0E` 密钥帧切分 |
/// | `+[IBAESData AES128WithData:withKey:encrypt:cbc:option:]` | `0x10cac` | AES 参数（`CCCrypt`）|
/// | `+[IBNSString stringToData:]` | `0x111c0` | **hex 字符串 → 字节**（`strtoul` 每 2 字符）|
/// | `+[IBNSData reverseData:]` | `0xe6fc` | 整体字节反转 |
/// | `+[IBNSData setNot:]` | `0xe4b4` | 逐字节按位取反（`mvn`）|
///
/// ## AES 参数（`0x10cac` 反汇编直接读出）
/// ```
/// x0 = encrypt ^ 1              → op（加密时 = 0 = kCCEncrypt）
/// x1 = 0                        → alg = kCCAlgorithmAES
/// x2 = option 参数              → options = 0（CBC、无 padding）
/// x5 = iv                       → cbc=0 时传 NULL → 全零 IV
/// ```
/// 即 **AES-128-CBC、IV 全零、无 padding**。
///
/// ## 一句话总结
/// `01` 帧把「长期密钥材料」用 `CkTRxSP` 加密后交给车端，车端回 16 字节挑战；
/// `03` 帧用 `Dk1` + 本次随机数派生的临时密钥 `enc1` 对挑战做变换后回传，
/// 归一化的控制码附在末尾。
public enum InBlueAuth {

    // MARK: - 常量

    /// `0x11f24` 处 `adr x2, CFSTR "628f073114ec49c78097e189ce8d2f92"`。
    ///
    /// `01` 帧第二段的明文就是这个固定 16 字节，密钥是 `CkTRxSP`。
    /// 因此**同一把钥匙下第二段恒等** —— 与真机抓包（20 余次会话第二段全是
    /// `7f267f6aff052051092931d42b9c88e3`）完全吻合。
    public static let constantKeyHex = "628f073114ec49c78097e189ce8d2f92"
    public static let constantKey: [UInt8] = FrameCodec.bytes(fromHex: constantKeyHex)

    /// 密钥帧总长（含命令号）。
    public static let keyFrameLength = 62

    // MARK: - 密钥材料

    /// `-[VCLSManager saveKeysData:]` @`0x12660` 切出的 6 个字段。
    ///
    /// 反汇编里每个字段都是
    /// `[frame subdataWithRange:NSMakeRange(loc, len)]` → `hexString:` →
    /// `setObject:forKey:`，**location 以含命令号的帧头为基准**。
    ///
    /// | 字段 | location | length | 本结构中的成员 |
    /// |---|---|---|---|
    /// | `Dk1`     | `0x01` = 1  | `0x10` = 16 | `dk1` |
    /// | `sd`      | `0x11` = 17 | 4           | `sd` |
    /// | `ed`      | `0x15` = 21 | 4           | `ed` |
    /// | `RndTRx`  | `0x19` = 25 | 3           | `rndTRx` |
    /// | `rights`  | `0x1C` = 28 | 1           | `rights` |
    /// | `keyType` | `0x1D` = 29 | 1           | `keyType` |
    /// | `CkTRxSP` | `0x1E` = 30 | 16          | `ckTRxSP` |
    ///
    /// 之后 `0x2E`(46) 起还有一段 16 字节（末 4 字节 = CIDPU）。
    public struct Keys: Sendable, Equatable {
        /// 帧偏移 1..17 —— `03` 帧派生临时密钥的根
        public var dk1: [UInt8]
        /// 帧偏移 17..21
        public var sd: [UInt8]
        /// 帧偏移 21..25
        public var ed: [UInt8]
        /// 帧偏移 25..28
        public var rndTRx: [UInt8]
        /// 帧偏移 28..29
        public var rights: [UInt8]
        /// 帧偏移 29..30
        public var keyType: [UInt8]
        /// 帧偏移 30..46 —— `01` 帧加密用的长期密钥
        public var ckTRxSP: [UInt8]
        /// 帧偏移 46..62 —— **同时是 `keysData` 的字典键（cidpu）**
        public var tail: [UInt8]
        /// CIDPU 原始 16 字节 —— 与 `tail` 相同。
        ///
        /// 依据：`saveKeysData:` @`0x129f4` 的 `setObject:forKey:`
        /// 把 `hexString(subdataWithRange:(0x2E,0x10))` 当作 key 存进 `_keysData`。
        public var cidpu: [UInt8]

        public init(
            dk1: [UInt8], sd: [UInt8], ed: [UInt8], rndTRx: [UInt8],
            rights: [UInt8], keyType: [UInt8], ckTRxSP: [UInt8],
            tail: [UInt8], cidpu: [UInt8]
        ) {
            self.dk1 = dk1; self.sd = sd; self.ed = ed; self.rndTRx = rndTRx
            self.rights = rights; self.keyType = keyType; self.ckTRxSP = ckTRxSP
            self.tail = tail; self.cidpu = cidpu
        }

        public var cidpuHex: String {
            cidpu.map { String(format: "%02x", $0) }.joined()
        }

        /// 供界面/日志展示
        public var summary: String {
            "Dk1=\(FrameCodec.hexString(dk1)) sd=\(FrameCodec.hexString(sd)) "
            + "ed=\(FrameCodec.hexString(ed)) RndTRx=\(FrameCodec.hexString(rndTRx)) "
            + "rights=\(FrameCodec.hexString(rights)) keyType=\(FrameCodec.hexString(keyType)) "
            + "CkTRxSP=\(FrameCodec.hexString(ckTRxSP))"
        }
    }

    // MARK: - 密钥帧解析

    /// 解析 `0x0E` 密钥帧（`frame` **含**命令号，长度 62）。
    ///
    /// 每个字段的 `location/length` 直接来自
    /// `-[VCLSManager saveKeysData:]` @`0x12660` 里的 `subdataWithRange:` 立即数，
    /// 键名来自紧随其后的 `CFSTR`：
    ///
    /// | 键名 | `subdataWithRange` | 证据 |
    /// |---|---|---|
    /// | `Dk1` | `(1, 0x10)` | `0x12810: mov w2,#1 ; 0x12814: mov w3,#0x10` |
    /// | `sd` | `(0x11, 4)` | `0x126c4: mov w2,#0x11 ; 0x126c8: mov w3,#4` |
    /// | `ed` | `(0x15, 4)` | `0x1271c: mov w2,#0x15` |
    /// | `CkTRxSP` | `(0x1E, 0x10)` | `0x1276c: mov w2,#0x1e ; 0x12770: mov w3,#0x10` |
    /// | `RndTRx` | `(0x19, 3)` | `0x127c0: mov w2,#0x19` |
    /// | `rights` | `(0x1C, 1)` | `0x12860: mov w2,#0x1c` |
    /// | `keyType` | `(0x1D, 1)` | `0x128b0: mov w2,#0x1d` |
    /// | *(字典键)* | `(0x2E, 0x10)` | `0x129a4: mov w2,#0x2e` |
    ///
    /// 最后一段 `(0x2E, 0x10)` **不是值而是键**：`0x129f4` 的
    /// `setObject:forKey:` 里 `x2 = 七元子字典`、`x3 = hexString(该 16 字节)`，
    /// 即 `keysData[cidpu] = {Dk1, sd, ed, CkTRxSP, RndTRx, rights, keyType}`。
    /// 所以 **cidpu 就是这 16 字节的 hex 字符串**（32 字符）。
    public static func parseKeyFrame(_ input: [UInt8]) -> Keys? {
        let frame: [UInt8]
        if input.first == 0x0E {
            frame = input
        } else {
            frame = [0x0E] + input
        }
        guard frame.count >= keyFrameLength else { return nil }

        func slice(_ loc: Int, _ len: Int) -> [UInt8] {
            guard loc >= 0, len > 0, loc + len <= frame.count else { return [] }
            return Array(frame[loc..<(loc + len)])
        }

        let tail = slice(0x2E, 0x10)
        return Keys(
            dk1: slice(0x01, 0x10),
            sd: slice(0x11, 4),
            ed: slice(0x15, 4),
            rndTRx: slice(0x19, 3),
            rights: slice(0x1C, 1),
            keyType: slice(0x1D, 1),
            ckTRxSP: slice(0x1E, 0x10),
            tail: tail,
            cidpu: tail
        )
    }

    // MARK: - 01 帧

    /// `01` 帧明文里 5 段的顺序 —— **已由反汇编完全确定，只有一个答案**。
    ///
    /// `-[VCLSManager requestParametersforCidpu:]` @`0x11bec`：
    /// ```asm
    /// 0x11cd4: adr x2, #0x21368      ; "sd"     → 存 [sp+0x30]
    /// 0x11d0c: adr x2, #0x21388      ; "ed"     → 存 x28
    /// 0x11d4c: adr x2, #0x213a8      ; "RndTRx" → 存 x23
    /// 0x11d6c: @selector(RND1)       ;          → 存 x24
    /// 0x11da4: adr x2, #0x213c8      ; "rights" → 存 x27
    /// 0x11dc4: @selector(stringWithFormat:)
    /// 0x11dd0: ldr x20, [sp, #0x30]  ; sd
    /// 0x11dd4: str x20, [sp]         ; vararg1 = sd
    /// 0x11dcc: stp x28, x23, [sp,#8] ; vararg2 = ed,      vararg3 = RndTRx
    /// 0x11dc8: stp x24, x0,  [sp,#0x18] ; vararg4 = RND1, vararg5 = rights
    /// 0x11ddc: adr x2, #0x21348      ; CFSTR "%@%@%@%@%@"
    /// ```
    /// 栈参数区从 `sp+0` 起按顺序排列，因此拼接顺序是
    /// **sd → ed → RndTRx → RND1 → rights**。

    public struct FirstMessage: Sendable {
        /// 完整帧（33 字节，含命令号 `0x01`）
        public var frame: [UInt8]
        /// 本次使用的 4 字节随机数（`VCLSManager.RND1` 的原始字节）
        public var rnd1: [UInt8]
        /// 第一段（随 RND1 变化）
        public var segment1: [UInt8]
        /// 第二段（同一把钥匙下恒定）
        public var segment2: [UInt8]
        /// 参与加密的 16 字节明文，便于日志对照
        public var plain: [UInt8]
    }

    /// 构造 `01` 帧 —— 对应 `-[VCLSManager requestParametersforCidpu:]` @`0x11bec`。
    ///
    /// ```objc
    /// rnd4 = [self randomDataWithBytes:4];        // 4 字节随机
    /// RND1 = [IBNSData hexString:rnd4];           // 8 个 hex 字符
    /// str  = [NSString stringWithFormat:@"%@%@%@%@%@", sd, ed, RndTRx, …, …];
    /// data = [IBNSString stringToData:str];       // hex → 16 字节
    /// seg1 = [IBAESData AES128EncryptWithData:data withKey:ckTRxSPBytes];
    /// seg2 = [IBAESData AES128EncryptWithData:constantBytes withKey:ckTRxSPBytes];
    /// return [seg1 mutableCopy] + seg2;           // 32 字节
    /// ```
    ///
    /// 注意：`RND1` 是 **hex 字符串**再被整体 `stringToData:` 解码，
    /// 所以最终明文里放的就是那 4 个原始字节本身。
    public static func buildFirstMessage(
        keys: Keys,
        rnd1: [UInt8]? = nil
    ) throws -> FirstMessage {
        guard keys.ckTRxSP.count == 16 else {
            throw InBlueAuthError.badKeyLength(field: "CkTRxSP", expected: 16, actual: keys.ckTRxSP.count)
        }
        guard keys.sd.count == 4, keys.ed.count == 4, keys.rndTRx.count == 3, keys.rights.count == 1 else {
            throw InBlueAuthError.badKeyFrame("sd/ed/RndTRx/rights 长度不符（期望 4/4/3/1）")
        }

        let r = rnd1 ?? CryptoBox.secureRandomBytes(4)
        guard r.count == 4 else {
            throw InBlueAuthError.badKeyLength(field: "RND1", expected: 4, actual: r.count)
        }

        // 顺序固定：sd → ed → RndTRx → RND1 → rights（反汇编 requestParametersforCidpu: 的栈布局）
        let plain: [UInt8] = keys.sd + keys.ed + keys.rndTRx + r + keys.rights
        guard plain.count == 16 else {
            throw InBlueAuthError.badKeyFrame("01 明文长度 \(plain.count)，期望 16")
        }

        let seg1 = try aes(plain: plain, key: keys.ckTRxSP)
        let seg2 = try aes(plain: constantKey, key: keys.ckTRxSP)

        var frame: [UInt8] = [0x01]
        frame.append(contentsOf: seg1)
        frame.append(contentsOf: seg2)

        return FirstMessage(frame: frame, rnd1: r, segment1: seg1, segment2: seg2, plain: plain)
    }

    // MARK: - 03 帧

    public struct ResponseMessage: Sendable {
        /// 完整帧（18 字节，含命令号 `0x03`）
        public var frame: [UInt8]
        /// 16 字节响应体
        public var body: [UInt8]
        /// 临时密钥 `enc1`（日志用）
        public var enc1: [UInt8]
        /// 自校验结果：`enc2[2..9)` 是否等于挑战的 `[9..16)`
        ///
        /// 原 App 在 `0x12498` 用 `isEqualToData:` 比较，失败时打
        /// `"Authentification is insufficient. Wrong challenge"` 并返回 nil。
        public var challengeVerified: Bool
        /// 车端给的期望值（挑战 `[9..16)`）
        public var expected: [UInt8]
        /// 本地算出的值（`enc2[2..9)`）
        public var computed: [UInt8]
    }

    /// 构造 `03` 帧 —— 对应 `-[VCLSManager calculateResponseforCidpu:randomData:command:]` @`0x12050`。
    ///
    /// 还原后的伪代码：
    /// ```objc
    /// part9 = [challenge subdataWithRange:NSMakeRange(0, 9)];
    ///
    /// rev  = [IBNSData reverseData:[IBNSString stringToData:RND1]];      // 4 字节反转
    /// buf1 = rev + rev[1..4) + rev[0..1) + rev[2..4) + rev[0..2) + rev[3..4) + rev[0..3);  // 16
    /// enc1 = AES128(buf1, key: hexToBytes(Dk1));                          // ★ 临时密钥
    ///
    /// buf2 = part9 + ~part9[0..7);                                        // 16
    /// enc2 = AES128(buf2, key: enc1);
    /// if (enc2[2..9) != challenge[9..16)) return nil;                     // ★ 自校验
    ///
    /// buf3 = part9 + ~part9[0..6) + command;                              // 16
    /// return [0x03] + AES128(buf3, key: enc1) + command;                  // 18
    /// ```
    public static func buildResponse(
        challenge: [UInt8],
        command: UInt8,
        rnd1: [UInt8],
        keys: Keys
    ) throws -> ResponseMessage {
        guard challenge.count >= 16 else {
            throw InBlueAuthError.badChallenge(challenge.count)
        }
        guard keys.dk1.count == 16 else {
            throw InBlueAuthError.badKeyLength(field: "Dk1", expected: 16, actual: keys.dk1.count)
        }
        guard rnd1.count == 4 else {
            throw InBlueAuthError.badKeyLength(field: "RND1", expected: 4, actual: rnd1.count)
        }

        let part9 = Array(challenge[0..<9])
        let expected = Array(challenge[9..<16])

        // ① 临时密钥
        let rev: [UInt8] = rnd1.reversed()
        var buf1: [UInt8] = []
        buf1.append(contentsOf: rev)
        buf1.append(contentsOf: rev[1..<4])
        buf1.append(contentsOf: rev[0..<1])
        buf1.append(contentsOf: rev[2..<4])
        buf1.append(contentsOf: rev[0..<2])
        buf1.append(contentsOf: rev[3..<4])
        buf1.append(contentsOf: rev[0..<3])
        // 上式正好 16 字节：4 + 3 + 1 + 2 + 2 + 1 + 3
        let enc1 = try aes(plain: buf1, key: keys.dk1)

        // ② 自校验
        var buf2 = part9
        buf2.append(contentsOf: not(Array(part9[0..<7])))
        let enc2 = try aes(plain: buf2, key: enc1)
        let computed = Array(enc2[2..<9])
        let verified = computed == expected

        // ③ 真正的响应体
        var buf3 = part9
        buf3.append(contentsOf: not(Array(part9[0..<6])))
        buf3.append(command)
        let body = try aes(plain: buf3, key: enc1)

        var frame: [UInt8] = [0x03]
        frame.append(contentsOf: body)
        frame.append(command)

        return ResponseMessage(
            frame: frame, body: body, enc1: enc1,
            challengeVerified: verified, expected: expected, computed: computed
        )
    }

    // MARK: - 原语

    /// `+[IBAESData AES128WithData:withKey:encrypt:cbc:option:]` @`0x10cac`
    /// → `CCCrypt(op=0, alg=AES, options=0, iv=NULL, …)`
    /// → **AES-128-CBC / IV 全零 / 无 padding**。
    public static func aes(plain: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard key.count == 16 else {
            throw InBlueAuthError.badKeyLength(field: "AES key", expected: 16, actual: key.count)
        }
        guard plain.count % 16 == 0, !plain.isEmpty else {
            throw InBlueAuthError.badBlockLength(plain.count)
        }
        return try CryptoBox.aesEncrypt(
            .cbcNoPadding,
            key: key,
            iv: [UInt8](repeating: 0, count: 16),
            plain: plain
        )
    }

    /// `+[IBNSData setNot:]` @`0xe4b4` —— 逐字节 `mvn`。
    public static func not(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { ~$0 }
    }
}

public enum InBlueAuthError: Error, CustomStringConvertible {
    case badKeyFrame(String)
    case badKeyLength(field: String, expected: Int, actual: Int)
    case badBlockLength(Int)
    case badChallenge(Int)

    public var description: String {
        switch self {
        case .badKeyFrame(let s): return "密钥帧异常：\(s)"
        case .badKeyLength(let f, let e, let a): return "\(f) 长度应为 \(e)，实际 \(a)"
        case .badBlockLength(let n): return "明文长度 \(n) 不是 16 的整数倍"
        case .badChallenge(let n): return "挑战长度 \(n) 不足 16 字节"
        }
    }
}
