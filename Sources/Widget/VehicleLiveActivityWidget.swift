import WidgetKit
import SwiftUI

/// 锁屏 / 灵动岛上的「数字钥匙」实时活动。
///
/// 它存在的技术目的见 `VehicleActivityAttributes` 的文档：
/// **有 Live Activity 才能拿到后台等同前台的 Core Bluetooth 权限**。
/// 所以这里除了显示状态，还承担「让 iOS 别把我们的广播合并投递」的作用。
///
/// UI 上刻意克制：只显示车名、锁状态、链路状态和最近一次预认证时间 ——
/// 用户在锁屏上一眼就能判断「现在按启动按钮有没有戏」。
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
                    Text(context.state.isLocked == true ? "已锁" : "未锁")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(context.state.isLocked == true ? .green : .orange)
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
                Text(context.state.isLocked == true ? "锁" : "开")
                    .font(.caption2.weight(.semibold))
            } minimal: {
                Image(systemName: context.state.isConnected ? "key.fill" : "key")
            }
        }
    }
}

// MARK: - 锁屏布局

private struct LockScreenView: View {
    let context: ActivityViewContext<VehicleActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：车名 / 在线 / 锁态
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.vehicleName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 6) {
                        StatusDot(ok: context.state.isConnected)
                        Text(context.state.statusText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(lockText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(lockColor)
                    // ★ 离线后**保留**最后一次上报的状态，并明确标出时间
                    //   —— 不让用户把"5 分钟前的快照"当成实时状态。
                    if let at = context.state.lastReportedAt {
                        Text(at, style: .relative)
                            .font(.caption2)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        VStack(spacing: 1) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
            Text(value == nil ? "—" : (value! ? on : off))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(value == nil
                                 ? Color.white.opacity(0.35)
                                 : (value! ? Color.white : Color.orange))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
