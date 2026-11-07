import SwiftUI

/// **液态玻璃设计规范（Liquid Glass）**
///
/// ## 三种材质，各管一层（2026-11-07 重新分层）
///
/// iOS 26/27 的 Liquid Glass 有一条容易被忽略的前提：
/// **玻璃是"控件层"的材质，不是内容容器的材质。**
///
/// | 层 | 用什么 | 例子 |
/// |---|---|---|
/// | L0 背景 | 渐变 + 氛围光 | `GlassScreenBackground` |
/// | L1 内容 | **半透明表面**（`contentCard`），不是玻璃 | 状态卡、设置分组、密钥卡 |
/// | L2 控件 | **玻璃**（`.buttonStyle(.glass)`、`glassPill`） | 主/次按钮、顶栏胶囊、通道角标 |
/// | L3 浮层 | 玻璃 + `.floating` 投影 | 操作横幅、日志浮窗（例外，见下） |
///
/// ### 为什么内容卡片不能用玻璃
///
/// 上一版把**所有面板**都改成了 `glassEffect(.regular)`，共 17 处。
/// 那是错的方向，三个具体后果：
///
/// 1. **玻璃失去意义**。玻璃之所以像玻璃，是因为背后有内容可透。
///    17 张卡片摞在渐变底上，每张背后都是另一张卡片 —— 全部退化成模糊白板，
///    与 `.ultraThinMaterial` 看不出区别，却贵得多（每张都要离屏合成）。
/// 2. **层次反而消失**。当所有层都是同一种材质时，深浅只由模糊决定，
///    卡片与卡片、卡片与背景之间没有明确的层级关系。
/// 3. **glass on glass**。卡片里的按钮本身就是 `.buttonStyle(.glass)`，
///    两层折射互相干扰，转角处出现噪点。
///
/// 现在内容卡片改成**半透明色面 + 0.5pt 描边 + 接触阴影**：
/// 它仍然透出底下的渐变（所以不像白色贴纸），但不再做模糊与折射。
/// 玻璃只留给真正的控件 —— 那时候它浮在**内容**上，才有东西可透。
///
/// ### 唯一的材质例外
/// 实时日志浮窗（`LiveLogFloatingView`）用 `.ultraThinMaterial` + 深色压层。
/// 它盖的是**内容**而不是空底，需要与下面的文字强分离；玻璃的透光性在这里反而是缺点。
/// 这是有意的，不要"统一"掉。
enum Glass {

    // MARK: - 圆角（四档；不要发明第五档）

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

    // MARK: - 字体（五档；遇到新的先想想能不能复用已有的）
    //
    // 改之前全项目有 8 / 9 / 9.5 / 10 / 11 / 12 / 13 / 14 / 15 / 16 / 18 十一种字号，
    // 差别都在 1pt 上下 —— 读者说不出哪里不对，但会觉得"每块都不一样"。
    // 1pt 的差异不产生层级，只产生噪声；层级要靠**跨档**拉开（9 → 13 → 22）。
    //
    // ★ 存量还有约 34 处 10pt / 12pt 没并进来。
    //   不是忘了：1pt 的改动会改变换行与行高，必须逐屏目视确认，
    //   批量替换会把已经调好的密集布局撑破。新增代码只用这里的五档。

    enum Typo {
        /// 页标题（22pt）。三个 Tab 页与二级页标题共用这一档
        static let page = Font.title2.weight(.bold)
        /// 卡片标题 / 弹窗标题。
        ///
        /// 用 `.subheadline` 而不是 `system(size: 15)`：字号固定会失去
        /// Dynamic Type（用户调大系统字号时这里不跟着变）。视觉上二者都是 15pt。
        static let cardTitle = Font.subheadline.weight(.semibold)
        /// 正文、列表主行（13pt）
        static let body = Font.system(size: 13)
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

    // MARK: - 内容表面（L1）

    /// 内容卡片的底色。**不是玻璃材质** —— 理由见本节开头。
    ///
    /// 半透明而不是不透明：卡片要能透出底下渐变的色温，否则在氛围光上
    /// 会变成一块"贴上去的白纸"。但**不做模糊** —— 模糊是玻璃的职责，
    /// 内容层只需要"比背景亮一档"这个关系。
    ///
    /// 浅色 72% / 深色 7%：这两个数字不是随手取的 ——
    /// 浅色底（0.82~0.94 亮度）上，72% 白能把卡片提到约 0.97，
    /// 与背景形成刚好看得出来的一档；深色底（0.06~0.11）上，
    /// 7% 白提到约 0.13，再高就会显得"发灰的塑料板"。
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.72)
    }

    /// 内容卡片的描边。
    ///
    /// 0.5pt（设备像素级）刚好能定义边缘，又不会在圆角处形成一圈实线。
    /// 浅色用黑（白描边在浅底上等于隐形，这是之前 `white.opacity(0.55)`
    /// 那套写法在浅色模式下完全失效的原因）；深色用白（黑描边同样看不见）。
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05)
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

