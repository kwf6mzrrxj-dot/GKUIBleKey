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
/// 现在改用 `QuickControlIntent`，执行模式是 `.background`：
/// 系统在后台把 App 进程拉起来执行 `perform()`，**不切前台、不打开 App**，
/// 动作直接落到 `AppModel`，也不经过 URL 分发。
///
/// 结果反馈不靠弹窗（后台没有界面），而是写进 Live Activity：
/// 锁屏卡片上会显示「蓝牙 · 19:28 / 云端 · 19:28」以及最新的锁态。
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
