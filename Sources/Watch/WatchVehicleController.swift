import Combine
import Foundation

/// 手表端控制器 —— **手表自己连车**，不是手机的遥控器。
///
/// ## 为什么手表可以自己连
///
/// 之前的结论是「BLE 绑定密钥（LTK/IRK）导不出来，手表仿冒不了 iPhone」——
/// 那只说明**不能复用手机的绑定**，不代表手表不能有自己的绑定。
/// 车端一车可挂 **5 台**设备（`Docs/DEPLOY_TO_IPHONE.md`），正确做法是让手表
/// 自己走一遍诊断仪流程：`诊断仪开窗口 → 6 位码 → 0x0D → 0x0E`，
/// 拿到属于**这个槽位**的密钥（`Docs/INBLUE_PROTOCOL_SPEC.md` 5.10）。
///
/// ## 协议栈全部复用
///
/// - `BLECentral`：扫描 / 连接 / 分包写入 / 广播解密
/// - `MeasuredSession`：`01 → 02 → 03 → 04` 状态机、消息序号、`0x0E` 落库
/// - `InBluePairing`：`0x0D` 登记帧（37B）
/// - `KeyStore`：手表的 Keychain（**手表自己那份密钥，不从手机拷**）
///
/// ## 刻意不做的三件事
///
/// 1. **预认证心跳 `0x0C`**：手表不做无感进入，29 秒一轮的心跳纯耗电；
/// 2. **常开扫描**：`ble.autoScanOnDisconnect = false`，只在用户操作时扫；
/// 3. **密钥同步**：不从 iPhone 拷密钥。5.10 明确写了「拷过去能不能过车端
///    校验取决于密钥是否与槽位绑定 —— 未验证」，而且拷过来还会**覆盖**手表
///    自己那份槽位密钥，把一条能用的路堵死。
@MainActor
public final class WatchVehicleController: ObservableObject {

    // MARK: - 配对阶段

    /// 配对走到哪一步。UI 只用它决定显示什么，不参与协议判断。
    public enum PairingStage: Equatable {
        /// 没有在配对
        case idle
        /// 正在扫描 / 连接（等链路就绪）
        case scanning
        /// `0x0D` 已发出，等车端 `0x0E`
        case waitingKey
        /// 收到 `0x0E` 且密钥已落库
        case succeeded
        /// 失败（带原因）
        case failed(String)

        /// 配对进行中 —— 这期间不许控件车，否则 `01` 会和 `0x0D` 抢同一条链路
        var isRunning: Bool {
            switch self {
            case .scanning, .waitingKey: return true
            case .idle, .succeeded, .failed: return false
            }
        }
    }

    // MARK: - 依赖

    public let ble = BLECentral()
    public let measured = MeasuredSession()
    public let pairing = InBluePairing()

    // MARK: - 界面状态

    /// 底部那一行状态文字
    @Published public private(set) var statusLine = "待机"
    /// 是否正在等车端回应（按钮转圈）
    @Published public private(set) var busy = false
    /// 本地有没有可用密钥（没有就只能去配对）
    @Published public private(set) var hasKeys = false
    /// 配对阶段
    @Published public private(set) var stage: PairingStage = .idle
    /// 配对倒计时（"剩 27 秒"）；非配对时为 nil
    @Published public private(set) var countdown: String?
    /// 配对页展示的最近几行日志（`InBluePairing.log` 是全量的，手表屏幕放不下）
    @Published public private(set) var pairingLog: [String] = []

    /// 车锁状态（来自广播解密，可能是 nil）。
    ///
    /// ★ 带 **120 秒过期窗口**：这个值只在扫到广播时更新，而手表是**按需扫描**
    /// （操作完 5 秒就停），所以内存里那份可能是几分钟前的。
    /// 把过期值当「现在」显示，用户会看到「已闭锁」而车门其实是开的 ——
    /// 对一把钥匙来说，这比「状态未知」糟得多。
    ///
    /// 手机端同样是 120 秒口径（`DiagnosticsView` 的 `statusUpdatedAt` 标注）。
    public var isLocked: Bool? {
        guard let updated = measured.statusUpdatedAt,
              Date().timeIntervalSince(updated) <= Self.statusFreshSeconds else {
            return nil
        }
        return measured.status?.isLocked
    }

