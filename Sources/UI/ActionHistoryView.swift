import SwiftUI
import UIKit

/// 操作历史 —— 本地最近 100 条车控记录。
///
/// 回答的问题很具体：车借人之后「他动过什么」、远程启动失败「是没发出去
/// 还是车端拒绝」。所以只显示动作 / 通道 / 结果 / 时间，不显示任何技术细节。
struct ActionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var history = ActionHistory.shared

    @State private var confirmClear = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    ContentUnavailableView("还没有操作记录",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("执行一次解锁、空调或引擎后，这里会留下记录"))
                } else {
                    // 不用 List(.insetGrouped)：它自带一层不透明分组底，
                    // 与液态玻璃背景打架（看起来像贴了一张白纸）。
                    // 改成 ScrollView + 玻璃卡片，与其它页同一套材质。
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Glass.sectionSpacing) {
                            ForEach(groups, id: \.day) { group in
                                dayCard(group)
                            }
                        }
                        .padding(.horizontal, Glass.pageMargin)
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(GlassScreenBackground())
            .navigationTitle("操作历史")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(copied ? "已复制" : "复制全部") { copyAll() }
                        .disabled(history.records.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(history.records.isEmpty)
                }
            }
            .alert("清空操作历史？", isPresented: $confirmClear) {
                Button("清空", role: .destructive) { history.clear() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删除这台手机上的记录，不影响车辆本身。")
            }
        }
    }

    /// 一天一张玻璃卡
    private func dayCard(_ group: DayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayTitle(group.day))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(group.records.enumerated()), id: \.element.id) { i, r in
                    row(r)
                    if i < group.records.count - 1 {
                        Divider().padding(.leading, 34)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .glassCard()
        }
    }

    // MARK: - 行

    private func row(_ r: ActionRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(r.success ? Color.green : Color.red)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(r.title)
                    .font(.system(size: 14, weight: .medium))

                HStack(spacing: 6) {
                    Text(r.channel)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                        .foregroundStyle(.secondary)
                    Text(r.at.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !r.note.isEmpty {
                    Text(r.note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 分组

    private struct DayGroup {
        let day: Date
        let records: [ActionRecord]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: history.records) {
            calendar.startOfDay(for: $0.at)
        }
        return grouped
            .map { DayGroup(day: $0.key, records: $0.value.sorted { $0.at > $1.at }) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "今天" }
        if Calendar.current.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.year().month().day())
    }

    private func copyAll() {
        UIPasteboard.general.string = history.exportText()
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}
