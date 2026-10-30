import SwiftUI

/// 手表端入口。
///
/// 手表**不直接连车**：BLE 的绑定密钥在 iPhone 的蓝牙控制器里导不出来，
/// 「仿冒 iPhone」在链路加密这一关就过不去。所以这里只做遥控 ——
/// 命令经 WatchConnectivity 交给 iPhone，由它用自己的绑定去发帧。
///
/// 代价：iPhone 必须在附近、且 App 能被唤起；因此**不排队命令**。
@main
struct GKUIBleKeyWatchApp: App {
    @StateObject private var controller = WatchRemoteController()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(controller)
                .task { controller.bootstrap() }
        }
    }
}
