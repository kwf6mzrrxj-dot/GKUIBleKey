import SwiftUI

/// 手表端入口。
///
/// ## 手表是**独立的钥匙**，不是手机的遥控器
///
/// 一开始的判断是「BLE 绑定密钥（LTK/IRK）在 iPhone 的蓝牙控制器里导不出来，
/// 手表仿冒不了 iPhone，所以只能当遥控器」。前半句对，后半句错 ——
/// 导不出来只说明**不能复用手机的绑定**，不代表手表不能有自己的绑定：
/// 车端一车可挂 **5 台**设备（`Docs/DEPLOY_TO_IPHONE.md`），
/// 手表自己走一遍「诊断仪窗口 → 6 位码 → 0x0D → 0x0E」就能拿到
/// 属于自己这个槽位的密钥（`Docs/INBLUE_PROTOCOL_SPEC.md` 5.10）。
///
/// 代价：手表得单独配一次对（不能白拿手机的钥匙）；收益：配好之后
/// **手机不在身边也能开车**，而且钥匙不需要跨设备传输。
@main
struct GKUIBleKeyWatchApp: App {
    @StateObject private var controller = WatchVehicleController()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(controller)
                .task { controller.bootstrap() }
        }
    }
}
