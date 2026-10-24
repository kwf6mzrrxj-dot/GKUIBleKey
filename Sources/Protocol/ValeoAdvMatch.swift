import Foundation

/// Valeo 广播匹配引擎 —— 完整照 `ValeoCoreCommunication` / `InBlue` 反汇编还原。
///
/// ## 为什么要单独一层
/// 「能不能发现车辆」和「是不是**我的**车辆」是两件事，原 App 分成两道判定：
/// 1. **Valeo 设备判定**（`+[VCBAdvertisingData isValeoDeviceWithAdvertisingData:]`）
///    —— 只看厂商数据前 2 字节魔数，与车辆无关；
/// 2. **归属判定**（`-[IBDevice checkCryptedID:]` → `+[VSSecurity checkCryptedID:withCidpu:random:]`）
///    —— 用本车 `cidpu` 做 AES，验证广播里的 `cryptedID` 是否由这把钥匙生成。
///
/// 之前实现只按**广播名**做包含匹配，两条都没有 —— 名称是显示用字段，
/// 车端根本不参与判定，所以会出现「名字像就判成目标」和「名字改了就当没有」。
public enum ValeoAdvMatch {

    // MARK: - 常量（全部取自反汇编立即数/CFString）

    /// `+[NSData dataWithBytes:0x10808 length:2]` —— `EE 01`
    ///
    /// `0xb9f4` 处 `adr x2, #0x10808` 指向这里，`isEqualToData:` 比较的就是它。
    public static let magic: [UInt8] = [0xEE, 0x01]

    /// `0xb890` 处 `adr x2, #0x1080a` 的 1 字节 —— 协议版本 `0x02`。
    ///
    /// `initWithAdvertisingDictionary:` 里：
    /// ```objc
    /// version = [manufacturer subdataWithRange:NSMakeRange(2, 1)];
    /// if ([version isEqual:<0x02>]) [self parseAdvertisingGen02:manufacturer];
    /// else                          [self parseAdvertisingGen03:manufacturer];
    /// ```
    /// 即 **等于 2 → Gen02，其余（含实测的 3）→ Gen03**。
    public static let gen02Version: UInt8 = 0x02

    /// `parseAdvertisingGen02:` 的长度门槛 —— `cmp x0, #0x17`
    public static let gen02MinLength = 23
    /// `parseAdvertisingGen03:` 的长度门槛 —— `cmp x0, #0x13`
    public static let gen03MinLength = 19
    /// Gen03 的扩展门槛 —— `cmp x0, #0x24`，满足才有 broadcastData / oemID
    public static let gen03ExtendedLength = 36

    /// `checkCryptedID:` 里拼进明文的固定盐 —— `CFSTR "BC145356BAFE0028"`（8 字节）
    public static let cidSaltHex = "BC145356BAFE0028"
    /// `checkCryptedID:` 要求 `cryptedID.length >= 12`（`cmp x0, #0xc`）
    public static let cryptedIDMinLength = 12

    /// `-[IBVehicleManager updateVehicleWithDevice:]` 的 RSSI 门限 ——
    /// `ldr d0, #0x1fc10` = `-91.0`，`fcmp` 后 `b.le` 直接返回。
    ///
    /// 注意是**严格大于**：天线均值 == -91 会被丢弃。
    public static let rssiFloor: Double = -91.0

    // MARK: - 广播解析结果

    public enum Gen: String, Sendable {
        case gen02
        case gen03
    }

    public struct Advertisement: Sendable, Equatable {
        public var gen: Gen
        /// 厂商数据原文
        public var raw: [UInt8]
        /// `kCBAdvDataIsConnectable`
        public var isConnectable: Bool
        /// 广播版本字节（`raw[2]`）
        public var protocolVersion: UInt8
        /// Gen02 = 整段；Gen03 = `raw[3..4)`
        public var antenna: [UInt8]
        /// `raw[4..6)` —— 两天线共 2 字节
        public var reSynchro: [UInt8]
        /// Gen03 的 `raw[6..7)`
        public var mode: UInt8?
        /// ★ 归属校验材料：Gen02 = `raw[7..23)`（16B）；Gen03 = `raw[7..19)`（12B）
        public var cryptedID: [UInt8]
        /// Gen02 = `raw[6..7)`（1B）；Gen03（≥36B）= `raw[19..35)`（16B）
        public var broadcastData: [UInt8]
        /// Gen03（≥36B）的 `raw[35..36)`
        public var oemID: UInt8?

