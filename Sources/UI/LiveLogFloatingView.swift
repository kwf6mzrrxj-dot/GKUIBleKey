import SwiftUI

/// 实时日志浮窗 —— 一个**固定位置**、可折叠的半透明浮窗，悬浮在所有界面之上，
/// 实时滚动显示最近日志行（`FileLogger` 驱动）。在开发者菜单可开关。
///
/// ## 交互
/// - 点击标题栏 → 折叠/展开
/// - 固定在屏幕顶部，不拖动（避免拖动与折叠手势冲突、以及拖出屏幕的问题）
/// - 自动滚动，始终显示最新日志
struct LiveLogFloatingView: View {
    @EnvironmentObject private var model: AppModel

    /// 是否折叠（只显示标题栏）
    @State private var collapsed = false

    var body: some View {
        // 仅浮窗内容本身（定位由 FloatingWindowController 的 hosting view frame 控制），
        // 不再铺全屏透明容器，从根源上避免触摸穿透失效。
        VStack(spacing: 0) {
            // 标题栏（点击折叠/展开）
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("实时日志")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(model.liveLogLines.count) 行")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
            }

            if !collapsed {
                Divider().opacity(0.4)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if model.liveLogLines.isEmpty {
                                Text("暂无日志")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity)
                            } else {
                                ForEach(Array(model.liveLogLines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(lineColor(line))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 180)
                    .onChange(of: model.liveLogLines.count) { _, _ in
                        if let last = model.liveLogLines.indices.last {
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            } else {
                // ★ 折叠时保留 180 高度占位（半透明背景），保持浮窗框高度稳定，
                //   避免 hosting view 高度变化导致的触摸区域错乱。
                Color.clear.frame(height: 180)
            }
        }
        .frame(width: 300, height: 260)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .clipped()
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
}
