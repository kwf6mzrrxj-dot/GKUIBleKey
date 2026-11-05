import SwiftUI

/// 历史日志浏览（2026-11-02）。
///
/// ## 为什么需要它
///
/// `FileLogger` 一直在往 `Documents/Logs/` 写文件并按大小轮转，
/// 但界面只能看内存里的最近 200 行 —— 用户反馈「不支持查看历史日志」，
/// 想回看昨晚点火那段时，东西其实还在磁盘上，只是没有入口。
///
/// 这里只做三件事：**列出文件 → 看内容 → 分享/删除**。
/// 内容按行渲染，但**大文件只显示尾部**（默认 3000 行），
/// 避免 5 MB 的日志把 SwiftUI 卡死；要看全文用「分享」导出。
struct LogHistoryView: View {
    @Environment(\.dismiss) private var dismiss

    struct LogFile: Identifiable {
        let id = UUID()
        let url: URL
        let size: Int
        let date: Date
        var name: String { url.lastPathComponent }
        var sizeText: String {
            size < 1024 ? "\(size) B"
            : size < 1024 * 1024 ? String(format: "%.1f KB", Double(size) / 1024)
            : String(format: "%.1f MB", Double(size) / 1024 / 1024)
        }
    }

    /// 同一层只能有一个 `.sheet(item:)` 真正生效 —— 分成两个修饰符时，
    /// 后加的那个会盖掉前一个（表现为「点文件没反应」）。合并成一个枚举。
    private enum ActiveSheet: Identifiable {
        case detail(LogFile)
        case export(URL)

        var id: String {
            switch self {
            case .detail(let f): return "detail-\(f.url.lastPathComponent)"
            case .export(let u): return "export-\(u.lastPathComponent)"
            }
        }
    }

    @State private var files: [LogFile] = []
    @State private var activeSheet: ActiveSheet?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    ContentUnavailableView("没有历史日志",
                                           systemImage: "doc.text",
                                           description: Text("日志写入后会自动出现在这里"))
                } else {
                    List {
                        Section {
                            ForEach(files) { f in
                                Button {
                                    activeSheet = .detail(f)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(f.name)
                                                .font(.system(.callout, design: .monospaced))
                                                .foregroundStyle(.primary)
                                            Text(f.date.formatted(date: .abbreviated,
                                                                  time: .standard))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(f.sizeText)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        } footer: {
                            Text("共 \(files.count) 个文件（当前 + 最多 5 个轮转，单个上限 2 MB）。"
                                 + "日志按大小自动轮转，超过 7 天的会被清理。")
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                    .scrollContentBackground(.hidden)
                    .background(GlassScreenBackground())
                }
            }
            .navigationTitle("历史日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    // 全部轮转文件合并导出 —— 排查时贴给人看只需要一个文件
                    Button {
                        if let url = FileLogger.shared.exportToTemporaryFile() {
                            activeSheet = .export(url)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(files.isEmpty)
                    .accessibilityLabel("导出全部日志")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(files.isEmpty)
                }
            }
            .alert("删除全部历史日志？", isPresented: $confirmDelete) {
                Button("删除", role: .destructive) {
                    FileLogger.shared.deleteAllFiles()
                    // 内存那份也要清 —— 否则「历史删光了，浮窗还在滚」，
                    // 用户会以为删除没生效。
                    LogFeed.shared.clear()
                    load()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删掉 Documents/Logs 下所有日志文件，不可恢复。"
                     + "如果还要留证据，先点进文件用「分享」导出。")
            }
            .sheet(item: $activeSheet) { s in
                switch s {
                case .detail(let f): LogFileDetailView(file: f)
                case .export(let url): LogExportSheet(url: url)
                }
            }
            .task { load() }
        }
    }

    private func load() {
        let fm = FileManager.default
        files = FileLogger.shared.allFileURLs().compactMap { url in
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            return LogFile(url: url, size: size, date: date)
        }
    }
}

/// 单个日志文件的内容（只读）。大文件只渲染尾部，全文走分享。
struct LogFileDetailView: View {
    let file: LogHistoryView.LogFile

    @Environment(\.dismiss) private var dismiss
    @State private var lines: [String] = []
    @State private var truncatedFrom = 0
    @State private var loading = true

    /// 尾行上限 —— 再多 SwiftUI 会明显卡
    private let tailLimit = 3000

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("读取中…")
                } else if lines.isEmpty {
                    ContentUnavailableView("文件为空", systemImage: "doc")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if truncatedFrom > 0 {
                                Text("只显示最后 \(lines.count) 行（前面 \(truncatedFrom) 行略过，"
                                     + "完整内容请用右上角分享导出）")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                    .padding(.bottom, 6)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: file.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .task { load() }
        }
    }

    private func load() {
        // 放到后台读，避免大文件卡主线程
        let url = file.url
        let limit = tailLimit
        Task.detached(priority: .userInitiated) {
            var all: [String] = []
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                all = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
            }
            let skipped = max(0, all.count - limit)
            let tail = skipped > 0 ? Array(all.suffix(limit)) : all
            await MainActor.run {
                self.truncatedFrom = skipped
                self.lines = tail
                self.loading = false
            }
        }
    }
}