        public var genLabel: String { gen == .gen02 ? "Gen02" : "Gen03" }
    }

    /// 设备与本车的关系 —— 对应原 App 的两级判定结果。
    public enum Identity: String, Sendable {
        /// 魔数命中，但还没配对过 / 没有 cidpu，无法确认是不是本车
        case valeoTarget = "Valeo 设备（未确认归属）"
        /// 厂商数据不是 EE 01 —— 原 App 会**直接丢弃**
        case notValeo = "非 Valeo 设备"
        /// cryptedID 用本车 cidpu 校验通过 —— 是本车
        case ownVehicle = "本车"
        /// 魔数命中，但 cidpu 校验不通过 —— 是别的 Valeo 车
        case otherValeoVehicle = "其他 Valeo 车辆"
    }

    // MARK: - ① 设备判定 + 解析

    /// 完整还原 `initWithAdvertisingDictionary:` 的判定与分支。
    ///
    /// 与原实现的差异（**都是防御，不改变匹配结果**）：
    /// - 原 App 在「魔数命中但长度 == 2」时会因 `subdataWithRange:{2,1}` 越界**抛异常**；
    ///   这里返回 `nil`，效果等同「不是目标」。
    public static func parse(
        manufacturer: [UInt8],
        isConnectable: Bool = true
    ) -> Advertisement? {
        // ① `isValeoDeviceWithAdvertisingData:` —— 长度 < 2 直接 NO
        guard manufacturer.count >= magic.count else { return nil }
        guard Array(manufacturer[0..<2]) == magic else { return nil }
        // ② 版本字节要能取到（原 App 此处会崩，这里转向"不匹配"）
        guard manufacturer.count >= 3 else { return nil }

        let version = manufacturer[2]
        var adv = Advertisement(
            gen: .gen03,
            raw: manufacturer,
            isConnectable: isConnectable,
            protocolVersion: version,
            antenna: [],
            reSynchro: [],
            mode: nil,
            cryptedID: [],
            broadcastData: [],
            oemID: nil
        )

        if version == gen02Version {
            guard manufacturer.count >= gen02MinLength else { return nil }
            adv.gen = .gen02
            adv.antenna = manufacturer                     // setAntennaGen2WithData: 传整段
            adv.reSynchro = Array(manufacturer[4..<6])
            adv.broadcastData = Array(manufacturer[6..<7])
            adv.cryptedID = Array(manufacturer[7..<23])
        } else {
            guard manufacturer.count >= gen03MinLength else { return nil }
            adv.gen = .gen03
            adv.antenna = Array(manufacturer[3..<4])
            adv.reSynchro = Array(manufacturer[4..<6])
            adv.mode = manufacturer[6]
            adv.cryptedID = Array(manufacturer[7..<19])
            if manufacturer.count >= gen03ExtendedLength {
                adv.broadcastData = Array(manufacturer[19..<35])
                adv.oemID = manufacturer[35]
            }
        }
        return adv
    }

    // MARK: - ② 归属判定（本车 vs 别的车）

