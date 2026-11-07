import Foundation

/// 车控指令的传输通道。
///
/// ## 为什么需要它
/// 原来只有蓝牙一条路：车端每条命令执行完就断开，所以「点了按钮 → 挂起 → 重连 → 执行」
/// 是常态。人不在车边时这条路根本走不通 —— 而车控最常用的场景恰恰是「人在外面」。
///
/// 现在加一条云端通道（`xchanger.cn`），两条路自动切换：
/// - **蓝牙**：在车边、链路已就绪时延迟最低（几十毫秒），且不消耗流量
/// - **网络**：不在车边、蓝牙连不上时唯一的办法，延迟 1–3 秒
///
/// ## 切换规则（见 `AppModel.resolveChannel`）
/// ```
/// 链路已就绪                       → 蓝牙
/// 未就绪，但最近 60s 收到过车辆广播   → 蓝牙（车就在附近，等它连上比走云快）
/// 其他情况且网络已配置              → 网络
/// 其他情况且网络未配置              → 蓝牙（保持 v3.x 的挂起重连行为）
/// ```
enum ControlChannel: String, Sendable, CaseIterable {
    case bluetooth
    case network

    var label: String {
        switch self {
        case .bluetooth: return "蓝牙"
        case .network: return "网络"
        }
    }

    var icon: String {
        switch self {
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .network: return "antenna.radiowaves.left.and.right"
        }
    }

    /// 角标用更短的图标 —— 按钮右上角只有 14pt 空间
    var badgeIcon: String {
        switch self {
        case .bluetooth: return "bolt.horizontal.circle.fill"
        case .network: return "wifi.circle.fill"
        }
    }
}

/// 时间格式化的共享实现。
///
/// 原来这两行调的是 `AppModel.hhmm`，但手表 target 不编 AppModel
/// （那是 iOS 主 App 的业务层），于是手表编译直接报 "cannot find AppModel"。
/// 格式化是纯展示逻辑，放这里两个 target 都能用。
enum StatusTimeFormat {

