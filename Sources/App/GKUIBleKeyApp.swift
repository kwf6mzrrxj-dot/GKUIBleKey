import SwiftUI

@main
struct GKUIBleKeyApp: App {
    /// ★ 用 `AppModel.shared` 而不是 `AppModel()`。
    ///
    /// App Intents（Siri / 快捷指令 / 操作按钮）在后台执行时拿的是
    /// `AppModel.shared`；如果这里再 new 一个，就会出现两个 `CBCentralManager`
    /// 同时抢同一台车 → 连接互相打断。
    @StateObject private var model = AppModel.shared

    /// ★ UIKit 层 URL 入口 —— 比 `.onOpenURL` 更可靠（冷启动不漏投）。
    /// 两者都保留，去重在 `AppModel.handleExternalURL` 里做。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // ★ 尽早载入日志配置（级别 / 单文件大小 / 保留天数），
        //   以便 App 启动阶段产生的日志就按用户配置过滤与轮转。
        FileLogger.shared.loadConfigFromDefaults()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // ★ 控制中心 / 锁屏控件的入口（`gkuiblekey://lock` 等）
                //
                // 控件那边用的是系统 `OpenURLIntent`：点一下先把 App 带到前台，
                // 再执行车控 —— 这条路径不依赖任何后台调度，是可靠性最高的。
                .onOpenURL { url in
                    model.handleExternalURL(url)
                }
        }
    }
}
