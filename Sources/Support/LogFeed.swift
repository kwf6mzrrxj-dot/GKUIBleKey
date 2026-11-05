import Foundation

extension Notification.Name {
    /// 浮窗右上角「关掉」→ 通知 AppModel 把开关置 false。
    ///
    /// 为什么绕一圈：浮窗不能持有 `AppModel`（`@EnvironmentObject` 会在
    /// 每次 `objectWillChange` 时重绘，而 RSSI/链路状态每秒都在变），
    /// 但开关状态又必须在 AppModel 里（开发者菜单的 Toggle 绑它）。
    /// 通知是这里最轻的连接方式。
    static let hideLiveLogFloating = Notification.Name("gkuiblekey.hideLiveLogFloating")
}

/// **实时日志流** —— 浮窗与「全部模块」日志页唯一的订阅源。
///
/// ## 为什么要单独一个对象（2026-11-05）
///
/// 改之前，实时日志行是 `AppModel` 上的 `@Published var liveLogLines`。
/// 后果是：`FileLogger` 每写一行就 `append` → `AppModel.objectWillChange`
/// → **整个 App 的所有界面重绘一次**。
///
/// debug 全开时 BLE 一帧广播就有好几行，浮窗开着导航时等于持续全量刷新。
/// 日志本身只是"看"，不该有这个代价。
///
/// 现在：
/// - `AppModel` 不再持有日志行，日志与业务状态彻底解耦
/// - 只有订阅 `LogFeed` 的两个视图（浮窗 / 诊断页）会重绘
/// - 写入按 120ms 合批，避免一帧多行触发多次 publish
///
/// ## 线程模型
/// `ingest` 可从任意线程调用（`FileLogger` 的回调不保证隔离）；
/// `lines` 只在主线程读写 —— 合批的 flush 固定落在 main。
///
/// `@unchecked Sendable` 的依据：跨线程共享的只有 `pending` / `flushScheduled`，
/// 两者都由 `lock` 保护；`lines` 与 `ObservableObject` 的 objectWillChange
/// 只在主线程触碰。没有其它可变状态。
public final class LogFeed: ObservableObject, @unchecked Sendable {

    /// 单例。线程安全由类内的 `lock` 与"主线程 flush"保证（见类型注释）。
    public static let shared = LogFeed()

    /// 保留行数。**三处必须一致**（浮窗 / 诊断页 / 清空提示），
    /// 所以只在这里定义一次。
    public static let capacity = 300

    /// 最近日志行（主线程读写）
    @Published public private(set) var lines: [String] = []

    private let lock = NSLock()
    private var pending: [String] = []
    private var flushScheduled = false

    private init() {
        // 首次渲染就有内容：读 FileLogger 的内存环形缓冲
        lines = FileLogger.shared.recentMemoryLines()
        if lines.count > Self.capacity {
            lines.removeFirst(lines.count - Self.capacity)
        }
    }

    /// 追加一行（线程安全，内部合批）
    public func ingest(_ line: String) {
        lock.lock()
        pending.append(line)
        let needSchedule = !flushScheduled
        flushScheduled = true
        lock.unlock()

        guard needSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.flush()
        }
    }

    /// 清空（界面「清空」按钮）
    public func clear() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        lines.removeAll(keepingCapacity: true)
    }

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        flushScheduled = false
        lock.unlock()

        guard !batch.isEmpty else { return }

        // 一次性赋值，只 publish 一次
        var merged = lines
        merged.append(contentsOf: batch)
        if merged.count > Self.capacity {
            merged.removeFirst(merged.count - Self.capacity)
        }
        lines = merged
    }
}
