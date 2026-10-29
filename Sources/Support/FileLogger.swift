import Foundation

// MARK: - 日志级别

/// 日志级别。数值越大越严重；`minimumLevel` 之下的一律丢弃（不产生字符串、不落盘）。
///
/// | 级别 | 使用场景 |
/// |---|---|
/// | `debug` | 高频协议细节：TX/RX 帧字节、广播原始数据、MTU、特征发现。**默认关闭**时也不影响排障结论（关键节点在 info 以上） |
/// | `info`  | 正常业务流程：连接/断开、配对开始/成功、动作执行结果、标定读取 |
/// | `warning` | 可恢复的异常：RSSI 过低、订阅失败后重试、标定缺失、协议乱序 |
/// | `error` | 不可恢复/需人工介入：密钥解析失败、鉴权自校验失败、写特征失败、命令超时（690） |
public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 固定宽度（5 字符），便于日志按列对齐 / grep
    public var label: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO "
        case .warning: return "WARN "
        case .error:   return "ERROR"
        }
    }

    public var name: String {
        switch self {
        case .debug:   return "debug"
        case .info:    return "info"
        case .warning: return "warning"
        case .error:   return "error"
        }
    }

    public init?(name: String) {
        switch name.lowercased() {
        case "debug", "verbose":         self = .debug
        case "info":                     self = .info
        case "warning", "warn":          self = .warning
        case "error", "err", "fatal":    self = .error
        default: return nil
        }
    }
}

// MARK: - 配置

/// 日志配置。全部字段都有安全默认值，可按需覆盖。
public struct LogConfig: Sendable, Equatable {
    /// 低于此级别不记录
    public var minimumLevel: LogLevel = .debug
    /// 单个文件上限（字节），超过即轮转
    public var maxFileBytes: Int = 2 * 1024 * 1024      // 2 MB
    /// 保留的轮转文件个数（不含当前文件）
    public var maxFiles: Int = 5
    /// 文件保留天数，过期删除
    public var retentionDays: Int = 7
    /// error 级别是否附带调用栈
    public var includeStackForError: Bool = true
    /// 是否对敏感字段做掩码
    public var redactSensitive: Bool = true
    /// 实时浮窗保留的行数
    public var memoryCapacity: Int = 300

    public init() {}
}

// MARK: - 日志器

/// 线程安全的分级日志器（单例）。
///
/// ## 设计要点
/// - **线程安全**：所有文件/内存写入都走**串行队列**；配置读写用 `NSLock`，
///   因此可从任意线程、任意 actor 调用（含 `nonisolated` 回调）。
/// - **级别过滤前置**：`log()` 先比较级别，低于阈值直接返回，
///   不拼接字符串、不排队——高频 TX/RX 也不会拖慢 BLE 回调。
/// - **轮转与保留**：当前文件 `gkuiblekey.log` → 超限重命名为 `gkuiblekey.1.log`，
///   依次后移，最多 `maxFiles` 份；另按 `retentionDays` 定期清理过期文件。
/// - **脱敏**：对 `Dk1/sd/ed/RndTRx/rights/keyType/CkTrxSP` 等密钥字段值、
///   以及 name 含 key/secret/token/password/idfv 的上下文字段做掩码。
///   **帧字节（TX/RX）不打码** —— 那是排障必需信息，且不含长期密钥。
/// - **兼容旧接口**：`append(_:tag:)` 等价于 `info(module: tag)`，
///   现有 13 处调用无需改动即可享受轮转/脱敏/过滤能力。
///
/// ## 配置方式
/// ```swift
/// // ① 代码
/// FileLogger.shared.config.minimumLevel = .info
/// FileLogger.shared.config.maxFileBytes = 1_048_576
///
/// // ② UserDefaults（启动时 loadConfigFromDefaults() 读取）
/// //    gkuiblekey.log.level           = "debug" | "info" | "warning" | "error"
/// //    gkuiblekey.log.maxFileKB       = 1024
/// //    gkuiblekey.log.maxFiles        = 5
/// //    gkuiblekey.log.retentionDays   = 7
/// ```
public final class FileLogger: @unchecked Sendable {

    public static let shared = FileLogger()

    // MARK: 内部状态

    /// 串行队列：所有文件 + 内存写入的唯一入口
    private let queue = DispatchQueue(label: "com.mmxisme.gkuiblekey.filelog", qos: .utility)
    /// 配置锁：只保护 `_config`，持锁时间极短
    private let configLock = NSLock()
    private var _config = LogConfig()

    private let dirURL: URL
    private var handle: FileHandle?
    private var currentSize: Int = 0
    private var memoryLines: [String] = []
    private var lastRetentionCheck = Date.distantPast

    /// 新增一行时的回调（主线程触发），用于实时浮窗
    public nonisolated(unsafe) var onNewLine: ((String) -> Void)?