    /// 缓存一个实例。
    ///
    /// `DateFormatter()` 的初始化是毫秒级开销，而 `hhmm` 处在状态页的渲染路径上
    /// （每次刷新都会为来源标签重新格式化一次时间）—— 每次新建纯属浪费。
    ///
    /// `DateFormatter` 在当前 SDK 里已经是 `Sendable`（格式化操作线程安全），
    /// 所以直接 `static let` 即可，不需要 `nonisolated(unsafe)`。
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func hhmm(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

/// 状态「还新不新鲜」的唯一定义处。
///
/// 2026-11-04 之前这里有四个各自为政的常量：
/// 蓝牙广播窗口 60s、按钮推荐 120s、`VehicleSnapshot.staleSeconds` 180s、
/// `StatusSource.staleSeconds` 180s。同一个概念四种阈值，
/// 改一处不会影响另一处 —— 于是「状态页说实时、按钮却不推荐」这类矛盾迟早出现。
///
/// 现在只剩两个值（蓝牙那个已迁走）：
/// - `cloudWindow`：云端快照多久算过期
/// - `recommendationWindow`：比 `cloudWindow` 更严 —— 拿状态去**推荐操作**要更保守
///
/// ## 蓝牙窗口去哪了（2026-11-05）
///
/// 原来这里是 `bluetoothWindow = 60`（"两轮心跳"）。但 60 秒只适合**路由决策**
/// （别因为丢一包就切网络），拿它画界面就是「车开走一分钟还显示已连接」。
///
/// 界面要的是「车还在不在说话」，判据变成「3 秒没收到广播」，
/// 放在 `AppModel.broadcastSilenceWindow` —— 它需要和 `linkState` 一起判断，
/// 不适合单独作为一个时间常量放在这里。
enum StatusFreshness {
    static let cloudWindow: TimeInterval = 180
    static let recommendationWindow: TimeInterval = 120
}

/// 一条车控指令在**通道无关**层面的描述。
///
/// 蓝牙层用 `IBCommandType` 的控制码，云端用 `serviceId + command + parameters`，
/// 两套编码完全无关。把「用户想干什么」抽出来，各自翻译，避免两边互相污染。
enum VehicleCommand: Sendable, Equatable {
    case lock
    case unlock
    case windowUp
    case windowDown
    /// 车窗微开（通风位）。**只能走云端** —— 蓝牙协议里这条命令只区分
    /// 开/关两种状态（控制码 0x04 / 0x05），没有中间档。
    case windowVent
    case find
    /// 远程空调。`temperature` 就是抓包里 `rce` 的值（摄氏度）。
    /// ⚠️ 开、关都要带这个参数 —— 官方 App 关空调时也发当前温度。
    case airConditioner(on: Bool, temperature: Int)
    /// 远程启停引擎。**只能走云端** —— 车端 BLE 协议里没有控制码。
    case engine(on: Bool)

    var label: String {
        switch self {
        case .lock: return "闭锁"
        case .unlock: return "解锁"
        case .windowUp: return "关窗"
        case .windowDown: return "开窗"
        case .windowVent: return "微开"
        case .find: return "寻车"
        case .airConditioner(let on, _): return on ? "开空调" : "关空调"
        case .engine(let on): return on ? "启动引擎" : "熄火"
        }
    }

    /// 云端是否支持这条命令。
    ///
    /// 目前**全部支持** —— 最后一条缺口（空调 / 引擎启停）已于 2026-11-04
    /// 抓到真实参数并填入 `GKCloudClient.RemoteCommandTable`。
    ///
    /// 保留这个属性而不是直接删掉，是为了让 `send()` 里的守卫和
    /// `routeToCloudIfNeeded` 的判断继续有意义：将来若出现云端做不到的动作
    /// （比如需要诊断仪的配对类操作），在这里返回 false 即可，调用方不用改。
    var isSupportedOnNetwork: Bool { true }

    /// 蓝牙通道完全没有这条命令 —— 只能走云端。
    ///
    /// 空调 / 引擎启停就是这一类：车端 BLE 协议里没有对应控制码，
    /// 原厂 App 也做不到。所以路由时**不必看链路状态**，直接走云。
    var isNetworkOnly: Bool {
        !isSupportedOnBluetooth && isSupportedOnNetwork
    }

    /// 蓝牙通道是否支持。
    ///
    /// - 空调 / 引擎启停：车端协议里**没有**这两条，原厂 App 也做不到
    /// - 车窗微开：蓝牙只有「开窗 / 关窗」两态（0x05 / 0x04），没有中间档；
    ///   只有云端 `RWS start + rws:ventilate` 才有这个位置
    var isSupportedOnBluetooth: Bool {
        switch self {
        // 空调 / 引擎：车端没有这两条控制码（原厂 App 也做不到）
        // 微开：蓝牙只有开/关两态，没有中间档
        case .airConditioner, .engine, .windowVent: return false
        default: return true
        }
    }
}

/// 把两条通道的状态归一化成一个快照，供车辆模型区统一展示。
///
/// 蓝牙快照来自 `VehicleStatus`（16 字节广播明文，字段齐全但**只在车附近有**）；
/// 网络快照来自 `vehicleStatus`（74 个字段，任何地方都有但延迟数秒）。
/// 两者字段名、含义都不同，这里只保留两边都能表达的公共子集。
/// 车辆位置（车端上报）。
///
/// ## 坐标系
/// `latitude` / `longitude` 是 **WGS-84** 原始 GPS，和 `CLLocation` 一致。
/// 要交给 `MKMapView` / 地图 SDK 显示，必须先过 `CoordinateTransform.wgs84ToGCJ02` ——
/// 否则在中国大陆会偏 400–500 米。判定依据见 `CoordinateTransform` 的注释。
///
/// ## 单位
/// 服务端给的是**微度**（度 × 3,600,000）的字符串，解析时已经除掉；
/// 这里存的是标准度数，可以直接用。
struct VehicleCoordinate: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    /// 海拔（米）。车端不一定给，缺失时为 nil
    let altitude: Double?
    /// 车端自评「这条位置能不能信」。地库、隧道里通常是 false ——
    /// 这时界面必须标出来，不能拿一个不可信的点当实时位置。
    let trusted: Bool
    /// 这份位置**在车端被采集**的时刻（服务端 `updateTime`）。
    ///
    /// 注意它可能比当前时间早很多：车停稳后车机休眠，位置就不再更新。
    /// 「找车」场景里，这个时间和坐标本身一样重要 ——
    /// 拿两小时前的位置当刚停的位置，会让人在错误的地方绕圈。
    let reportedAt: Date

    /// 转成地图用的 GCJ-02。UI 只应该用它，不要直接把 `latitude/longitude` 丢给地图。
    var mapCoordinate: (latitude: Double, longitude: Double) {
        CoordinateTransform.wgs84ToGCJ02(latitude: latitude, longitude: longitude)
    }
}

struct VehicleSnapshot: Sendable, Equatable {
    var isLocked: Bool?
    var isTrunkClosed: Bool?
    var isDoorsClosed: Bool?
    var isEngineRunning: Bool?
    /// 四门是否关闭，顺序：左前 / 右前 / 左后 / 右后。
    /// 蓝牙广播（`parseDoorsStatus:`）和云端（`doorOpenStatus*`）都有这四个，
    /// 所以能精确到「哪一扇门开着」，而不是只有「有门开着」。
    var doorClosed: [Bool]? = nil
    /// 车窗是否「已知」。蓝牙广播里**没有**窗位字段，云端才有，
    /// 所以在蓝牙快照里恒为 false —— 不能把「不知道」当成「全关」。
    var isWindowsKnown: Bool = false
    var isWindowsClosed: Bool?
    var isSunroofOpen: Bool? = nil
    var updatedAt: Date