    /// 车锁状态的保鲜期（秒）
    private static let statusFreshSeconds: TimeInterval = 120

    // MARK: - 内部

    /// 链路还没就绪时用户点了按钮 → 记住，等 `.ready` 后自动补发
    private var pendingAction: IBCommandType?
    /// 控车超时（4 秒，与 `IBManager.commandTimeout` 一致）
    private var actionTimeoutTask: Task<Void, Never>?
    /// 「连接 + 发现服务」看门狗（用户点了按钮但链路一直不就绪）
    private var connectWatchdogTask: Task<Void, Never>?
    /// 配对超时（扫描 60 秒 / 等 `0x0E` 30 秒）
    private var pairingTimeoutTask: Task<Void, Never>?
    /// 倒计时刷新
    private var countdownTask: Task<Void, Never>?
    /// 「操作完再扫几秒」—— 用来让车端广播把车锁状态刷新过来
    private var scanStopTask: Task<Void, Never>?
    /// 配对截止时间（用于倒计时）
    private var deadline: Date?
    private var cancellables = Set<AnyCancellable>()

    /// 配对扫描窗口时长。
    ///
    /// 为什么是 60 秒：诊断仪开窗后用户要点「开始配对」、手表要扫到车、
    /// 还要连接 + 订阅（首次配对时系统会弹 6 位码输入，链路会停在
    /// `.discovering` 5–15 秒）。30 秒在真机上不够。
    private static let scanWindowSeconds: TimeInterval = 60.0

    /// `0x0E` 超时 —— 与手机端 `AppModel.pairingTimeoutSeconds` 同源
    /// （反汇编 `cmp w21,#0x55` 分支的 `fmov d0,#30.0`）。
    private static let keyWaitSeconds: TimeInterval = 30.0

    /// 控车超时（`IBManager.commandTimeout` 默认值 4.0）
    private static let actionTimeoutSeconds: TimeInterval = 4.0

    /// 点按钮后等链路就绪的上限
    private static let connectWatchdogSeconds: TimeInterval = 15.0

    public init() {
        // 手表按需扫描：断连后不自动续扫（手机端保持常开，见 BLECentral 注释）
        ble.autoScanOnDisconnect = false

        ble.onFrame = { [weak self] bytes in
            self?.handleIncoming(bytes)
        }
        ble.onBroadcastStatus = { [weak self] plain in
            self?.measured.updateVehicleStatus(plain: plain)
        }
        // 链路就绪 → 补发挂起的动作 / 发配对帧
        ble.$linkState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                guard state == .ready else { return }
                self.connectWatchdogTask?.cancel()
                self.connectWatchdogTask = nil
                // 配对优先：正在配对时不控件车
                if self.stage == .scanning {
                    self.sendPairingFrame()
                    return
                }
                guard let action = self.pendingAction else { return }
                self.pendingAction = nil
                self.start(action)
            }
            .store(in: &cancellables)

