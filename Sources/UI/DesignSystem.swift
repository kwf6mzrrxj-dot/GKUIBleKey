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

    /// 滚动内容的底部留白。
    ///
    /// 悬浮标签栏（iOS 26）高约 56、离底 24，它的上半部分会**压住滚动内容**。
    /// 原来取 72 —— 少了 8pt，最后一行（引擎 / 电源）正好被切掉一半：
    /// 一半在标签栏下面、一半露在标签栏两侧，看起来像布局坏了。
    /// 96 = 标签栏顶沿（80）+ 16 的呼吸位。
    static let tabBarInset: CGFloat = 96

    // MARK: - 字体（只有五档，遇到新的先想想能不能复用已有的）
    //
    // 改之前全项目有 8 / 9 / 9.5 / 10 / 11 / 12 / 13 / 14 / 15 / 16 / 18 十一种字号，
    // 差别都在 1pt 上下 —— 读者说不出哪里不对，但会觉得"每块都不一样"。
    // 1pt 的差异不产生层级，只产生噪声；层级要靠**跨档**拉开（9 → 13 → 22）。

    enum Typo {
        /// 页标题（22pt）。三个 Tab 页与二级页标题共用这一档
        static let page = Font.title2.weight(.bold)
        /// 卡片标题 / 弹窗标题（15pt semibold）
        static let cardTitle = Font.system(size: 15, weight: .semibold)
        /// 正文、列表主行（13pt）
        static let body = Font.system(size: 13)
        /// 次要说明、按钮标签（11pt）
        static let caption = Font.caption
        /// 极次要信息、状态第三行（9pt）
        static let micro = Font.system(size: 9)
        /// 等宽数字（计时、dBm、字节）
        static func mono(_ size: CGFloat = 9) -> Font {
            .system(size: size, design: .monospaced)
        }
    }

    // MARK: - 语义色（同一个含义只用一个颜色）
    //
    // 排查时发现"成功"有时用 green、有时用 accent；通道色有的写 blue 有的写 green。
    // 这里固定下来，新代码只从这里取。
    enum Tone {
        /// 成功 / 在线 / 已连接
        static let success = Color.green
        /// 警告 / 需注意 / 过期
        static let warning = Color.orange
        /// 失败 / 危险
        static let danger = Color.red
        /// 蓝牙通道
        static let bluetooth = Color.blue
        /// 网络通道
        static let network = Color.green
        /// 发送 / 主动
        static let outgoing = Color.cyan
    }

    // MARK: - 层次（2026-11-05 阴影审查后新增）

    /// 界面分四层，每层只有一个视觉权重，别再让同类元素用不同深度。
    ///
    /// | 层 | 内容 | 阴影 |
    /// |---|---|---|
    /// | L0 | 渐变底 + 氛围光 | 无 |
    /// | L1 | 卡片（状态 / 设置 / 密钥） | `.card` |
    /// | L2 | 卡内嵌块（斑马纹 / 状态条 / 刻度带） | 无，靠底色 |
    /// | L3 | 浮层（日志浮窗 / 操作横幅） | `.floating` |
    ///
    /// 之前全项目只有浮窗一处 `.shadow`，且顺序写错被裁掉了 —— 等于**没有任何阴影**。
    /// 结果是所有面和背景之间只靠材质差别区分，浅色模式下卡片像"贴纸"，
    /// 浮窗像"贴纸上的黑纸"。层次不是靠加各种描边补出来的，是靠这两级投影建立的。
    enum Elevation {
        /// L1 卡片：接触阴影。极轻、近距离、只为了让面"离开底"一档
        case card
        /// L3 浮层：投影。明显的距离感，说明它盖在内容之上
        case floating
    }

    /// L2 斑马纹 —— 表格行交替底色。
    ///
    /// 之前是 `glassFill.opacity(0.5)` 和 `0.4` 两个值叠乘，
    /// 最终 3% / 2.4%，肉眼分不出，但每次合成都要算一遍两层 alpha。
    /// 收敛成单值：浅色 4.5% 黑 / 深色 5.5% 白 —— 刚好能横向串行，又不形成条纹。
    static func zebra(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
    }

    // MARK: - 描边

    /// 玻璃边缘高光。
    ///
    /// 之前散落着 `white.opacity(0.15)` / `0.12` 两处自绘描边，问题有两个：
    /// ① 浅色模式下白色描边压在浅底上等于隐形，深色下才成立 —— 同一根线时有时无；
    /// ② 与 `glassEffect` 自带高光叠在一起，转角处会出现双线。
    /// 现在统一交给系统材质，这里只保留需要强调"可点"的一层内描边。
    static func rimStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.55)
    }
}

// MARK: - 投影