    /// `-[IBDevice checkCryptedID:]` @`0x71dc` 的完整还原。
    ///
    /// ```objc
    /// if (cryptedID.length < 12) return NO;
    /// tail4 = [cryptedID subdataWithRange:NSMakeRange(8, 4)];
    /// head8 = [cryptedID subdataWithRange:NSMakeRange(0, 8)];
    /// buf   = [head8 mutableCopy];
    /// [buf appendData:[IBNSString stringToData:@"BC145356BAFE0028"]];
    /// cidpuData = [IBNSString stringToData:self.cidpu];
    /// return [VSSecurity checkCryptedID:tail4 withCidpu:cidpuData random:buf];
    /// ```
    ///
    /// 而 `+[VSSecurity checkCryptedID:withCidpu:random:]` @`0x13e20` 是
    /// `CCCrypt(op=kCCEncrypt, AES, options=0, key=cidpu, iv=NULL, data=random)`，
    /// 然后用 `subdataWithRange:NSMakeRange(2, tail4.length)` 与 `tail4` 比较：
    /// ```objc
    /// if (encrypted.length <= tail4.length + 2) return NO;   // cmp / b.ls
    /// return [[encrypted subdataWithRange:NSMakeRange(2, tail4.length)]
    ///            isEqualToData:tail4];
    /// ```
    /// 即 **密文的第 2..6 字节 = 广播里的 4 字节校验码**。
    ///
    /// - Parameters:
    ///   - cryptedID: 解析出的 `cryptedID`（Gen02 16B / Gen03 12B）
    ///   - cidpu: 本车 `cidpu` 的 hex 字符串（`saveKeysData:` 存的 4 字节 CIDPU）
    public static func isOwnVehicle(cryptedID: [UInt8], cidpuHex: String) -> Bool {
        guard cryptedID.count >= cryptedIDMinLength else { return false }
        let head8 = Array(cryptedID[0..<8])
        let tail4 = Array(cryptedID[8..<12])

        var plain = head8
        plain.append(contentsOf: FrameCodec.bytes(fromHex: cidSaltHex))
        guard plain.count == 16 else { return false }

        guard let key = cidpuAESKey(cidpuHex) else { return false }
        guard let enc = try? CryptoBox.aesEncrypt(
            .cbcNoPadding, key: key,
            iv: [UInt8](repeating: 0, count: 16),
            plain: plain
        ) else { return false }

        // 原 App 的越界保护：`encrypted.length <= tail4.length + 2` 直接失败
        guard enc.count > tail4.count + 2 else { return false }
        return Array(enc[2..<(2 + tail4.count)]) == tail4
    }

    /// 把 `cidpu` hex 字符串转成 AES-128 key。
    ///
    /// `+[VSSecurity checkCryptedID:withCidpu:random:]` 直接用
    /// `dataFromHex(cidpu)` 得到的字节当 key，长度由 CCCrypt 校验（必须是 16）。
    /// 实测密钥帧末尾只有 4 字节 CIDPU，因此这里不足 16 时**右补零**，
    /// 并在调用方日志里标明 —— 真正的 16 字节 cidpu 要等车端下发完整值。
    public static func cidpuAESKey(_ hex: String) -> [UInt8]? {
        var bytes = FrameCodec.bytes(fromHex: hex)
        guard !bytes.isEmpty else { return nil }
        if bytes.count > 16 { bytes = Array(bytes.prefix(16)) }
        if bytes.count < 16 {
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 16 - bytes.count))
        }
        return bytes
    }

    // MARK: - ③ 综合判定（给扫描用）

    /// 判定一台广播设备对本 App 的意义，优先级与原 App 一致：
    /// **魔数 → 归属**（魔数不过直接当不存在）。
    public static func identify(
        manufacturer: [UInt8],
        cidpuHex: String,
        rssi: Int,
        isConnectable: Bool = true
    ) -> (identity: Identity, advertisement: Advertisement?) {
        guard let adv = parse(manufacturer: manufacturer, isConnectable: isConnectable) else {
            return (.notValeo, nil)
        }
        // RSSI 门限：原 App 在 `updateVehicleWithDevice:` 里过滤，
        // 严格大于 -91 才进入匹配（这里是单天线值，双天线场景取均值）
        if Double(rssi) <= rssiFloor {
            return (.valeoTarget, adv)      // 仍标记为 Valeo，但上层应按"弱信号"处理
        }
        guard !cidpuHex.isEmpty else { return (.valeoTarget, adv) }
        return isOwnVehicle(cryptedID: adv.cryptedID, cidpuHex: cidpuHex)
            ? (.ownVehicle, adv)
            : (.otherValeoVehicle, adv)
    }
}