    private static let filePrefix = "gkuiblekey"

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dirURL = docs.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        currentSize = (try? FileManager.default.attributesOfItem(
            atPath: currentFileURL().path)[.size] as? Int) ?? 0
    }

    // MARK: 配置

    public var config: LogConfig {
        get {
            configLock.lock(); defer { configLock.unlock() }
            return _config
        }
        set {
            configLock.lock(); _config = newValue; configLock.unlock()
            queue.async { [weak self] in self?.applyRetentionLocked() }
        }
    }

    /// 从 `UserDefaults` 载入配置覆盖（App 启动时调用一次）。
    public func loadConfigFromDefaults() {
        let d = UserDefaults.standard
        var c = LogConfig()
        if let s = d.string(forKey: "gkuiblekey.log.level"), let lv = LogLevel(name: s) {
            c.minimumLevel = lv
        }
        let kb = d.integer(forKey: "gkuiblekey.log.maxFileKB")
        if kb > 0 { c.maxFileBytes = kb * 1024 }
        let files = d.integer(forKey: "gkuiblekey.log.maxFiles")
        if files > 0 { c.maxFiles = files }
        let days = d.integer(forKey: "gkuiblekey.log.retentionDays")
        if days > 0 { c.retentionDays = days }
        config = c
    }

    // MARK: 分级 API

    public func debug(_ message: String, module: String = "APP", context: [String: String] = [:]) {
        log(.debug, message, module: module, context: context)
    }

    public func info(_ message: String, module: String = "APP", context: [String: String] = [:]) {
        log(.info, message, module: module, context: context)
    }

    public func warning(_ message: String, module: String = "APP", context: [String: String] = [:]) {
        log(.warning, message, module: module, context: context)
    }

    public func error(
        _ message: String,
        module: String = "APP",
        context: [String: String] = [:],
        error: Error? = nil,
        includeStack: Bool = true
    ) {
        var ctx = context
        if let error { ctx["error"] = "\(error)" }
        log(.error, message, module: module, context: ctx, forceStack: includeStack)
    }

    /// 兼容旧接口：`append(_:tag:)` == `info(module: tag)`。
    public func append(_ line: String, tag: String = "") {
        log(.info, line, module: tag.isEmpty ? "APP" : tag, context: [:])
    }

    // MARK: 读取 / 导出

    /// 内存环形缓冲区的最近日志（实时浮窗首次渲染用）
    public func recentMemoryLines() -> [String] {
        queue.sync { memoryLines }
    }

    /// 所有日志文件（当前 + 轮转），按新旧排序
    public func allFileURLs() -> [URL] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dirURL.path)) ?? []
        return names
            .filter { $0.hasPrefix(Self.filePrefix) && $0.hasSuffix(".log") }
            .compactMap { name -> URL? in
                let url = dirURL.appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                return (attrs?[.modificationDate] as? Date).map { _ in url }
            }
            .sorted {
                let d1 = (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date) ?? .distantPast
                let d2 = (try? fm.attributesOfItem(atPath: $1.path)[.modificationDate] as? Date) ?? .distantPast
                return d1 > d2
            }
    }

    /// 拼接全部日志文本（供分享/导出）
    public func exportText() -> String {
        allFileURLs()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    // MARK: 核心写入

    private func currentFileURL() -> URL {
        dirURL.appendingPathComponent("\(Self.filePrefix).log")
    }

    private func fileURL(index: Int) -> URL {
        index == 0
            ? dirURL.appendingPathComponent("\(Self.filePrefix).log")
            : dirURL.appendingPathComponent("\(Self.filePrefix).\(index).log")
    }

    private func log(
        _ level: LogLevel,
        _ message: String,
        module: String,
        context: [String: String],
        forceStack: Bool = false
    ) {
        // ★ 级别过滤前置：持锁时间极短，且不拼接字符串
        configLock.lock()
        let cfg = _config
        configLock.unlock()
        guard level >= cfg.minimumLevel else { return }

        let line = Self.format(level, message, module: module, context: context,
                              cfg: cfg, forceStack: forceStack)

        queue.async { [weak self] in
            self?.writeLocked(line, cfg: cfg)
        }
    }

    /// 统一格式：`2006-01-02 15:04:05.123 [LEVEL] [MODULE] message ctx{k=v}`
    private static func format(
        _ level: LogLevel,
        _ message: String,
        module: String,
        context: [String: String],
        cfg: LogConfig,
        forceStack: Bool
    ) -> String {
        let ts = stampFormatter.string(from: Date())
        let body = cfg.redactSensitive ? redact(message) : message
        var out = "\(ts) [\(level.label)] [\(module)] \(body)"

        if !context.isEmpty {
            let kv = context.sorted { $0.key < $1.key }.map { key, value -> String in
                let masked = (cfg.redactSensitive && isSensitiveKey(key))
                    ? mask(value)
                    : (cfg.redactSensitive ? redact(value) : value)
                return "\(key)=\(masked)"
            }.joined(separator: " ")
            out += " ctx{\(kv)}"
        }

        if level == .error, forceStack, cfg.includeStackForError {
            let frames = Thread.callStackSymbols.prefix(10).dropFirst()   // 去掉本函数帧
            if !frames.isEmpty {
                out += "\n  ⤷ " + frames.joined(separator: "\n    ")
            }
        }
        return out
    }

    private func writeLocked(_ line: String, cfg: LogConfig) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        ensureHandleLocked()

        if let handle {
            try? handle.write(contentsOf: data)
            currentSize += data.count
        } else {
            // 句柄打开失败 → 退化为整文件追加，至少不丢日志
            if let existing = try? Data(contentsOf: currentFileURL()) {
                var merged = existing
                merged.append(data)
                try? merged.write(to: currentFileURL())
                currentSize = merged.count
            } else {
                try? data.write(to: currentFileURL())
                currentSize = data.count
            }
        }

        // 内存环形（只取首行，避免堆栈把浮窗撑乱）
        let firstLine = line.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? line
        memoryLines.append(firstLine)
        if memoryLines.count > cfg.memoryCapacity {
            memoryLines.removeFirst(memoryLines.count - cfg.memoryCapacity)
        }
        if let callback = onNewLine {
            DispatchQueue.main.async { callback(firstLine) }
        }

        // 超限轮转
        if currentSize > cfg.maxFileBytes {
            rotateLocked(cfg: cfg)
        }

        // 每小时检查一次过期清理
        if Date().timeIntervalSince(lastRetentionCheck) > 3600 {
            lastRetentionCheck = Date()
            applyRetentionLocked()
        }
    }

    private func ensureHandleLocked() {
        if handle != nil { return }
        let url = currentFileURL()
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
            currentSize = 0
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// 轮转：`gkuiblekey.log` → `.1` → `.2` …，超出 `maxFiles` 的最旧文件删除
    private func rotateLocked(cfg: LogConfig) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default

        let maxIndex = max(cfg.maxFiles, 1)
        try? fm.removeItem(at: fileURL(index: maxIndex))

        if maxIndex > 1 {
            for i in stride(from: maxIndex - 1, through: 1, by: -1) {
                let src = fileURL(index: i)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.moveItem(at: src, to: fileURL(index: i + 1))
            }
        }
        if fm.fileExists(atPath: currentFileURL().path) {
            try? fm.moveItem(at: currentFileURL(), to: fileURL(index: 1))
        }
        currentSize = 0
        ensureHandleLocked()
    }

    /// 按保留天数删除过期日志文件
    private func applyRetentionLocked() {
        let cfg = _config
        let cutoff = Date().addingTimeInterval(-Double(cfg.retentionDays) * 86_400)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in files {
            guard url.lastPathComponent.hasPrefix(Self.filePrefix) else { continue }
            guard let date = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { continue }
            if date < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: 脱敏

    private static let sensitiveKeys = [
        "dk1", "cktrxsp", "cktrx", "key", "secret", "token", "password",
        "idfv", "auth", "credential", "private",
    ]

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeys.contains { lower.contains($0) }
    }

    /// 长串中间打码，保留首尾各 4 字符便于比对
    private static func mask(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 16 else { return "***" }
        return "\(compact.prefix(4))…\(compact.suffix(4))(len=\(compact.count))"
    }

    /// 消息体里的 `Dk1=xxxx` / `CkTRxSP=xxxx` 等字段值做掩码。
    /// **不动**裸帧字节（`→ 01 09 …`），因为那是排障必需且不含长期密钥。
    private static let sensitiveFieldRegex = try! NSRegularExpression(
        pattern: #"\b(Dk1|sd|ed|RndTRx|rights|keyType|CkTRxSP)\s*=\s*([0-9A-Fa-f][0-9A-Fa-f\s]{6,})"#,
        options: []
    )

    private static func redact(_ text: String) -> String {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = sensitiveFieldRegex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        var result = text
        // 从后往前替换，避免 range 位移
        for m in matches.reversed() {
            guard m.numberOfRanges == 3,
                  let full = Range(m.range(at: 0), in: result),
                  let valueRange = Range(m.range(at: 2), in: result) else { continue }
            let raw = String(result[valueRange])
            let masked = mask(raw)
            // 只替换值部分：保留 `Dk1=`
            let keyPart = String(result[full]).components(separatedBy: "=").first ?? ""
            result.replaceSubrange(full, with: "\(keyPart)=\(masked)")
        }
        return result
    }
}