/// 两级投影的实现。透明度与半径按明暗分开 —— 同一组数值不可能同时适配两种底：
/// 浅色底需要"轻而淡"，深色底需要"重而近"（黑压在近黑上，只能靠更大的 alpha 才有一点点分离）。
private struct GlassShadowModifier: ViewModifier {
    let level: Glass.Elevation
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let alpha: Double
        let radius: CGFloat
        let dy: CGFloat

        switch level {
        case .card:
            // ★ 深色下几乎不用投影。
            //
            // 投影靠"把背景压暗"产生分离，而深色背景本身亮度只有 0.07~0.11，
            // 再压 40% 也只是从 0.09 掉到 0.05 —— 肉眼看不出层次，
            // 却会在卡片四周留下**一圈更黑的边**，看起来像脏了。
            // 深色模式的层次由材质建立：玻璃比底亮一档，边界靠边缘高光。
            alpha = dark ? 0.18 : 0.07
            radius = dark ? 6 : 10
            dy = dark ? 2 : 3
        case .floating:
            // 浮层在深色下仍需要一点：它压住的是**内容**而不是空底，
            // 内容有亮有暗，纯靠描边分不开。但要配合描边一起用，
            // 单靠阴影在深色里同样无效。
            alpha = dark ? 0.45 : 0.18
            radius = dark ? 22 : 20
            dy = dark ? 9 : 8
        }

        return content.shadow(color: .black.opacity(alpha), radius: radius, y: dy)
    }
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
                    : [Color(red: 0.94, green: 0.96, blue: 0.99),
                       Color(red: 0.82, green: 0.85, blue: 0.91)],
                startPoint: .top, endPoint: .bottom)

            // 光源一：右上角主色雾光。
            //
            // 浓度从 0.14 提到 0.18、半径从 420 拉到 520：
            // 之前这层几乎看不出来，等于**玻璃背后是一片均匀的浅底** ——
            // 玻璃只模糊、没有可透的内容，于是每张卡片都变成一块白板。
            // 阴影再准也救不了：层次的根在背景，不在投影。
            RadialGradient(
                colors: [Color.accentColor.opacity(scheme == .dark ? 0.22 : 0.18),
                         .clear],
                center: .init(x: 0.85, y: 0.02),
                startRadius: 10,
                endRadius: 520)

            // 光源二：左下角冷雾。
            //
            // 只有一盏灯时，卡片从左上到右下透出的底色是一样的；
            // 加一盏对角的冷光后，同一张卡的两个角有轻微色温差，
            // 玻璃的"厚度"才立得住，也才有东西可投影。
            RadialGradient(
                colors: [Color(red: 0.60, green: 0.70, blue: 0.95)
                            .opacity(scheme == .dark ? 0.10 : 0.16),
                         .clear],
                center: .init(x: 0.10, y: 0.92),
                startRadius: 10,
                endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 玻璃容器

extension View {

    /// 统一玻璃卡片（系统 Liquid Glass 材质 + L1 接触阴影）。
    ///
    /// - Parameters:
    ///   - radius: 默认 `Glass.cardRadius`（20）；内嵌小卡传 `Glass.controlRadius`
    ///   - elevated: 是否加 `.card` 级投影。默认加；
    ///     **列表里成批出现的卡片要传 `false`** —— 一屏十几张都带投影时，
    ///     相邻两张的投影会在中间叠成一条灰带，反而比不加更脏，而且每张都要离屏合成。
    func glassCard(radius: CGFloat = Glass.cardRadius,
                   elevated: Bool = true) -> some View {
        let base = glassEffect(.regular, in: .rect(cornerRadius: radius))
        return Group {
            if elevated {
                base.glassElevation(.card)
            } else {
                base
            }
        }
    }

    /// 胶囊（顶栏状态、通道徽标）—— 与卡片同一材质，形状不同
    func glassPill() -> some View {
        glassEffect(.regular, in: .capsule)
    }

    /// 圆形小徽标（通道角标）。
    ///
    /// 原来这里是 `.ultraThinMaterial` + `Circle().strokeBorder(.white.opacity(0.12))`：
    /// 材质语言与卡片不同（模糊 vs 玻璃），描边在浅色底上又看不见 ——
    /// 16pt 的小圆上等于既没有厚度也没有边。
    func glassBadge() -> some View {
        glassEffect(.regular, in: .circle)
    }

    /// 小标签（"需网络"这类角标）
    func glassChip() -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: Glass.chipRadius))
    }

    /// 套一层投影（`.card` 或 `.floating`）。已是玻璃的视图用这个补层次。
    func glassElevation(_ level: Glass.Elevation) -> some View {
        modifier(GlassShadowModifier(level: level))
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
