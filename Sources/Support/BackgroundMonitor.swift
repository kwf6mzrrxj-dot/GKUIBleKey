import Foundation
#if os(iOS)
import UIKit
#endif

/// 后台保活监控 —— 专门回答「App 退到后台 / 被系统回收后，还能不能干活」。
///
/// ## 为什么需要它
///
/// iOS 没有任何 API 能直接查「我现在还有没有后台执行权」。能查的只有
/// `UIApplication.shared.applicationState` 和 `backgroundTimeRemaining`，
/// 而后者在前台和后台都会返回巨大值，单看不出来。
///
/// 所以这里靠**三类证据反推**：
///
/// 1. **前后台切换 + 后台停留时长**
///    → 确认测试场景（切后台多久、什么时候回来）
///
/// 2. **30 秒心跳**（含状态 / 广播计数 / 连接次数 / 后台剩余时间）
///    → 心跳时间戳**断档 = 进程被挂起**。这是最硬的判据：
///      连续 30 秒一条 = 后台活着；出现 5 分钟空白 = 被挂起过。
///
/// 3. **进程重启间隔**（`UserDefaults` 存 lastSeen，每次心跳刷新）
///    → 冷启动时算「距上次存活多久」：
///      差距 30 秒内 = 一直在跑；差距几小时 = 被系统杀过。
///      再配合日志里有没有 `willRestoreState`，就能判断
///      「被杀了之后有没有被 BLE 事件唤醒」。
///
/// ## 使用方式
///
/// ```swift
/// BackgroundMonitor.shared.start()        // AppModel.init 里调一次
/// BackgroundMonitor.shared.noteBroadcast() // BLECentral 的 didDiscover 里
/// ```
///
/// 日志 `module = "保活"`，筛出来就是一条完整的时间线。
@MainActor
public final class BackgroundMonitor {

    public static let shared = BackgroundMonitor()
    private init() {}

    // MARK: - 持久化键

    private let lastSeenKey = "bgmon.lastSeen"
    private let launchCountKey = "bgmon.launchCount"

    // MARK: - 运行时状态

    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatIndex = 0
    private var broadcastCount = 0
    private var connectCount = 0
    private var disconnectCount = 0
    private var backgroundEnteredAt: Date?
    private var lastHeartbeatAt: Date?

    /// 当前是否在后台。
    ///
    /// 用来给「预认证这一轮是在前台还是后台发出的」打标记 ——
    /// 排查后台保活时，只看「已发次数」无法区分这两种情况，
    /// 而它们的意义完全不同（后台发出才说明保活真的在工作）。
    public private(set) var isInBackground = false

    /// 心跳间隔。30 秒足够密：既能看出断档，又不会把日志刷爆
    /// （一天约 2880 行，`FileLogger` 的轮转能扛住）。
    private let heartbeatInterval: TimeInterval = 30

    // MARK: - 生命周期

    /// App 启动时调用一次（`AppModel.init`）。
    public func start() {
        let now = Date()
        appLaunchTime = now

        // ⚠️ 顺序很重要：**先读旧的 lastSeen，再写入新的**。
        //    先写后读的话读到的就是刚写的 now，差值恒为 0，
        //    「被系统杀了多久」这条证据就永远看不到。
        let previous = UserDefaults.standard.object(forKey: lastSeenKey) as? Date
        let launch = UserDefaults.standard.integer(forKey: launchCountKey) + 1
        UserDefaults.standard.set(launch, forKey: launchCountKey)
        UserDefaults.standard.set(now, forKey: lastSeenKey)

        var msg = "[保活] 进程启动 #\(launch)"
        if let previous {
            let gap = now.timeIntervalSince(previous)
            msg += "，距上次存活 \(Self.format(gap))"
            if gap > 120 {
                msg += "（说明中间被系统终止过）"
            }
        } else {
            msg += "（首次启动）"
        }
        log(msg)
        log("[保活] 启动状态=\(stateText) 后台剩余=\(backgroundRemainingText)")

        startHeartbeat()
    }

    public func didEnterBackground() {
        isInBackground = true
        backgroundEnteredAt = Date()
        log("[保活] ⬇️ 进入后台（前台停留 \(Self.format(Date().timeIntervalSince(appLaunchTime)))）")
    }

    public func willEnterForeground() {
        isInBackground = false
        var msg = "[保活] ⬆️ 即将回前台"
        if let at = backgroundEnteredAt {
            let stay = Date().timeIntervalSince(at)
            msg += "（后台停留 \(Self.format(stay))，期间心跳 \(heartbeatIndex) 次，"
            msg += "理论应有 \(Int(stay / heartbeatInterval)) 次）"
            if let last = lastHeartbeatAt {
                let gap = Date().timeIntervalSince(last)
                msg += " 距上次心跳 \(Self.format(gap))"
            }
        }
        log(msg)
        backgroundEnteredAt = nil
    }

    public func didBecomeActive() {
        log("[保活] ✅ 已回前台 状态=\(stateText) 广播累计=\(broadcastCount) 连接=\(connectCount)")
    }

    // MARK: - BLE 事件计数

    public func noteBroadcast() { broadcastCount += 1 }
    public func noteConnect()   { connectCount += 1 }
    public func noteDisconnect() { disconnectCount += 1 }

    // MARK: - 心跳

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.beat()
            }
        }
    }

    private func beat() {
        heartbeatIndex += 1
        let now = Date()
        // 同样要先取旧值再覆盖，否则间隔恒为 0，断档检测失效。
        let previous = lastHeartbeatAt
        lastHeartbeatAt = now
        // 刷新 lastSeen：下次冷启动靠它算「被杀了多久」
        UserDefaults.standard.set(now, forKey: lastSeenKey)

        var line = "[保活] 心跳 #\(heartbeatIndex) 状态=\(stateText)"
        line += " 广播累计=\(broadcastCount) 连接=\(connectCount) 断开=\(disconnectCount)"
        line += " 后台剩余=\(backgroundRemainingText)"
        if let previous {
            let gap = now.timeIntervalSince(previous)
            if gap > heartbeatInterval * 2 {
                line += " ⚠️ 距上次心跳 \(Self.format(gap))，中间被挂起过"
            }
        }
        log(line)
    }

    // MARK: - 环境信息

    private var appLaunchTime = Date()

    private var stateText: String {
        // watchOS 没有 UIApplication（App 生命周期由 SwiftUI 管），
        // 手表端也没有"后台保活"这个概念 —— 直接给固定值。
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active:   return "前台"
        case .inactive: return "过渡(inactive)"
        case .background: return "后台"
        @unknown default: return "未知"
        }
        #else
        return "手表前台"
        #endif
    }

    private var backgroundRemainingText: String {
        #if os(iOS)
        let r = UIApplication.shared.backgroundTimeRemaining
        if r.isInfinite || r > 1_000_000 { return "无限" }
        return String(format: "%.0fs", r)
        #else
        return "不适用"
        #endif
    }

    private static func format(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0f 秒", seconds) }
        if seconds < 3600 {
            return String(format: "%.0f 分 %.0f 秒",
                          seconds / 60, seconds.truncatingRemainder(dividingBy: 60))
        }
        return String(format: "%.1f 小时", seconds / 3600)
    }

    private func log(_ line: String) {
        FileLogger.shared.info(line, module: "保活")
    }
}
