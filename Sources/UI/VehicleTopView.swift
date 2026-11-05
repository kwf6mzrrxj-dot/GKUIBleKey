import SwiftUI

/// 车辆俯视图 + 状态瓦片 + 功能入口。
///
/// ## 为什么单独做一个
/// 侧视图（`car_on`）有质感，但**看不清哪里开着** —— 3/4 视角下四扇门互相遮挡，
/// 只能把状态堆成角标。俯视图（`car_top`，554×1151 竖版）
/// 四门四窗全在平面上一一对应，可以直接把状态标在位置上。
///
/// ## 布局（2026-11-04 第二次调整）
///
/// 上一版是「车图 150 宽 + 右侧一列 8 行文字」。问题有两个：
/// ① 车图占 150×312，右侧那列文字只有 ~230 高，右下角空出一大块；
/// ② 一列文字既挤又长，扫读时得一行行往下看。
///
/// 现在改成「左侧车图 + 右侧 2×4 状态瓦片 + 底部功能入口」：
/// - 瓦片是两列网格，宽度吃满剩余空间，右侧不再留白；
/// - 关键项（车锁 / 车门 / 车窗 / 天窗 / 后备箱 / 引擎 / 上电 / ACC）一屏看全，
///   不需要滚动；
/// - 右下角那块原本空着的地方放了「钥匙」「网络」两个入口 —— 空白变成可点的东西。
struct VehicleTopView: View {
    let snapshot: VehicleSnapshot?
    /// 仅当数据来自蓝牙时才有值（用来补上电/ACC 两项）
    var status: VehicleStatus?

    /// 功能入口。传 nil 时该按钮不画 —— 让这个视图在别的页面也能复用。
    var onOpenKey: (() -> Void)? = nil
    var onOpenCloud: (() -> Void)? = nil

    /// 车图宽度。高度按原图比例 1151/554 算，不写死 —— 换图会变形。
    /// 136 是算出来的：卡片内容宽 ~330，减去间距后右侧还剩 180，
    /// 刚好放下两列 86 宽的瓦片。
    private let imageWidth: CGFloat = 136
    private var imageHeight: CGFloat { imageWidth * 1151 / 554 }

