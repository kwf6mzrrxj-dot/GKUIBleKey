import Foundation
import os

/// 一条车控操作记录。
///
/// ## 为什么只存本地
///
/// 没有服务端（免费账号也没有推送证书），所以"谁在什么时候开了车门"
/// 只能存在这台手机上。它的用途很具体：
/// - 车借给朋友后，回看对方到底操作了什么
/// - 远程启动失败时，确认是"没发出去"还是"车端拒绝"
/// - 排查"我明明点了解锁"这类争议
///
/// 不记录任何密钥材料、token、VIN —— 只有动作名、通道、结果、时间。
public struct ActionRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    /// 动作名（用户可读，如「解锁」「开空调 24℃」）
    public let title: String
    /// 通道：蓝牙 / 云端 / 控制中心 / 快捷指令
    public let channel: String
    public let success: Bool
    /// 失败原因或补充说明，成功时一般为空
    public let note: String

    public init(id: UUID = UUID(), at: Date = Date(), title: String,
                channel: String, success: Bool, note: String = "") {
        self.id = id
        self.at = at
        self.title = title
        self.channel = channel
        self.success = success
        self.note = note
    }
}

/// 操作历史（本地，最多 100 条）。
///
/// 落盘用 `Documents/action-history.json`：
/// - 不用 UserDefaults：100 条带中文的记录塞进去，整个 defaults 会变得很大，
///   而它每次启动都要整体解码
/// - 不用 SwiftData：为一个线性列表引入一套 ORM 不划算
///
/// 写入失败只记日志、不抛错 —— 历史记录丢一条不该影响车控主流程。
@MainActor
public final class ActionHistory: ObservableObject {

    public static let shared = ActionHistory()

    /// 保留条数。100 条大约覆盖两周的正常使用。
    public static let capacity = 100

    @Published public private(set) var records: [ActionRecord] = []

    private let fileURL: URL
    private static let log = Logger(subsystem: "com.mmxisme.gkuiblekey", category: "history")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = docs.appendingPathComponent("action-history.json")
        load()
    }

    /// 追加一条（新的在最前）
    public func append(_ record: ActionRecord) {
        records.insert(record, at: 0)
        if records.count > Self.capacity {
            records.removeLast(records.count - Self.capacity)
        }
        save()
    }

    /// 便捷入口：成功/失败一行
    public func record(_ title: String, channel: String, success: Bool, note: String = "") {
        append(ActionRecord(title: title, channel: channel,
                            success: success, note: note))
    }

    public func clear() {
        records.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 导出成纯文本（分享/复制用）
    public func exportText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let header = "操作历史 · \(records.count) 条 · 导出 \(f.string(from: Date()))\n"
        let body = records.map { r in
            let mark = r.success ? "✅" : "❌"
            let note = r.note.isEmpty ? "" : "  \(r.note)"
            return "\(f.string(from: r.at))  \(mark) [\(r.channel)] \(r.title)\(note)"
        }.joined(separator: "\n")
        return header + body
    }

    // MARK: - 落盘

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try JSONDecoder.history.decode([ActionRecord].self, from: data)
        } catch {
            Self.log.error("操作历史解码失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder.history.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("操作历史写入失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension JSONEncoder {
    static let history: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let history: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