    /// 车辆位置。云端没回 `position`、或坐标全为 0 时为 nil。
    ///
    /// 蓝牙广播没有位置，只有云端车况带这个字段 ——
    /// 所以只用蓝牙时它是 nil，界面据此不显示地图卡。
    var coordinate: VehicleCoordinate? = nil

    // ★ 2026-11-04：删掉了 `source: ControlChannel` 字段。
    //   它和 `StatusSource` 表达同一件事（这份数据从哪来），但没人读它 ——
    //   界面一律用 `AppModel.activeStatus.source`。两个类型并存只会让人猜该信哪个。

    /// 超过这个时间就当作「不是实时状态」，UI 只展示不据此做推荐
    static var staleSeconds: TimeInterval { StatusFreshness.cloudWindow }

    var isFresh: Bool {
        Date().timeIntervalSince(updatedAt) <= Self.staleSeconds
    }
}

/// 云端请求的进行状态（UI 用）
enum CloudState: Equatable, Sendable {
    case idle
    /// 正在下发指令
    case sending(String)
    /// 正在拉状态
    case refreshing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .sending, .refreshing: return true
        case .idle, .failed: return false
        }
    }

    var text: String? {
        switch self {
        case .idle: return nil
        case .sending(let what): return "云端下发「\(what)」…"
        case .refreshing: return "云端读取车况…"
        case .failed(let msg): return msg
        }
    }
}

/// 云端返回的一个原始字段。`vehicleStatus` 有七十多个字段，
/// 语义化展示（车锁/车门那些）会丢掉大半 —— 这里保留全量，供「状态」页逐条列出。
struct StatusField: Identifiable, Hashable, Sendable {
    let id: String          // path 唯一，直接当 id
    /// 第一层分组名（basicVehicleStatus / additionalVehicleStatus / ...）
    let group: String
    /// 完整路径，去掉分组前缀后的部分，便于阅读
    let path: String
    /// 已格式化好的值（布尔转 是/否，空值转 —）
    let value: String
}

