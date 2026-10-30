import Foundation
import WatchConnectivity

/// 手机侧：把钥匙同步给配对的手表。
///
/// 只做两件事：
/// 1. 手表激活会话时，主动把当前钥匙推送过去（`updateApplicationContext`，不要求可达）
/// 2. 手表点「同步钥匙」时，回应一次 `getKeys`
///
/// 安全边界：
/// - 仅在 `isPaired && isWatchAppInstalled` 时推送，绝不广播给未配对设备
/// - 传输走系统加密通道；落库在手表自己的 Keychain
/// - 内容就是「导出备份」那段文本，与用户手动导出的是同一份数据
final class WatchKeySyncResponder: NSObject {

    /// 与 `KeyStore.shared` 同一套写法：`WCSessionDelegate` 的回调来自后台队列，
    /// 但本类只持有一个「是否已激活」的布尔，且只在主线程写，故显式声明为 unsafe。
    public nonisolated(unsafe) static let shared = WatchKeySyncResponder()

    private var didActivate = false

    func activate() {
        guard WCSession.isSupported(), !didActivate else { return }
        didActivate = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// 只在「配对 + 装了手表 App」时推送
    private func pushKeys(to session: WCSession) {
        guard session.isPaired, session.isWatchAppInstalled else { return }
        let text = KeyStore.shared.exportBackup()
        guard !text.isEmpty else { return }
        try? session.updateApplicationContext([
            "keys": text,
            "ts": Date().timeIntervalSince1970,
        ])
    }
}

extension WatchKeySyncResponder: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        pushKeys(to: session)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 换表后需要重新激活，否则后续消息都收不到
        session.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard message["cmd"] as? String == "getKeys" else {
            replyHandler([:])
            return
        }
        let text = KeyStore.shared.exportBackup()
        guard !text.isEmpty else {
            replyHandler(["error": "noKeys"])
            return
        }
        if session.isPaired, session.isWatchAppInstalled {
            try? session.updateApplicationContext(["keys": text])
        }
        replyHandler(["keys": text])
    }
}
