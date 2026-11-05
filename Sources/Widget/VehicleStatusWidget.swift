import WidgetKit
import SwiftUI
import AppIntents

/// 桌面小组件 —— 车控 App 最高频的入口其实不是 App 本身，是桌面。
///
/// ## 为什么没有状态显示
///
/// 小组件在**独立进程**里运行，读不到主 App 的 `UserDefaults` / `AppModel`。
/// 共享数据需要 App Group，而本项目用的是免费个人开发者账号 ——
/// 加 App Group entitlement 会让签名和设备安装一起挂掉（这与 watchOS
/// profile 缺失是同一类限制）。
///
/// 所以这里**只做动作按钮**：点一下就执行，不需要先打开 App。
/// 状态显示留给锁屏实时活动（那边由 App 主动推送快照，本来就有数据）。
///
/// ## 点击后谁来执行
///
/// 复用控制中心那套 `QuickControlIntent`（`.background` 模式）：
/// 系统在 App 进程里执行 `performControlAction`，会等云端请求真的返回
/// （这一段在 2026-11-05 修过，见 `QuickControlIntent.perform` 的注释）。
struct VehicleStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "VehicleStatusWidget",
                            provider: VehicleWidgetProvider()) { _ in
            VehicleWidgetView()
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(white: 0.10), Color(white: 0.16)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                }
        }
        .configurationDisplayName("数字钥匙")
        .description("不用打开 App，直接从桌面解锁、锁车。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct VehicleWidgetEntry: TimelineEntry {
    let date: Date
}

struct VehicleWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> VehicleWidgetEntry {
        VehicleWidgetEntry(date: Date())
    }

    func getSnapshot(in context: Context,
                     completion: @escaping (VehicleWidgetEntry) -> Void) {
        completion(VehicleWidgetEntry(date: Date()))
    }

    func getTimeline(in context: Context,
                     completion: @escaping (Timeline<VehicleWidgetEntry>) -> Void) {
        // 内容是纯按钮，没有会过期的数据 → 不需要定时刷新。
        completion(Timeline(entries: [VehicleWidgetEntry(date: Date())], policy: .never))
    }
}

private struct VehicleWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: medium
        default:            small
        }
    }

    // MARK: - 小尺寸

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                actionButton(.unlock, "解锁", "lock.open.fill", .green)
                actionButton(.lock, "锁车", "lock.fill", .blue)
            }
        }
    }

    // MARK: - 中尺寸

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header
                Spacer()
                Text("点按即执行")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                actionButton(.unlock, "解锁", "lock.open.fill", .green)
                actionButton(.lock, "锁车", "lock.fill", .blue)
                actionButton(.trunk, "后备箱", "car.side.rear.open", .orange)
                actionButton(.find, "寻车", "light.beacon.max.fill", .yellow)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "key.radiowaves.forward.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
            Text("数字钥匙")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func actionButton(_ action: QuickControlAction,
                              _ title: String,
                              _ icon: String,
                              _ tint: Color) -> some View {
        Button(intent: QuickControlIntent(action)) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(tint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
