import WidgetKit
import SwiftUI
import AppIntents

/// 控制中心 / 锁屏的「闭锁」控件。
///
/// ## 为什么用 `OpenURLIntent` 而不是自定义 `AppIntent`
///
/// 控件的 action 必须在 **Widget 扩展** 里声明，而我们的车控逻辑
/// （`AppModel` → `BLECentral` → 加密帧）全在主 App。扩展里既没有这些类型，
/// 也不该把整套 BLE 栈编进去。
///
/// `OpenURLIntent` 是系统提供的，声明时不需要引用任何业务类型：
/// 点一下就带着 URL 把 App 打开，剩下的交给 App 的 `onOpenURL`。
///
/// 副作用是「点控件会打开 App」—— 但这恰好是**可靠性最高**的路径：
/// App 一在前台，BLE 权限就是完整的，不用赌后台调度。
struct LockControlWidget: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.mmxisme.gkuiblekey.control.lock") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "gkuiblekey://lock")!)) {
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
            ControlWidgetButton(action: OpenURLIntent(URL(string: "gkuiblekey://unlock")!)) {
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
            ControlWidgetButton(action: OpenURLIntent(URL(string: "gkuiblekey://find")!)) {
                Label("寻车", systemImage: "location.fill")
            }
        }
        .displayName("寻车")
        .description("鸣笛闪灯，方便找车")
    }
}
