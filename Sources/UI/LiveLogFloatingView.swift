import SwiftUI

/// 实时日志浮窗 —— 一个**固定位置**、可折叠的半透明浮窗，悬浮在所有界面之上，
/// 实时滚动显示最近日志行（`LogFeed` 驱动）。在开发者菜单可开关。
///
/// ## 交互
/// - 点右侧箭头 → 折叠/展开（折叠状态持久化）
/// - 点右上角 × → 关闭浮窗（通知 AppModel 把开关置 false，两处状态保持一致）
/// - 固定在屏幕左上角，**不可拖动** —— 拖动会与按钮手势、Safe Area 冲突，
///   而且拖出屏幕后没有任何办法找回（没有手势复位）。
///
/// ## 为什么自己不持有 AppModel
/// `@EnvironmentObject` 会在 `objectWillChange` 时重绘整个视图。
/// AppModel 上 RSSI、链路状态每秒都在变，浮窗跟着重绘就是持续掉帧。
/// 所以这里只订阅 `LogFeed`（最多 8 次/秒、且只在真写日志时），
/// 关闭动作走 `NotificationCenter`。
struct LiveLogFloatingView: View {
    @ObservedObject private var feed = LogFeed.shared
    @AppStorage("gkuiblekey.liveLog.collapsed") private var collapsed = false

    static let width: CGFloat = 300
    static let expandedHeight: CGFloat = 260
    /// 折叠高度必须 ≥ 标题栏实际高度（22 按钮 + 上下各 7 内边距 = 36），
    /// 否则 `.clipShape` 会把按钮下沿切掉，看起来像被压扁。
    static let collapsedHeight: CGFloat = 38

    private var currentHeight: CGFloat {
        collapsed ? Self.collapsedHeight : Self.expandedHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !collapsed {
                Divider().opacity(0.4)
                logScroll
            }
        }
        .frame(width: Self.width, height: currentHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Glass.pillRadius)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Glass.pillRadius)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        // 圆角裁剪放最后：折叠时内容不会溢出圆角
        .clipShape(RoundedRectangle(cornerRadius: Glass.pillRadius))
        .onAppear { syncWindowHeight() }
        .onChange(of: collapsed) { _, _ in syncWindowHeight() }
    }

    // MARK: - 标题栏

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.caption2)
                .foregroundStyle(.green)
            Text("实时日志")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Text("\(feed.lines.count) 行")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                // 关掉浮窗：写 UserDefaults（下次启动不再出现）+ 通知 AppModel 同步开关
                UserDefaults.standard.set(false, forKey: "gkuiblekey.liveLogFloating")
                NotificationCenter.default.post(name: .hideLiveLogFloating, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭实时日志浮窗")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - 日志正文

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if feed.lines.isEmpty {
                        Text("暂无日志")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(feed.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(lineColor(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: feed.lines.count) { _, _ in
                guard let last = feed.lines.indices.last else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    /// 按内容给日志行着色（发送/接收/错误/警告区分）。深色半透明底，用亮色。
    private func lineColor(_ line: String) -> Color {
        if line.contains("❌") || line.contains("失败") || line.contains("error") {
            return .red
        }
        if line.contains("⚠️") || line.contains("警告") {
            return .orange
        }
        if line.contains("→") { return .cyan }   // 发送
        if line.contains("←") { return .green }  // 接收
        if line.contains("✅") { return .green }
        return .white.opacity(0.82)
    }

    /// 折叠/展开后同步宿主窗口高度。
    ///
    /// 关键：浮窗用的是独立 `UIWindow` + `UIHostingController`，触摸区由
    /// hosting view 的 frame 决定。只改 SwiftUI 里的高度、不改 frame，
    /// 折叠后那 220pt 透明区域**仍然会吃掉点击** —— 用户会发现状态页
    /// 顶部一条区域点不动，却看不出原因。
    private func syncWindowHeight() {
        FloatingWindowController.shared.setContentHeight(currentHeight)
    }
}
