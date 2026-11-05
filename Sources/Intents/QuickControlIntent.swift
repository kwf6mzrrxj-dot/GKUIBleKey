import AppIntents
import os
import Foundation

/// 控制中心 / 锁屏控件用的「轻量动作枚举」。
///
/// ## 为什么不直接用 `IBCommandType`
///
/// 这份文件同时编进 **主 App** 和 **Widget 扩展**（控件必须在扩展里声明）。
/// 扩展里不编协议层，所以这里只放原始字符串，映射在主 App 侧做
/// （`QuickControlAction.command` 的扩展实现放在 `AppModel` 所在 target）。
enum QuickControlAction: String, AppEnum, CaseIterable {
    case lock
    case unlock
    case trunk
    case find

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "车辆动作")
    }

    static var caseDisplayRepresentations: [QuickControlAction: DisplayRepresentation] {
        [
            .lock:   DisplayRepresentation(title: "闭锁"),
            .unlock: DisplayRepresentation(title: "解锁"),
            .trunk:  DisplayRepresentation(title: "后备箱"),
            .find:   DisplayRepresentation(title: "寻车"),
        ]
    }

    var title: String {
        switch self {
        case .lock:   return "闭锁"
        case .unlock: return "解锁"
        case .trunk:  return "后备箱"
        case .find:   return "寻车"
        }
    }
}

/// 控件点击 → 在主 App 里执行车控。
///
/// ## 为什么不用 `OpenURLIntent`
///
/// v9.2 之前控件用 `OpenURLIntent(gkuiblekey://lock)`：靠系统打开自定义 scheme，
/// 再把动作交给 `onOpenURL`。真机反馈**点了完全没有日志** —— 说明 URL 根本没送达。
///
/// 换成 `AppIntent`：系统**在 App 进程里**执行 `perform()`，动作直接落地，
/// 不经过 URL 分发这一层。执行模式是 `.background`（不拉前台）——
/// 点控件只应在原地生效，不该把人带进 App。
///
/// 扩展里也编译这个类型（否则控件无法声明 action），但扩展那份 `perform()`
/// 被 `#if` 编空 —— 它不该在扩展里跑：扩展没有 `AppModel`，也没有 BLE 栈。
struct QuickControlIntent: AppIntent {
    static var title: LocalizedStringResource { "车辆快捷控制" }
    static var description: IntentDescription {
        IntentDescription("从控制中心 / 锁屏控件执行一次车控")
    }
    /// ★ **后台执行，不跳转 App**（2026-11-04 用户要求）。
    ///
    /// 控制中心/锁屏的控件点下去，用户期待的是「就地生效」，
    /// 而不是被带进一个 App、看完横幅再退出来。所以这里只要 `.background`：
    /// 系统在后台把 App 进程拉起来执行 `perform()`，界面不出现。
    ///
    /// 为什么能做到：
    /// - **云端通道**：后台发一个 HTTPS 请求，秒级完成，不需要前台
    /// - **蓝牙通道**：`UIBackgroundModes: bluetooth-central` 允许后台连接与收发
    ///
    /// 代价：后台没有可点的地方，失败了用户也看不到弹窗。所以结果一律写进
    /// Live Activity（锁屏卡片）与日志，用户在锁屏上就能看到「已通过云端闭锁」。
    ///
    /// ⚠️ 后台执行有时间预算（系统给的几十秒）。所以 `performControlAction`
    /// 里是**云端优先**：配了云端就走网络，不把时间花在重连 BLE 上。
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "动作")
    var action: QuickControlAction

    init() {}

    init(_ action: QuickControlAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        // 扩展这一份只是为了让 `ControlWidgetButton` 能声明 action 类型。
        // 扩展里没有 AppModel、也没有 BLE 栈，真正的工作必须在 App 进程完成。
        //
        // ★ 但万一系统真把动作路由到了扩展（这是排查时要确认的第一件事），
        //   至少留下一條能被看到的痕迹 —— 扩展里没有 FileLogger，
        //   用 os_log，在 Console.app 里按 subsystem 过滤即可：
        //     log stream --predicate 'subsystem == "com.mmxisme.gkuiblekey"'
        Logger(subsystem: "com.mmxisme.gkuiblekey", category: "control")
            .error("⚠️ 控件动作在扩展进程执行 —— 错误路径，App 侧不会收到")
        return .result()
        #else
        // ★ 必须 `await` 到真的结束（2026-11-05 修复）。
        //
        // 原来是 `await MainActor.run { performControlAction(action) }` ——
        // 那只保证了「同步调用发生在主线程」，`performControlAction` 内部
        // 发出的网络请求是个独立 `Task`，`perform()` 立刻返回。
        // 而 Intent 一结束，系统**马上挂起 App 进程**，请求还没发出去就被掐了。
        //
        // 表现就是：控件点了没反应，日志里连「控制中心控件 → 闭锁」都不一定有。
        let ok = await AppModel.shared.performControlAction(action)
        return .result(dialog: IntentDialog(stringLiteral: ok ? "已执行" : "执行失败"))
        #endif
    }
}
