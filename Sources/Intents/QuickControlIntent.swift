import AppIntents
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
/// 换成 `AppIntent` + `openAppWhenRun = true`：系统先把 App 带到前台，
/// 再**在 App 进程里**执行 `perform()`，动作直接落地，不经过 URL 分发这一层。
///
/// 扩展里也编译这个类型（否则控件无法声明 action），但扩展那份 `perform()`
/// 被 `#if` 编空 —— 它不该在扩展里跑：扩展没有 `AppModel`，也没有 BLE 栈。
struct QuickControlIntent: AppIntent {
    static var title: LocalizedStringResource { "车辆快捷控制" }
    static var description: IntentDescription {
        IntentDescription("从控制中心 / 锁屏控件执行一次车控")
    }
    /// ★ 先把 App 带到前台再执行 —— 前台 BLE 权限完整，且能给出可见反馈
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "动作")
    var action: QuickControlAction

    init() {}

    init(_ action: QuickControlAction) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await MainActor.run {
            AppModel.shared.performControlAction(action)
        }
        #endif
        return .result()
    }
}
