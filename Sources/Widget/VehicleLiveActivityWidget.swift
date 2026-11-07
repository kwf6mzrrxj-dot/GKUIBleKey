import WidgetKit
import SwiftUI

/// 锁屏 / 灵动岛 / CarPlay 上的「数字钥匙」实时活动。
///
/// ## 数据源（2026-11-04，与主页同一套规则）
/// 由 `AppModel.activeStatus` 统一产生，**不是**这里自己挑：
///
/// - 蓝牙收到广播（60 秒内）→ 车锁 / 四门 / 后备箱 / 引擎 用蓝牙，
///   车窗 / 天窗 用云端补（蓝牙 16 字节广播里没有这两项）
/// - 蓝牙没收到、云端有   → 整份用云端
/// - 两边都没有           → 「暂无数据」
///
/// `statusText` 只说数据从哪来（蓝牙实时 / 云端 / 暂无数据），
/// 时间统一由 `lastReportedAt` 以相对形式表达 —— 两者不再各写一遍时分。
///
/// ## 四格为什么是「门 / 窗 / 后箱 / 引擎」
/// 2026-11-07 把「电源」换成了「窗」。ACC / 点火档只有坐在车里才有意义，
/// 而这张卡绝大多数时候是**站在车外**看的 —— 那一刻「窗关没关」
/// 比「电源通没通」重要得多。
///
/// ## CarPlay
/// 车载屏幕观看距离远，锁屏那套 9pt/11pt 的字在上面基本看不清。
/// iOS 26 起 CarPlay 可以显示 Live Activity，用 `activityFamily == .medium`
/// 区分出来给一套更大的排版（见 `LockScreenView` 的 `isWide` 分支）。
struct VehicleLiveActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VehicleActivityAttributes.self) { context in
            // MARK: 锁屏 / 通知中心
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let grid = StatGrid(context.state)

