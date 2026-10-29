import SwiftUI
import UIKit

/// UIKit 层 URL 入口 —— **比 SwiftUI `.onOpenURL` 更可靠**。
///
/// ## 为什么需要它
///
/// 控制中心 / 锁屏控件用的是系统 `OpenURLIntent`，点一下会带 URL 打开 App。
/// 但 App **冷启动**时，SwiftUI 的 `.onOpenURL` 存在漏投：
///
/// 实测（2026-10-29 日志）：
/// ```text
/// 21:59:33.252  进程启动 #12            ← 用户点控件，App 冷启动
/// 21:59:33.273  Live Activity 已启动
/// 21:59:33.490  ✅ 已回前台              ← 确实到前台了
///               ［但没有任何「控制中心控件 → …」记录］
/// ```
/// URL 丢了。用户看到的就是「点了没反应」。
///
/// `application(_:open:options:)` 是 UIKit 层的**唯一权威入口**，冷启动时
/// 系统保证调用它（SwiftUI 的 `onOpenURL` 内部也走它，但时序上更晚、
/// 且在 scene 尚未连接时会丢）。
///
/// 两条路径都保留，由 `AppModel.handleExternalURL` 内部做 1.5 秒去重，
/// 所以即使两个入口都收到同一个 URL 也只会执行一次。
final class AppDelegate: NSObject, UIApplicationDelegate {

    /// iOS 26 把 `OpenURLOptionsKey` 标记为弃用、推荐改用 `UISceneDelegate`。
    ///
    /// 但 SwiftUI 的 App 生命周期下没有 `UISceneDelegate` 可挂（scene 由
    /// `WindowGroup` 托管），而这条 UIKit 入口正是我们要的**冷启动兜底**。
    /// 所以显式标注为「故意使用弃用入口」，注释即理由。
    @available(iOS, deprecated: 26.0,
               message: "SwiftUI 生命周期下无可用的 UISceneDelegate，故意保留作冷启动兜底")
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard url.scheme?.lowercased() == "gkuiblekey" else { return false }
        // `fromDelegate: true` → 标记「这是冷启动的首次投递」，
        // 让随后可能补发的 SwiftUI `.onOpenURL` 被去重（见 AppModel 里的说明）。
        AppModel.shared.handleExternalURL(url, fromDelegate: true)
        return true
    }
}
