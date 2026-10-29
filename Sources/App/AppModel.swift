import Foundation
import Combine
import UIKit

/// 协调 BLE 链路与 InBlue 会话，并实现**可靠的重试/恢复策略**。
///
/// ## 与原 App 的差异（均为体验/安全增强，不改变协议行为）
/// 1. **不再 5 次封顶**：原 App `_kRetryTimes = 5`（`0x40de0`），用满即报
///    `40001 控车指令重发次数已满`，用户必须从头再来。这里改为带退避的持续重试。
/// 2. **失败自动重建会话**：对应原 SDK 的 `destorySession` + 重新
///    `initializationDK:`，而不是把失败抛给用户。
///
/// ## 2026-10-24 清理
/// 旧的「五步 DK 协议」（`FE 01` 帧、`DKSession`/`ExSession`/`DKTuning` 等 8 个文件、
/// 约 1400 行）已移除。它基于早期对 `GLBLEAuthSDK` 的假设，与实测链路
/// （`01/02/03`）无关，保留只会干扰判断。
@MainActor
public final class AppModel: ObservableObject {

    /// 全局唯一实例。
    ///
    /// ## 为什么必须单例
    ///
    /// App Intents（Siri / 快捷指令 / 操作按钮）在**后台**执行，UI 可能完全没加载，
    /// 拿不到 `@StateObject` 里那个实例。如果 Intent 自己 `AppModel()`，
    /// 就会出现**第二个 `CBCentralManager`**：两个中心同时扫同一台车、
    /// 抢同一个写特征，连接会互相打断（表现为「秒断」）。
    ///
    /// 所以整个 App 只允许一个 `AppModel`：UI 用 `@StateObject(wrappedValue: .shared)`，
    /// Intent 用 `AppModel.shared`，两者是同一个对象。
    public static let shared = AppModel()

    public let ble = BLECentral()
    /// InBlue 配对器（首次绑定用；日常认证走 `measured`）
    public let pairing = InBluePairing()

    /// ★ **点火位置验证判定器** —— 照 `IBVehicle` 的
    /// `checkRssiForPassiveStart` / `isInPassiveStartArea` 反汇编实现。
    @Published public var passiveStart = PassiveStartJudge()

    /// ★ 双天线 RSSI 缓存（标定采样用）—— 对应 `RSSIAntennaOne` / `RSSIAntennaTwo`。
    /// 广播回调时按 antenna 高 4 位分路，标定进行中时合成喂给 `passiveStart`。
    private var rssiAntennaOne: Double?
    private var rssiAntennaTwo: Double?

    /// ★ **无感进入（Passive Entry / PE）总开关** —— 对应
    /// `-[IBVehicle enablePassiveEntry]` @`0xa3d8` → `openConnexionForCommand:0x11`
    /// 与 `-[IBVehicle disablePassiveEntry]` @`0xa394` → `openConnexionForCommand:0x12`。
    ///
    /// ## 语义（Android 版文案 `settings_pe_tip` 实证）
    /// 「开启后，靠近车辆时可以通过**拉门把手**解锁」。
    /// 即这是车端 PEPS「**靠近自动解锁**」功能的开关 —— App 只负责把这个开关
    /// 发给车端，真正的解锁由车端 PEPS 在检测到钥匙靠近时完成
    /// （配合预认证保活 `0x0C`，见 `preAuth`）。
    ///
    /// ⚠️ 原 App 无任何「远离闭锁 / 离车自动落锁」文案与逻辑 —— 该方向
    /// 未经反汇编证实，本 App 不臆造。
    ///
    /// 状态持久化在 UserDefaults（按 cidpu 区分），非敏感配置、不占用 Keychain。
    @Published public private(set) var passiveEntryEnabled = false
    /// 正在切换无感进入开关（请求已发、等车端 04 回执）
    @Published public private(set) var passiveEntrySwitching = false

    /// ★ **当前唯一使用的会话状态机**：`01 → 02 → 03 → 04`（+ 车端推送 `05`）。
    public let measured = MeasuredSession()

    /// ★ **预认证保活** —— 见 `PreAuthenticationController` 的逐行反汇编说明。
    /// 原 App 在被动进入流程里只发 `0x0C`，**不会**自动发 unlock/lock。
    public let preAuth = PreAuthenticationController()

    @Published public var statusLine = "未连接"
    @Published public var isBusy = false
    /// 是否已提示过「RSSI 未标定」（只提示一次）
    private var didWarnUncalibrated = false

    // MARK: - ★ 实时日志浮窗

    /// 实时日志行（最近 200 行），供浮窗显示。由 `FileLogger` 回调驱动更新。
    @Published public private(set) var liveLogLines: [String] = []
    /// 实时日志浮窗是否开启（UserDefaults 持久化，开发者菜单可开关）。
    @Published public var liveLogFloatingEnabled = false {
        didSet {
            UserDefaults.standard.set(liveLogFloatingEnabled, forKey: "gkuiblekey.liveLogFloating")
            // ★ 驱动全局浮窗（独立 UIWindow，悬浮在所有界面之上）
            //   窗口操作必须在主线程，用 Task 切到 MainActor。
            let enabled = liveLogFloatingEnabled
            Task { @MainActor [weak self] in
                guard let self else { return }
                if enabled {
                    FloatingWindowController.shared.show(model: self)
                } else {
                    FloatingWindowController.shared.hide()
                }
            }
        }
    }
    private let liveLogCapacity = 200

    /// 只读监听模式：**只订阅、不发任何字节**。
    ///
    /// 用途：第一次接触车辆模块时，在**没有密钥、不做任何协议假设**的前提下验证
    /// BLE 层是否真的通了 —— 能不能发现设备、能不能连接、能不能发现
    /// `F000FF10` 服务与 `F000FF11/FF12` 特征、订阅后车端会不会主动下发数据。
    ///
    /// 这一步能把「链路问题」和「协议问题」彻底分开：
    /// - 链路都不通 → 先解决 BLE（UUID、广播名、配对）
    /// - 链路通、但车端不发数据 → 说明还缺鉴权，属正常
    /// - 链路通、车端主动发数据 → 这些字节就是最宝贵的协议线索
    @Published public var listenOnly = false

    // ── 防暴力破解（PEPS 强制要求：连续失败要锁定，避免被穷举）──────
    /// 连续鉴权失败次数
    @Published public private(set) var consecutiveAuthFailures = 0
    /// 达到该次数后进入锁定（与车端 PEPS 的锁定策略配合）
    public var maxAuthFailuresBeforeLock = 5
    /// 锁定剩余时间（秒）
    @Published public private(set) var lockoutRemaining: Int = 0
    public var lockoutDuration: TimeInterval = 60
    public var isLockedOut: Bool { lockoutRemaining > 0 }

    // ── 密钥完整性（启动时校验，防篡改）──────────────────────────
    /// 上次完整性校验结果
    @Published public private(set) var keyIntegrityOK: Bool?
    @Published public private(set) var keyIntegrityDetail = "未校验"

