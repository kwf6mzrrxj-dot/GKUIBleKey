import SwiftUI
import UIKit

/// 统一日志页。
///
/// 汇总四个来源，联调时对着看最省事：
/// - **原始报文**：BLE 收发 hex，带毫秒时间戳（可与抓包工具对齐）
/// - **DK 会话**：五步握手、控车指令、车端状态的逐步记录
/// - **InBlue 配对**：配对三消息与参数记录
/// - **全部模块**：`FileLogger` 的全量流，与实时浮窗**同源**
///
/// 支持一键复制当前来源，或导出磁盘上的全部历史（含已轮转文件）。
struct LogView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case measured = "实测会话"
        case raw = "原始报文"
        case pairing = "配对"
        case appLog = "全部模块"
        var id: String { rawValue }
    }

    @State private var source: Source = .measured
    @State private var autoScroll = true
    @State private var copied = false
    @State private var exportFile: LogExportFile?

    private var lines: [String] {
        switch source {
        // ★ 默认看这个：当前真实链路（01/02/03/04/05）的记录。
        //   之前这里错绑到已废弃的 `session`（旧 DKSession），所以日志永远是空的。
        case .measured: return model.measured.log
        case .raw:      return model.ble.rxHexStream
        case .pairing:  return model.pairing.log
        // 全部模块由 `AppLogList` 自己渲染（它独立订阅 LogFeed，
        // 否则本页每来一条日志都会连带重绘其它三个来源）。
        case .appLog:   return []
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                logBody
            }
            .background(GlassScreenBackground())
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 导出**磁盘**日志（全部轮转文件合并）。
                    // ★ 不能写成 `ShareLink(item: FileLogger.shared.exportText())`：
                    //   ShareLink 的 item 在 body 求值时就算，每来一行日志都会
                    //   重读一遍全部文件（最大 10 MB）。改成点击后才生成临时文件。
                    Button {
                        if let url = FileLogger.shared.exportToTemporaryFile() {
                            exportFile = LogExportFile(url: url)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("导出磁盘日志")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? "已复制" : "复制全部") { copyAll() }
                        .disabled(displayCount == 0)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $exportFile) { f in
                LogExportSheet(url: f.url)
            }
        }
    }

    // MARK: - 顶部控制

    private var controls: some View {
        VStack(spacing: Glass.innerSpacing) {
            // 四段已经很挤，标签里不再带条数（会在窄屏被截断）——
            // 当前来源的条数在下面「共 N 条」显示。
            Picker("来源", selection: $source) {
                ForEach(Source.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)

            // ★ 落盘级别不在这里了（2026-11-05 第三轮审查）：
            //   它控制的是**磁盘写入**，与"查看当前来源"没关系，
            //   放在查看页会让人以为改它能让上面的行变多。
            //   已移到「诊断 → 日志」卡片，那里才是调日志行为的地方。

            HStack {
                Toggle("自动滚到底部", isOn: $autoScroll)
                    .font(.caption2)
                    .tint(.cyan)
                Spacer()
                // 「全部模块」的条数由 AppLogList 自己显示（那里订阅了 LogFeed，
                // 才能跟着刷新）；这里只显示另外三个内存来源的条数。
                if source != .appLog {
                    Text("共 \(lines.count) 条")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            // 说清这页的边界：它是内存视图，不是全部历史。
            // 用户上次就是在这里找不到昨晚的日志（其实在磁盘上）。
            // 只留一行 —— 上一版写了两行，把正文高度吃掉 30pt。
            Text("内存视图 · 重启即清空 · 历史在「诊断 → 历史」")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 当前来源的实际行数（「全部模块」不在 `lines` 里，单独取）
    private var displayCount: Int {
        source == .appLog ? LogFeed.shared.lines.count : lines.count
    }

    // MARK: - 日志正文

    private var logBody: some View {
        Group {
            if source == .appLog {
                AppLogList(autoScroll: autoScroll)
            } else if lines.isEmpty {
                VStack(spacing: Glass.innerSpacing) {
                    Image(systemName: "text.alignleft")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: lines.count) { _, newCount in
                        guard autoScroll, newCount > 0 else { return }
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var emptyHint: String {
        switch source {
        case .measured: return "还没有实测会话记录。\n连上车辆后点「解锁」或「准备点火」，这里会显示 01→02→03→04 的逐步日志。"
        case .raw:      return "还没有收发数据。\n连上车辆模块后，这里会显示每一帧的 hex。"
        case .pairing:  return "还没有配对记录。\n点首页「配对」发起首次绑定后会记录在这里。"
        case .appLog:   return "还没有全模块日志。"
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("→") { return .cyan }
        if line.contains("←") { return .green }
        if line.contains("❌") || line.contains("错误") || line.contains("失败") { return .red }
        if line.contains("⚠️") { return .orange }
        return .primary
    }

    // MARK: - 复制

    private func copyAll() {
        // 「全部模块」的行不在 `lines` 里（它由 AppLogList 独立渲染），
        // 复制时要从 LogFeed 取 —— 否则这个来源的「复制全部」永远是禁用的。
        let sourceLines = source == .appLog ? LogFeed.shared.lines : lines
        guard !sourceLines.isEmpty else { return }
        let header = "=== \(source.rawValue) · \(sourceLines.count) 条 · \(BLECentral.stamp()) ===\n"
        UIPasteboard.general.string = header + sourceLines.joined(separator: "\n")
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

/// 「全部模块」日志列表 —— 独立订阅 `LogFeed`。
///
/// ## 为什么单独一个视图
/// `LogView` 的 body 依赖 `model`（AppModel 每秒都在 publish：RSSI、链路状态）。
/// 如果把 `LogFeed` 也挂在 `LogView` 上，日志每来一行就会把整个页面
/// （Picker、级别控件、计数、另外三个来源）全部重算一遍。
/// 拆出来后只有这一个列表重绘。
///
/// 与实时浮窗**同源同容量**（`LogFeed.capacity = 300`），
/// 所以两边行数一致 —— 之前一个 200 一个 300，用户以为日志丢了。
private struct AppLogList: View {
    let autoScroll: Bool
    @ObservedObject private var feed = LogFeed.shared

    var body: some View {
        if feed.lines.isEmpty {
            VStack(spacing: Glass.innerSpacing) {
                Image(systemName: "text.alignleft")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("还没有全模块日志。\n连上车辆或触发一次操作后，这里会记录所有模块的输出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(feed.lines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(color(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(idx)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: feed.lines.count) { _, _ in
                        guard autoScroll, let last = feed.lines.indices.last else { return }
                        withAnimation(.linear(duration: 0.15)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }

                // 计数放在这里而不是顶部：本视图订阅了 LogFeed，数字才是实时的
                Text("共 \(feed.lines.count) 行（全模块，最多 \(LogFeed.capacity)）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 6)
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("❌") || line.contains("失败") || line.contains("error") { return .red }
        if line.contains("⚠️") || line.contains("警告") { return .orange }
        if line.contains("→") { return .cyan }
        if line.contains("←") { return .green }
        if line.contains("✅") { return .green }
        return .primary
    }
}

/// 导出文件句柄（`URL` 不满足 `Identifiable`，`.sheet(item:)` 需要一个包装）
struct LogExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 导出结果页：确认文件已生成，再交给系统分享。
///
/// 为什么不直接 `ShareLink(item: URL)` 放在工具栏：
/// 生成 10 MB 文件要时间，需要让用户知道"正在导出/已导出"，并给他一个
/// 能选「存到文件」的完整分享面板。工具栏图标点一下直接弹分享，
/// 大日志时会有 1–2 秒的空白期，看着像没反应。
struct LogExportSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    private var sizeText: String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        return bytes < 1024 * 1024
            ? String(format: "%.1f KB", Double(bytes) / 1024)
            : String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Glass.sectionSpacing) {
                Image(systemName: "doc.text.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
                Text(url.lastPathComponent)
                    .font(.system(.callout, design: .monospaced))
                    .multilineTextAlignment(.center)
                Text("\(sizeText) · 全部轮转日志已合并")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ShareLink(item: url) {
                    Label("分享 / 存储到「文件」", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)

                Text("这份文件包含磁盘上的全部日志（含已轮转的历史文件），"
                     + "比页面里能看到的多。\n"
                     + "⚠️ 收发报文按排障需要保留了原始十六进制（未打码），"
                     + "里面含本次会话的密钥派生数据 —— 请勿公开发布。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .navigationTitle("导出日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
