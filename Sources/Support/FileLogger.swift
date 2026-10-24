import Foundation

/// ★ **日志落盘** —— 解决"重装/重启就看不到日志"的问题。
///
/// ## 为什么要这个
/// 之前日志只存在内存里（`rxHexStream` / `measured.log`），
/// 一旦 App 重启或重装就全没了，排查问题时最需要的那几条刚好丢掉了。
///
/// 现在所有关键日志**同时追加写入沙盒 Documents 下的 `gkuiblekey.log`**：
/// - **覆盖安装**（不卸载）时文件保留
/// - 可以用 `xcrun devicectl device copy from` 直接把文件拉出来看
///
/// ⚠️ 注意：**卸载** App 仍会清空沙盒（iOS 行为），所以更新时**不要卸载**。
public final class FileLogger {

    public nonisolated(unsafe) static let shared = FileLogger()

    private let queue = DispatchQueue(label: "com.mmxisme.gkuiblekey.filelog")
    private let fileURL: URL
    private let formatter: DateFormatter
    /// 单文件上限，防止无限增长（超过就截半）
    private let maxBytes = 512 * 1024

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("gkuiblekey.log")
        formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
    }

    /// 日志文件路径（供界面显示 / 外部拉取）
    public var path: String { fileURL.path }

    /// 追加一行（自动加时间戳）
    public func append(_ line: String, tag: String = "") {
        let text = "[\(formatter.string(from: Date()))]"
            + (tag.isEmpty ? " " : " [\(tag)] ")
            + line + "\n"
        guard let data = text.data(using: .utf8) else { return }

        queue.async { [fileURL, maxBytes] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                try? data.write(to: fileURL)
                return
            }
            // 超过上限就截掉前半，避免文件无限大
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
               size > maxBytes,
               let existing = try? Data(contentsOf: fileURL) {
                let half = existing.suffix(maxBytes / 2)
                try? (Data(half)).write(to: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// 读取全部日志（供界面「导出/复制」）
    public func readAll() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// 清空日志文件
    public func clear() {
        queue.async { [fileURL] in
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
