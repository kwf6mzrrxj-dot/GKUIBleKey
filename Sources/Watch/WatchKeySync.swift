import Foundation
import WatchConnectivity

/// 手表侧的密钥通道：从 iPhone 取一次钥匙，写进手表的 Keychain。
///
/// 为什么需要它：手表读不到手机的 Keychain，`WatchConnectivity` 是唯一的通路。
/// 传输内容就是手机端「导出备份」的那段文本（`KeyStore.exportBackup()`），
/// 复用它避免再造一套序列化格式。
///
/// - 配对状态下的 WCSession 通道本身是加密的；
/// - 落库走手表的 Keychain（与手机同一套 `KeyStore` 实现）。
@MainActor
final class WatchKeySync: NSObject, ObservableObject {

    static let shared = WatchKeySync()

    private var onKeys: ((String) -> Void)?
    private var didActivate = false

    /// - Parameter onKeys: 收到备份文本时的回调（由控制器写库）
    func activate(onKeys: @escaping (String) -> Void) {
        self.onKeys = onKeys
        guard WCSession.isSupported(), !didActivate else { return }
        didActivate = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// 主动向 iPhone 要一次（用户点「同步钥匙」）
    func requestKeys() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        // 先看手机上次推送的上下文（不要求可达）
        apply(session.receivedApplicationContext)
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["cmd": "getKeys"], replyHandler: { [weak self] reply in
            guard let text = reply["keys"] as? String else { return }
            Task { @MainActor in self?.deliver(text) }
        }, errorHandler: { _ in })
    }

    private func apply(_ context: [String: Any]) {
        if let text = context["keys"] as? String { deliver(text) }
    }

    private func deliver(_ text: String) {
        guard !text.isEmpty else { return }
        onKeys?(text)
    }
}

extension WatchKeySync: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        // ★ 只把 Sendable 的 String 带进 MainActor。
        //   直接把 `[String: Any]` 丢进 Task 会触发 Swift 6 的
        //   "sending 'context' risks causing data races"。
        let text = session.receivedApplicationContext["keys"] as? String
        Task { @MainActor in
            if let text { self.deliver(text) }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let text = applicationContext["keys"] as? String
        Task { @MainActor in
            if let text { self.deliver(text) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let text = message["keys"] as? String else { return }
        Task { @MainActor in self.deliver(text) }
    }
}
