import SwiftUI

/// 手表端入口。
///
/// ## 定位（2026-11-04 彻底重构）
///
/// **手表 = 手机的远程遥控器**，走云端，不碰蓝牙。
///
/// 旧版让手表自己当一把钥匙：在表上跑完整 BLE 协议栈（扫描 / `01→04` 会话 /
/// `0x0D` 配对 / `0x0C` 保活）。放弃它的理由是三条硬事实：
///
/// 1. watchOS **没有** `bluetooth-central` 后台模式 —— 熄屏即挂起，
///    「靠近解锁」在表上不可能成立
/// 2. 手表要**单独配一次对**（诊断仪开窗口 + 6 位码），实际几乎配不成功
/// 3. 协议栈里一大半代码只为了证明「钥匙在场」，而这件事对一块表没有意义
///
/// 现在账号与手机共用（`PhoneWatchSync` 推送），数据与命令全部走云端
/// `device-api.xchanger.cn`。手表的职责只剩：抬手看状态、抬腕按一下。
@main
struct GKUIBleKeyWatchApp: App {
    @StateObject private var controller = WatchCloudController()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchRootView()
            }
            .environmentObject(controller)
            .task { controller.activate() }
        }
    }
}
