import SwiftUI
import UIKit

/// 车辆舞台 —— **吉利博越 PRO（NL3B）车型**，图源为原 App `Assets.car`
/// 里的 `Remote_pic_car_on/off_NL3B`（1125×675，透明背景，车头朝左 3/4 视角）。
///
/// ## 2026-11-07 重构：状态从「车图下方三行」改成「环绕车图」
///
/// 之前车图下面依次是：通道胶囊 → 四门一行 → 天窗/车窗/引擎一行 →
/// 能源三格。四行加起来有 150pt，车本身只占 168 —— 也就是说**说明比主体还高**，
/// 而且每一行都在回答同一个问题（"车现在什么样"），用户得从上往下读四遍。
///
/// 现在：
///
/// | 位置 | 内容 | 理由 |
/// |---|---|---|
/// | 车图左上 | 锁 | 车头一侧，和"车整体"的语义最近 |
/// | 车图中上 | 天窗 | 天窗在车顶，就该画在车顶上方 |
/// | 车图右上 | 后备箱 | 车尾在右 |
/// | 车图左下 | 引擎 | 引擎盖在车头（左） |
/// | 车图中下 | 四门 | 四个门合并成一句（见下） |
/// | 车图右下 | 车窗 | — |
/// | 车图下沿 | 能源（悬浮） | 读数不属于"车的状态"，是"车的存量"，单独一条 |
///
/// ### 四门为什么合并
/// 3/4 视角下只能看见右侧两个门，左前 / 左后其实被车身挡住了 ——
/// 硬把四个 chip 摆在车图上，有两个一定"指错位置"。
/// 所以按**信息量**合并：全关时只说"四门全关"（4 个字回答 4 个字段），
/// 有门开时精确指出是哪一扇（`"右后门开"`），最多再合并成"2 门开"。
/// 精确性没有丢：真要逐门看，状态页的俯视图（`VehicleTopView`）本来就是干这个的。
///
/// ### 通道胶囊为什么删掉
/// 顶栏已经有一个一模一样的（`model.preferredChannel`，同一份数据、
/// 同一个点击去向）。同一屏里两个"现在走哪条路"，用户会以为它们可能不一致。
///
/// ### 标注为什么不做成玻璃
/// 六个玻璃胶囊叠在一张车图上，每颗都在折射同一个底 ——
/// 结果是六块模糊的雾斑盖住车，而车才是这屏的主体。
/// 这里用「半透明面 + 极细描边」：**正常状态只有轮廓没有重量**（灰色、安静），
/// **异常状态才浮出颜色**（橙色底 + 橙色字）。一眼扫过去，
/// 第一视觉落点是"哪一项不对劲"，而不是"这里有六个徽章"。
struct CarModelView: View {
    @Environment(\.colorScheme) private var scheme

    /// 已归一好的状态（蓝牙优先、云端兜底，判定在 `AppModel.activeStatus`）。
    /// 这里不再自己判一遍 —— 两处判定迟早会不一致。
    let snapshot: VehicleSnapshot?
    let stage: Stage
    /// 车图高度。**调用方传，视图内部不再写死** ——
    ///
    /// 之前这里写死 220，外层又套 `.frame(height: 196)` 想省空间，
    /// 结果内层内容比外层框高 120，溢出部分正好被下面的按钮压住。
    var carHeight: CGFloat = 178
    /// 能源读数。三项都为空时不画 —— 不留一条写满「—」的空壳。
    var energy: EnergyReadout? = nil

    enum Stage: Equatable {
        /// 未连接 / 扫描中 → 静态车图
        case connecting
        /// 配对流程进行中 → 车灯闪烁动画
        case pairing
        /// 已连接 → 静态车图 + 浮动动画
        case ready
    }

    /// 上下两行浮标的高度。固定值而不是靠内容撑 ——
    /// 某项没数据时那一侧会消失，撑开的布局会让车图跟着上下跳。
    private let railHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // 车图。`scaledToFit` 后实际宽度约等于 carHeight × 1.667，
                // 左右各留出约 25pt —— 那正是浮标能"站在车外"的余量。
                Group {
                    switch stage {
                    case .connecting: CarImage(named: "car_on")
                    case .pairing:    PairingCarView()
                    case .ready:      FloatingCarView()
                    }
                }
                .frame(height: carHeight)

