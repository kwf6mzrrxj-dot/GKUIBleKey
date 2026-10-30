import Combine
import Foundation
import WatchConnectivity

/// 手表能发起的三个动作。
///
/// 刻意不复用手机端的 `IBCommandType`（它在 `Sources/Protocol` 里）——
/// 手表只做遥控，不需要把整条协议栈编进来。名字与手机端 URL scheme 对齐，
/// 两边靠字符串通信，编译期不耦合。
enum WatchAction {
    case lock
    case unlock
    case find

    /// 与手机端 `handleExternalURL` 的 host 保持一致
    var wireName: String {
        switch self {
        case .lock:   return "lock"
        case .unlock: return "unlock"
        case .find:   return "find"
        }
    }

    var title: String {
        switch self {
        case .lock:   return "闭锁"
        case .unlock: return "解锁"
        case .find:   return "寻车"
        }
    }
}

/// 手表端控车控制器 —— **完全不碰 BLE**，只当 iPhone 的遥控器。
///
/// ## 为什么是遥控而不是自己连车
///
/// BLE 的绑定密钥（LTK / IRK）在 iPhone 的蓝牙控制器里，没有任何 API 能导出，
/// 手表也拿不到；「仿冒 iPhone」在链路加密这一关就过不去。
/// 所以手表只发一条消息给 iPhone，由 iPhone 用**它自己的绑定**去发帧 ——
/// 车端根本不认识手表，也就不需要二次配对，钥匙也不出手机。
///
/// 代价：iPhone 必须在附近、且 App 能被唤起。因此这里**不排队命令** ——
/// 手表的锁车指令如果延迟两分钟才执行，比失败更危险。
@MainActor
final class WatchRemoteController: NSObject, ObservableObject {

    @Published private(set) var statusLine = "正在连接 iPhone…"
    @Published private(set) var busy = false
    @Published private(set) var isLocked: Bool?
    @Published private(set) var online = false
    @Published private(set) var reachable = false

    private var didActivate = false

    // MARK: - 生命周期

    func bootstrap() {
        guard WCSession.isSupported() else {
            statusLine = "此设备不支持与 iPhone 通信"
            return
        }
        let session = WCSession.default
        session.delegate = self
        if !didActivate {
            didActivate = true
            session.activate()
        }
        refreshStatus()
    }

    /// 向 iPhone 要一次当前状态（在线 / 车锁）
    func refreshStatus() {
        send(["cmd": "status"]) { [weak self] reply in
            let locked = reply["locked"] as? Bool
            let online = reply["online"] as? Bool ?? false
            let text = reply["text"] as? String ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.isLocked = locked
                self.online = online
                if !text.isEmpty { self.statusLine = text }
            }
        } failure: { [weak self] message in
            Task { @MainActor in self?.statusLine = message }
        }
    }

    // MARK: - 控车

    func perform(_ action: WatchAction) {
        guard !busy else { return }
        busy = true
        statusLine = "正在发送「\(action.title)」…"
        send(["cmd": "perform", "action": action.wireName]) { [weak self] reply in
            let ok = reply["ok"] as? Bool ?? false
            let text = reply["text"] as? String ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.statusLine = text.isEmpty ? (ok ? "已执行" : "未执行") : text
                self.refreshStatus()
            }
        } failure: { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.statusLine = message
            }
        }
    }

    // MARK: - 传输

    private func send(
        _ message: [String: Any],
        reply: @escaping ([String: Any]) -> Void,
        failure: @escaping (String) -> Void
    ) {
        guard WCSession.isSupported() else { failure("不支持与 iPhone 通信"); return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            failure("iPhone 通道尚未就绪，请稍候再试")
            return
        }
        // ★ 不可达时直接失败，**不排队**：
        //   一条「解锁」如果十分钟后才执行，比没执行更糟。
        guard session.isReachable else {
            failure("iPhone 不在附近，或 App 未运行")
            return
        }
        session.sendMessage(message, replyHandler: { dict in
            reply(dict)
        }, errorHandler: { _ in
            failure("发送失败，请再试一次")
        })
    }
}

extension WatchRemoteController: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let activated = (activationState == .activated)
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if activated {
                self.statusLine = "已连接 iPhone"
                self.refreshStatus()
            } else {
                self.statusLine = "无法连接 iPhone：请在手机上打开一次 App"
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.reachable = reachable
            if reachable {
                self.statusLine = "iPhone 已连接"
                self.refreshStatus()
            } else {
                self.statusLine = "iPhone 不在附近，或 App 未运行"
            }
        }
    }
}