enum StatusFlattener {
    /// 把 `vehicleStatus` 递归摊平成「分组 + 路径 + 值」的扁列表。
    ///
    /// 之所以不硬编码字段名：服务端会加字段，硬编码的话新数据永远看不见。
    /// 摊平后至少能保证「拿到的都能看到」。
    static func flatten(_ dict: [String: Any]) -> [StatusField] {
        var out: [StatusField] = []
        for (group, value) in dict.sorted(by: { $0.key < $1.key }) {
            walk(value, group: group, prefix: group, into: &out)
        }
        return out.sorted { ($0.group, $0.path) < ($1.group, $1.path) }
    }

    private static func walk(_ value: Any, group: String, prefix: String,
                             into out: inout [StatusField]) {
        if let sub = value as? [String: Any] {
            if sub.isEmpty {
                out.append(StatusField(id: prefix, group: group,
                                       path: strip(prefix, group), value: "(空)"))
                return
            }
            for (k, v) in sub.sorted(by: { $0.key < $1.key }) {
                walk(v, group: group, prefix: "\(prefix).\(k)", into: &out)
            }
            return
        }
        if let arr = value as? [Any] {
            if arr.isEmpty {
                out.append(StatusField(id: prefix, group: group,
                                       path: strip(prefix, group), value: "(空)"))
            } else {
                let joined = arr.map(display).joined(separator: ", ")
                out.append(StatusField(id: prefix, group: group,
                                       path: strip(prefix, group), value: joined))
            }
            return
        }
        out.append(StatusField(id: prefix, group: group,
                               path: strip(prefix, group), value: display(value)))
    }

    private static func strip(_ path: String, _ group: String) -> String {
        path.hasPrefix(group + ".") ? String(path.dropFirst(group.count + 1)) : path
    }

    private static func display(_ value: Any) -> String {
        switch value {
        case is NSNull: return "—"
        case let b as Bool: return b ? "是" : "否"
        case let s as String: return s.isEmpty ? "—" : s
        case let n as NSNumber: return n.stringValue
        default: return String(describing: value)
        }
    }
}

/// 当前显示的状态**来自哪里**，以及它有多新。
///
/// 界面上必须能看出这个 —— 用户不知道「这是蓝牙实时」还是「这是三分钟前的云端快照」，
/// 就会拿过期数据做判断（比如以为车锁着，其实刚被人打开）。
enum StatusSource: Equatable, Sendable {
    /// 蓝牙广播解出来的，`at` = 最后一次收到车端信号的时间
    case bluetooth(Date)
    /// 云端拉的，`at` = 这次拉取的时间
    case cloud(Date)
    /// 两边都没有
    case none

    var label: String {
        switch self {
        case .bluetooth: return "蓝牙实时"
        case .cloud: return "云端"
        case .none: return "暂无数据"
        }
    }

    var icon: String {
        switch self {
        case .bluetooth: return "bolt.horizontal.circle.fill"
        case .cloud: return "wifi.circle.fill"
        case .none: return "questionmark.circle"
        }
    }

    var at: Date? {
        switch self {
        case .bluetooth(let d), .cloud(let d): return d
        case .none: return nil
        }
    }

    /// 超过这个时间就算「这份状态已经不新鲜了」
    static var staleSeconds: TimeInterval { StatusFreshness.cloudWindow }

    /// 界面上统一使用的来源文案：
    /// 「蓝牙实时 · 19:28」/「云端 · 19:28 更新」/「暂无数据」
    ///
    /// 之前 `RootView` 里 `statusPageSubtitle` 和 `keyStatusText` 各写了一份
    /// 几乎相同的 switch，改一处很容易漏掉另一处。
    var displayText: String {
        switch self {
        case .bluetooth(let at): return "蓝牙实时 · " + StatusTimeFormat.hhmm(at)
        case .cloud(let at):     return "云端 · " + StatusTimeFormat.hhmm(at) + " 更新"
        case .none:              return "暂无数据"
        }
    }
}
