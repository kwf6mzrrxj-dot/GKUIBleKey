import Foundation
import os
import WatchConnectivity

/// 手机 → 手表的同步通道。
///
/// ## 传什么、为什么
///
/// | 内容 | 时机 | 通道 |
/// |---|---|---|
/// | 账号（手机号 / VIN / MD5 / token） | 登录成功、清除配置、App 启动 | `transferUserInfo`（必达）+ `applicationContext` |
/// | 车况快照 | 每次云端刷新成功 | `applicationContext`（**覆盖式**，只留最新一份） |
///
/// 账号用 `transferUserInfo`：它是**排队必达**的 —— 手表 App 没在前台也能收，
/// 隔天打开也会补投。账号丢了手表就完全不可用，值得用更可靠的那条通道。
///
/// 快照用 `applicationContext`：它天然是「最新一份覆盖上一份」的语义，
/// 正好对应车况这种只看当前值的状态，不会在手表上堆一长串历史。
///
/// ## 谁说了算
///
/// **手机是账号的唯一来源**。手表不做登录界面 ——
/// 在 40mm 的屏幕上输手机号 + 密码 + 17 位 VIN 不现实，
/// 而且两处都能改账号，必然出现「手机改了、手表还是旧账号」的分裂状态。
@MainActor
final class PhoneWatchSync: NSObject {

    static let shared = PhoneWatchSync()

    private var session: WCSession?
    /// 手表当前是否可达（不可达时 `applicationContext` 仍会排队，只是晚一点到）
    private(set) var isReachable = false

    /// 「云端是否已配置」的缓存，给 WCSession 回调在任意线程读。
    ///
    /// 2026-11-04 第二轮审查 L3：原来用 `nonisolated(unsafe) static var`。
    /// 虽然只读写一个 Bool、实践上不会出问题，但跨线程读写非原子值在 Swift 里
    /// 严格说是未定义行为 —— 编译器不拦不代表没有竞态。换成带锁的访问器，
    /// 代价是一次 `withLock`，比"祈祷它别出问题"便宜。
    nonisolated private static let configuredHintLock = OSAllocatedUnfairLock(initialState: false)

    nonisolated private static var configuredHint: Bool {
        get { configuredHintLock.withLock { $0 } }
        set { configuredHintLock.withLock { $0 = newValue } }
    }

    private override init() { super.init() }

    // MARK: - 启动

    func start() {
        guard WCSession.isSupported() else {
            FileLogger.shared.warning("此设备不支持 WCSession，手表同步不可用", module: "手表")
            return
        }
        let s = WCSession.default
        s.delegate = self
        session = s
        s.activate()
    }

    // MARK: - 推送

    /// 推送账号。手机上每次「配置成功 / 清除配置 / 启动」都调一次。
    func pushAccount(_ payload: CloudAccountPayload?) {
        guard let session, session.activationState == .activated else {
            // 冷启动时 `start()` 里的 activate() 是异步的，配置成功可能赶在激活之前。
            // 这时推不出去 —— 不能静默，否则手表会一直停在旧账号上，
            // 而且没有任何线索。留一条日志，配合手表的「重新同步」可恢复。
            FileLogger.shared.warning(
                "手表同步：通道尚未激活，本次账号未推送（可在手表上点「重新同步」）",
                module: "手表")
            return
        }

        Self.configuredHint = (payload != nil)
        var context = session.applicationContext
        if let payload, let data = try? JSONEncoder().encode(payload) {
            context[CloudSyncKey.account] = data
            // 必达通道：手表 App 没跑也能补投
            session.transferUserInfo([CloudSyncKey.account: data])
        } else {
            context.removeValue(forKey: CloudSyncKey.account)
        }
        try? session.updateApplicationContext(context)

        // 不用 `payload!`：encode 失败也会走到 else 分支，虽然那时 payload 非 nil，
        // 但强解包让读者每次都得停下来推一遍"这里到底可不可能崩"。
        let desc = payload.map { "已推送账号（\($0.maskedPhone)）" } ?? "已清除账号"
        FileLogger.shared.info("手表同步：\(desc)", module: "手表")
    }

    /// 推送车况快照。只在**云端刷新成功**后调，避免把过期数据推过去。
    func pushSnapshot(_ payload: CloudSnapshotPayload?) {
        guard let session, session.activationState == .activated else { return }
        var context = session.applicationContext
        if let payload, let data = try? JSONEncoder().encode(payload) {
            context[CloudSyncKey.snapshot] = data
        } else {
            context.removeValue(forKey: CloudSyncKey.snapshot)
        }
        try? session.updateApplicationContext(context)
    }
}

// MARK: - WCSessionDelegate

extension PhoneWatchSync: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // 同 `sessionReachabilityDidChange`：先把需要的值取成 Sendable，再跳 MainActor
        let reachable = session.isReachable
        let stateValue = activationState.rawValue
        let message = error?.localizedDescription
        Task { @MainActor in
            self.isReachable = reachable
            if let message {
                FileLogger.shared.warning("手表同步激活失败：\(message)", module: "手表")
            } else {
                FileLogger.shared.info("手表同步已激活（state=\(stateValue)）", module: "手表")
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.isReachable = false }
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // 换表 / 重新配对后必须重新激活，否则通道永久失效
        session.activate()
        Task { @MainActor in self.isReachable = false }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        // `WCSession` 不是 Sendable，不能直接捕获进 Task；先取 Bool 再跳
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    /// 手表发来的即时消息。
    ///
    /// ## 两种消息
    ///
    /// | `cmd` | 手表想要什么 | 这里做什么 |
    /// |---|---|---|
    /// | 无 / 其它 | 问「现在配好了吗」 | 回一个 Bool |
    /// | `resync` | 账号丢了，请重推一次 | 回执 + **真的重推** |
    ///
    /// ## 为什么必须真的重推（2026-11-04 第二轮审查 S1）
    ///
    /// 上一版只回 `["configured": ...]`，**完全不看 message 内容**。于是手表那个
    /// 「重新同步」按钮点了之后什么都不会发生，而界面还写着"已请求 iPhone 重新同步" ——
    /// 手表唯一的恢复入口在撒谎。
    ///
    /// 会走到这里的典型场景：手表 App 是后装的（手机早就配好，不会再有新推送）、
    /// 手机在通道未激活时推过（那条被 `pushAccount` 的 guard 挡掉了）、手表重装或换表。
    ///
    /// `replyHandler` 不是 Sendable，不能带进 `Task`，所以先同步回执、
    /// 再异步补推 —— 回执只代表"请求已收到"，不代表账号已送达，
    /// 手表那边会用超时判断最终结果。
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let cmd = message["cmd"] as? String
        let wantResync = (cmd == "resync")

        replyHandler(["configured": Self.configuredHint,
                      "resyncAccepted": wantResync])

        guard wantResync else { return }
        Task { @MainActor in
            FileLogger.shared.info("手表请求重新同步账号 → 开始重推", module: "手表")
            AppModel.shared.syncAccountToWatch()
        }
    }
}
