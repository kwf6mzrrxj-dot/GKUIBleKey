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
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "car.side.fill")
                .font(.system(size: 24))
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

            VStack(alignment: .trailing, spacing: 4) {
                Text(context.state.isLocked == true ? "已锁" : "未锁")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(context.state.isLocked == true ? .green : .orange)
                if let at = context.state.lastPreAuthAt {
                    Text(at, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
