import Foundation
import WatchConnectivity

/// 手机侧：接手表发来的控车请求，交给 `AppModel` 执行，再把结果回给手表。
///
/// 为什么手表不自己连车：BLE 的绑定密钥（LTK / IRK）在 iPhone 的蓝牙控制器里，
/// 没有任何 API 能导出；「仿冒 iPhone」过不了链路加密这一关。所以手表只当遥控器 ——
/// 车端根本不认识手表，也就不需要二次配对，钥匙也不出手机。
final class WatchRemoteBridge: NSObject {

    /// 与 `KeyStore.shared` 同一套写法：`WCSessionDelegate` 的回调来自后台队列，
    /// 但本类只持有一个「是否已激活」的布尔，且只在主线程写。
    public nonisolated(unsafe) static let shared = WatchRemoteBridge()

    private var didActivate = false

    func activate() {
        guard WCSession.isSupported(), !didActivate else { return }
        didActivate = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// 回执可能要在 `Task` 里延后调用，包一层让它能跨 actor 传递
    private struct ReplyBox: @unchecked Sendable {
        let handler: ([String: Any]) -> Void
        func call(_ payload: [String: Any]) { handler(payload) }
    }

    /// 与手表约定的指令名（和 URL scheme 保持一致）
    private static func action(for name: String) -> IBCommandType? {
        switch name.lowercased() {
        case "lock":       return .lock
        case "unlock":     return .unlock
        case "trunk":      return .openCloseTrunk
        case "find":       return .panic
        case "windowup":   return .windowUp
        case "windowdown": return .windowDown
        default:           return nil
        }
    }

    @MainActor
    private static func statusPayload() -> [String: Any] {
        let model = AppModel.shared
        var payload: [String: Any] = [
            "online": model.isVehicleOnline,
            "text": model.statusLine,
        ]
        if let locked = model.measured.status?.isLocked {
            payload["locked"] = locked
        }
        return payload
    }
}

extension WatchRemoteBridge: WCSessionDelegate {

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 换表后必须重新激活，否则后续消息收不到
        session.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let cmd = message["cmd"] as? String else {
            replyHandler([:])
            return
        }
        let box = ReplyBox(handler: replyHandler)

        switch cmd {
        case "status":
            Task { @MainActor in
                box.call(WatchRemoteBridge.statusPayload())
            }

        case "perform":
            guard let raw = message["action"] as? String,
                  let action = WatchRemoteBridge.action(for: raw) else {
                box.call(["ok": false, "text": "无法识别的指令"])
                return
            }
            Task { @MainActor in
                let model = AppModel.shared
                let ok = await model.runIntentCommand(action, timeout: 10)
                box.call(["ok": ok, "text": model.watchResultText])
            }

        default:
            box.call(["ok": false, "text": "未知请求：\(cmd)"])
        }
    }
}
