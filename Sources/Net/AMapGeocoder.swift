import Foundation
import CoreLocation

/// 高德逆地理编码的结果。
///
/// 字段命名刻意和原 App 一致 —— 它链的是高德定位 SDK，回调结构是：
/// ```
/// AMapLocationReGeocode:{formattedAddress; country; province; city; district;
///   street; number; POIName; AOIName;}
/// ```
/// 对应关系：
///
/// | 高德字段 | 这里 | 说明 |
/// |---|---|---|
/// | `formattedAddress` | `formatted` | 「上海市浦东新区高东镇严家港路」 |
/// | `AOIName` | `aoi` | AOI 面（小区/园区），「XX小区」的来源 |
/// | `POIName` | `poi` | 最近兴趣点 |
/// | `number` / `building.name` | `building` | 门牌 / 楼栋 |
struct AMapAddress: Sendable, Equatable {
    let formatted: String
    let aoi: String?
    let poi: String?
    /// `addressComponent.building.name`。住宅区里**几乎总是空数组**，
    /// 所以不要指望它 —— 楼栋要从 `formatted` 里切（见 `title`）。
    let building: String?

    /// 界面主标题，对应高德 App 位置卡的第一行。
    ///
    /// 优先级照抄原 App：**AOI → POI → 完整地址**。
    /// AOI 是"面"（一个小区），POI 是"点"（一家店）——
    /// 找车时"在哪个小区"比"旁边是哪家便利店"有用，所以 AOI 在前。
    ///
    /// ## 楼栋从哪来
    /// 高德的 `formatted_address` 命中小区时会直接带上楼栋：
    /// `上海市浦东新区高桥镇浦凌佳苑7号楼`。所以「AOI 名之后的那一段」
    /// 就是楼栋号 —— 切出来拼在 AOI 后面，得到「浦凌佳苑7号楼」，
    /// 和在高德 App 里看到的一致。
    ///
    /// 不走 `building.name`：那个字段在住宅区实测是 `[]`；
    /// 更不能用 `streetNumber.number` —— 它给的是**最近的门牌**，
    /// 实测有 171 米开外的情况，拼上去就是假地址。
    var title: String {
        if let aoi, !aoi.isEmpty {
            if let suffix = suffixAfterAOI(aoi), !suffix.isEmpty {
                return aoi + suffix
            }
            if let building, !building.isEmpty, !aoi.contains(building) {
                return "\(aoi) \(building)"
            }
            return aoi
        }
        if let poi, !poi.isEmpty { return poi }
        return formatted
    }

    /// `formatted` 里 AOI 名之后的那一段（通常就是「7号楼」）。
    private func suffixAfterAOI(_ aoi: String) -> String? {
        guard let range = formatted.range(of: aoi) else { return nil }
        let suffix = String(formatted[range.upperBound...])
        // 兜底：万一后面跟的是「附近」「对面」这类描述，宁可不拼
        guard !suffix.isEmpty, suffix.count <= 8 else { return nil }
        return suffix
    }
}

/// 高德 Web 服务 · 逆地理编码。
///
/// ## 为什么需要它
/// MapKit 的反查只到**道路级**（「严家港路」），拿不到小区名和楼栋。
/// 原 App 之所以能显示「XX小区」，是因为它链了高德 SDK，用的是
/// `AOIName`（AOI 面）和 `number`（门牌）。要复现同样的粒度，只能调高德。
///
/// ## 坐标系
/// **传 GCJ-02**（`VehicleCoordinate.mapCoordinate`），不传 `coordsys=gps`：
/// 高德这个接口默认就按 GCJ-02 解释，和我们给 MapKit 的是同一套坐标。
/// 如果改用 `coordsys=gps` 让它自己转，就等于对同一个点做两次转换 ——
/// 又偏 400 米。
///
/// ## key
/// 走 `AMapCredential`，不写死在源码里（本仓库是公开的）。
enum AMapGeocoder {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // 定位卡的地址是"顺手解析"，不能为了它让卡片转 10 秒圈。
        //
        // 但 4 秒对蜂窝网络偏紧：实测在弱网下经常刚好卡在边界上，
        // 表现就是"时好时坏"。放宽到 6 秒 —— 代价是失败时多等 2 秒
        // 才回退 MapKit，而 MapKit 的结果本来也只在失败时才用到。
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    /// 结果缓存。
    ///
    /// 不缓存会有两个后果：① 车控页和状态页各有一张位置卡，同一坐标发两次请求；
    /// ② 每次切页 / 卡片重建都再来一次。个人 key 只有 5000 次/天，
    /// 这种重复请求纯属浪费。
    ///
    /// `NSCache` 自带淘汰和线程安全，所以用 `nonisolated(unsafe)` 声明 ——
    /// 这不是"绕过并发检查"，是这个类型本身满足并发使用。
    nonisolated(unsafe) private static let cache = NSCache<NSString, CacheBox>()

    private final class CacheBox: NSObject {
        let value: AMapAddress
        init(_ value: AMapAddress) { self.value = value }
    }

    /// 逆地理编码。失败（无 key / 网络错 / 额度用尽 / 该点无数据）一律返回 nil，
    /// 调用方回退到 MapKit —— **不能让一次解析失败拖垮整张卡**。
    static func reverse(gcjLatitude: Double, gcjLongitude: Double) async -> AMapAddress? {
        // 4 位小数 ≈ 11 米：同一个车位重复打开必然命中，
        // 车开出十几米才会 miss —— 那个尺度上地址本来也该变。
        let cacheKey = String(format: "%.4f,%.4f", gcjLatitude, gcjLongitude) as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit.value }

