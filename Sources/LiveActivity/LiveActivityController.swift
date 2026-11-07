import Foundation
@preconcurrency import ActivityKit

/// 管理「数字钥匙」Live Activity 的生命周期。
///
/// ## 它不是 UI 装饰，是后台蓝牙权限的钥匙
///
/// Apple Core Bluetooth 文档（iOS 26+）：有 `CBManager` 实例 + 启动 Live Activity
/// 的 App，在后台可获得**与前台相同的 BLE 权限** —— 尤其是后台扫描时
/// `AllowDuplicates` 仍然生效（不会被系统合并成十几秒一次）。
///
/// 用户实测：同一份原厂 App 在 iOS 26 稳定点火、在 iOS 27 要试很多次。
/// （机制未确认：15 Pro + iOS 27 正常，更像 N1 芯片的组合问题。）
/// 差别不在 App 逻辑，而在系统是否给后台 BLE 权限。我们之前没有 Live Activity，
/// 后台广播被合并投递 → 29 秒的预认证节奏必然跑不准。
///
/// ## 何时开、何时关（2026-11-04 调整）
///
/// 由 `AppModel.refreshLiveActivity()` 决定，规则是「有内容就留、没内容就收」：
///
/// ```
/// 有状态（蓝牙实时 / 云端有数）        → 显示，数据源写在 statusText 里
/// 没状态，但开了预认证保活             → 仍然保留卡片（后台 BLE 权限的凭据）
/// 没状态，也没开保活                   → 结束，不在锁屏留空卡片
/// ```
///
/// 早期版本是"只在预认证保活开启时启动"，那样纯蓝牙用户（没开保活）
/// 永远看不到状态卡片；后来改成"只在云端配置时启动"，又让车在旁边的用户
/// 看到「暂无数据」。现在按内容判断，两种情况都不再出现。
@MainActor
public final class LiveActivityController {

    private var activity: Activity<VehicleActivityAttributes>?

    /// 内容多久没更新就让系统把卡片标为过期。
    ///
    /// ## 为什么必须给 `staleDate`
    /// App 被系统杀掉之后，没有任何代码在更新这张卡。之前传的是 `nil` ——
    /// 系统永远不会把它标成过期，锁屏上就一直挂着一份**看起来是实时的旧状态**。
    /// 用户据此判断"车锁着"然后走开，这比没有卡片更危险。
    ///
    /// ## 阈值为什么是 20 分钟而不是 5 分钟（2026-11-07 修正）
    ///
    /// 最初取 300 秒，想的是"比 `VehicleSnapshot.staleSeconds`（180 s）宽一档"。
    /// 那个思路错了 —— **两个阈值量的根本不是一回事**：
    ///
    /// - `staleSeconds` 判断的是「这份数据能不能用来做决策」（远程控车前要确认）
    /// - `staleDate` 判断的是「这张卡片还可能代表现状吗」
    ///
    /// 而**车锁状态在没人动它时是稳定的**。用户锁车走开、蓝牙断开、收不到广播，
    /// 这是最正常不过的场景；此时锁屏卡上写「已锁」依然是对的，
    /// 5 分钟后就把它标成「过期」属于误报。
    ///
    /// 20 分钟的依据：超过这个时长，人大概率已经离开了车的视野范围，
    /// 且期间车辆被他人操作的可能性开始变得不能忽略 —— 那时候提示"可能已过期"是有价值的。
    ///
    /// 只要 App 还活着且收得到广播，每次 `update` 都会把 staleDate 往后推
    /// （`measured.$status` 每帧触发，内部 2 秒节流），正常使用中不会触发。
    private static let staleAfter: TimeInterval = 1200

    /// 当前是否有活动在跑
    public var isRunning: Bool { activity != nil }

    /// 启动或复用（已存在则只更新内容）。
    ///
    /// App 被系统重启后 `activity` 是 nil，但系统里可能还留着上一次的活动，
    /// 所以先扫一遍 `Activity.activities` 复用，避免锁屏上堆两个卡片。
    /// - Returns: 是否「已在运行或刚启动成功」。调用方据此决定要不要退避重试。
    @discardableResult
    public func startOrUpdate(
        vehicleName: String,
        state: VehicleActivityAttributes.ContentState
    ) -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            FileLogger.shared.warning(
                "Live Activity 被系统关闭（设置 → 蓝牙钥匙 → 实时活动），后台 BLE 权限降级",
                module: "保活")
            return false
        }

        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(Self.staleAfter))

        if let a = activity {
            Task { @MainActor in await a.update(content) }
            return true
        }
        if let existing = Activity<VehicleActivityAttributes>.activities.first {
            activity = existing
            Task { @MainActor in await existing.update(content) }
            return true
        }
        do {
            activity = try Activity.request(
                attributes: VehicleActivityAttributes(vehicleName: vehicleName),
                content: content,
                pushType: nil)
            FileLogger.shared.info(
                "Live Activity 已启动（后台 BLE 权限提升为前台同级）", module: "保活")
            return true
        } catch {
            // 最常见的是 `Target is not foreground` —— App 被后台唤醒时无法 request，
            // 只能等下次回到前台再试（见 AppModel.refreshLiveActivity 的退避）。
            FileLogger.shared.warning(
                "Live Activity 启动失败：\(error.localizedDescription)（后台扫描会被合并）",
                module: "保活")
            return false
        }
    }

    /// 只更新内容（不创建）
    public func update(_ state: VehicleActivityAttributes.ContentState) {
        guard let a = activity else { return }
        let content = ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(Self.staleAfter))
        Task { @MainActor in await a.update(content) }
    }

    /// 结束并立即从锁屏移除
    public func end() {
        guard let a = activity else { return }
        activity = nil
        Task { @MainActor in await a.end(nil, dismissalPolicy: .immediate) }
        FileLogger.shared.info("Live Activity 已结束", module: "保活")
    }
}
