import SwiftUI

@main
struct GKUIBleKeyApp: App {
    /// ★ 用 `AppModel.shared` 而不是 `AppModel()`。
    ///
    /// App Intents（Siri / 快捷指令 / 操作按钮）在后台执行时拿的是
    /// `AppModel.shared`；如果这里再 new 一个，就会出现两个 `CBCentralManager`
    /// 同时抢同一台车 → 连接互相打断。
    @StateObject private var model = AppModel.shared

    init() {
        // ★ 尽早载入日志配置（级别 / 单文件大小 / 保留天数），
        //   以便 App 启动阶段产生的日志就按用户配置过滤与轮转。
        FileLogger.shared.loadConfigFromDefaults()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}