        guard let key = AMapCredential.webKey,
              var components = URLComponents(string: "https://restapi.amap.com/v3/geocode/regeo")
        else {
            FileLogger.shared.warning("高德逆地理：没有可用 key（Bundle 里没有 amap-key.txt，"
                                      + "UserDefaults 也没有 amap.webKey）", module: "Net")
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            // ⚠️ location 是「经度,纬度」—— 和几乎所有其他坐标书写顺序相反。
            //    写反了高德会把它当成南极洲附近，返回 status=1 但 regeocode 是空的。
            URLQueryItem(name: "location",
                         value: String(format: "%.7f,%.7f", gcjLongitude, gcjLatitude)),
            // all 才返回 aois / pois / building；base 只给 formatted_address
            URLQueryItem(name: "extensions", value: "all"),
            URLQueryItem(name: "radius", value: "200"),
            URLQueryItem(name: "batch", value: "false")
        ]

        guard let url = components.url else {
            FileLogger.shared.warning("高德逆地理：URL 拼装失败", module: "Net")
            return nil
        }

        // 每一步都留痕 —— 这条路径以前是**全静默**的，
        // 真机上出现"小区名不显示了"时完全无从下手：不知道是没请求、
        // 请求失败、还是返回了但解析不出来。一次排查就得多装两版。
        let startedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            FileLogger.shared.warning("高德逆地理失败（\(ms)ms）：\(error.localizedDescription)",
                                      module: "Net")
            return nil
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            FileLogger.shared.warning("高德逆地理失败：HTTP \(code)", module: "Net")
            return nil
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            FileLogger.shared.warning("高德逆地理失败：返回不是合法 JSON（\(data.count) 字节）",
                                      module: "Net")
            return nil
        }
        // status == "1" 才是成功；"0" 时 info 里写明原因（额度、key 无效、平台不匹配）
        guard (root["status"] as? String) == "1",
              let regeocode = root["regeocode"] as? [String: Any] else {
            let status = root["status"] as? String ?? "nil"
            let info = root["info"] as? String ?? "nil"
            FileLogger.shared.warning("高德逆地理被拒：status=\(status) info=\(info)",
                                      module: "Net")
            return nil
        }

        guard let parsed = parse(regeocode) else {
            FileLogger.shared.warning("高德逆地理返回了数据但解析失败（缺 formatted_address）",
                                      module: "Net")
            return nil
        }

        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        FileLogger.shared.info("高德逆地理（\(ms)ms）：\(parsed.formatted)"
                               + "｜AOI=\(parsed.aoi ?? "—")｜标题=\(parsed.title)",
                               module: "Net")
        cache.setObject(CacheBox(parsed), forKey: cacheKey)
        return parsed
    }

    private static func parse(_ regeocode: [String: Any]) -> AMapAddress? {
        let component = regeocode["addressComponent"] as? [String: Any] ?? [:]

        // formatted_address 在 regeocode 顶层（不在 addressComponent 里）。
        // 它在直辖市偶尔会是数组，所以统一走 `string(_:)` 取值。
        guard let formatted = string(regeocode["formatted_address"]) else { return nil }

        // 楼栋只认 building.name。
        // ⚠️ 不要退回 `streetNumber.number` —— 它给的是**最近的门牌**，
        //    实测可能在一百多米外（车停在小区里，最近门牌在隔壁路上），
        //    拼进标题就是一条假地址。楼栋的正解见 `AMapAddress.title`。
        var building: String?
        if let b = component["building"] as? [String: Any],
           let name = string(b["name"]) {
            building = name
        }

        let aoi = firstNamedItem(regeocode["aois"])
        let poi = firstNamedItem(regeocode["pois"])

        return AMapAddress(formatted: formatted, aoi: aoi, poi: poi, building: building)
    }

    /// 高德把"没有值"表示成 `[]`（空数组）而不是 `null`，所以不能直接 `as? String`。
    private static func string(_ any: Any?) -> String? {
        if let s = any as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let array = any as? [Any] {
            return array.compactMap { $0 as? String }.first { !$0.isEmpty }
        }
        return nil
    }

    private static func firstNamedItem(_ any: Any?) -> String? {
        guard let list = any as? [[String: Any]] else { return nil }
        // 高德按距离排序，取第一个即可 —— 它就是"最近的那个"
        return list.compactMap { string($0["name"]) }.first
    }
}

// MARK: - key

/// 高德 Web 服务 key 的读取。
///
/// 本仓库是**公开**的，key 写进源码就等于公开（个人额度 5000 次/天，
/// 被人拿去刷当天就用不了）。所以按项目里 `builtin-keys.txt` 的同一套做法：
/// 实际值放本地不入库的文件，仓库里只留 `.example` 模板。
enum AMapCredential {

    /// UserDefaults 键 —— 留一个后门，换 key 不必重新打包
    static let defaultsKey = "amap.webKey"

    /// 解析一次就记住。Bundle 里的文件在进程生命周期内不会变，
    /// 每次请求都重新读一遍是纯 IO 浪费（虽然是毫秒级）。
    nonisolated(unsafe) private static var cached: String??

    static var webKey: String? {
        if let cached { return cached }

        let resolved = resolve()
        cached = resolved
        return resolved
    }

    private static func resolve() -> String? {
        if let override = UserDefaults.standard.string(forKey: defaultsKey) {
            let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let url = Bundle.main.url(forResource: "amap-key", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        // 模板文件里有以 # 开头的注释行，跳过它们
        return raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
