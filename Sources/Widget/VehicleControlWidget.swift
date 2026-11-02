import WidgetKit
import SwiftUI
import AppIntents

/// 控制中心 / 锁屏的「闭锁」控件。
///
/// ## 为什么用 `QuickControlIntent` 而不是 `OpenURLIntent`（2026-11-02 改）
///
/// 原来用 `OpenURLIntent(gkuiblekey://lock)`：靠系统打开自定义 scheme，
/// 再把动作交给 App 的 `onOpenURL`。真机反馈是**点了完全没有日志** ——
/// 说明 URL 根本没送达，整条链在路上就断了。
///
/// 现在改用 `QuickControlIntent`：`openAppWhenRun = true`，
/// 系统先把 App 带到前台，再**在 App 进程里**执行 `perform()`，
/// 动作直接落到 `AppModel`，不经过 URL 分发。
///
/// 代价与以前一样：点控件会打开 App。好处是前台 BLE 权限完整，
/// 而且能在界面上给出可见反馈（顶部横幅「已收到控件：闭锁」）。
struct LockControlWidget: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mmxisme.gkuiblekey.control.lock") {
            ControlWidgetButton(action: QuickControlIntent(.lock)) {
                Label("闭锁", systemImage: "lock.fill")
            }
        }
        .displayName("车辆闭锁")
        .description("一键闭锁车门")
    }
}

/// 控制中心 / 锁屏的「解锁」控件。
struct UnlockControlWidget: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mmxisme.gkuiblekey.control.unlock") {
            ControlWidgetButton(action: QuickControlIntent(.unlock)) {
                Label("解锁", systemImage: "lock.open.fill")
            }
        }
        .displayName("车辆解锁")
        .description("一键解锁车门")
    }
}

/// 控制中心的「寻车」控件（鸣笛闪灯）。
struct FindControlWidget: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mmxisme.gkuiblekey.control.find") {
            ControlWidgetButton(action: QuickControlIntent(.find)) {
                Label("寻车", systemImage: "location.fill")
            }
        }
        .displayName("寻车")
        .description("鸣笛闪灯，方便找车")
    }
}