                annotationRails
            }
            .frame(maxWidth: .infinity)
            .frame(height: carHeight)

            if let energy, !energy.isEmpty {
                // ★ 左对齐，不居中、不占满宽（2026-11-07 重做）。
                //
                // 原来是一条居中的玻璃胶囊横跨整宽，问题有三个：
                // ① 它横在车图和按钮之间，看起来像**第二张卡片**，
                //    把"看车 → 操作"这条纵向流拦腰截断；
                // ② 三格等宽，把"油量"和"电瓶"画成同等重要 ——
                //    可油量是每周都看、电瓶是半年看一次；
                // ③ 不可点却用玻璃材质，和车图上的六个浮标（半透明面）不同族。
                //
                // 现在：左边缘与标题「博越 PRO」、下方按钮网格对齐，
                // 宽度随内容，材质改成和浮标一样的半透明面。
                HStack(spacing: 0) {
                    energyBar(energy)
                    Spacer(minLength: 0)
                }
                // ★ 必须显式撑满 + 左对齐。
                //
                // `VStack` 默认把子视图**水平居中**，而带 `Spacer` 的 HStack
                // 只是"可以"撑满，并不保证 —— 外层没有 `maxWidth: .infinity` 时，
                // 它按内容宽度居中，左边缘就比标题缩进了 30pt（真机截图量出来的）。
                .frame(maxWidth: .infinity, alignment: .leading)
                // 不能上移压车图：试过 `padding(.top, -10)`，
                // 它正好盖住底部那排浮标（引擎 / 四门 / 车窗）。
                // 4pt：车图自身底部约有 20pt 透明区，够贴合又不挤。
                .padding(.top, 4)
            }
        }
    }

    // MARK: - 环绕浮标

    private var annotationRails: some View {
        // 没有任何车况时整块不画。
        //
        // `PairingView` 也用这个视图（`snapshot: nil`）—— 配对过程中车还没连上，
        // 摆一排「引擎 —」「四门 —」只会让人以为配对出了问题。
        Group {
            if snapshot != nil {
                railsContent
            }
        }
    }

    private var railsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let s = snapshot {
                    // 锁：车头侧。`nil`（没有数据）时整颗不画，不猜。
                    // ⚠️「未锁」必须是橙色：它和「已锁」共用绿色的话，
                    //    一眼扫过去整排都是绿的，等于把最需要处理的一项藏了起来。
                    if let locked = s.isLocked {
                        stageBadge(icon: locked ? "lock.fill" : "lock.open.fill",
                                   text: locked ? "已锁" : "未锁",
                                   tone: locked ? .good : .warn,
                                   alert: !locked)
                    }
                    Spacer(minLength: 4)
                    // 天窗：正上方 —— 天窗就在车顶，位置本身就是标注。
                    if let open = s.isSunroofOpen {
                        stageBadge(icon: open ? "sun.max.fill" : "sun.max",
                                   text: open ? "天窗开" : "天窗关",
                                   tone: .warn,
                                   alert: open)
                    }
                    Spacer(minLength: 4)
                    // 后备箱：车尾侧
                    if let closed = s.isTrunkClosed {
                        stageBadge(icon: "car.rear.open",
                                   text: closed ? "后备箱关" : "后备箱开",
                                   tone: .warn,
                                   alert: !closed)
                    }
                }
            }
            .frame(height: railHeight)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                // 引擎：车头下方（引擎盖在左）
                if let running = snapshot?.isEngineRunning {
                    stageBadge(icon: "engine.combustion",
                               text: running ? "引擎运行" : "引擎熄火",
                               tone: .active,
                               alert: false,
                               highlight: running)
                } else {
                    stageBadge(icon: "engine.combustion", text: "引擎 —",
                               tone: .neutral, alert: false)
                }

                Spacer(minLength: 4)

                // 四门：合并成一句
                if let door = doorReadout {
                    stageBadge(icon: door.open ? "door.left.hand.open" : "door.left.hand.closed",
                               text: door.text,
                               tone: .warn,
                               alert: door.open)
                }

                Spacer(minLength: 4)

                // 车窗：只有云端给窗位，蓝牙快照里恒为「不知道」——
                // 那就不显示，不拿"—"占一个位置假装有数据。
                if let closed = snapshot?.isWindowsClosed, snapshot?.isWindowsKnown == true {
                    stageBadge(icon: "wind",
                               text: closed ? "车窗全关" : "车窗开着",
                               tone: .warn,
                               alert: !closed)
                }
            }
            .frame(height: railHeight)
        }
        .padding(.horizontal, 2)
        .allowsHitTesting(false)
    }

    /// 四门合并后的读数。
    private var doorReadout: (text: String, open: Bool)? {
        guard let closed = snapshot?.doorClosed, closed.count == 4 else { return nil }
        let names = ["左前", "右前", "左后", "右后"]
        let open = (0..<4).compactMap { closed[$0] ? nil : names[$0] }
        if open.isEmpty { return ("四门全关", false) }
        if open.count == 1 { return ("\(open[0])门开", true) }
        // "2 扇门开" 而不是 "2 门开"：后者读起来像"2 号门开"
        return ("\(open.count) 扇门开", true)
    }

    /// 车图上的浮标。
    ///
    /// - Parameters:
    ///   - alert: 这一项**需要人去处理**（门开着、没锁、后备箱开）。
    ///     只有它为 `true` 时才上色上底 —— 全车正常时整排是安静的灰字，
    ///     用户扫一眼就能确认"没有橙色"，不必逐个读文字。
    ///   - highlight: 中性但值得注意的活跃态（引擎在转）。给色不给底。
    private func stageBadge(icon: String, text: String, tone: Tone,
                            alert: Bool, highlight: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        // 正常态用 secondary 而不是 primary：六个 primary 字压在车图上，
        // 眼睛会先读字再看车 —— 主次反了。
        .foregroundStyle(alert ? tone.color : (highlight ? tone.color : Color.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(badgeFill(alert: alert, tone: tone))
        }
        .overlay {
            Capsule().strokeBorder(badgeStroke, lineWidth: 0.5)
        }
    }

    private func badgeFill(alert: Bool, tone: Tone) -> Color {
        if alert {
            return tone.color.opacity(scheme == .dark ? 0.24 : 0.15)
        }
        // 车图本身是深灰渐变，浅色模式的 78% 白底能保证文字可读；
        // 深色模式用 10% 白 —— 只要比车图亮一档就够，再高就成了白纸片。
        return scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.78)
    }

    private var badgeStroke: Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
    }

    // MARK: - 能源（悬浮读数带）

    /// 能源读数带。
    ///
    /// ## 分两级，不搞三格等宽
    /// | 级别 | 项目 | 理由 |
    /// |---|---|---|
    /// | 主 | 油量、续航 | 回答"现在能不能开走"，每周都要看 |
    /// | 次 | 电瓶电压 | 回答"会不会打不着火"，半年看一次 |
    ///
    /// 三格等宽会把这两类画成同等重要 —— 之前就是这样，
    /// 于是"12.3 V"和"油量 62%"占了一样宽的位置。
    ///
    /// ## 顺序
    /// 左→右 = 因果链：有多少油 → 还能跑多远 → 车况健康。
    /// 起点与标题、下方按钮网格同一条竖线，眼睛不用重新找边。
    ///
    /// ## 材质
    /// **半透明面，不是玻璃**。它不可点，和车图上的六个浮标是一族；
    /// 用玻璃会让"能点的才发光"这条视觉规则失效。
    private func energyBar(_ e: EnergyReadout) -> some View {
        HStack(spacing: 0) {
            if let fuel = e.fuelPercent {
                energyCell(icon: "fuelpump.fill", label: "油量",
                           value: String(format: "%.0f%%", fuel),
                           // 见底才变色 —— 40% 这种常见值天天报警就没意义了
                           tint: fuel < 15 ? Glass.Tone.warning : .primary,
                           primary: true)
            }
            if let range = e.rangeKM {
                if e.fuelPercent != nil { energyDivider }
                energyCell(icon: "map.fill", label: "续航",
                           value: "\(Int(range.rounded())) km", primary: true)
            }
            if let volts = e.batteryVolts {
                if e.fuelPercent != nil || e.rangeKM != nil { energyDivider }
                energyCell(icon: "car.battery", label: "电瓶",
                           value: String(format: "%.1f V", volts),
                           // 熄火静置低于 12 V 就打不着了，这格必须变色
                           tint: volts < 12.0 ? Glass.Tone.danger : .secondary,
                           primary: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // 用 `controlRadius`(14) 而不是 `pillRadius`(12)：
        // 它下面紧挨着的车辆位置卡也是 14，两条并排的圆角必须一样，
        // 差 2pt 单看没感觉，并排看就是"没对齐"。
        .contentCard(radius: Glass.controlRadius, elevated: false)
    }

    /// 一格读数。`primary` 只决定字号与字重 ——
    /// 不靠颜色区分主次，颜色留给"这一项是不是出问题了"。
    private func energyCell(icon: String, label: String, value: String,
                            tint: Color = .primary, primary: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: primary ? 9 : 8, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: primary ? 10 : 9))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: primary ? 15 : 11,
                                  weight: primary ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .baselineOffset(primary ? 0 : -1)
        }
        .padding(.horizontal, 7)
    }

    private var energyDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.09))
            .frame(width: 0.5, height: 12)
    }

    // MARK: - 语义色

    private enum Tone {
        /// 正常 / 已关闭（但**不上色** —— 只有 alert 时才取这个色）
        case good
        /// 需要处理（门没关、没锁）
        case warn
        /// 引擎在转
        case active
        case neutral

        var color: Color {
            switch self {
            case .good:   return .green
            case .warn:   return .orange
            case .active: return .cyan
            case .neutral: return .secondary
            }
        }
    }
}

