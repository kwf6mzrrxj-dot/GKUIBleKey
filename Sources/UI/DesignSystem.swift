import SwiftUI

/// **液态玻璃设计规范（Liquid Glass）**
///
/// 汇总到一处的原因：改之前同一种"卡片"在项目里有 4 种写法 ——
/// `glassEffect(.regular)`（密钥页）、`.ultraThinMaterial` 无描边、
/// `.ultraThinMaterial` + 自绘描边（主界面）、纯 `systemBackground`（日志/诊断页）；
/// 圆角也在 20/16/14/12/10/22 之间乱跳。看起来像四个人各做一半。
///
/// ## 为什么统一到 `glassEffect` 而不是 `.ultraThinMaterial`
///
/// `.ultraThinMaterial` 只是模糊，没有折射、没有边缘高光、没有厚度；
/// 想让它"像玻璃"就得自己补描边和阴影，于是每个地方补的参数都不一样 ——
/// 这正是风格不一致的根源。
///
/// `glassEffect` 是 iOS 26 起系统提供的 Liquid Glass 材质，
/// 与 `.buttonStyle(.glass)`、控制中心、Dock 用的是**同一套**渲染，
/// 高光方向、折射强度、深浅色适配都由系统统一。
/// 所有面板一律走它，才能和系统控件看起来是一体的。
enum Glass {

    // MARK: - 圆角（只有三档，别再发明第四档）

    /// 大卡片（车辆状态、设置分组、日志卡、密钥卡）
    static let cardRadius: CGFloat = 20
    /// 控件容器（内嵌小卡、刻度带）
    static let controlRadius: CGFloat = 14
    /// 胶囊与小标签（状态胶囊、通道徽标）
    static let pillRadius: CGFloat = 12
    /// 极小标签（"需网络"这类角标）
    static let chipRadius: CGFloat = 6

    // MARK: - 间距（4 的倍数）

    /// 卡片内边距
    static let cardPadding: CGFloat = 16
    /// 卡片之间
    static let sectionSpacing: CGFloat = 14
    /// 卡片内部元素之间
    static let innerSpacing: CGFloat = 10
    /// 页面左右边距
    static let pageMargin: CGFloat = 20
}

// MARK: - 屏幕背景

/// 全屏底：一层纵向渐变 + 一层右上角氛围光。
///
/// 玻璃之所以像玻璃，前提是**背后有东西可透**。纯 `systemBackground`
/// 会让材质退化成一块灰板 —— 这是之前二级页（日志 / 诊断 / 密钥）
/// 看起来"廉价"的根本原因。
struct GlassScreenBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.11, green: 0.12, blue: 0.16),
                       Color(red: 0.06, green: 0.07, blue: 0.10)]
                    : [Color(red: 0.93, green: 0.95, blue: 0.98),
                       Color(red: 0.84, green: 0.87, blue: 0.92)],
                startPoint: .top, endPoint: .bottom)

            // 氛围光：不参与交互，只为让上方玻璃有层次
            RadialGradient(
                colors: [Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.14),
                         .clear],
                center: .init(x: 0.85, y: 0.02),
                startRadius: 10,
                endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 玻璃容器

extension View {

    /// 统一玻璃卡片（系统 Liquid Glass 材质）。
    ///
    /// - Parameters:
    ///   - radius: 默认 `Glass.cardRadius`（20）；内嵌小卡传 `Glass.controlRadius`
    ///   - elevated: 兼容旧调用点。系统材质自带层次，这个参数目前不影响渲染，
    ///     保留是为了不逐个改调用方；将来若要区分投影再加。
    func glassCard(radius: CGFloat = Glass.cardRadius,
                   elevated: Bool = true) -> some View {
        let _ = elevated
        return glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// 胶囊（顶栏状态、通道徽标）—— 与卡片同一材质，形状不同
    func glassPill() -> some View {
        glassEffect(.regular, in: .capsule)
    }

    /// 小标签（"需网络"这类角标）
    func glassChip() -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: Glass.chipRadius))
    }
}

// MARK: - 分组容器

/// 把一屏里的多个玻璃面板包进来，让系统在同一容器内统一处理折射与重叠。
///
/// 不包也能跑，但相邻的两块玻璃各自采样背景，边界处会出现一道"接缝"。
struct GlassSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(spacing: Glass.sectionSpacing) {
            content
        }
    }
}