    /// 四门在图片上的相对坐标（左前 / 右前 / 左后 / 右后）。
    /// 按原图像素量的：门把手在 x≈16% / 84%，前后门中心 y≈39% / 56%。
    private let doorSpots: [(x: CGFloat, y: CGFloat)] = [
        (0.155, 0.392), (0.845, 0.392),
        (0.155, 0.556), (0.845, 0.556)
    ]
    private let doorNames = ["左前", "右前", "左后", "右后"]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            carLayer
            infoArea
        }
    }

    // MARK: - 左：车图 + 位置标记

    private var carLayer: some View {
        ZStack(alignment: .topLeading) {
            CarImage(named: "car_top")
                .frame(width: imageWidth, height: imageHeight)

            // 四门
            ForEach(0..<4, id: \.self) { i in
                doorDot(index: i)
                    .position(x: imageWidth * doorSpots[i].x,
                              y: imageHeight * doorSpots[i].y)
            }

            // 天窗：覆盖车顶中间那块玻璃
            sunroofPatch

            // 车头方向的"引擎"标记（开着时点亮）
            engineDot
        }
        .frame(width: imageWidth, height: imageHeight)
    }

    private func doorDot(index: Int) -> some View {
        let closed = doorClosed?[safe: index]
        let open = closed == false
        return Circle()
            .fill(open ? Color.orange : Color.clear)
            .frame(width: 8, height: 8)
            .overlay {
                Circle().strokeBorder(
                    open ? Color.orange
                         : (closed == nil ? Color.secondary.opacity(0.35)
                                          : Color.green.opacity(0.75)),
                    lineWidth: 1.4)
            }
            .background {
                if open {
                    Circle().fill(Color.orange.opacity(0.25))
                        .frame(width: 16, height: 16)
                }
            }
            .accessibilityLabel("\(doorNames[index])门\(open ? "开着" : "关着")")
    }

    private var sunroofPatch: some View {
        let open = snapshot?.isSunroofOpen
        return RoundedRectangle(cornerRadius: Glass.chipRadius, style: .continuous)
            .fill(open == true ? Color.blue.opacity(0.42) : Color.clear)
            .overlay {
                RoundedRectangle(cornerRadius: Glass.chipRadius, style: .continuous)
                    .strokeBorder(open == true ? Color.clear : Color.secondary.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .frame(width: imageWidth * 0.44, height: imageHeight * 0.29)
            .position(x: imageWidth * 0.5, y: imageHeight * 0.575)
            .accessibilityLabel(open == true ? "天窗开着" : "天窗关着")
    }

    private var engineDot: some View {
        let running = status?.isEngineRunning ?? snapshot?.isEngineRunning
        return Circle()
            .fill(running == true ? Color.cyan : Color.clear)
            .frame(width: 6, height: 6)
            .overlay {
                Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            }
            .position(x: imageWidth * 0.5, y: imageHeight * 0.16)
            .accessibilityLabel(running == true ? "引擎运行" : "引擎熄火")
    }

    // MARK: - 右：状态瓦片 + 入口

    private var infoArea: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible())], spacing: 8) {
                tile(icon: "lock.fill", title: "车锁", value: lockText, tone: lockTone)
                tile(icon: "door.left.hand.closed", title: "车门", value: doorText, tone: doorTone)
                tile(icon: "wind", title: "车窗", value: windowText, tone: windowTone)
                tile(icon: "sun.max", title: "天窗", value: sunroofText, tone: sunroofTone)
                tile(icon: "car.rear", title: "后备箱", value: trunkText, tone: trunkTone)
                tile(icon: "engine.combustion", title: "引擎", value: engineText, tone: engineTone)
                // 下面两项只有蓝牙广播里有，云端不给 —— 没有就显示「—」，
                // 不写成「关」蒙混过去。
                tile(icon: "power", title: "上电", value: ignitionText, tone: ignitionTone)
                tile(icon: "bolt.car", title: "ACC", value: accText, tone: accTone)
            }

            Spacer(minLength: 0)

            entryRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单个状态瓦片：上面一行是小字标题，下面一行是值。
    /// 比「一行一个键值对」省一半高度，两列并排正好填满右侧。
    private func tile(icon: String, title: String, value: String, tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            // `.quaternary` ≈ 8% label 色，再 ×0.35 → 约 2.8%，在渐变底上等于没有。
            // 瓦片于是"没有形状"，只剩一行悬浮文字。改用自适应的 secondary 12%。
            RoundedRectangle(cornerRadius: Glass.pillRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        }
    }

    /// 原本右下角是空的 —— 现在放两个入口：钥匙详情、网络通道。
    /// 都是「状态页看到了问题，下一步想去处理」时最可能点的地方。
    @ViewBuilder
    private var entryRow: some View {
        if onOpenKey != nil || onOpenCloud != nil {
            HStack(spacing: 8) {
                if let action = onOpenKey {
                    entry(icon: "key.fill", title: "钥匙", action: action)
                }
                if let action = onOpenCloud {
                    entry(icon: "antenna.radiowaves.left.and.right", title: "网络", action: action)
                }
            }
        }
    }

    private func entry(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .background {
                // 同上：给这个可点的入口一个真正看得见的底
                RoundedRectangle(cornerRadius: Glass.pillRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - 取值

    /// 四门状态。
    ///
    /// ★ 只用 `snapshot`（2026-11-05 修复）。
    ///
    /// 原来优先读 `status`（蓝牙广播的原始结构），但那东西**车走了也不清空** ——
    /// 它会一直留着最后一次的值。于是状态页永远显示「最后一次蓝牙看到的门」，
    /// 而车控页用的是 `activeStatus`（蓝牙优先、云端兜底），两边长期对立。
    ///
    /// `snapshot` 已经是归一后的结果：蓝牙在就用蓝牙的，蓝牙没了就用云端的，
    /// 蓝牙的字段也已经在 `AppModel.snapshotFromBluetooth` 里合并过。
    private var doorClosed: [Bool]? { snapshot?.doorClosed }

    // 锁 / 后备箱 / 引擎：同样只用 `snapshot` —— 理由见 `doorClosed`。
    private var lockText: String {
        guard let locked = snapshot?.isLocked else { return "—" }
        return locked ? "已锁" : "未锁"
    }
    private var lockTone: Tone {
        guard let locked = snapshot?.isLocked else { return .neutral }
        return locked ? .good : .warn
    }

    /// 能精确到哪一扇 —— 这是四门字段独立的价值
    private var doorText: String {
        guard let states = doorClosed else { return "—" }
        let openIdx = states.enumerated().filter { !$0.element }.map(\.offset)
        if openIdx.isEmpty { return "全关" }
        return openIdx.map { doorNames[$0] }.joined(separator: " ")
    }
    private var doorTone: Tone {
        guard let states = doorClosed else { return .neutral }
        return states.allSatisfy { $0 } ? .good : .warn
    }

    private var windowText: String {
        guard let s = snapshot, s.isWindowsKnown else { return "—" }
        return (s.isWindowsClosed ?? false) ? "全关" : "开着"
    }
    private var windowTone: Tone {
        guard let s = snapshot, s.isWindowsKnown else { return .neutral }
        return (s.isWindowsClosed ?? false) ? .good : .warn
    }

    private var sunroofText: String {
        guard let open = snapshot?.isSunroofOpen else { return "—" }
        return open ? "开" : "关"
    }
    private var sunroofTone: Tone {
        guard let open = snapshot?.isSunroofOpen else { return .neutral }
        return open ? .warn : .good
    }

    private var trunkText: String {
        guard let closed = snapshot?.isTrunkClosed else { return "—" }
        return closed ? "关" : "开"
    }
    private var trunkTone: Tone {
        guard let closed = snapshot?.isTrunkClosed else { return .neutral }
        return closed ? .good : .warn
    }

    private var engineText: String {
        guard let running = snapshot?.isEngineRunning else { return "—" }
        return running ? "运行" : "熄火"
    }
    private var engineTone: Tone {
        guard let running = snapshot?.isEngineRunning else { return .neutral }
        return running ? .active : .good
    }

    /// 上电 / ACC 只有蓝牙广播里有，云端不提供。
    ///
    /// 调用方（`RootView`）只在**蓝牙活跃**时才传 `status`，否则传 nil ——
    /// 否则车开走后会一直显示最后一次蓝牙看到的上电状态。
    private var ignitionText: String {
        guard let on = status?.isIgnitionOn else { return "—" }
        return on ? "开" : "关"
    }
    private var ignitionTone: Tone {
        guard let on = status?.isIgnitionOn else { return .neutral }
        return on ? .active : .neutral
    }

    private var accText: String {
        guard let on = status?.isAccOn else { return "—" }
        return on ? "开" : "关"
    }
    private var accTone: Tone {
        guard let on = status?.isAccOn else { return .neutral }
        return on ? .active : .neutral
    }

    private enum Tone {
        case good, warn, active, neutral

        var color: Color {
            switch self {
            case .good: return .green
            case .warn: return .orange
            case .active: return .cyan
            case .neutral: return .secondary
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