// MARK: - 能源读数

/// 车图下方那条悬浮读数带的输入。
///
/// 单独一个类型而不是三个 `Double?` 参数：三项同源（云端车况）、
/// 同进同出（都为空时整条不画），打包传更不容易漏一项。
struct EnergyReadout: Equatable {
    var fuelPercent: Double?
    var rangeKM: Double?
    var batteryVolts: Double?

    var isEmpty: Bool {
        fuelPercent == nil && rangeKM == nil && batteryVolts == nil
    }
}

/// 用 `UIImage(named:)` 加载并包成 `Image`，规避 colormap/CgBI 解码问题。
struct CarImage: View {
    let named: String

    var body: some View {
        if let img = UIImage(named: named) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "car.side")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .onAppear {
                    FileLogger.shared.warning("车辆模型帧加载失败：\(named)", module: "UI")
                }
        }
    }
}

// MARK: - 配对中（车灯闪烁）

/// 配对中：车图 + 车灯光斑呼吸闪烁（寻车灯效果，对应原 App 配对时车辆被唤醒）
private struct PairingCarView: View {
    @State private var blink = false

    var body: some View {
        ZStack {
            CarImage(named: "car_on")

            // 车灯光斑（叠加在车头上方，随呼吸明暗）
            CarImage(named: "car_light")
                .opacity(blink ? 0.9 : 0.15)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                blink = true
            }
        }
    }
}

