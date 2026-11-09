import CoreLocation
import Foundation

/// 手机当前定位 —— 只服务于「车辆位置」地图卡。
///
/// ## 为什么不复用 `BLECentral` 里那个 `CLLocationManager`
/// `BLECentral` 确实有一个，但它的唯一职责是**让 iBeacon 扫描拿到权限**，
/// 从不读位置，而且生命周期跟蓝牙绑死（断连就停）。地图卡需要的恰好相反：
/// 只有站在路边找车时才用，与蓝牙链路无关。
///
/// ## 坐标系（这里最容易出错）
/// `CLLocation` 给的是 **WGS-84**，车端给的也是 WGS-84。
/// 两个点都必须在显示前过 `CoordinateTransform.wgs84ToGCJ02` ——
/// **只转一边**的话蓝点和车标会差出 400 米，看起来像"车停在隔壁街区"，
/// 而这种错在地图上完全不像 bug，用户只会觉得车真的停那儿。
///
/// ## 为什么不做后台常驻
/// `Info.plist` 里有 `location` 后台模式（那是靠近解锁要的），
/// 但这个类**只在卡片可见期间** `start()`，`onDisappear` 就 `stop()`。
/// 找车是几秒钟的事，没必要为它一直开着 GPS。
@MainActor
final class UserLocationProvider: NSObject, ObservableObject {

    /// 一次定位结果。存原始值而不是 `CLLocation`：
    /// 跨 actor 传递时不必依赖 CoreLocation 的 `Sendable` 标注。
    struct Fix: Sendable, Equatable {
        /// WGS-84 纬度
        let latitude: Double
        /// WGS-84 经度
        let longitude: Double
        /// 水平精度（米）。用来判断这个点够不够准
        let accuracy: Double
        let at: Date

        /// GCJ-02 —— 交给 MapKit 的版本
        var mapCoordinate: (latitude: Double, longitude: Double) {
            CoordinateTransform.wgs84ToGCJ02(latitude: latitude, longitude: longitude)
        }
    }

    /// 全 App 共用一个。
    ///
    /// 车控页和状态页各有一张位置卡，两边若各建一个 `CLLocationManager`，
    /// 就是两个 GPS 会话在同时跑 —— 耗电翻倍，而且两边的时间戳会不一致。
    /// 共享之后用**引用计数**管理生命周期：最后一个使用者消失才真正停。
    ///
    /// ## ⚠️ 已知行为：计数可能停在非零，这不是泄漏
    /// SwiftUI 的 `TabView` 会保留已访问页的视图，`onAppear` / `onDisappear`
    /// **不随切页配对**。所以两页都看过之后，计数会稳定在 2，GPS 会话不关。
    ///
    /// 这是有意接受的：
    /// - `desiredAccuracy = nearestTenMeters` + `distanceFilter = 15`，
    ///   站着不动时根本不产生定位回调，也就没有耗电；
    /// - 找车是高频操作，每次进页面重起 GPS 反而要等首点。
    ///
    /// **不要**为了"关掉它"去加定时器或改 `scenePhase` 逻辑 ——
    /// 那会让"切页回来位置是空的"变成新问题。
    /// 真正需要修的是**成对性**：任何 `start()` 都必须有对应的 `stop()`
    /// （全屏地图曾经漏过一次，见 CODE_REVIEW_2026-11-07_ROUND6 的 P0-1）。
    static let shared = UserLocationProvider()

    @Published private(set) var fix: Fix?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// 定位失败的原因（权限被拒 / 服务关闭）。界面据此给一句人话。
    @Published private(set) var failure: String?

    /// 当前有多少个视图在用它
    private var activeUsers = 0

    private lazy var manager: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        // 找车不需要亚米级：城市里 10 米足够判断"在路这边还是那边"，
        // 而 `Best` 会把 GPS 拉满，从打开卡片开始就一直耗电。
        m.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        // 走出 15 米才回调。站着不动时不该每秒都产生一个新坐标。
        m.distanceFilter = 15
        return m
    }()

    /// 卡片出现时调用（可重入，按引用计数）。
    func start() {
        activeUsers += 1
        guard activeUsers == 1 else { return }   // 已经有一个使用者，不重复启动

        _ = manager                       // 触发 lazy 初始化，挂上 delegate
        refreshAuthorization()

        switch authorization {
        case .notDetermined:
            // 只为"看我在哪"申请，不升级到 Always ——
            // 后台定位已经由靠近解锁那条链路单独申请过，两者不该互相牵连。
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            failure = nil
            manager.startUpdatingLocation()
        case .denied, .restricted:
            failure = "位置权限未开启，看不到你和车的相对位置"
        @unknown default:
            break
        }
    }

    /// 卡片消失时调用。
    ///
    /// `stopUpdatingLocation()` 不会清 `fix` —— 上次的位置仍有参考价值
    /// （可能只是切到别的页又回来），重新 `start()` 会立刻补一个新点。
    func stop() {
        activeUsers = max(0, activeUsers - 1)
        guard activeUsers == 0 else { return }
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways
        else { return }
        manager.stopUpdatingLocation()
    }

    private func refreshAuthorization() {
        let status = manager.authorizationStatus
        authorization = status
        if status == .denied || status == .restricted {
            failure = "位置权限未开启，看不到你和车的相对位置"
        }
    }
}

extension UserLocationProvider: CLLocationManagerDelegate {

    /// 回调在创建 manager 的 run loop（主线程）上，但 delegate 协议本身
    /// 不标 `@MainActor`，所以显式声明 `nonisolated` 再跳回主 actor，
    /// 不依赖"它一定在主线程"这个隐式约定。
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        // 负数表示这次定位无效（CoreLocation 用它表示"未知"）
        guard last.horizontalAccuracy >= 0 else { return }

        let fix = Fix(latitude: last.coordinate.latitude,
                      longitude: last.coordinate.longitude,
                      accuracy: last.horizontalAccuracy,
                      at: last.timestamp)
        Task { @MainActor [weak self] in
            self?.fix = fix
            self?.failure = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // 权限类错误由 `locationManagerDidChangeAuthorization` 统一处理，
        // 这里只接「暂时定不到位」（进隧道、地库里常见），不把它当致命错。
        guard (error as? CLError)?.code != .denied else { return }
        Task { @MainActor [weak self] in
            self?.failure = "正在定位…"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorization = status
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                self.failure = nil
                self.manager.startUpdatingLocation()
            case .denied, .restricted:
                self.fix = nil
                self.failure = "位置权限未开启，看不到你和车的相对位置"
            default:
                break
            }
        }
    }
}

// MARK: - 距离

extension UserLocationProvider.Fix {
    /// 到某点的直线距离（米）。
    ///
    /// 用**原始 WGS-84** 算，不拿 GCJ-02 算：
    /// 在地面走路/开车的尺度上两者差不到 1 米，但这里的输入本来就是原始值，
    /// 少一次转换就少一处可能对不上的地方。
    func distance(to coordinate: VehicleCoordinate) -> CLLocationDistance {
        let a = CLLocation(latitude: latitude, longitude: longitude)
        let b = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return a.distance(from: b)
    }

    /// 这个点够不够准 —— 精度圈超过 100 米时（室内、地库）没什么参考价值
    var isUsable: Bool { accuracy > 0 && accuracy < 100 }
}
