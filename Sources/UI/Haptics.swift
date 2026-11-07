import SwiftUI

/// **触感反馈**。
///
/// ## 为什么不用 `UIImpactFeedbackGenerator` 直接调
///
/// 直接调要自己管三件事：生成器的线程（UIKit 是 `@MainActor`）、
/// `prepare()` 的时机（不 prepare 会有几十毫秒延迟）、
/// 以及 App 进后台后生成器的失效重建。
/// SwiftUI 的 `.sensoryFeedback` 把这三件都交给系统，代价是必须挂在**值变化**上。
///
/// ## 为什么是"并行手势"而不是包装 ButtonStyle
///
/// 系统的 `.glass` / `.glassProminent` 是 `PrimitiveButtonStyle` ——
/// 它的 `Configuration` 只暴露 `label` 和 `trigger()`，**没有 `isPressed`**，
/// 所以写不出「按下时震动」的包装器（`PrimitiveButtonStyleConfiguration`
/// 也没有公开 init，不能手动构造一个带回调的副本）。
///
/// `simultaneousGesture` 是"并行"识别，不与 Button 自身的手势竞争 ——
/// 按钮的 action 照常触发，多出来的一次 TapGesture 只负责计一次数。
///
/// ## 为什么不是每个按钮都同样强度
///
/// 触感是**分级信息**：全部一样重，等于告诉用户"每件事同等重要"。
/// 分三档：普通点击、主操作、危险动作。
extension View {

    /// 点按触感。挂在 Button 上（在 `.buttonStyle` 之后）。
    ///
    /// - Parameter feedback: 默认轻触（`Haptics.tap`）。
    ///   主操作传 `Haptics.commit`，危险动作用 `Haptics.warn`。
    ///
    /// ⚠️ **长按型按钮不要用这个** —— `HoldToConfirmButton` 用 `LongPressGesture`，
    /// 按住 0.6 秒后松手时 `TapGesture` 同样会识别（它没有时长上限），
    /// 会在命令发出的那一刻多震一次。那类按钮自己调 `Haptics.warn`。
    func tactile(_ feedback: SensoryFeedback = Haptics.tap) -> some View {
        modifier(TactileModifier(feedback: feedback))
    }
}

/// 触感的统一取值。
///
/// 用 `SensoryFeedback` 而不是 `UIImpactFeedbackGenerator.FeedbackStyle`：
/// 前者是 SwiftUI 原生类型，能直接喂给 `.sensoryFeedback`。
///
/// ⚠️ `impact` 有两个维度，别混：
/// - `weight: .light / .medium / .heavy` —— 力量（没有 rigid —— rigid 在下一个维度）
/// - `flexibility: .rigid / .solid / .soft` —— 软硬，rigid 是「硬而快地衰减」
enum Haptics {
    /// 普通按钮（次要动作、设置行、图标按钮）
    static let tap = SensoryFeedback.impact(weight: .light, intensity: 0.7)
    /// 主操作（解锁 / 闭锁 / 启动引擎 / 提交）
    static let commit = SensoryFeedback.impact(weight: .medium)
    /// 危险动作（长按确认完成、删除、解绑）——
    /// 用 rigidity 而不是更大的 weight：要的是「咔哒一下到位」的手感，
    /// 不是「更响」，后者在连续点击时会变成噪音。
    static let warn = SensoryFeedback.impact(flexibility: .rigid, intensity: 1.0)
    /// 选择切换（分段控件、单位切换）
    static let select = SensoryFeedback.selection
}

/// 实现：一次 TapGesture 只负责让 `tick` 自增，
/// 真正的触感由 `.sensoryFeedback` 在值变化时触发。
///
/// 拆成两步的原因：`sensoryFeedback` 只接受「值变化」作为触发条件，
/// 不接受"在这里震一下"这样的命令式调用。
private struct TactileModifier: ViewModifier {
    let feedback: SensoryFeedback

    @State private var tick = 0

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                TapGesture().onEnded { tick &+= 1 }
            )
            .sensoryFeedback(trigger: tick) { _, _ in feedback }
    }
}