            return DynamicIsland {
                // MARK: 展开态
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.vehicleName)
                            .font(.caption).lineLimit(1)
                    } icon: {
                        Image(systemName: "car.side.fill")
                    }
                    .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        // 没有数据 ≠ 未锁。以前 `isLocked == true ? "已锁" : "未锁"`
                        // 会把「还没收到广播」直接画成「未锁」，比不显示更糟。
                        Text(lockShortText(context.state.isLocked, long: true))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(lockShortColor(context.state.isLocked))
                        if let at = context.state.lastReportedAt {
                            Text(at, style: .relative)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // 展开态的高度足够放这四格，且必须和锁屏卡给出**同一组结论** ——
                    // 长按展开后看到的信息比锁屏更少，会让人以为锁屏那版是错的。
                    HStack(spacing: 4) {
                        islandStat("门", grid.door)
                        islandStat("窗", grid.window)
                        islandStat("后箱", grid.trunk)
                        islandStat("引擎", grid.engine)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isConnected ? "key.fill" : "key")
                    .foregroundStyle(context.state.isConnected ? .green : .orange)
            } compactTrailing: {
                Text(lockShortText(context.state.isLocked, long: false))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(lockShortColor(context.state.isLocked))
            } minimal: {
                Image(systemName: context.state.isConnected ? "key.fill" : "key")
            }
        }
        // 声明同时支持「锁屏小卡」和「CarPlay / 更大画布」两种家族。
        // 不写这行时系统只会用锁屏那套排版去渲染车机，字会小到看不清。
        .supplementalActivityFamilies([.small, .medium])
    }

    /// 动态岛展开态的一格。
    ///
    /// 不加背景块：灵动岛本来就是纯黑，`white.opacity(0.08)` 的底几乎看不见，
    /// 反而把三行文字挤在一起。只用「标签淡 + 值亮」的对比分层。
    private func islandStat(_ title: String, _ stat: Stat) -> some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            Text(stat.value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stat.tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 四格的取值

/// 一格的值与语气。
private struct Stat {
    let value: String
    let tone: StatTone

    init(_ value: String, _ tone: StatTone) {
        self.value = value
        self.tone = tone
    }

    static let unknown = Stat("—", .unknown)
}

/// 一格的状态语气。
///
/// 之前唯一的一套规则是 `value == true ? 白 : 橙` —— 对门 / 后箱成立
/// （关着是常态、开着要留意），但套到引擎上就反了：
/// **引擎停着显示橙色警示、转着显示白色**。车停着是常态，不该报警。
///
/// 语气由每个字段自己声明「哪个方向算异常」，而不是从布尔值统一猜 ——
/// 没有一个通用规则能同时对上这四项。
private enum StatTone {
    /// 常态
    case normal
    /// 需要留意（门开着 / 引擎在转 / 天窗开着）
    case alert
    /// 没上报过 —— 必须和「上报了是关」区分开
    case unknown

    var color: Color {
        switch self {
        case .normal:  return .white
        case .alert:   return .orange
        case .unknown: return .white.opacity(0.35)
        }
    }
}

/// 从卡片内容算出四格。
///
/// 放在文件级而不是某个 View 里：锁屏卡和灵动岛展开态**必须给出同一组结论**，
/// 各算一遍迟早会漂移（一边改了、另一边忘了）。
private struct StatGrid {
    let door: Stat
    let window: Stat
    let trunk: Stat
    let engine: Stat

    init(_ s: VehicleActivityAttributes.ContentState) {
        door = Self.doorStat(s)
        window = Self.windowStat(s)
        trunk = Self.trunkStat(s)
        engine = Self.engineStat(s)
    }

    /// 门：有逐门数据就说「哪一扇」，没有才退回聚合值。
    ///
    /// 「有门开着」和「左后门开着」是两个量级的信息 ——
    /// 前者要绕车检查一圈，后者直接走过去关。
    private static func doorStat(_ s: VehicleActivityAttributes.ContentState) -> Stat {
        if let doors = s.doorClosed, doors.count == 4 {
            let names = ["左前", "右前", "左后", "右后"]
            let open = zip(names, doors).filter { !$0.1 }.map { $0.0 }
            if open.isEmpty { return Stat("关", .normal) }
            if open.count == 1 { return Stat(open[0], .alert) }
            return Stat("\(open.count)门开", .alert)
        }
        guard let closed = s.isDoorClosed else { return .unknown }
        return Stat(closed ? "关" : "开", closed ? .normal : .alert)
    }

    /// 窗：车窗与天窗合并成一个语义 ——「还有没有能进水的口子」。
    ///
    /// 两个都写「开」会撑爆格子，所以分开表达：
    /// 车窗开 → 「开」；只有天窗开 → 「天」。
    ///
    /// ## 天窗未知时的取舍
    /// `isSunroofOpen == nil` 时以车窗为准显示「关」，**不**因为天窗不确定就报「—」。
    /// 两条理由：
    /// 1. 没有天窗的车型，这个字段可能恒缺 —— 要求「天窗已知才敢说关」
    ///    会让这类车永远显示「—」，把一个能确定的答案变成不知道。
    /// 2. 车窗才是进水的常见来源。
    /// 天窗开着时下一次刷新就会变成「天」，不会长期显示错误。
    private static func windowStat(_ s: VehicleActivityAttributes.ContentState) -> Stat {
        let win = s.isWindowsClosed
        let sun = s.isSunroofOpen

        if win == false { return Stat("开", .alert) }
        // 车窗关着（或未知）但天窗开着 —— 都算有口子，只是来源不同
        if sun == true { return Stat("天", .alert) }
        if win == true { return Stat("关", .normal) }
        // 车窗未知、天窗也没开：真的不知道
        return .unknown
    }

    private static func trunkStat(_ s: VehicleActivityAttributes.ContentState) -> Stat {
        guard let closed = s.isTrunkClosed else { return .unknown }
        return Stat(closed ? "关" : "开", closed ? .normal : .alert)
    }

    private static func engineStat(_ s: VehicleActivityAttributes.ContentState) -> Stat {
        guard let running = s.isEngineRunning else { return .unknown }
        // 在转才值得留意（远程启动中 / 车正在被使用），停着是常态
        return Stat(running ? "转" : "停", running ? .alert : .normal)
    }
}

// MARK: - 共用取值

/// 锁状态文案。`nil` = 还没收到过数据 → 显示「—」，不能写成「未锁」。
private func lockShortText(_ value: Bool?, long: Bool) -> String {
    guard let value else { return "—" }
    if long { return value ? "已锁" : "未锁" }
    return value ? "锁" : "开"
}

private func lockShortColor(_ value: Bool?) -> Color {
    guard let value else { return .white.opacity(0.6) }
    return value ? .green : .orange
}

// MARK: - 锁屏布局

private struct LockScreenView: View {
    let context: ActivityViewContext<VehicleActivityAttributes>

    /// `.medium` = CarPlay / 更大画布；`.small` = 锁屏紧凑卡
    @Environment(\.activityFamily) private var activityFamily
    private var isWide: Bool { activityFamily == .medium }

    /// 车机上放大一档 —— 隔着半米看 9pt 等于看不见
    private func scaled(_ base: CGFloat) -> CGFloat {
        isWide ? base * 1.45 : base
    }

    var body: some View {
        let grid = StatGrid(context.state)

        VStack(alignment: .leading, spacing: 8) {
            // 第一行：车名 / 在线 / 锁态
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "car.side.fill")
                    .font(.system(size: scaled(22)))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.vehicleName)
                        .font(.system(size: scaled(15), weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        StatusDot(ok: context.state.isConnected)
                        Text(context.state.statusText)
                            .font(.system(size: scaled(11)))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(lockText)
                        .font(.system(size: scaled(13), weight: .semibold))
                        .foregroundStyle(lockColor)
                    // ★ 离线后**保留**最后一次上报的状态，并明确标出时间
                    //   —— 不让用户把"5 分钟前的快照"当成实时状态。
                    if let at = context.state.lastReportedAt {
                        Text(at, style: .relative)
                            .font(.system(size: scaled(10)))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }

            // 第二行：离车时真正要确认的四项（见 `StatGrid`）
            HStack(spacing: 8) {
                miniStat("门", grid.door)
                miniStat("窗", grid.window)
                miniStat("后箱", grid.trunk)
                miniStat("引擎", grid.engine)
            }
        }
        .padding(.horizontal, isWide ? 22 : 16)
        .padding(.vertical, isWide ? 18 : 12)
    }

    private var lockText: String {
        guard let locked = context.state.isLocked else { return "状态未知" }
        return locked ? "已锁" : "未锁"
    }

    private var lockColor: Color {
        guard let locked = context.state.isLocked else { return .white.opacity(0.6) }
        return locked ? .green : .orange
    }

    private func miniStat(_ title: String, _ stat: Stat) -> some View {
        VStack(spacing: isWide ? 3 : 1) {
            Text(title)
                .font(.system(size: scaled(9)))
                .foregroundStyle(.white.opacity(0.5))
            Text(stat.value)
                .font(.system(size: scaled(11), weight: .semibold))
                .foregroundStyle(stat.tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isWide ? 8 : 3)
        .background(Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: isWide ? 10 : 6))
    }
}

private struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
    }
}