// MARK: - 内容卡片（L1）

/// 内容卡片的实现。**不是玻璃**，理由见 `Glass` 开头的三材质分层。
///
/// 三段组成：半透明色面（透出背景色温）+ 0.5pt 描边（定义边缘）+ 接触阴影（离开底面）。
/// 这三样加起来的效果，比 `glassEffect(.regular)` 在纯内容场景更"稳" ——
/// 因为玻璃的折射只在背后有对比内容时才好看，而卡片背后通常是另一张卡片。
private struct ContentCardModifier: ViewModifier {
    let radius: CGFloat
    let elevated: Bool

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let face = content
            .background(shape.fill(Glass.surface(scheme)))
            .overlay(shape.strokeBorder(Glass.hairline(scheme), lineWidth: 0.5))

        // 列表里成批出现的卡片要传 `elevated: false` —— 一屏十几张都带投影时，
        // 相邻两张的投影会在中间叠成一条灰带，反而比不加更脏。
        Group {
            if elevated {
                face.glassElevation(.card)
            } else {
                face
            }
        }
    }
}

// MARK: - List 行背景

/// `List` / `Form` 的行背景。
///
/// 之前三处列表页都用 `Rectangle().fill(.ultraThinMaterial)` —— 那是**模糊**，
/// 而内容卡片已经改成半透明实心面（`Glass.surface`）。两种材质语言并存时，
/// 从主界面点进设置页，质感会明显跳一下。
///
/// 用同一个 `Glass.surface` 而不是 `.ultraThinMaterial`：
/// 行与卡片属于同一层（L1 内容），材质应当一致。
///
/// 注意 `.listRowBackground(...)` 收的是 **View 不是 ShapeStyle** ——
/// 直接传 `.ultraThinMaterial` 会报 `generic parameter 'V' could not be inferred`。
struct GlassListRowBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle().fill(Glass.surface(scheme))
    }
}

// MARK: - 玻璃容器

extension View {

    /// **L1 内容卡片**：半透明表面 + 描边 + 接触阴影。
    ///
    /// 名字里没有 glass 是故意的 —— 它不是玻璃。
    /// 2026-11-07 之前这里叫 `glassCard` 且真的用了 `glassEffect`，
    /// 17 处调用让整个 App 变成"玻璃摞玻璃"，反而没有层次。
    ///
    /// - Parameters:
    ///   - radius: 默认 `Glass.cardRadius`（20）；内嵌小卡传 `Glass.controlRadius`
    ///   - elevated: 是否加 `.card` 级投影。列表里成批出现的卡片传 `false`。
    func contentCard(radius: CGFloat = Glass.cardRadius,
                     elevated: Bool = true) -> some View {
        modifier(ContentCardModifier(radius: radius, elevated: elevated))
    }

    /// **L2 玻璃胶囊**（顶栏状态、通道徽标）。
    ///
    /// 保留玻璃：它浮在**滚动内容**之上，背后一直有新内容经过 ——
    /// 这正是玻璃该用的场景，透光与折射都能被看见。
    func glassPill() -> some View {
        glassEffect(.regular, in: .capsule)
    }

    /// **L2 圆形小徽标**（通道角标）。
    ///
    /// ⚠️ 它叠在**玻璃按钮**上，所以**不能用玻璃** —— 那是 glass on glass，
    /// 两层折射互相干扰，16pt 的小圆上表现为边缘噪点。
    /// 改成半透明色面 + 细描边：仍然能看清，但不再和底下的按钮抢材质。
    func surfaceBadge() -> some View {
        modifier(SurfaceBadgeModifier())
    }

    /// 小标签（"需网络"这类角标）。同上，叠在玻璃上，用表面不用玻璃。
    func surfaceChip() -> some View {
        modifier(SurfaceBadgeModifier(radius: Glass.chipRadius))
    }

    /// 套一层投影（`.card` 或 `.floating`）。已是玻璃的视图用这个补层次。
    func glassElevation(_ level: Glass.Elevation) -> some View {
        modifier(GlassShadowModifier(level: level))
    }
}

/// 叠在玻璃之上的小徽标：半透明面 + 细描边。
///
/// 「比底下那层再亮一档」就够了 —— 小尺寸图形不需要折射，
/// 需要的是**轮廓清晰**。玻璃在这里只会让它糊成一团。
private struct SurfaceBadgeModifier: ViewModifier {
    var radius: CGFloat? = nil      // nil = 圆形

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let fill = scheme == .dark
            ? Color.white.opacity(0.14)
            : Color.white.opacity(0.85)
        let line = scheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.08)

        Group {
            if let radius {
                content
                    .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(line, lineWidth: 0.5))
            } else {
                content
                    .background(Circle().fill(fill))
                    .overlay(Circle().strokeBorder(line, lineWidth: 0.5))
            }
        }
    }
}
