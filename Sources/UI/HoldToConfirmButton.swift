import SwiftUI
import UIKit

/// **长按确认按钮** —— 用于"误触代价明显高于点击成本"的动作。
///
/// ## 为什么需要
///
/// 后备箱按钮误触 = 后备箱在商场停车场敞开一小时；开窗误触 = 雨里进水。
/// 这类动作不适合单击即执行，但也不适合每次弹确认框（太吵）。
/// 长按 0.6 秒是这两者之间的折中：手滑点不到，真要开也不费事。
///
/// ## 视觉（2026-11-05 第二版）
///
/// 第一版用一块绿色矩形遮罩铺满按钮，有三个问题：
/// 1. 遮罩的圆角（16）和系统 `.glass` 的实际圆角不一致 → 绿色从按钮四角露出来
/// 2. 遮罩盖在图标与文字**之上**，玻璃材质的高光被压住，看起来发脏
/// 3. 空 `Button(action: {})` 自带按压高亮，和自定义进度叠加成两层反馈
///
/// 现在改成：
/// - **底部一条 2.5pt 进度胶囊**（内缩 14pt），只占空白，不遮内容
/// - 按下时整体缩到 0.97，给"按住有效"的物理感
/// - 玻璃底复用系统 `.buttonStyle(.glass)`（按钮 `allowsHitTesting(false)`，
///   手势由外层透明层接管，否则 Button 会先吃掉按下事件）
struct HoldToConfirmButton<Label: View>: View {
    /// 长按到位后执行
    let action: () -> Void
    /// 长按时长
    var holdSeconds: Double = 0.6
    @ViewBuilder var label: Label

    @State private var pressing = false

    var body: some View {
        ZStack {
            // 只借外观，不参与事件
            Button(action: {}) { label }
                .buttonStyle(.glass)
                .allowsHitTesting(false)

            progressBar

            // 手势层
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: holdSeconds,
                                    maximumDistance: 40,
                                    pressing: { isPressing in
                    pressing = isPressing
                    if isPressing {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }, perform: {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    action()
                })
        }
        .scaleEffect(pressing ? 0.97 : 1)
        .brightness(pressing ? 0.03 : 0)
        .animation(.easeOut(duration: 0.12), value: pressing)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("长按 \(String(format: "%.1f", holdSeconds)) 秒执行")
        // 辅助功能用户无法"长按"，给一个等效的激活动作
        .accessibilityAction { action() }
    }

    /// 贴底进度条：只占按钮下方的留白，不压图标与文字
    private var progressBar: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: pressing ? geo.size.width : 0, height: 2.5)
                    // 涨满用 holdSeconds（线性，像进度）；
                    // 松手用 0.12 秒快速退回，不要用同一个时长 —— 那看起来像倒放
                    .animation(pressing
                               ? .linear(duration: holdSeconds)
                               : .easeOut(duration: 0.12),
                               value: pressing)
            }
            .frame(height: 2.5)
            .padding(.horizontal, 14)
            .padding(.bottom, 7)
        }
        .allowsHitTesting(false)
    }
}
