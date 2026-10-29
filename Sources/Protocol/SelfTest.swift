import Foundation

/// 基础层自检。
///
/// 用**公开的标准测试向量**验证密码学与编解码实现是否正确 ——
/// 这样在真机联调之前，就能把「实现 bug」与「协议参数猜错」两类问题分开。
/// 后者只能靠实测报文解决，前者这里就能排掉。
public enum SelfTest {

    public struct Result: Identifiable, Sendable {
        public let id = UUID()
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public static func runAll() -> [Result] {
        [
            testSHA256(),
            testHMACSHA256(),
            testAESRoundTrip(),
            testAESKnownVector(),
            testInBluePlainOrder(),
            testValeoAdvParse(),
            testValeoAdvRejects(),
            testCryptedIDRoundTrip(),
            testCryptedIDBoundaries(),
            testVehicleStatusBits(),
            testCommandTable(),
            testPassiveStartJudge(),
            testErrorCodeTable(),
        ]
    }

    // MARK: - SHA-256

    /// NIST 向量：SHA-256("abc")
    static func testSHA256() -> Result {
        let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let got = CryptoBox.sha256(Array("abc".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Result(
            name: "SHA-256(\"abc\")",
            passed: got == expected,
            detail: got == expected ? "匹配 NIST 向量" : "期望 \(expected.prefix(16))… 实得 \(got.prefix(16))…")
    }

    // MARK: - HMAC-SHA256

    /// RFC 4231 / 常用向量：
    /// key="key", data="The quick brown fox jumps over the lazy dog"
    static func testHMACSHA256() -> Result {
        let expected = "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        let key = Array("key".utf8)
        let data = Array("The quick brown fox jumps over the lazy dog".utf8)

        let viaCryptoKit = CryptoBox.hmacSHA256(key: key, data: data)
            .map { String(format: "%02x", $0) }.joined()
        let viaCommonCrypto = CryptoBox.hmacSHA256CommonCrypto(key: key, data: data)
            .map { String(format: "%02x", $0) }.joined()

        let ok = (viaCryptoKit == expected) && (viaCommonCrypto == expected)
        return Result(
            name: "HMAC-SHA256 双实现一致",
            passed: ok,
            detail: ok
                ? "CryptoKit 与 CommonCrypto 均匹配 RFC 向量"
                : "CryptoKit=\(viaCryptoKit.prefix(16))… CommonCrypto=\(viaCommonCrypto.prefix(16))…")
    }

    // MARK: - AES

    /// AES-128-CBC PKCS7 加解密往返。
    static func testAESRoundTrip() -> Result {
        do {
            let key = [UInt8](repeating: 0x11, count: 16)
            let iv = [UInt8](repeating: 0x22, count: 16)
            let plain = Array("0123456789ABCDEF0123456789ABCDEF".utf8)
            let ct = try CryptoBox.aesEncrypt(.cbcPKCS7, key: key, iv: iv, plain: plain)
            let back = try CryptoBox.aesDecrypt(.cbcPKCS7, key: key, iv: iv, cipher: ct)
            let ok = back == plain
            return Result(
                name: "AES-128-CBC 往返",
                passed: ok,
                detail: ok ? "明文 \(plain.count)B → 密文 \(ct.count)B → 还原一致"
                           : "还原不一致（\(back.count)B vs \(plain.count)B）")
        } catch {
            return Result(name: "AES-128-CBC 往返", passed: false, detail: "\(error)")
        }
    }

    /// FIPS-197 AES-128 单块 ECB 向量（无填充）：
    /// key=000102...0F, plain=00112233445566778899AABBCCDDEEFF
    /// cipher=69C4E0D86A7B0430D8CDB78070B4C55A
    static func testAESKnownVector() -> Result {
        do {
            let key = Array(0x00...0x0F).map { UInt8($0) }
            let plain: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                  0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
            let expected = "69c4e0d86a7b0430d8cdb78070b4c55a"
            let ct = try CryptoBox.aesEncrypt(.ecbNoPadding, key: key, iv: [], plain: plain)
            let got = ct.map { String(format: "%02x", $0) }.joined()
            let ok = got.lowercased() == expected
            return Result(
                name: "AES-128-ECB FIPS-197 向量",
                passed: ok,
                detail: ok ? "匹配 FIPS-197" : "期望 \(expected) 实得 \(got)")
        } catch {
            return Result(name: "AES-128-ECB FIPS-197 向量", passed: false, detail: "\(error)")
        }
    }

    // MARK: - InBlue 明文顺序

    /// 验证 `01` 明文的两种候选顺序都恰好 16 字节、且互不相同。
    ///
    /// 这两点是硬约束：AES-CBC 无 padding 要求明文是整块；
    /// 而两种顺序如果等价，自动探测就失去意义。
    static func testInBluePlainOrder() -> Result {
        let sd: [UInt8] = [0xA1, 0xA1, 0xA1, 0xA1]        // 4
        let ed: [UInt8] = [0xB2, 0xB2, 0xB2, 0xB2]        // 4
        let rndTRx: [UInt8] = [0xC3, 0xC3, 0xC3]          // 3
        let rights: [UInt8] = [0xD4]                      // 1
        let rnd1: [UInt8] = [0xE5, 0xE5, 0xE5, 0xE5]      // 4

        let orderA = sd + ed + rndTRx + rnd1 + rights      // 默认（栈布局）
        let orderB = sd + ed + rndTRx + rights + rnd1      // 备用

        let ok = orderA.count == 16 && orderB.count == 16 && orderA != orderB
        return Result(
            name: "01 明文顺序候选（各 16B 且互异）",
            passed: ok,
            detail: ok
                ? "默认 \(orderA.count)B / 备用 \(orderB.count)B，内容不同 → 自动探测有意义"
                : "长度 \(orderA.count)/\(orderB.count)，相同=\(orderA == orderB)")
    }

    // MARK: - ★ 广播匹配（照 VCBAdvertisingData 反汇编）

    /// 用一段**早期录制的真机 19 字节厂商数据**验证 Gen03 解析。
    ///
    /// 说明：样本仅作解析回归用（固定输入 → 固定输出），不作为协议结论的依据。
    /// 凡是与协议语义相关的判断，一律以反汇编为准。
    ///
    /// 期望：
    /// ```
    /// 版本 = 0x03            → 走 Gen03 分支
    /// antenna      = [3..4)  = 82
    /// reSynchro    = [4..6)  = 4E 8B
    /// mode         = [6]     = 01
    /// cryptedID    = [7..19) = 28 39 3F 1F 1F 63 58 E7 35 3E 0C 2D   （12 字节）
    /// broadcastData= 空（长度 19 < 36）
    /// ```
    static func testValeoAdvParse() -> Result {
        let raw: [UInt8] = [0xEE, 0x01, 0x03, 0x82, 0x4E, 0x8B, 0x01, 0x28, 0x39, 0x3F,
                            0x1F, 0x1F, 0x63, 0x58, 0xE7, 0x35, 0x3E, 0x0C, 0x2D]
        guard let adv = ValeoAdvMatch.parse(manufacturer: raw) else {
            return Result(name: "Valeo 广播 Gen03 解析", passed: false, detail: "解析返回 nil")
        }
        let cidHex = adv.cryptedID.map { String(format: "%02X", $0) }.joined()
        let checks: [(String, Bool)] = [
            ("Gen03", adv.gen == .gen03),
            ("version=3", adv.protocolVersion == 0x03),
            ("antenna=[82]", adv.antenna == [0x82]),
            ("reSynchro=4E8B", adv.reSynchro == [0x4E, 0x8B]),
            ("mode=01", adv.mode == 0x01),
            ("cryptedID=12B", adv.cryptedID.count == 12),
            ("cryptedID=28393F1F1F6358E7353E0C2D", cidHex == "28393F1F1F6358E7353E0C2D"),
            ("broadcastData 为空", adv.broadcastData.isEmpty),
        ]
        let bad = checks.filter { !$0.1 }.map { $0.0 }
        return Result(
            name: "Valeo 广播 Gen03 解析（实测 19B）",
            passed: bad.isEmpty,
            detail: bad.isEmpty ? "8 项字段全部命中实测值" : "不符：\(bad.joined(separator: ", "))")
    }

    /// 边界：原 App 会**直接判否**的输入。
    ///
    /// - 魔数不对 → nil
    /// - 长度不足 2 → nil
    /// - `EE 01` 后只有 1 字节（长度 3）→ 版本可取，但 Gen03 门槛 19 → nil
    /// - 版本 02 但长度 22（门槛 23）→ nil
    static func testValeoAdvRejects() -> Result {
        let cases: [(String, [UInt8])] = [
            ("魔数不符", [0x4C, 0x00, 0x02]),
            ("长度 1", [0xEE]),
            ("长度 0", []),
            ("EE01+版本 但仅 3B", [0xEE, 0x01, 0x03]),
            ("版本02 长度22", [0xEE, 0x01, 0x02] + [UInt8](repeating: 0, count: 19)),
        ]
        var leaked: [String] = []
        for (name, bytes) in cases where ValeoAdvMatch.parse(manufacturer: bytes) != nil {
            leaked.append(name)
        }
        // 版本 02 且长度 23 必须通过（边界内）
        let ok23 = [0xEE, 0x01, 0x02] + [UInt8](repeating: 0, count: 20)
        let passed23 = ValeoAdvMatch.parse(manufacturer: ok23)?.gen == .gen02
        let ok = leaked.isEmpty && passed23
        return Result(
            name: "Valeo 广播边界拒绝",
            passed: ok,
            detail: ok ? "5 个非法输入全部拒绝；Gen02 长度 23 正确通过"
                       : "误判通过：\(leaked.joined(separator: ", "))；Gen02@23=\(passed23)")
    }

    /// 归属校验闭环：按反汇编的**生成方向**造一个 cryptedID，再让校验函数判本车。
    ///
    /// 生成规则（`checkCryptedID:` 的逆）：
    /// ```
    /// head8 = 任意 8 字节
    /// enc   = AES-128-CBC(key = cidpu, iv = 0, plain = head8 || "BC145356BAFE0028")
    /// cryptedID = head8 || enc[2..6)
    /// ```
    /// 若实现里的 IV、块模式、偏移、盐任一写错，这里就会失败。
    static func testCryptedIDRoundTrip() -> Result {
        let cidpuHex = "6ac89ad4"
        guard let key = ValeoAdvMatch.cidpuAESKey(cidpuHex) else {
            return Result(name: "cryptedID 归属校验闭环", passed: false, detail: "cidpu 转 key 失败")
        }
        let head8: [UInt8] = [0x28, 0x39, 0x3F, 0x1F, 0x1F, 0x63, 0x58, 0xE7]
        var plain = head8
        plain.append(contentsOf: FrameCodec.bytes(fromHex: ValeoAdvMatch.cidSaltHex))
        do {
            let enc = try CryptoBox.aesEncrypt(
                .cbcNoPadding, key: key, iv: [UInt8](repeating: 0, count: 16), plain: plain)
            let cryptedID = head8 + Array(enc[2..<6])
            let mine = ValeoAdvMatch.isOwnVehicle(cryptedID: cryptedID, cidpuHex: cidpuHex)

            // 换一把 cidpu 必须判否（证明不是恒真）
            let others = ValeoAdvMatch.isOwnVehicle(cryptedID: cryptedID, cidpuHex: "11223344")

            let ok = mine && !others
            return Result(
                name: "cryptedID 归属校验闭环",
                passed: ok,
                detail: ok
                    ? "本车 cidpu → 命中；另一把 cidpu → 不命中（密钥参与判定）"
                    : "本车=\(mine) 其他=\(others)（期望 true/false）")
        } catch {
            return Result(name: "cryptedID 归属校验闭环", passed: false, detail: "\(error)")
        }
    }

    /// 边界：`cryptedID.count < 12` 必须判否（`cmp x0, #0xc`）。
    static func testCryptedIDBoundaries() -> Result {
        let short = [UInt8](repeating: 0xAA, count: 11)
        let empty: [UInt8] = []
        let a = ValeoAdvMatch.isOwnVehicle(cryptedID: short, cidpuHex: "6ac89ad4")
        let b = ValeoAdvMatch.isOwnVehicle(cryptedID: empty, cidpuHex: "6ac89ad4")
        let c = ValeoAdvMatch.isOwnVehicle(
            cryptedID: [UInt8](repeating: 0, count: 12), cidpuHex: "")
        let ok = !a && !b && !c
        return Result(
            name: "cryptedID 长度/空 cidpu 边界",
            passed: ok,
            detail: ok ? "11B / 0B / 空 cidpu 全部正确判否" : "短帧=\(a) 空=\(b) 空cidpu=\(c)")
    }

    // MARK: - ★ 车辆状态位解析（照 parseStatus: 反汇编）

    /// 验证 `parseStatus:` 的取位：`isLocked = bin[7]` = **status 字节（plain[4]）的 bit0**。
    ///
    /// 反汇编依据：`parseBroadcastData:` @`0x4bc0` 解密后，
    /// `[self parseStatus:[plain subdataWithRange:NSMakeRange(4,1)]]`，
    /// 而 `parseStatus:` @`0x4de4` 里 `substringWithRange:(7,1)` → `_isLocked`。
    ///
    /// ## 发动机（2026-10-29 修正后的关键回归）
    /// `_isEnginRunning` 的 range 是 **{1,2}**（`0x5094 mov w2,#1` + `0x5098 mov w3,#2`），
    /// 取两位后用 `strtol(_, NULL, 2)` 解析、`cmp #2` 判等 —— 只有 `10b` 算运行。
    /// 旧实现取单 bit `bit5`，于是真车「发动机启动」时（bit6=1/bit5=0）
    /// 恒判未启动，UI 只显示「上电」。这组用例把该错误钉死。
    static func testVehicleStatusBits() -> Result {
        func state(_ statusByte: UInt8) -> VehicleStatus {
            var p = [UInt8](repeating: 0, count: 16)
            p[4] = statusByte   // 状态字节在明文 [4]
            return VehicleStatus(decryptedPlain: p)
        }

        let a = state(0x01)   // bit0=1 → 已锁
        let b = state(0x40)   // bit6=1，bit0=0 → 未锁
        let c = state(0x00)   // 全零 → 未锁

        let lockOK = a.isLocked && !b.isLocked && !c.isLocked

        // ── 发动机 2 位编码 ────────────────────────────────
        // 0x50 = 0101_0000：bit4(上电)=1，bit6:bit5 = 10b = 2 → 运行
        let run   = state(0x50)
        // 0x10 = 0001_0000：bit4=1，bit6:bit5 = 00b = 0 → 只上电没启动
        let ignOnly = state(0x10)
        // 0x20 = 0010_0000：bit6:bit5 = 01b = 1 → 不是运行（旧实现会误判为运行）
        let code1 = state(0x20)
        // 0x60 = 0110_0000：bit6:bit5 = 11b = 3 → 不是运行
        let code3 = state(0x60)

        let engOK = run.isEngineRunning && run.engineStateCode == 2
            && !ignOnly.isEngineRunning && ignOnly.isIgnitionOn
            && !code1.isEngineRunning && code1.engineStateCode == 1
            && !code3.isEngineRunning && code3.engineStateCode == 3

        // ── 引擎盖 = bin[0] = bit7（旧实现错取 bit6）────────
        let hoodOpen   = state(0x00)   // bit7=0 → 引擎盖未关（开）
        let hoodClosed = state(0x80)   // bit7=1 → 关闭
        let hoodOK = hoodClosed.isHoodClosed && !hoodOpen.isHoodClosed

        // ── 四门 + ACC 抽查 ───────────────────────────────
        var p = [UInt8](repeating: 0, count: 16)
        p[6] = 0x0F; p[7] = 0x01
        let doors = VehicleStatus(decryptedPlain: p)
        let doorOK = doors.isFLDoorClosed && doors.isFRDoorClosed
            && doors.isRLDoorClosed && doors.isRRDoorClosed
            && !doors.isFLDoorLocked && doors.isAccOn

        let ok = lockOK && engOK && hoodOK && doorOK
        let detail: String = ok
            ? "锁 bit0；发动机 bit6:bit5 的 base-2 值==2；引擎盖 bit7；四门 bit0-3；ACC bit0 —— 全部吻合 parseStatus:/parseDoorsStatus:/parsePowerStatus:"
            : "lock=\(lockOK) eng=\(engOK)(0x50=\(run.engineStateCode)/\(run.isEngineRunning) "
              + "0x10=\(ignOnly.engineStateCode)/\(ignOnly.isEngineRunning) "
              + "0x20=\(code1.engineStateCode)/\(code1.isEngineRunning) "
              + "0x60=\(code3.engineStateCode)/\(code3.isEngineRunning)) "
              + "hood=\(hoodOK) doors=\(doorOK)"
        return Result(
            name: "状态位解析（parseStatus: 发动机为 2 位编码）",
            passed: ok,
            detail: detail)
    }

    // MARK: - ★ 命令号表

    /// 11 个命令号必须与 `-[IBVehicle xxx]` 里 `mov w2, #N` 的立即数一致，
    /// 并且 `controlCode` 必须等于 `rawValue`（`03` 帧末字节直接写这个数）。
    static func testCommandTable() -> Result {
        let expect: [IBCommandType: UInt8] = [
            .lock: 0x01, .unlock: 0x02, .openCloseTrunk: 0x03,
            .windowUp: 0x04, .windowDown: 0x05, .panic: 0x06,
            .requestPairedDevices: 0x0D,
            .enablePassiveEntry: 0x11, .disablePassiveEntry: 0x12,
            .pairing: 0x55,
        ]
        var bad: [String] = []
        for (cmd, want) in expect where cmd.rawValue != want {
            bad.append("\(cmd.label)=0x\(String(format: "%02X", cmd.rawValue))≠0x\(String(format: "%02X", want))")
        }
        for cmd in IBCommandType.allCases where cmd.controlCode != cmd.rawValue {
            bad.append("\(cmd.label) controlCode≠rawValue")
        }
        let ok = bad.isEmpty
        return Result(
            name: "命令号表（IBCommandType）",
            passed: ok,
            detail: ok ? "11 个命令号与反汇编立即数一致，controlCode == rawValue"
                       : bad.joined(separator: "; "))
    }

    // MARK: - ★ 被动启动判定式

    /// 验证 `rssisOneAndTwo > calibration - leaveOffset`
    /// （`0xb030 cmp w25,w8` + `0xb034 b.le 0xb230`→`setIsInPassiveStartArea:NO`）。
    ///
    /// 同时验证 `leaveOffset` 的默认值 32 来自 `0x7900 mov w2,#0x20`。
    ///
    /// 注意：`combinedRSSI` 是合成 dB 值 `10×log10(√(10^(r1/10)²+10^(r2/10)²))`，
    /// 同路 `-30` 合成约 `-28.5`、`-60` 合成约 `-58.5`（`pondOutToIn=1.0`）。
    static func testPassiveStartJudge() -> Result {
        // ① 未标定：基准 = 0 - 32 = -32；合成 -28 > -32 → 在区域
        var a = PassiveStartJudge()
        _ = a.check(rssiOne: -30, rssiTwo: -30)

        // ② 未标定且很远：合成 -58 < -32 → 不在区域
        var b = PassiveStartJudge()
        _ = b.check(rssiOne: -60, rssiTwo: -60)

        // ③ 标定 -50：基准 = -50 - 32 = -82；合成 -58 > -82 → 在区域
        var c = PassiveStartJudge()
        c.calibration = -50
        _ = c.check(rssiOne: -60, rssiTwo: -60)

        let ok = a.leaveOffset == 32
            && a.threshold == -32
            && a.isInPassiveStartArea
            && !b.isInPassiveStartArea
            && c.isInPassiveStartArea
        return Result(
            name: "被动启动判定式（RSSI > calibration - leaveOffset）",
            passed: ok,
            detail: ok
                ? "未标定基准 -32：合成 -28 在区域、-58 不在；标定 -50 后合成 -58 在区域"
                : "leaveOffset=\(a.leaveOffset) 基准=\(a.threshold) a=\(a.isInPassiveStartArea) b=\(b.isInPassiveStartArea) c=\(c.isInPassiveStartArea)")
    }

    // MARK: - ★ 错误码表

    /// 验证错误码表已装载，且 `04` 结果码只对 `0x00` 给"成功"。
    static func testErrorCodeTable() -> Result {
        let sdk = ErrorCodeTable.message(for: 40001)          // 控车指令重发次数已满
        let biz = ErrorCodeTable.message(for: 2015)           // 钥匙在车内
        let okSuccess = ErrorCodeTable.describeResultByte(0x00) == "成功"
        let okOpaque = !ErrorCodeTable.describeResultByte(0x02).contains("成功")
        let ok = sdk != nil && biz != nil && okSuccess && okOpaque
        return Result(
            name: "错误码表（Localizable.strings）",
            passed: ok,
            detail: ok
                ? "40001=\(sdk!)  2015=\(biz!)  04(00)=成功  04(02)=未编造语义"
                : "sdk=\(String(describing: sdk)) biz=\(String(describing: biz))")
    }
}
