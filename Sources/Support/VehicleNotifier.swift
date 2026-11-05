import Foundation
import UserNotifications
import os

/// 通知模块的日志。放在文件级（而不是 `@MainActor` 类的静态属性）——
/// `UNUserNotificationCenter.add` 的完成闭包是 `@Sendable` 的，
/// 里面引用 MainActor 隔离的属性会过不了严格并发检查。
private let vehicleNotifyLog = Logger(subsystem: "com.mmxisme.gkuiblekey",
                                     category: "notify")

/// 本地通知 —— 车控软件最容易被抱怨的那件事："我到底锁了没有"。
///
/// ## 为什么只能做本地通知
///
/// 没有后台服务端（免费账号也没有推送证书），所以拿不到车端的主动推送。
/// 但有一个**很强的本地信号**：蓝牙链路断开。
/// 人离开车 → 车端停止广播 → 链路断开，这个时刻恰好是"该提醒"的时刻。
///
/// 于是策略只有一条：
/// - 链路断开时，如果最后已知状态是**未锁 / 门未关 / 后备箱未关** → 发一条本地通知
/// - 其它情况一律不发（包括"正常锁好离开"，避免噪音）
///
/// ## 配额
/// 每天最多 3 条。这个数字不是拍脑袋：蓝牙在车库、电梯口会反复断连，
/// 不设上限的话一天能弹二十次，用户第一件事就是去系统设置里关掉通知 ——
/// 那之后连真正需要的提醒也收不到了。
@MainActor
public final class VehicleNotifier {

    public static let shared = VehicleNotifier()

    /// 通知总开关（默认开，但首次需要系统授权）
    public static let enabledKey = "gkuiblekey.notify.unlocked"
    /// 每日配额
    private static let dailyLimit = 3

    private static let quotaDateKey = "gkuiblekey.notify.quota.date"
    private static let quotaCountKey = "gkuiblekey.notify.quota.count"

    private var didRequest = false
    /// 下一次链路断开不提醒（用户主动断开时使用）
    private var suppressNext = false

    private init() {}

    /// 用户主动断开连接时调用 —— 这不是"人离开车"，不该发提醒。
    public func suppressNextLinkLost() {
        suppressNext = true
    }

    // MARK: - 授权

    /// 首次进入 App 时请求授权。
    ///
    /// 只请求一次（系统本身也只弹一次）；用户拒绝后不反复骚扰，
    /// 设置页里有入口可以跳系统设置。
    public func requestAuthorizationIfNeeded() async {
        guard !didRequest else { return }
        didRequest = true
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            vehicleNotifyLog.info("通知授权：\(granted ? "已允许" : "被拒绝", privacy: .public)")
        } catch {
            vehicleNotifyLog.error("通知授权失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 当前授权状态（设置页展示用）
    public func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - 触发

    /// 链路断开时调用。只在"确实该提醒"的时候发通知。
    ///
    /// - Parameter snapshot: 最后已知的车况（`AppModel.activeStatus.snapshot`）
    func handleLinkLost(snapshot: VehicleSnapshot?) {
        if suppressNext {
            suppressNext = false
            return
        }
        guard UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true else {
            return
        }
        guard let snapshot else { return }

        // 逐级判断：未锁 > 门/后备箱未关。两种都命中也只发一条（先说不锁）。
        let message: String
        if snapshot.isLocked == false {
            message = "离开时车辆未锁。点击查看并锁车。"
        } else if snapshot.isDoorsClosed == false {
            message = "离开时有车门未关。点击查看。"
        } else if snapshot.isTrunkClosed == false {
            message = "离开时后备箱未关。点击查看。"
        } else {
            return
        }

        guard consumeQuota() else {
            vehicleNotifyLog.info("今日提醒配额已用完，跳过")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = snapshot.isLocked == false ? "车辆未锁" : "车门/后备箱未关"
        content.body = message
        content.sound = .default
        content.categoryIdentifier = "VEHICLE_STATE"

        let request = UNNotificationRequest(identifier: "vehicle-unlocked-\(UUID().uuidString)",
                                            content: content,
                                            trigger: nil)   // nil = 立即
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                vehicleNotifyLog.error("通知投递失败：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - 配额

    /// 消耗一次配额；返回 false 表示今天已经发满了
    private func consumeQuota() -> Bool {
        let d = UserDefaults.standard
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())

        if d.string(forKey: Self.quotaDateKey) != today {
            d.set(today, forKey: Self.quotaDateKey)
            d.set(0, forKey: Self.quotaCountKey)
        }
        let used = d.integer(forKey: Self.quotaCountKey)
        guard used < Self.dailyLimit else { return false }
        d.set(used + 1, forKey: Self.quotaCountKey)
        return true
    }
}
