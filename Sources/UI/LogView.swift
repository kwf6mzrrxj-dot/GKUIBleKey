import SwiftUI
import UIKit

/// 统一日志页。
///
/// 汇总三个来源，联调时对着看最省事：
/// - **原始报文**：BLE 收发 hex，带毫秒时间戳（可与抓包工具对齐）
/// - **DK 会话**：五步握手、控车指令、车端状态的逐步记录
/// - **InBlue 配对**：配对三消息与参数记录
///
/// 支持一键复制全部，方便贴出来分析。
struct LogView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case measured = "实测会话"
        case raw = "原始报文"
        case pairing = "InBlue 配对"
        var id: String { rawValue }
    }

    @State private var source: Source = .measured
    @State private var autoScroll = true
    @State private var copied = false
    /// 落盘日志的级别过滤（与 `FileLogger.shared.config.minimumLevel` 同步，写入 UserDefaults 持久化）
    @State private var logLevel: LogLevel = FileLogger.shared.config.minimumLevel

    private var lines: [String] {
        switch source {
        // ★ 默认看这个：当前真实链路（01/02/03/04/05）的记录。
        //   之前这里错绑到已废弃的 `session`（旧 DKSession），所以日志永远是空的。
        case .measured: return model.measured.log
        case .raw:      return model.ble.rxHexStream
        case .pairing:  return model.pairing.log
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                logBody
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // 导出落盘日志（全部轮转文件拼接），便于外部分析
                    ShareLink(item: FileLogger.shared.exportText()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? "已复制" : "复制全部") { copyAll() }
                        .disabled(lines.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 顶部控制

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("来源", selection: $source) {
                ForEach(Source.allCases) { s in
                    Text("\(s.rawValue) (\(count(for: s)))").tag(s)
                }
            }
            .pickerStyle(.segmented)

            // ★ 落盘日志的级别过滤（运行时生效，写 UserDefaults 持久化）
            HStack(spacing: 8) {
                Text("落盘级别")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Picker("级别", selection: $logLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { lv in
                        Text(lv.label.trimmingCharacters(in: .whitespaces)).tag(lv)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: logLevel) { _, newValue in
                    FileLogger.shared.config.minimumLevel = newValue
                    UserDefaults.standard.set(newValue.name, forKey: "gkuiblekey.log.level")
                }
            }

            HStack {
                Toggle("自动滚到底部", isOn: $autoScroll)
                    .font(.caption2)
                    .tint(.cyan)
                Spacer()
                Text("共 \(lines.count) 条")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func count(for s: Source) -> Int {
        switch s {
        case .measured: return model.measured.log.count
        case .raw:      return model.ble.rxHexStream.count
        case .pairing:  return model.pairing.log.count
        }
    }

    // MARK: - 日志正文

    private var logBody: some View {
        Group {
            if lines.isEmpty {
                VStack(spacing: 10) {
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
        let header = "=== \(source.rawValue) · \(lines.count) 条 · \(BLECentral.stamp()) ===\n"
        UIPasteboard.general.string = header + lines.joined(separator: "\n")
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
