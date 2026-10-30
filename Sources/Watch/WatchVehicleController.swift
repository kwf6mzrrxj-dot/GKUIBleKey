import Combine
import Foundation

/// 手表端的控车控制器。
///
/// 刻意做成**手机端 `AppModel` 的最小闭环**：只保留
/// 「扫描 → 连接 → 01/02/03/04 → 结果」这一条路，不碰配对、预认证、无感进入、锁屏卡片。
///
/// 协议实现全部复用：
/// - `BLECentral`：扫描 / 连接 / 分包写入 / 广播解密
/// - `MeasuredSession`：`01 → 02 → 03 → 04` 状态机与消息序号
/// - `KeyStore`：Keychain（密钥由 iPhone 通过 WatchConnectivity 同步一次）
@MainActor
public final class WatchVehicleController: ObservableObject {

    public let ble = BLECentral()
    public let measured = MeasuredSession()

    /// 底部那一行状态文字
    @Published public private(set) var statusLine = "待机"
    /// 是否正在等车端回应（按钮转圈）
    @Published public private(set) var busy = false
    /// 本地有没有可用密钥（没有就提示先同步）
    @Published public private(set) var hasKeys = false
    /// 车锁状态（来自广播解密，可能是 nil）
    public var isLocked: Bool? { measured.status?.isLocked }

    /// 点按钮时链路还没就绪 → 记住，等 `.ready` 后自动补发
    private var pendingAction: IBCommandType?
    private var timeoutTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        ble.onFrame = { [weak self] bytes in
            self?.handleIncoming(bytes)
        }
        ble.onBroadcastStatus = { [weak self] plain in
            self?.measured.updateVehicleStatus(plain: plain)
        }
        // 链路就绪 → 如果刚才点过按钮，补发
        ble.$linkState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                guard state == .ready, let action = self.pendingAction else { return }
                self.pendingAction = nil
                self.start(action)
            }
            .store(in: &cancellables)
        refreshKeyState()
    }

    // MARK: - 生命周期

    /// 页面出现时调用：开扫描 + 激活与 iPhone 的密钥通道。
    public func bootstrap() {
        ble.startScan()
        WatchKeySync.shared.activate { [weak self] text in
            self?.importKeys(text)
        }
    }

    /// 收到 iPhone 发来的备份文本 → 写入手表 Keychain。
    public func importKeys(_ text: String) {
        let n = KeyStore.shared.importBackup(text)
        measured.reloadKeys()
        refreshKeyState()
        statusLine = n > 0 ? "已从 iPhone 同步 \(n) 项密钥" : "密钥同步失败：内容无法识别"
    }

    /// 主动向 iPhone 要一次钥匙（用户点「同步钥匙」）
    public func requestKeysFromPhone() {
        statusLine = "正在向 iPhone 请求钥匙…"
        WatchKeySync.shared.requestKeys()
    }

    private func refreshKeyState() {
        hasKeys = measured.keys != nil
            || KeyStore.shared.communicationKey?.isEmpty == false
    }

    // MARK: - 控车

    public func perform(_ action: IBCommandType) {
        guard hasKeys else {
            statusLine = "没有钥匙：先在 iPhone 上绑定，再同步到手表"
            return
        }
        guard !busy else { return }
        guard ble.isWriteReady else {
            pendingAction = action
            statusLine = "正在连接车辆…"
            if !ble.connectRemembered() { ble.startScan() }
            return
        }
        start(action)
    }

    private func start(_ action: IBCommandType) {
        busy = true
        // 与手机端同一套：轻量复位 + 序号归零，否则车端会判乱序
        measured.resetCommandOnly()
        measured.resetPacketCounter()
        measured.reloadKeys()
        measured.perform(action)

        let frame = measured.buildAuth1()
        guard !frame.isEmpty else {
            busy = false
            statusLine = "鉴权帧构造失败（密钥不完整）"
            return
        }
        guard ble.send(frame) else {
            busy = false
            statusLine = "写入失败：链路刚断开，请再点一次"
            return
        }
        statusLine = "已发鉴权，等待车端挑战…"
        armTimeout()
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        guard let (cmd, _) = MeasuredFrame.decode(bytes) else { return }
        // `handle` 返回需要自动回给车端的帧（收到 02 → 03）
        if let next = measured.handle(bytes) {
            _ = ble.send(next)
        }
        if cmd == 0x04 {
            finish()
        }
    }

    private func finish() {
        timeoutTask?.cancel()
        timeoutTask = nil
        busy = false
        switch measured.lastResult {
        case .success:
            statusLine = "「\(measured.lastSucceededAction?.label ?? "动作")」成功"
        case .refused(let code):
            statusLine = "车端拒绝（0x\(String(format: "%03X", code))）"
        case .timedOut:
            statusLine = "超时：车端没有回应"
        case .paired:
            statusLine = "配对完成"
        case .acceptedAwaitingNames:
            statusLine = "已受理"
        case .none:
            statusLine = "已完成"
        }
    }

    /// 4 秒超时 —— 与手机端 `IBManager.commandTimeout` 一致
    private func armTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.measured.commandTimedOut()
            self.busy = false
            self.statusLine = "超时（4 秒无回应），可再试一次"
        }
    }
}
