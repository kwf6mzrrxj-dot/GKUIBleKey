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
/// 用户实测：**同一份原厂 App 在 iOS 26 稳定点火、在 iOS 27 抽奖**。
/// 差别不在 App 逻辑，而在系统是否给后台 BLE 权限。我们之前没有 Live Activity，
/// 后台广播被合并投递 → 29 秒的预认证节奏必然跑不准。
///
/// ## 何时开、何时关
///
/// 只在「预认证保活开启」时启动 —— 那正是需要后台 BLE 的场景。
/// 关掉保活就立即结束，避免锁屏上留一个没用的卡片。
@MainActor
public final class LiveActivityController {

    private var activity: Activity<VehicleActivityAttributes>?

    /// 当前是否有活动在跑
    public var isRunning: Bool { activity != nil }

    /// 启动或复用（已存在则只更新内容）。
    ///
    /// App 被系统重启后 `activity` 是 nil，但系统里可能还留着上一次的活动，
    /// 所以先扫一遍 `Activity.activities` 复用，避免锁屏上堆两个卡片。
    public func startOrUpdate(
        vehicleName: String,
        state: VehicleActivityAttributes.ContentState
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            FileLogger.shared.warning(
                "Live Activity 被系统关闭（设置 → 蓝牙钥匙 → 实时活动），后台 BLE 权限降级",
                module: "保活")
            return
        }

        let content = ActivityContent(state: state, staleDate: nil)

        if let a = activity {
            Task { @MainActor in await a.update(content) }
            return
        }
        if let existing = Activity<VehicleActivityAttributes>.activities.first {
            activity = existing
            Task { @MainActor in await existing.update(content) }
            return
        }
        do {
            activity = try Activity.request(
                attributes: VehicleActivityAttributes(vehicleName: vehicleName),
                content: content,
                pushType: nil)
            FileLogger.shared.info(
                "Live Activity 已启动（后台 BLE 权限提升为前台同级）", module: "保活")
        } catch {
            FileLogger.shared.warning(
                "Live Activity 启动失败：\(error.localizedDescription)（后台扫描会被系统合并）",
                module: "保活")
        }
    }

    /// 只更新内容（不创建）
    public func update(_ state: VehicleActivityAttributes.ContentState) {
        guard let a = activity else { return }
        Task { @MainActor in await a.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// 结束并立即从锁屏移除
    public func end() {
        guard let a = activity else { return }
        activity = nil
        Task { @MainActor in await a.end(nil, dismissalPolicy: .immediate) }
        FileLogger.shared.info("Live Activity 已结束", module: "保活")
    }
}