    public init() {
        // ★ 后台保活监控：记录进程启动 / 前后台切换 / 30 秒心跳。
        //   `App Intents` 后台冷启动时这里同样会跑，所以日志能区分
        //   「用户打开 App」和「系统为 Siri/快捷指令启动了进程」。
        BackgroundMonitor.shared.start()

        // ★ 前后台切换 → 写进「保活」日志，形成时间线。
        //
        // 用 `Task { @MainActor }` 而不是 `MainActor.assumeIsolated`：
        // NotificationCenter 的 Combine 投递线程虽通常是主线程，但没有 API 保证，
        // assumeIsolated 在非主线程会直接崩溃，这里只差几毫秒，不值得冒险。
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { _ in
                Task { @MainActor in BackgroundMonitor.shared.didEnterBackground() }
            }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { _ in
                Task { @MainActor in BackgroundMonitor.shared.willEnterForeground() }
            }
            .store(in: &cancellables)
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { _ in
                Task { @MainActor in BackgroundMonitor.shared.didBecomeActive() }
            }
            .store(in: &cancellables)

        // ★★★ 内置钥匙：首次启动写入 Keychain，然后重载
        //
        // `measured` 是属性初始化器，它的 `init()` 里已经读过一次 Keychain
        // （`MeasuredSession.init` → `loadKeysFromStore()`）。所以这里写入之后
        // 必须显式 `reloadKeys()`，否则 `measured.keys` 仍是旧值、
        // 主界面会继续显示「尚未绑定车辆」。
        //
        // 只在首次应用（`BuiltInKeys.applyIfNeeded` 带 UserDefaults 标记），
        // 之后自己配对成功的密钥不会被覆盖。
        if BuiltInKeys.applyIfNeeded() {
            measured.reloadKeys()
        }

        // ★★★ 关键：把子 ObservableObject 的 objectWillChange 转发到 AppModel 自身，
        //     否则所有 UI 都只 `@EnvironmentObject model`、没人 `@ObservedObject`
        //     直接观察子对象，导致 `measured.keys`/`measured.status`/`pairing.log` 等
        //     变化时界面**不刷新**。
        //    典型表现：配对成功、密钥已落 Keychain，但主页仍显示「尚未绑定车辆」。
        //    2026-10-25 修复。
        measured.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        // ★ 配对器（InBluePairing）也是 ObservableObject，转发以刷新配对页日志
        pairing.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        // ★ 预认证控制器同样转发（其 isEnabled 变化需驱动开发者菜单 Toggle）
        preAuth.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        ble.onFrame = { [weak self] bytes in
            self?.handleIncomingFrame(bytes)
        }
        // ★★★ 广播解密出的车辆状态明文 → 更新状态（照原 App parseBroadcastData:）。
        ble.onBroadcastStatus = { [weak self] plain in
            self?.measured.updateVehicleStatus(plain: plain)
        }
        // ★★★ 分路 RSSI → 标定流程（照 addRSSI: @0x801c：按 antenna 高4位分路存两路 RSSI）
        ble.onDualRSSI = { [weak self] antennaNo, rssi in
            self?.handleDualRSSI(antenna: antennaNo, rssi: rssi)
        }

        // ★★★ 实时日志浮窗：订阅 FileLogger 的新增行回调，刷新 liveLogLines。
        //     首次加载时读内存缓冲区的最近行，保证打开浮窗就有内容。
        liveLogFloatingEnabled = UserDefaults.standard.bool(forKey: "gkuiblekey.liveLogFloating")
        liveLogLines = FileLogger.shared.recentMemoryLines()
        FileLogger.shared.onNewLine = { [weak self] line in
            guard let self else { return }
            self.liveLogLines.append(line)
            if self.liveLogLines.count > self.liveLogCapacity {
                self.liveLogLines.removeFirst(self.liveLogLines.count - self.liveLogCapacity)
            }
        }
        // 启动时若开关已开，主动拉起浮窗（init 赋值不触发 didSet）
        if liveLogFloatingEnabled {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                FloatingWindowController.shared.show(model: self)
            }
        }

        // RSSI → 中继防护（周期性采样，检测突变）
        ble.$rssi
            .compactMap { (raw: Int?) -> Int? in raw }
            .sink { [weak self] (value: Int) in
                guard let self else { return }
                self.relayGuard.record(value)
                // ★ 点火位置验证：照原 App 的 checkRssiForPassiveStart
                //   原 App 用 RSSI1/RSSI2 两个天线值；这里 BLE 只给一个，
                //   先用同一个值填两路（待确认模块是否上报双路 RSSI）。
                let v = Double(value)
                _ = self.passiveStart.check(rssiOne: v, rssiTwo: v)
                // 未标定 → 只提示一次，避免日志刷屏
                if !self.passiveStart.isCalibrated, !self.didWarnUncalibrated {
                    self.didWarnUncalibrated = true
                    self.measured.recordNote(
                        "⚠️ RSSI 未标定（calibration/leaveOffset 缺失）：被动进入不会自动启动")
                }
                // ★ 把判定结果交给预认证控制器（对应 checkRssiForPassiveStart:
                //   的 launchPrehautentification / stopPreAuthentication 两条分支）
                self.preAuth.updateArea(self.passiveStart.isInPassiveStartArea)
            }
            .store(in: &cancellables)

        // ★ 预认证回调
        preAuth.onLog = { [weak self] line in
            self?.measured.recordNote(line)
        }
        preAuth.onSend = { [weak self] in
            // 预认证 = 一次完整 `01→02→03(0x0C)→04`
            self?.beginMeasuredAuth(asPreAuthentication: true)
        }

        // ★ 出范围（9 秒无数据）→ 复位预认证边沿。
        //   对应原 App `-[VCBDevice resetWithTimeout]` @`0x9fb4` →
        //   `deviceWhentOutOfRange` → `-[IBVehicle vehicleWentOutOfRange]` @`0xa800`。
        //   我们原先只在「断连」时复位，连着但走远的场景不会复位，
        //   导致回来不再触发一次被动进入。
        ble.onWentOutOfRange = { [weak self] in
            self?.preAuth.resetEdge()
            self?.measured.recordNote("出范围：已复位被动进入/预认证的边沿状态")
        }

        // ★ 链路就绪 → ① 配对流程在等则自动发 0x0D；② 有挂起的控车动作则自动执行
        ble.$linkState
            .filter { $0 == .ready }
            .sink { [weak self] _ in
                guard let self else { return }
                if self.pairingArmed {
                    self.appendPairingLog("链路已就绪，自动发配对登记帧（0x0D）")
                    self.beginMeasuredAuthPairing()
                    return
                }
                // ★ 用户点了按钮但当时未连接 → 这里补执行
                if let action = self.pendingActionAfterConnect {
                    self.pendingActionAfterConnect = nil
                    self.measured.recordNote("链路已就绪，自动执行「\(action.label)」")
                    self.perform(action)
                    return
                }
                // ★ 预认证在「未连接」时被挂起 → 这里补发。
                //
                // 不补这一步的话，预认证永远发不出去：它的触发点是"进入区域"，
                // 那时链路没连上，`beginMeasuredAuth` 的 `guard isWriteReady`
                // 会直接丢弃，之后没有任何地方会重试。
                if self.pendingPreAuth {
                    self.pendingPreAuth = false
                    self.measured.recordNote("链路已就绪，补发预认证（0x0C）")
                    self.beginMeasuredAuth(asPreAuthentication: true)
                }
            }
            .store(in: &cancellables)