        refreshKeyState()
    }

    // MARK: - 生命周期

    /// 界面出现时调用。**不自动开扫描** —— 手表省电，等用户真的要用再扫。
    public func bootstrap() {
        refreshKeyState()
        if hasKeys {
            statusLine = "就绪"
        } else {
            statusLine = "手表还没有钥匙，先配对"
        }
    }

    /// 界面消失时收尾：停扫描、断链路、取消所有权计时器。
    ///
    /// 手表 App 一旦退到后台就会被系统挂起，留着扫描/连接只会让下一次
    /// 唤起拿到一条「看起来连着、其实已经死了」的链路（`isWriteReady`
    /// 为真但写不出去 —— 手机端踩过这个坑，见 v6.1）。
    public func teardown() {
        cancelPairingSilently()
        // ★ 配对阶段必须复位（2026-10-30 审查修复）。
        //   原来这里只取消计时器、不改 `stage`，于是「配对中被手腕放下打断」
        //   会留下 `stage == .scanning`：再抬手 `beginPairing()` 被
        //   `guard !stage.isRunning` 直接拦住 —— 界面明明没在扫，用户却
        //   再也点不了「开始配对」，只能杀 App。
        if stage.isRunning {
            stage = .idle
        }
        pendingAction = nil
        busy = false
        actionTimeoutTask?.cancel()
        actionTimeoutTask = nil
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        scanStopTask?.cancel()
        scanStopTask = nil
        ble.disconnect()
        ble.stopScan()
    }

    private func refreshKeyState() {
        // 与手机端 `AppModel.hasLocalKey` 同一套判定：内存 + Keychain 双查。
        // `measured.keys` 是内存缓存，解绑后若没刷干净会误判「已配对」。
        hasKeys = measured.keys != nil
            || KeyStore.shared.communicationKey?.isEmpty == false
    }

    // MARK: - 配对（0x0D → 0x0E）

    /// 开始配对。调用方必须已经让诊断仪打开配对窗口（或者正在打开）。
    public func beginPairing() {
        guard ble.isBluetoothReady else {
            stage = .failed("蓝牙未就绪")
            statusLine = "蓝牙未就绪，请检查手表蓝牙开关"
            return
        }
        guard !hasKeys else {
            // 车端不接受重复登记（手机端同样的教训：本地有密钥时发 0x0D 会零响应）。
            stage = .failed("手表上已有钥匙")
            statusLine = "已有钥匙：要重新配对，先解绑这辆车"
            return
        }
        guard !stage.isRunning else { return }

        // ★ 清掉可能挂着的控车请求（2026-10-30 审查修复）。
        //   场景：用户点了「解锁」但链路没就绪（`pendingAction` 挂着），
        //   接着去配对。配对成功后再扫到广播时 `.ready` 回调会把那个
        //   **几分钟前的解锁**补发出去 —— 用户根本没想再开一次。
        pendingAction = nil
        busy = false
        actionTimeoutTask?.cancel()
        actionTimeoutTask = nil
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        scanStopTask?.cancel()
        scanStopTask = nil

        pairing.resetForNewAttempt()
        pairingLog = []
        appendPairing("开始配对：扫描并连接车辆…")

        // 与手机端 `startFullPairing` 同一条确定性路径：
        // 先停干净 → 复位连接状态 → 置配对窗口 → 再扫。
        ble.stopScan()
        if let p = ble.currentPeripheral {
            ble.cancelConnection(p)
        }
        ble.prepareForPairingScan()
        setPairingWindow(true)
        stage = .scanning
        statusLine = "正在扫描车辆…"
        appendPairing("诊断仪窗口开着吗？没有窗口车端不会回 0x0E。")

        deadline = Date().addingTimeInterval(Self.scanWindowSeconds)
        startCountdown()
        armPairingTimeout(Self.scanWindowSeconds) { [weak self] in
            self?.failPairing("扫描超时（60 秒没连上车辆）")
        }
        ble.startScan()
    }

    /// 用户主动取消配对 / 页面关闭时调用。
    public func cancelPairing() {
        guard stage.isRunning else { return }
        appendPairing("已取消本次配对")
        cancelPairingSilently()
        stage = .idle
        statusLine = hasKeys ? "就绪" : "已取消配对"
    }

    /// 不写日志的收尾（`teardown` 用）
    private func cancelPairingSilently() {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        deadline = nil
        countdown = nil
        setPairingWindow(false)
        if case .scanning = stage {
            ble.stopScan()
        } else if case .waitingKey = stage {
            ble.stopScan()
        }
    }

    /// 配对窗口 = 「允许无条件连扫到的下一台 Valeo 设备」。
    ///
    /// 平时绝不能开（会连错车，见 v6.8 的 `hit` 判定修复），
    /// 所以配对一结束就必须在**所有**出口复位。
    private func setPairingWindow(_ on: Bool) {
        ble.autoConnectWhilePairing = on
        ble.pairingMode = on
    }

    /// 链路就绪 → 发 `0x0D`。
    ///
    /// 依据 `+[IBMessageFactory pairingMessage]` @`0x13afc`：
    /// `0D + sidpu(16B 固定常量) + 设备名(20B 零填充)`，共 37 字节；
    /// 车端收到直接回 `0x0E`，**没有挑战-响应**。
    private func sendPairingFrame() {
        guard stage == .scanning else { return }

        // 照原 App `openConnexionForCommand:` 的第一道闸 `[device isValid]`：
        // cidpu 必须是 32 个 hex 字符，否则原 App 一帧都不发。
        guard measured.isVehicleValid else {
            failPairing("车辆标识无效（cidpu 未识别）")
            return
        }
        // ★ 配对也是「一轮新命令」：必须清零消息序号。
        //   否则上一轮收过 0x0F（15）时，本次 0x0E（14）会被单调校验判乱序。
        measured.resetPacketCounter()

        let frame = pairing.buildPairingMessage()
        guard frame.count == InBluePairing.frameLength else {
            failPairing("配对帧构造失败（\(frame.count) 字节，应为 37）")
            return
        }
        guard ble.send(frame) else {
            failPairing("配对帧写入失败（写特征未就绪）")
            return
        }

        stage = .waitingKey
        statusLine = "已发配对请求，等车端下发密钥…"
        appendPairing("已发 0x0D（\(frame.count) 字节），等 0x0E")
        deadline = Date().addingTimeInterval(Self.keyWaitSeconds)
        armPairingTimeout(Self.keyWaitSeconds) { [weak self] in
            self?.failPairing("等密钥超时（30 秒）")
        }
    }

    /// 收到 `0x0E` 并且真的落库了 —— 才算配对成功。
    private func finishPairingOK(payload: [UInt8]) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        deadline = nil
        countdown = nil
        setPairingWindow(false)

        refreshKeyState()
        guard hasKeys else {
            // `measured.handle` 报了 `.paired` 但 Keychain 里读不出来 ——
            // 不能报成功（手机端踩过「帧长不符也报成功」的坑）。
            stage = .failed("密钥未写入 Keychain")
            statusLine = "❌ 密钥没能保存，请重试"
            appendPairing("❌ 0x0E 解析成功但 Keychain 里读不到密钥")
            return
        }

        stage = .succeeded
        statusLine = "配对完成（\(payload.count) 字节密钥）"
        appendPairing("✅ 配对成功，密钥已写入手表 Keychain")

        // ★★ 必须主动断开 —— 这是车端判定「配对完成」的收尾信号。
        //
        // 依据：`Docs/CHANGELOG.md` v1.5 的现场结论（收到 0x0E 就停住不断开，
        // 车端一直等 → 诊断仪超时判「配对失败」），以及 5.10 第 5 条。
        // 反汇编 `-[IBDevice disconnect]` @0x6588 虽然只做 `resetCommandTimeout
        // + startScan`（不断 BLE），但车端在 `0x0E` 之后本身就会断开；
        // 这里主动断只是把那一刻提前，不改变时序语义。
        //
        // `disconnect()` 会置 `suppressAutoReconnect`，所以断连回调**不会**
        // 触发重扫 —— 手表按需扫描，正是我们要的。
        ble.disconnect()
        // 但配对时起的扫描还在跑。留 3 秒收几条广播（界面立刻有车锁状态），
        // 然后回到静止。
        scheduleStopScan(after: 3)
    }

    private func failPairing(_ reason: String) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        deadline = nil
        countdown = nil
        setPairingWindow(false)
        ble.stopScan()
        // ★ 失败也要断链（2026-10-30 审查修复）。
        //   配对超时/写失败时链路可能还连着，而车端**不接受空闲连接**
        //   （0.5–1.5 秒后自己踢掉）。留一条"即将被踢"的链路，用户紧接着
        //   点控车会命中 `isWriteReady == true`，把 01 发进一条死链路，
        //   白等 4 秒超时。
        ble.disconnect()

        stage = .failed(reason)
        statusLine = reason
        appendPairing("❌ \(reason)")
        pairing.fail(reason)
    }

    private func armPairingTimeout(_ seconds: TimeInterval, _ onFire: @escaping () -> Void) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return          // 被取消
            }
            guard !Task.isCancelled else { return }
            onFire()
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let d = self.deadline {
                    let left = Int(d.timeIntervalSinceNow.rounded(.up))
                    self.countdown = left > 0 ? "剩 \(left) 秒" : "已超时"
                } else {
                    self.countdown = nil
                }
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func appendPairing(_ line: String) {
        let ts = Self.clock.string(from: Date())
        pairingLog.append("[\(ts)] \(line)")
        if pairingLog.count > 6 { pairingLog.removeFirst(pairingLog.count - 6) }
        FileLogger.shared.info("[手表配对] \(line)", module: "配对")
    }

    // MARK: - 解绑

    /// 解绑这辆车：清 Keychain + 内存副本 + 链路缓存。
    ///
    /// 手表端必须能解绑，否则「配错了 / 想在别的车上用」就彻底卡死 ——
    /// 而且配对会被 `hasKeys` 拦住。
    public func unbind() {
        cancelPairingSilently()
        pendingAction = nil
        busy = false
        actionTimeoutTask?.cancel()
        actionTimeoutTask = nil
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        scanStopTask?.cancel()
        scanStopTask = nil

        ble.disconnect()
        ble.stopScan()
        ble.forgetRememberedPeripheral()

        // 顺序与手机端 `deleteVehicle()` 一致：先 Keychain，再内存副本
        KeyStore.shared.clearAll()
        measured.forgetKeys()
        measured.reset()
        pairing.resetForNewAttempt()

        refreshKeyState()
        stage = .idle
        statusLine = "已解绑，可以重新配对"
    }

    // MARK: - 控车

    public func perform(_ action: IBCommandType) {
        guard hasKeys else {
            statusLine = "手表还没有钥匙：先去配对"
            return
        }
        guard ble.isBluetoothReady else {
            statusLine = "蓝牙未就绪（手表设置里检查一下）"
            return
        }
        guard !busy else { return }
        // 配对进行中不许控件车：`0x0D` 和 `01` 会抢同一条链路
        guard !stage.isRunning else {
            statusLine = "正在配对，先别控车"
            return
        }
        // 能不能发字节只看真实 GATT 链路（`isWriteReady`），
        // 不是「车辆在线」那个 60 秒窗口 —— 两者不可互换。
        guard ble.isWriteReady else {
            pendingAction = action
            busy = true
            statusLine = "正在连接车辆…"
            scanStopTask?.cancel()
            scanStopTask = nil
            armConnectWatchdog()
            if !ble.connectRemembered() {
                ble.startScan()
            }
            return
        }
        start(action)
    }

    private func start(_ action: IBCommandType) {
        connectWatchdogTask?.cancel()
        connectWatchdogTask = nil
        busy = true
        // 与手机端同一套：轻量复位 + 序号归零，否则车端判乱序
        measured.resetCommandOnly()
        measured.resetPacketCounter()
        measured.reloadKeys()
        measured.perform(action)

        let frame = measured.buildAuth1()
        guard !frame.isEmpty else {
            busy = false
            statusLine = "鉴权帧构造失败（密钥不完整）"
            scheduleStopScan(after: 1)
            return
        }
        guard ble.send(frame) else {
            busy = false
            statusLine = "写入失败：链路刚断开，请再点一次"
            scheduleStopScan(after: 1)
            return
        }
        statusLine = "已发鉴权，等待车端挑战…"
        armActionTimeout()
    }

    private func handleIncoming(_ bytes: [UInt8]) {
        guard let (cmd, payload) = MeasuredFrame.decode(bytes) else { return }

        // ★ `0x0D` 必须在这里拦掉：`MeasuredSession.handle` 的 switch 没有它，
        //   落进 default 会被判「Invalid Message type」并把本轮标成 refused ——
        //   手机端 `handlePairingFrame` 就是同样的顺序（先拦 0x0D）。
        if cmd == 0x0D {
            appendPairing("← 0x0D 回显 \(FrameCodec.hexString(bytes))")
            return
        }

        // ★ `0x0E` 只在配对等待态才接受。
        //   非配对态收到密钥帧说明状态机不同步（或链路串了别人的会话），
        //   此时绝不能交给 `MeasuredSession` —— 它会直接覆盖 Keychain 里
        //   那把正在用的钥匙。
        if cmd == 0x0E {
            guard stage == .waitingKey else {
                appendPairing("⚠️ 非配对状态收到 0x0E（\(payload.count)B），已忽略")
                return
            }
            pairing.acceptRawResponse(payload)
            measured.handle(bytes)
            guard measured.lastResult == .paired else {
                failPairing("密钥帧无法解析（\(payload.count) 字节）")
                return
            }
            finishPairingOK(payload: payload)
            return
        }

        // 控车路径
        //
        // ★ 只有「鉴权链的实质响应」才撤销超时（与手机端 `handleIncomingFrame`
        //   同一口径）：`05` 是车端周期性状态帧，它一来就撤表的话，
        //   命令没回应也永远不会报超时，界面一直挂着。
        guard (0x01...0x05).contains(cmd) || cmd == 0x0F else {
            _ = measured.handle(bytes)      // 其它帧只记录
            return
        }
        if cmd != 0x05 {
            actionTimeoutTask?.cancel()
            actionTimeoutTask = nil
        }
        if let next = measured.handle(bytes) {
            // 收到 02 → 自动回 03
            if ble.send(next) {
                statusLine = "已自动回复鉴权3，等待结果"
                // ★ 03 发出后**必须重新起表**（与手机端一致）。
                //   4 秒只覆盖「01 → 第一帧」；02 一到就被取消，
                //   若不重起，车端收下 03 却不回 04 时本轮就再没有任何计时器，
                //   `busy` 与 `pendingAction` 永久悬挂，只能杀 App。
                armActionTimeout()
            } else {
                // ★ 写失败必须让用户看见（不能 `_ =` 丢掉返回值）：
                //   链路在 02 和 03 之间断掉是真实会发生的（车端 1.5 秒即断）。
                busy = false
                pendingAction = nil
                statusLine = "鉴权3 写入失败（链路已断），请再点一次"
                scheduleStopScan(after: 1)
            }
            return
        }
        if cmd == 0x04 {
            finishAction()
        }
    }

    private func finishAction() {
        actionTimeoutTask?.cancel()
        actionTimeoutTask = nil
        busy = false
        pendingAction = nil
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
        // 手表按需扫描，但**不能立刻停**：车锁状态来自广播解密，
        // 操作刚结束时手上那份还是操作前的。多扫 5 秒让广播把新状态带回来，
        // 否则用户解锁成功、屏幕还显示「已闭锁」。
        scheduleStopScan(after: 5)
    }

    /// 延时停扫 —— 留一段时间收广播，之后按需扫描模式回到静止。
    private func scheduleStopScan(after seconds: TimeInterval) {
        scanStopTask?.cancel()
        scanStopTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            guard !self.busy, !self.stage.isRunning else { return }
            self.ble.stopScan()
        }
    }

    /// 4 秒超时 —— 与手机端 `IBManager.commandTimeout` 一致。
    private func armActionTimeout() {
        actionTimeoutTask?.cancel()
        actionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.actionTimeoutSeconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            self.measured.commandTimedOut()
            self.busy = false
            self.statusLine = "超时（4 秒无回应），可再试一次"
            self.ble.stopScan()
        }
    }

    /// 点了按钮但链路一直没就绪 —— 不能永远转圈。
    ///
    /// 手机端 v6.1 的三层死锁就是这么来的：`connectRemembered()` 对僵尸态返回
    /// `true` 却什么都不做，界面永久停在「正在连接车辆…」。
    private func armConnectWatchdog() {
        connectWatchdogTask?.cancel()
        connectWatchdogTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.connectWatchdogSeconds * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            guard !self.ble.isWriteReady else { return }
            self.pendingAction = nil
            self.busy = false
            self.statusLine = "连接超时：车不在附近，或蓝牙被占用"
            self.ble.resetLinkAndRescan()
            self.ble.stopScan()
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