// MARK: - 已连接（浮动）

/// 已连接：车图轻微浮动（悬浮感）。状态浮标由外层叠加，这里只管动画。
private struct FloatingCarView: View {
    @State private var float = false

    var body: some View {
        CarImage(named: "car_on")
            .offset(y: float ? -4 : 4)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    float = true
                }
            }
    }
}

// MARK: - 布局样张（仅 DEBUG）

#if DEBUG
/// 车图区的布局样张开关。
///
/// ## 为什么需要
/// 上下两排浮标和能源带都**只在有真实车况时才出现**。模拟器里既没有蓝牙
/// 也没有云端账号，界面永远是空白态 —— 于是"最不该出问题的情况"
/// 恰好成了唯一能看到的情况，而真正会挤坏布局的是**每个字段都有值**的时候。
///
/// ## 用法
/// ```
/// xcrun simctl launch <UDID> com.mmxisme.gkuiblekey -mockVehicle 1
/// ```
/// `-key value` 形式的启动参数会自动进 `UserDefaults` 的 NSArgumentDomain，
/// 所以这里直接 `bool(forKey:)` 就能读到，不需要解析 `ProcessInfo`。
///
/// 正常安装（Release / 不带参数）下 `isEnabled` 恒为 false。
enum UIMockVehicle {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "mockVehicle")
    }

    /// 最挤的一份样张：有门开着、车窗开着、引擎在转、能源三项齐全。
    /// 故意选"不正常"的组合 —— 异常态才有底色和颜色，是最占空间的那一档。
    static let snapshot = VehicleSnapshot(
        isLocked: false,
        isTrunkClosed: true,
        isDoorsClosed: false,
        isEngineRunning: true,
        doorClosed: [true, true, false, false],   // 左后 / 右后门开着
        isWindowsKnown: true,
        isWindowsClosed: false,
        isSunroofOpen: false,
        updatedAt: Date()
    )

    static let energy = EnergyReadout(fuelPercent: 62, rangeKM: 486, batteryVolts: 12.3)
}
#endif