        // ★ 断连/失败 → 复位预认证的边沿状态。
        //   否则"断开时在区域内"会残留 `wasInsideArea = true`，
        //   重连后一直停在区域内，不会再触发一次 launch。
        ble.$linkState
            .filter { $0 == .disconnected || $0 == .failed || $0 == .idle }
            .sink { [weak self] _ in
                self?.preAuth.resetEdge()
                // ★ 断连时复位无感进入切换状态：避免切换请求悬空后开关一直转圈
                self?.passiveEntrySwitching = false
                self?.pendingPassiveEntryValue = nil
            }
            .store(in: &cancellables)

        // ★★★ **蓝牙就绪即自动连接** —— 这是"打开 App 就自动连上"的关键。
        //
        // 不能只靠 SwiftUI 的 `onAppear`/`onChange`：冷启动时
        // `CBCentralManager` 的 state 还是 `.unknown`，此时 `startScan()`
        // 会被 guard 拒绝，自动连接就静默失败了。
        // 直接订阅 `managerState`，等它真正变成 `.poweredOn` 再动手。
        ble.$managerState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                guard state == .poweredOn else { return }
                // ★ 尽快动手：只等一拍（150ms）让系统把已连接外设表填好，
                //   不做长延时 —— 原 App 是"秒连"，靠的就是立刻走
                //   retrieveConnectedPeripherals / 已记住的 identifier。
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self.autoConnect()
                }
            }
            .store(in: &cancellables)

        // ★ 双保险：init 里也立刻试一次（context 已就绪时可能直接命中缓存）
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.autoConnect()
        }

        // 启动即做一次密钥完整性校验
        verifyKeyIntegrity()
        // 启动即读取车端标定值（`getCalibrationSavedValues` @0xb83c）
        loadCalibration()
        // 启动即读取无感进入开关状态（靠近车辆拉门把手解锁）
        loadPassiveEntryState()
    }

    /// 读取车端标定值 —— 照 `-[IBVehicle getCalibrationSavedValues]` @`0xb83c`。
    ///
    /// ```asm
    /// 0xb864: [NSUserDefaults standardUserDefaults]
    /// 0xb8c0: adr x2, #0x20a48 ; CFSTR "%@_CALIBRATION"
    /// 0xb8ec: objectForKey:
    /// 0xb90c: setCalibration:
    /// ```
    /// 写入点在 `-[IBVehicle didCalibrationCompleted:error:]` @`0xa41c`。
    ///
    /// 未标定时 `calibration = nil`，判定时按 `0` 处理
    /// （与原 App 的 `[nil intValue]` 等价）。
    public func loadCalibration() {
        guard let cidpu = KeyStore.shared.cidpuFullHex, !cidpu.isEmpty else {
            passiveStart.calibration = nil
            return
        }
        let key = "\(cidpu)_CALIBRATION"
        if let n = UserDefaults.standard.object(forKey: key) as? NSNumber {
            passiveStart.calibration = n.intValue
            measured.recordNote("已读取标定值 calibration=\(n.intValue)（key=\(key)）")
        } else {
            passiveStart.calibration = nil
        }
    }

    /// 读取无感进入开关状态（按 cidpu 区分）。
    ///
    /// 与标定值同一套路：`<cidpu>_PASSIVE_ENTRY` 存 UserDefaults。
    /// 未配对（无 cidpu）时读全局默认值，默认关闭。
    public func loadPassiveEntryState() {
        if let cidpu = KeyStore.shared.cidpuFullHex, !cidpu.isEmpty {
            passiveEntryEnabled = UserDefaults.standard.bool(forKey: "\(cidpu)_PASSIVE_ENTRY")
        } else {
            passiveEntryEnabled = UserDefaults.standard.bool(forKey: "gkuiblekey.passiveEntry.default")
        }
    }

    /// 切换无感进入（靠近车辆拉门把手解锁）总开关。
    ///
    /// 依据：`enablePassiveEntry`(0x11) / `disablePassiveEntry`(0x12) 都是
    /// `openConnexionForCommand:` 的一次完整鉴权链 `01→02→03(控制码)→04`。
    /// 成功后（收到 04 00）再落状态；失败保持原状并提示。
    public func setPassiveEntry(_ enabled: Bool) {
        guard !passiveEntrySwitching else {
            statusLine = "无感进入开关切换中，请稍候"
            return
        }
        guard !listenOnly else {
            statusLine = "只读监听模式：不会发送任何指令"
            return
        }
        guard !isLockedOut else {
            statusLine = "已锁定：\(lockoutRemaining)s 后可重试"
            return
        }
        guard ble.isWriteReady else {
            statusLine = "写特征未就绪，无法切换无感进入（需先连接车辆）"
            return
        }
        passiveEntrySwitching = true
        // 记录本次期望值，供 04 回执时确认是否切换成功
        pendingPassiveEntryValue = enabled
        perform(enabled ? .enablePassiveEntry : .disablePassiveEntry)
    }

    /// 期望的无感进入目标值（收到 04 回执后据此落状态）
    private var pendingPassiveEntryValue: Bool?

    /// 无感进入开关回执落状态：成功才翻转并持久化，失败保持原状。
    private func settlePassiveEntryToggle(_ result: MeasuredSession.ActionResult) {
        defer { passiveEntrySwitching = false }
        guard let target = pendingPassiveEntryValue else { return }
        pendingPassiveEntryValue = nil
        switch result {
        case .success:
            passiveEntryEnabled = target
            if let cidpu = KeyStore.shared.cidpuFullHex, !cidpu.isEmpty {
                UserDefaults.standard.set(target, forKey: "\(cidpu)_PASSIVE_ENTRY")
            } else {
                UserDefaults.standard.set(target, forKey: "gkuiblekey.passiveEntry.default")
            }
            measured.recordNote("无感进入已\(target ? "开启" : "关闭")（靠近车辆拉门把手解锁）")
            statusLine = target ? "已开启无感进入：靠近车辆拉门把手解锁" : "已关闭无感进入"
        case .refused(let code):
            statusLine = "切换无感进入失败（原 App 错误码 0x\(String(format: "%03X", code))）"
        case .acceptedAwaitingNames:
            // 不会发生（无感进入命令不走 0x0D）
            statusLine = "无感进入：已受理（异常分支）"
        case .paired:
            // 不会发生（配对成功不走无感切换）
            statusLine = "无感进入：配对完成（异常分支）"
        case .timedOut:
            statusLine = "切换无感进入超时（4s，code 690）"
        }
    }

    // MARK: - InBlue 配对（首次绑定）

    /// 发起配对：需要先有链路（BLE 已连上）。
    /// ★ **不用扫描的连接**：取系统已配对/已连接的车辆模块。
    ///
    /// 对应车主问的"被动匹配"：如果 iPhone 的「设置 → 蓝牙」里
    /// 已经有这台车，就不必扫描，直接连。
    public func connectSystemPaired() {
        let ok = ble.connectSystemPaired()
        statusLine = ble.lastMessage
        if !ok {
            statusLine += "（可改用「扫描」）"
        }
    }

    // MARK: - ★ 一键配对（真正的一步到底）

    /// 配对时将使用的手机名（供界面展示）
    public static var currentDeviceNameForPairing: String {
        InBluePairing.currentDeviceName()
    }

    private func appendPairingLog(_ s: String) {
        pairing.appendExternal("· \(s)")
    }

    /// 配对流程是否在等待链路就绪（就绪后自动发登记帧）
    @Published public var pairingArmed = false

    /// 非空表示这次配对**被主动阻止**（典型：本地已有密钥）。
    /// `PairingView` 用它弹说明，避免用户以为"点了没反应"。
    @Published public var pairingBlockedReason: String?

    /// **一键配对** —— 用户唯一需要做的操作。
    ///
    /// 内部自动串联（依据原 App 反汇编 `startPairing` @`0xa350`）：
    /// ```
    /// ① 若已连接 → 关旧连接重连（触发系统配对）
    /// ② 若未连接 → 扫描并连接
    /// ③ 链路一就绪 → 自动发配对登记帧 0x0D（由 linkState 订阅驱动）
    /// ④ 0x0D = 0D + sidpu(16B) + 设备名(20B)，车端直接回 0x0E 密钥（无挑战-响应）
    /// ⑤ 收到 0x0E → saveKeysData 落密钥 + 配对成功
    /// ```
    /// 依据原 App `generateFirstMessage:` @0xff98 里 `cmp #0x55 → generatePairingMessage`
    /// （配对发 0x0D 登记帧，普通命令才走 01 鉴权链），以及
    /// `+[IBMessageFactory pairingMessage]` @0x13afc 的 37 字节格式。
    ///
    /// ★ 系统配对框是 iOS 自动弹的（访问加密特征时要求输 6 位码），App 不参与。
    public func startFullPairing(force: Bool = false) {
        // ★★★ 本地已有密钥时**不发** 0x0D —— 这是原 App 的真实行为
        //
        // 日志实证（`Docs/evidence/xiaoka_gl.log`，9 次 requestPairing 全部 keys=0）：
        //
        // | 本地密钥 | 扫到广播时原 App 的反应 |
        // |---|---|
        // | `keys = 0` | `didFoundVehicleRequestPairing` → 停扫描 → 连接 → SMP 加密 → 发 `0x0D` |
        // | `keys = 1` | 只有 `didShowVehicle`（解析状态）→ **绝不发 `0x0D`** |
        //
        // 反汇编对应 `-[IBVehicleManager updateVehicleWithDevice:]` @`0xd220`：
        //
        // ```asm
        // 0xd300: initDevice:cidpu:      ; 内部 checkCryptedID: 校验广播归属
        // 0xd318: cbz x0, #0xd3b8        ; 不是本车 → 丢弃
        // 0xd320: isUnpairedDevice
        // 0xd32c: cbz w0, #0xd3b8        ; 已配对 → 丢弃（不创建未配对车辆）
        // 0xd368: initWithoutKey         ; 仅未配对时创建"无密钥车辆"
        // ```
        //
        // **这正是我们 2026-10-28 21:15 零响应的原因**：本地还留着上次失败的
        // 旧密钥 → 我们照样发 `0x0D` → 车端不接受重复登记 → 一个字节都不回
        // → 30 秒超时。
        if !force, measured.keys != nil {
            let reason = """
            本地已有这台车的密钥，配对未发起。

            原 App 在「本地有密钥」时从不发送配对登记帧（0x0D）——它只在 \
            「本地无密钥」时才把广播识别为「请求配对」。我们之前每次都发，\
            所以车端一直零响应。

            如果车端确实已经删掉这把钥匙（诊断仪清过槽位），请先到
            「开发者 → 密钥管理 → 解绑车辆」清除本地密钥，然后再配对。
            """
            pairingBlockedReason = reason
            statusLine = "⚠️ 本地已有密钥，已阻止重复配对（避免又一次零响应）"
            appendPairingLog("⚠️ 配对被阻止：本地已有密钥。原 App 在 keys=1 时不会发起配对。")
            return
        }
        pairingBlockedReason = nil
        pairing.resetForNewAttempt()
        pairingArmed = true

        // ★★★ 2026-10-25 修复「绑定页收不到配对、诊断页点扫描才收到」：
        // 之前按 `hasLink` 分叉（已连接→reconnect，否则→scan），
        // 但 `linkState` 可能停在 `.scanning`（App 启动 autoConnect 已扫过），
        // 或残留 `.connecting`，导致漏判、或 cancel 后立即扫的竞态，
        // 最终「扫描没真正跑起来 / 连接没触发」。
        //
        // 现在统一走「先停干净 → 再重新扫描」的确定性路径：
        //   1. 停止任何进行中的扫描/连接
        //   2. 复位连接相关状态
        //   3. 置 autoConnectWhilePairing 后重新 startScan
        // 保证绑定页一打开，扫描一定在跑、发现车端后一定自动连接触发配对。
        ble.stopScan()
        if let p = ble.currentPeripheral {
            ble.cancelConnection(p)
        }
        ble.prepareForPairingScan()
        statusLine = "配对中：扫描并连接车辆模块…"
        ble.autoConnectWhilePairing = true
        ble.startScan()
    }

    /// **自动连接** —— App 启动 / 蓝牙就绪 / 回到前台时调用。
    ///
    /// 只保留「扫描 → 发现 → 连接」这一条路径（原 App 也是这条）：
    /// ① 已在就绪/连接中 → 什么都不做
    /// ② 尝试接管已连接设备，失败则扫描
    ///
    /// ★★★ 另外：**本地无密钥时自动进入「配对等待」** —— 这是原 App 的默认行为。
    ///
    /// 原 App 没有「点绑定」这个动作：`keys = 0` 时扫到本车广播，
    /// 内部先由 `-[IBVehicleManager updateVehicleWithDevice:]` @`0xd220`
    /// 判定 `isUnpairedDevice`，再创建"无密钥车辆"并回调
    /// `manager:didFoundVehicleRequestPairing:`，然后**自动**停扫描、连接、发 `0x0D`。
    ///
    /// 日志逐条印证：9 次 `didFoundVehicleRequestPairing` **全部发生在 `keys = 0`**；
    /// `keys = 1` 时只有 `didShowVehicle`（解析状态），从不触发配对。
    ///
    /// 所以这里只要把 `pairingArmed` 置真即可 —— 连接仍由扫描回调里的
    /// 「归属校验通过（`hit`）」触发，不会误连别人的车。
    public func autoConnect() {
        guard ble.linkState != .ready,
              ble.linkState != .connecting,
              ble.linkState != .discovering else { return }
        // ★ 本地无密钥 = 原 App 的「未配对」状态 → 自动等配对
        if measured.keys == nil {
            if !pairingArmed {
                pairingArmed = true
                appendPairingLog(
                    "本地无密钥（keys=0）→ 自动进入配对等待："
                    + "扫到本车广播即连接并发 0x0D（对齐原 App 的 didFoundVehicleRequestPairing 路径）")
            }
            // 配对必须「主动连接」：v4.4 起扫描命中不再自动连（避免空连接
            // 被车端 2 秒踢掉），所以这里显式置位。
            ble.forceConnectOnce = true
        }
        ble.adoptConnectedPeripheral()      // 已连着就直接用（不 connect、不 cancel）
        if ble.linkState == .discovering || ble.linkState == .ready { return }
        statusLine = "扫描车辆模块…"
        ble.startScan()
    }

    /// 发起配对鉴权链（`01 → 02 → 03(0x55) → 0x0E`）。
    ///
    /// 对应原 App `startPairing` → `openConnexionForCommand:0x55` 之后的
    /// `formatCommand:toDevice:`：`cmp #0x55` 跳过 cidpu 检查 → `generateFirstMessage:`。
    /// 配对：链路就绪后发 **`0x0D` 登记帧**（不是 01 鉴权链）。
    ///
    /// 依据 `+[IBMessageFactory pairingMessage]` @0x13afc：
    /// `0x0D + sidpu(16B) + 设备名(20B)`，车端收到直接回 `0x0E` 密钥，
    /// **没有挑战-响应**（之前误实现成 01→02→03 鉴权链，导致自校验必失败）。
    private func beginMeasuredAuthPairing() {
        pairingArmed = false
        // ★ 照原 App `openConnexionForCommand:` 的第一道闸 `[device isValid]`：
        //   配对走的是同一条 `openConnexionForCommand:0x55`，同样先校验车辆有效性。
        //   注意 isValid 的 `key` 是 cidpu 派生的车辆对象、不是配对密钥，
        //   所以「还没配过」不影响这条校验通过（只要扫描到本车、cidpu 长度对）。
        guard measured.isVehicleValid else {
            let c = KeyStore.shared.cidpuFullHex ?? "(null)"
            statusLine = "车辆无效（Vehicle is not valid）：cidpu=\(c)"
            appendPairingLog("❌ 车辆无效（Vehicle is not valid）：cidpu=\(c) —— 原 App 此时不发帧")
            pairing.fail("车辆无效（cidpu=\(c)）")
            return
        }
        // ★ 配对也是「一轮新命令」：必须清零消息序号。
        //   否则若上一轮收过 0x0F（lastPacket=15），本次 0x0E（14）会被
        //   单调校验判为乱序 → 配对直接失败。
        measured.resetPacketCounter()
        let frame = pairing.buildPairingMessage()
        guard frame.count == InBluePairing.frameLength else {
            statusLine = "配对登记帧构造失败（\(frame.count)B）"
            pairing.fail("配对登记帧构造失败")
            return
        }
        guard ble.send(frame) else {
            statusLine = "配对登记帧写入失败"
            pairing.fail("配对登记帧写入失败（写特征未就绪）")
            return
        }
        statusLine = "已发配对登记帧 0x0D（\(frame.count)B），等待车端下发 0x0E 密钥…"
        // ★ 配对走 30 秒档（`cmp w21,#0x55` 分支的 `fmov d0,#30.0`）
        startCommandTimeout("配对登记帧 0x0D", seconds: AppModel.pairingTimeoutSeconds)
    }

    // MARK: - ★ 命令超时（照 `openConnexionForCommand:` @`0x4988`）

    /// ### 反汇编：两档超时，不是统一的 30 秒
    ///
    /// ```asm
    /// 0x4a84: cmp  w21, #0x55            ; command == 0x55（配对）
    /// 0x4a88: b.ne #0x4b0c               ; 不是配对 → 走 else
    /// 0x4a9c: fmov d0, #30.0             ; ★ 配对：30 秒
    /// ...
    /// 0x4b0c: (else)
    /// 0x4b28: ldr  x1, @selector(commandTimeout)
    /// 0x4b50: scheduledTimerWithTimeInterval:…   ; ★ 其他命令：IBManager.commandTimeout
    /// ```
    ///
    /// 而 `-[IBManager init]` @`0xed40` 里写死了这个默认值：
    ///
    /// ```asm
    /// 0xed40: ldrsw x8, #0x28084         ; _OBJC_IVAR_$_IBManager._commandTimeout
    /// 0xed44: mov   x9, #0x4010000000000000
    /// 0xed48: str   x9, [x19, x8]
    /// ```
    ///
    /// `0x4010000000000000` 是 IEEE-754 双精度的 **4.0**。
    ///
    /// ### 日志实证（Docs/evidence/xiaoka_gl.log）
    ///
    /// ```text
    /// 20:35:02.831  Stopping scan
    /// 20:35:06.919  Timeout to send command is reached     ← +4.088s
    /// 20:43:07.281  Stopping scan
    /// 20:43:11.375  Timeout to send command is reached     ← +4.094s
    /// ```
    ///
    /// 全日志 `Command failed. Code : 690` 共 **5 次**，全部约 4 秒；
    /// 只有配对（0x55）那次才走 30 秒。
    ///
    /// 超时走 `closeConnexionForCommand` @`0x62dc` 的 `didNeedReconnect == NO` 分支
    /// （反汇编确认全库无 `setDidNeedReconnect:YES`）：
    /// **只回报 `Timeout to send command is reached.`（code 690），不断开、不重连。**
    private var commandTimeoutTask: Task<Void, Never>?

    /// 普通命令超时（`IBManager.commandTimeout` 默认值）
    static let commandTimeoutSeconds: TimeInterval = 4.0

    /// 配对命令（`0x55`）超时
    static let pairingTimeoutSeconds: TimeInterval = 30.0

    private func startCommandTimeout(
        _ what: String,
        seconds: TimeInterval = AppModel.commandTimeoutSeconds
    ) {
        cancelCommandTimeout()
        commandTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.commandTimeoutTask = nil
            self.measured.commandTimedOut()
            self.statusLine = "❌ \(what) 超时（\(Int(seconds))s，code 690）"
            self.appendPairingLog("❌ 命令超时：Timeout to send command is reached. (code 690)")
        }
    }

    private func cancelCommandTimeout() {
        commandTimeoutTask?.cancel()
        commandTimeoutTask = nil
    }

    /// 配对完成后的收尾：重新扫描（对应原 App `callDidPairingSuccess` 末尾的
    /// `disconnect`，而 `disconnect` @0x6588 实为 `resetCommandTimeout` + `startScan`，
    /// **并不断开 BLE 连接**，只是重置命令并重新扫描，用新密钥识别本车）。
    ///
    /// 反汇编 @0x6588：`resetCommandTimeout → device(nil 判断) → startScan` 全程同步，
    /// **无延迟**。之前这里加了 0.5s 延迟是「断开重扫」的遗留，现去掉对齐原 App。
    private func finishPairingWithReconnect() {
        // ★ 用轻量复位：原 App `resetCommandTimeout` @`0x64f4` 只 invalidate 定时器，
        //   **不动**刚收到的密钥帧与车辆状态（M2）。
        measured.resetCommandOnly()
        // 立即重新扫描（对应 startScan，用新密钥识别本车，进入「已配对」状态）
        statusLine = "配对完成，正在重新扫描车辆…"
        ble.startScan()
    }
    /// 处理配对相关帧：`0x0D`（配对请求回显）与 **`0x0E`（密钥下发）**。
    ///
    /// `0x0E` 在这里记进配对日志，并转交 `MeasuredSession.handle`（对应原 App
    /// `analyzeMessage:` 的 `case 14` → `saveKeysData:`）落 Keychain。
    private func handlePairingFrame(_ bytes: [UInt8]) -> Bool {
        guard let (cmd, payload) = MeasuredFrame.decode(bytes) else { return false }

        switch cmd {
        case 0x0D:
            pairing.appendExternal("← 0x0D \(FrameCodec.hexString(bytes))")
            return true

        case 0x0E:
            // ★ 密钥帧：两件事都做 —— 记进配对日志 + 交给会话解析并落 Keychain
            pairing.acceptRawResponse(payload)
            _ = measured.handle(bytes)          // MeasuredSession 里会 saveKeyData()
            // ★ 配对后 cidpu 变了 → 重新读该车对应的标定值
            //   （`getCalibrationSavedValues` 用 "<cidpu>_CALIBRATION" 作 key）
            loadCalibration()
            statusLine = "收到车端密钥（\(payload.count)B）已保存，配对完成"
            // ★★★ 原 App 配对成功后 `callDidPairingSuccess` @0x6d6c 里会
            //     `disconnect` @0x6588（实为 `resetCommandTimeout` + `startScan`，
            //     **并不断开 BLE 连接**），用新密钥重新扫描识别本车。
            finishPairingWithReconnect()
            return true

        default:
            return false
        }
    }

    /// 向下兼容入口：只有设备名，没有 sidpu/cidpu 参数（原 App 也不需要）。
    // MARK: - 链路

    public func startScan() {
        statusLine = "扫描车辆模块…"
        ble.startScan()
    }

    public func disconnect() {
        ble.disconnect()
        measured.reset()
        statusLine = "已断开"
    }

    /// 解绑车辆（对应 `IBManager deleteVehicleWithCidpu:` → 本地清密钥 + 清标定）。
    ///
    /// 反汇编：`deleteVehicleWithCidpu:` 只做本地清理，**不发 BLE 命令**：
    /// `vehicleWithCidpu:` → `clearCalibrationData` + `deleteKeyWithCidpu:`。
    /// 本 App 单车辆槽位，清全部密钥即等于删除这辆车；同时清标定值并复位状态。
    public func deleteVehicle() {
        // 清标定值（对应 clearCalibrationData）
        if let cidpu = KeyStore.shared.cidpuFullHex, !cidpu.isEmpty {
            UserDefaults.standard.removeObject(forKey: "\(cidpu)_CALIBRATION")
        }
        UserDefaults.standard.removeObject(forKey: "gkuiblekey.calibration.default")
        UserDefaults.standard.removeObject(forKey: "gkuiblekey.passiveEntry.default")

        // 清密钥（对应 deleteKeyWithCidpu:）
        KeyStore.shared.clearAll()

        // 复位状态（解绑应回到「未绑定」的干净状态）
        ble.disconnect()
        ble.forgetRememberedPeripheral()      // 清记住的设备，避免解绑后误连旧车
        measured.reset()
        passiveStart.cancelCalibration()
        passiveStart.calibration = nil
        passiveEntryEnabled = false
        // ★ 复位各类悬挂状态，避免解绑后残留
        pairingArmed = false
        pendingAction = nil
        pendingPassiveEntryValue = nil
        passiveEntrySwitching = false
        didWarnUncalibrated = false
        consecutiveAuthFailures = 0
        lockoutRemaining = 0
        rssiAntennaOne = nil
        rssiAntennaTwo = nil
        statusLine = "已解绑车辆（密钥与标定已清除）"
        measured.recordNote("解绑：已清除密钥与标定值（照 deleteVehicleWithCidpu:）")
    }

    // MARK: - 中继防护

    /// 中继攻击防护（基于 RSSI 突变检测）
    public let relayGuard = RelayGuard()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 车控动作（统一入口）

    /// 当前正在执行的动作（供日志/界面显示）
    @Published public private(set) var pendingAction: IBCommandType?

    /// 用户点了按钮但当时链路未就绪 → 挂在这里，等 `.ready` 后自动执行。
    @Published public private(set) var pendingActionAfterConnect: IBCommandType?

    /// 预认证「等链路就绪再发」的挂起标志。
    ///
    /// ## 为什么必须有它
    ///
    /// 预认证的触发时机是「进入被动启动区域」（`preAuth.onSend`），
    /// 那一刻链路通常**还没连上**。而 `beginMeasuredAuth` 开头有
    /// `guard ble.isWriteReady`，未就绪就直接 return —— 于是这一轮预认证
    /// 被**静默丢弃**，等链路就绪后也没有人再触发它。
    ///
    /// 实测后果（2026-10-29 日志）：
    /// - 预认证从"进入区域"到"离开区域"一次 `0x0C` 都没发出去
    /// - 车端因此始终不认为"钥匙在场" → **点火不了**、拉门把手不解锁
    ///
    /// 现在改成：未就绪时置位并主动连接，`.ready` 回调里补发。
    private var pendingPreAuth = false

    /// ★ **所有车控动作的唯一入口**。
    ///
    /// 链路：`01`（连接确认）→ `02`（挑战）→ `03`（动作 + 控制码）→ `04`（结果）。
    /// 原 App 就是这样——**没有单独的"控车帧"**，`03` 末尾那个字节既是鉴权响应
    /// 也是动作码（`responseMessageWithData:` 里 `command` 直接进 `03`）。
    ///
    /// 11 个命令的全部控制码都来自 `-[IBVehicle xxx]` 里的 `mov w2, #N` 立即数，
    /// 见 `IBCommandType` 的逐条注释 —— **没有"未确认所以拒发"的动作了**。
    public func perform(_ action: IBCommandType) {
        guard !listenOnly else {
            statusLine = "只读监听模式：不会发送任何指令"
            return
        }
        // ★ 防爆破锁定：此前只记录 `lockoutRemaining` 却没有拦截，
        //   等于锁定形同虚设。这里在唯一入口处硬拦截。
        guard !isLockedOut else {
            statusLine = "已锁定：连续失败 \(consecutiveAuthFailures) 次，\(lockoutRemaining)s 后可重试"
            return
        }
        guard ble.isWriteReady else {
            // ★ 未连接时不再只是弹提示 —— 记住动作、强制连一次，链路就绪后自动执行。
            //
            // 背景：v3.1 加了「扫描常开」，v3.3 又加了「断开后 15 秒内不自动重连」
            // 的冷却（防止「连→断→扫→连」死循环）。两者叠加会导致：车端刚断开、
            // 用户马上点按钮时链路还没就绪，原来是直接拒绝，体验很差。
            // 现在改成「挂起重试」。
            pendingActionAfterConnect = action
            ble.forceConnectOnce = true          // 无视冷却，扫到就立刻连
            // ★ 优先「直接连已知设备」——不等扫描广播，省掉 1–2 秒
            //   （车端每条命令执行完就断开，靠扫描等广播会很慢）
            if !ble.connectRemembered() {
                let st = ble.linkState
                if st != .scanning && st != .connecting && st != .discovering {
                    ble.startScan()
                }
            }
            statusLine = "未连接，正在连接车辆，就绪后自动执行「\(action.label)」…"
            measured.recordNote("未连接（\(ble.linkState)）→ 连接后自动执行「\(action.label)」")
            return
        }
        pendingAction = action
        beginMeasuredAuth(action: action)
    }

    /// 重新计算「点火位置验证」—— 纯本地 RSSI 判定，**不发送任何帧**。
    ///
    /// 对应 `-[IBVehicle checkRssiForPassiveStart]` @`0xac04`：
    /// 用最近若干次 RSSI 采样的接近偏移做差比较（见 `PassiveStartJudge`），
    /// 结果只决定「是否允许触发被动启动」，与本 App 是否发命令无关。
    public func refreshPassiveStartVerdict() {
        statusLine = "点火位置验证（本地 RSSI）：\(passiveStart.summary)"
    }

    // MARK: - ★ 标定流程（照 VCBDevice startCalibration / calibrationWithRSSIOne:RSSITwo:）

    /// 分路 RSSI 处理 —— 对应 `addRSSI:` @`0x801c`。
    ///
    /// 广播回调时，按 antenna 高 4 位（0x80=天线1/0x40=天线2）把本次 RSSI
    /// 分路存进 `rssiAntennaOne` / `rssiAntennaTwo`；标定进行中时，两路都齐
    /// 就合成一次采样喂给 `passiveStart.addCalibrationSample`。
    private func handleDualRSSI(antenna: Int, rssi: Int) {
        let v = Double(rssi)
        switch antenna {
        case 1: rssiAntennaOne = v
        case 2: rssiAntennaTwo = v
        default: return
        }

        // 标定进行中 → 两路都齐则采样一次
        guard passiveStart.isCalibrating,
              let one = rssiAntennaOne, let two = rssiAntennaTwo else { return }

        if let avg = passiveStart.addCalibrationSample(rssiOne: one, rssiTwo: two) {
            finishCalibration(value: avg)
        }
    }

    /// 开始标定 —— 对应 `IBVehicle.startCalibration` @`0xa28c` →
    /// `openConnexionForCommand:0x0D`（触发车端进入标定/持续广播）。
    ///
    /// 之后 App 进入标定模式，靠广播回调按 antenna 分路采集 90 次 RSSI，
    /// 算均值写入 `calibration`（见 `handleDualRSSI`）。
    public func startCalibration() {
        guard ble.isWriteReady else {
            statusLine = "写特征未就绪，无法开始标定（需先连接车辆）"
            return
        }
        guard !passiveStart.isCalibrating else {
            statusLine = "标定已在进行中"
            return
        }
        rssiAntennaOne = nil
        rssiAntennaTwo = nil
        passiveStart.startCalibration()
        statusLine = "标定开始：触发 0x0D 后采集 90 次双天线 RSSI…"
        measured.recordNote("标定开始（照 startCalibration → openConnexionForCommand:0x0D）")
        // 触发车端进入标定模式（0x0D 与「查设备名」同码）
        perform(.requestPairedDevices)
    }

    /// 取消标定。
    public func cancelCalibration() {
        passiveStart.cancelCalibration()
        statusLine = "已取消标定"
    }

    /// 标定完成 → 写 `NSUserDefaults["<cidpu>_CALIBRATION"]`（照 didCalibrationCompleted:）。
    private func finishCalibration(value: Int) {
        if let cidpu = KeyStore.shared.cidpuFullHex, !cidpu.isEmpty {
            UserDefaults.standard.set(value, forKey: "\(cidpu)_CALIBRATION")
        } else {
            UserDefaults.standard.set(value, forKey: "gkuiblekey.calibration.default")
        }
        measured.recordNote("✅ 标定完成：calibration=\(value)，已写入 <cidpu>_CALIBRATION")
        statusLine = "标定完成：calibration=\(value)，点火位置验证已可用"
    }

    /// 查询车端「已配对手机名册」。
    ///
    /// 依据：`-[IBVehicle requestPairedDevicesNames]` @`0xa30c`
    /// → `openConnexionForCommand:0x0D` → 走 `01/02/03` 流程，
    /// `03` 帧末尾的控制码就是 `0x0D`；车端回 `0x0F`（设备名列表）。
    ///
    /// `0x04` 只表示「受理」，真正结果在 `0x0F`
    /// （`checkResultMessage:` 对 `command == 0x0D` 特判：直接 return，不等 04 判成功）。
    public func requestPairedDeviceNames() {
        perform(.requestPairedDevices)
    }

    // MARK: - 下行

    private func handleIncomingFrame(_ bytes: [UInt8]) {
        // ★ 收到任何下行帧 → 取消 30s 命令超时（命令已得到回应）
        cancelCommandTimeout()
        // ★★ 实测协议优先：首字节就是命令号

        // 配对帧（0x0D / 0x0E）先交给配对流程
        if handlePairingFrame(bytes) { return }

        // 0x01–0x05 是鉴权链；0x0F 是「已配对设备名」回执 ——
        // 少了 0x0F 的话，`requestPairedDevicesNames()` 发出去后回执会被
        // 下面的"未知帧"分支吞掉，功能永远不闭环。
        if let (cmd, _) = MeasuredFrame.decode(bytes),
           (0x01...0x05).contains(cmd) || cmd == 0x0F {
            if let next = measured.handle(bytes) {
                // 收到 02 后自动回 03 —— 事件驱动，不用等固定延时
                if ble.send(next) {
                    statusLine = "已自动回复鉴权3，等待结果"
                } else {
                    statusLine = "鉴权3 写入失败（写特征未就绪）"
                }
            } else {
                    // ★ 04 结果码 → 成功/失败分流（原 App `checkResultMessage:` 三种结局）
                if cmd == 0x04, let result = measured.lastResult {
                    // 预认证往返结束 → 交给控制器排下一次（6.5s / 29.0s）
                    // 依据：`didPassiveStartCompletedWithError:` @0xb6cc
                    let isPreAuth = (measured.pendingAction == nil)
                    switch result {
                    case .success:
                        recordAuthSuccess()
                        statusLine = isPreAuth
                            ? "✅ 钥匙已被车内认可，可踩刹车按启动按钮（6.5s 后自动续发）"
                            : "「\(measured.lastSucceededAction?.label ?? "动作")」执行成功（04 00）"
                    case .acceptedAwaitingNames:
                        statusLine = "已受理，等待车端回 0x0F 设备名"
                    case .refused(let code):
                        // 失败码：记入防爆破计数（原 App 无此逻辑，属安全增强）
                        // lastStatusCode 保留车端 04 结果字节，这里 code 是原 App 错误码
                        recordAuthFailure("原 App 错误码 0x\(String(format: "%03X", code))")
                    case .paired:
                        statusLine = "✅ 配对成功"
                    case .timedOut:
                        statusLine = "❌ 命令超时（4s，code 690）"
                    }
                    // ★ Siri / 快捷指令在等结果 → 交出（`resolveIntent` 幂等，
                    //   没有 Intent 在等时是空操作）
                    switch result {
                    case .success, .paired, .acceptedAwaitingNames:
                        resolveIntent(true)
                    case .refused, .timedOut:
                        resolveIntent(false)
                    }
                    // ★ 无感进入开关回执：用 pendingPassiveEntryValue 判断是否在切换，
                    //   成功则落状态，失败/拒绝也复位 switching（避免开关一直转圈）。
                    if pendingPassiveEntryValue != nil {
                        settlePassiveEntryToggle(result)
                    }
                    if isPreAuth {
                        // 不区分成功/失败：反汇编 `0xb7d4` 的 `cbz x20` 是 self 判空，
                        // 不是 error 分支；实测节奏 30 秒（见 `didComplete()` 说明）。
                        preAuth.didComplete()
                    }
                    return
                }
                // ★ 0x0F 设备名回执：解析已在 MeasuredSession 里完成，
                //   这里只负责把结果报给用户（否则状态行会被下面的通用文案覆盖）。
                if cmd == 0x0F {
                    statusLine = measured.pairedDeviceNames.isEmpty
                        ? "0x0F 已收到，但未解析出设备名"
                        : "车端已配对手机：\(measured.pairedDeviceNames.joined(separator: ", "))"
                    return
                }
                statusLine = "鉴权：\(measured.phase.rawValue)"
                if let code = measured.lastStatusCode {
                    statusLine += code == 0x00 ? "（成功）" : "（失败码 \(String(format: "%02X", code))）"
                }
                // ★ 03 自校验失败 → 原 App 的 0x278，重试无用，必须重新配对
                if measured.challengeVerified == false {
                    recordAuthFailure(ProtocolErrorCode.wrongChallenge.message)
                }
            }
            return
        }

        // 既不是配对帧、也不是 01..05 —— 记录原始字节即可（不臆测含义）
        statusLine = "收到未知帧：\(bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))…"
    }

    // MARK: - ★ 实测协议的鉴权入口

    /// 发起一次实测协议的鉴权（`01 → 02 → 03 → 04`）。
    ///
    /// 与旧握手的区别：**不需要固定延时**，02 到达后由 `handleIncomingFrame`
    /// 自动回复 03 —— 完全事件驱动，这正是解决"多次才能打着火"的思路。
    ///
    /// - Parameter action: 本次要执行的动作。`nil` 表示沿用会话里已设的控制码。
    /// - Parameter asPreAuthentication: 为 `true` 时强制走 `0x0C` 预认证，
    ///   **不会**沿用上一次的控车动作（否则定时预认证会误发锁/解锁）。
    public func beginMeasuredAuth(action: IBCommandType? = nil,
                                  asPreAuthentication: Bool = false) {
        guard ble.isWriteReady else {
            if asPreAuthentication {
                // ★★ 预认证**不能丢**：它的触发时机（刚进入被动启动区域）
                //    几乎必然早于链路建立。原来的 `return` 等于把这一轮预认证
                //    悄无声息地扔掉，之后没有任何地方会重试 —— 表现为
                //    「预认证一直没发出去 → 车端不认为钥匙在场 → 点火不了」。
                pendingPreAuth = true
                ble.forceConnectOnce = true
                if ble.connectRemembered() {
                    statusLine = "预认证待发：正在连接车辆…"
                    measured.recordNote("预认证挂起（链路未就绪）→ 直接连已知设备，就绪后补发")
                } else {
                    ble.startScan()
                    statusLine = "预认证待发：扫描车辆模块…"
                    measured.recordNote("预认证挂起（链路未就绪且无已知设备）→ 开始扫描")
                }
            } else {
                statusLine = "写特征未就绪，无法发起鉴权"
            }
            return
        }
        // ★ 防爆破：预认证与手动动作都要走同一道闸
        guard !isLockedOut else {
            statusLine = "已锁定：\(lockoutRemaining)s 后可重试"
            return
        }
        // ★ 密钥完整性：校验明确失败时不再发帧（此前只提示、不拦截）
        guard keyIntegrityOK != false else {
            statusLine = "密钥完整性校验未通过：\(keyIntegrityDetail)"
            return
        }
        let target = action ?? pendingAction
        // ★ 原 App `formatCommand:toDevice:` @`0xfb48` 只做 `setIsValidVehicle:0`
        //   （会话重置），**不清**已落库的密钥/车辆状态 —— 故用轻量复位（M2），
        //   并清零消息序号，让本轮 01→02→04 的单调校验从 0 开始（H2）。
        measured.resetCommandOnly()
        measured.resetPacketCounter()
        // ★ 每次鉴权前从 Keychain 重载 —— 配对刚写入的密钥能立刻用上
        measured.reloadKeys()
        if asPreAuthentication {
            measured.preparePreAuthentication()
        } else if let target {
            measured.perform(target)
        }
        let frame = measured.buildAuth1()
        guard !frame.isEmpty else {
            statusLine = "鉴权1 构造失败：缺少密钥材料（需先配对拿到 0E 密钥）"
            return
        }
        guard ble.send(frame) else {
            statusLine = "鉴权1 写入失败"
            return
        }
        statusLine = "已发鉴权1（\(frame.count)B），等待车端 02 挑战…"
        // ★ 普通命令走 4 秒档（`IBManager.commandTimeout` = 4.0，@0xed44）。
        //   原 App 日志实证：Stopping scan → Timeout 之间恒为 4.09 秒。
        startCommandTimeout("鉴权1")
    }

    // MARK: - 密钥完整性校验（启动时 / 手动触发）

    /// 校验必需密钥是否存在、长度是否合理，并与记录的指纹比对以检测篡改。
    public func verifyKeyIntegrity() {
        let store = KeyStore.shared
        var problems: [String] = []

        let comm = store.communicationKey
        if comm == nil {
            problems.append("缺少 communicationKey（尚未配对或未导入）")
        } else if let c = comm, c.count < 16 {
            problems.append("communicationKey 长度异常（\(c.count) 字节）")
        }

        // 指纹比对：首次记录，之后比对
        if let c = comm, !c.isEmpty {
            let fp = CryptoBox.sha256(c).map { String(format: "%02x", $0) }.joined()
            if let saved = store.getString(.integrityFingerprint) {
                if saved != fp {
                    problems.append("communicationKey 指纹变化（本地密钥可能被篡改）")
                }
            } else {
                store.setString(fp, for: .integrityFingerprint)
            }
        }

        keyIntegrityOK = problems.isEmpty
        keyIntegrityDetail = problems.isEmpty ? "通过（密钥存在且指纹一致）" : problems.joined(separator: "；")
        statusLine = "密钥校验：\(keyIntegrityDetail)"
    }

    // MARK: - 防暴力破解

    /// 记录一次鉴权失败；达阈值进入锁定。
    public func recordAuthFailure(_ reason: String) {
        consecutiveAuthFailures += 1
        if consecutiveAuthFailures >= maxAuthFailuresBeforeLock {
            startLockout()
        }
        statusLine = "鉴权失败（\(consecutiveAuthFailures)/\(maxAuthFailuresBeforeLock)）：\(reason)"
    }

    // MARK: - ★ App Intents（Siri / 快捷指令 / 操作按钮）

    /// 等待中的 Intent 回调。
    ///
    /// 一次只允许一条命令在飞：BLE 链路是单通道，两个 `0x01` 撞在一起
    /// 会让车端的序号/挑战状态错乱。
    private var intentContinuation: CheckedContinuation<Bool, Never>?

    /// 供 App Intent 使用：发一条控车命令并**等待结果**。
    ///
    /// - Returns: `true` = 收到 `04 00`（车端确认执行）
    ///
    /// 超时兜底 12 秒：正常流程里车端 4 秒命令超时会先触发，走不到这里；
    /// 但如果蓝牙不可用 / 车不在范围，`perform` 会一直等连接，
    /// 不能让 Siri 无限挂住。
    public func runIntentCommand(_ action: IBCommandType,
                                 timeout: TimeInterval = 12) async -> Bool {
        guard intentContinuation == nil else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            intentContinuation = cont
            perform(action)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.resolveIntent(false)
            }
        }
    }

    /// 结束 Intent 等待。幂等：已经 resume 过就直接返回。
    private func resolveIntent(_ ok: Bool) {
        guard let cont = intentContinuation else { return }
        intentContinuation = nil
        cont.resume(returning: ok)
    }

    public func recordAuthSuccess() {
        consecutiveAuthFailures = 0
        statusLine = "鉴权成功"
    }

    private func startLockout() {
        lockoutRemaining = Int(lockoutDuration)
        statusLine = "连续失败达 \(maxAuthFailuresBeforeLock) 次，已锁定 \(lockoutRemaining)s（防暴力破解）"
        Task { [weak self] in
            guard let self else { return }
            while self.lockoutRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.lockoutRemaining -= 1
            }
            self.consecutiveAuthFailures = 0
            self.statusLine = "锁定已解除，可重新尝试"
        }
    }
}
