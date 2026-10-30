import SwiftUI

/// 手表端入口。
///
/// ## 能力边界（先写清楚，避免以后误以为"没做完"）
///
/// watchOS **不给**普通 App 持续的后台 BLE：一退出前台就被挂起，
/// `Task.sleep` 不推进、扫描也停。所以手表端只做**前台控车**：
/// 抬腕 → 打开 App → 点解锁/闭锁/寻车。
///
/// 不做、也做不到的：
/// - 无感进入（走到车旁自动解锁）—— 需要常驻扫描
/// - 点火保活（每 30 秒 `0x0C`）—— 需要后台定时器
///
/// 协议栈完全复用手机端：`BLECentral` / `MeasuredSession` / `KeyStore`，
/// 手表只是换了一套更小的 UI 和密钥来源（从 iPhone 同步一次）。
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
