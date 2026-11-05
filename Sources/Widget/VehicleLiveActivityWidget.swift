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
/// 上电 / ACC 只有蓝牙广播里有，云端不提供 —— 蓝牙不在时显示「—」。
/// `statusText` 会写明「蓝牙 · 19:28」或「云端 · 19:28」，用户能看出数据新旧。
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
            DynamicIsland {
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
                    // 没有数据 ≠ 未锁。以前 `isLocked == true ? "已锁" : "未锁"`
                    // 会把「还没收到广播」直接画成「未锁」，比不显示更糟。
                    Text(lockShortText(context.state.isLocked, long: true))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(lockShortColor(context.state.isLocked))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        StatusDot(ok: context.state.isConnected)
                        Text(context.state.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let at = context.state.lastPreAuthAt {
                            Text(at, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
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

            // 第二行：全部车辆状态（门 / 后备箱 / 引擎 / 电源）
            HStack(spacing: 8) {
                miniStat("门", context.state.isDoorClosed, on: "关", off: "开")
                miniStat("后箱", context.state.isTrunkClosed, on: "关", off: "开")
                miniStat("引擎", context.state.isEngineRunning, on: "转", off: "停")
                miniStat("电源", context.state.isIgnitionOn ?? context.state.isAccOn,
                         on: "开", off: "关")
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

    /// 一格小状态。`value == nil` 时显示「—」——区分「没上报过」和「上报了是关」
    private func miniStat(_ title: String, _ value: Bool?,
                          on: String, off: String) -> some View {
        VStack(spacing: isWide ? 3 : 1) {
            Text(title)
                .font(.system(size: scaled(9)))
                .foregroundStyle(.white.opacity(0.5))
            Text(value == nil ? "—" : (value! ? on : off))
                .font(.system(size: scaled(11), weight: .semibold))
                .foregroundStyle(value == nil
                                 ? Color.white.opacity(0.35)
                                 : (value! ? Color.white : Color.orange))
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
