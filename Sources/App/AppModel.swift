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

    @Published public var statusLine = "待机"
    /// 是否已提示过「RSSI 未标定」（只提示一次）
    private var didWarnUncalibrated = false

    // MARK: - ★ 车辆在线（语义化状态）

    /// 顶栏该回答的问题是「车在不在」，不是「GATT 握到第几步」。
    ///
    /// ## 为什么改（2026-10-30）
    ///
    /// 原 App 26 天日志里实测：**343 段连接，中位 0.596 秒**，两次断开间隔中位
    /// **30.0 秒** —— 链路实际占空比只有 2%，它从来没"一直保持连接"。
    /// 但它界面上不显示链路状态，所以用户感觉"一直是连着的"。
    ///
    /// 而我们原来把 `linkState` 直接画在顶栏，于是每 29 秒就闪一次
    /// 「已连接 → 未连接 → 扫描中」，看起来像"不稳定"，实际两者一模一样。
    ///
    /// 现在顶栏只说「车辆在线 / 离线」，判定依据是**最近一次收到车端信号**的时间；
    /// 扫描中/握手/已连接这些原始状态全部留在诊断页。
    ///
    /// 窗口取 **60 秒**（两个心跳周期）：漏掉一轮心跳不会立刻变灰，
    /// 但真的走远了（RSSI 收不到广播 + 没有帧）两轮之后就会显示离线。
    public static let vehicleOnlineWindow: TimeInterval = 60

    /// 最近一次「确认车在附近」的时刻：收到本车广播 / 收到车端任意帧 / 命令成功。
    @Published public private(set) var lastVehicleContactAt: Date?

    /// 只用于让「在线」随时间自然过期 —— SwiftUI 不会因为 `Date()` 推进而重绘。
    @Published private var onlineTick = Date()
    private var onlineTickTask: Task<Void, Never>?
    /// 上一次同步给锁屏卡片的在线状态（只在翻转时刷新，避免每帧都推一次活动）
    private var lastKnownOnline = false

    /// 车在不在（顶栏用）
    public var isVehicleOnline: Bool {
        _ = onlineTick          // 读取它，让视图随 tick 重算
        // 没绑定也没在配对 → 没有"你的车"可在线。
        // 少了这一条，解绑瞬间 `linkState` 还是 `.ready`（断开是异步的），
        // 顶栏会替一辆已经解绑的车闪一下「车辆在线」。
        guard hasLocalKey || pairingArmed else { return false }
        // 链路就绪是最强的「车在」证据 —— 刚连上时可能还没收到广播，
        // 只看 `lastVehicleContactAt` 会短暂显示离线（回前台首帧尤其明显）。
        if ble.linkState == .ready { return true }
        guard let t = lastVehicleContactAt else { return false }
        return onlineTick.timeIntervalSince(t) < Self.vehicleOnlineWindow
    }

    /// 最近一次联络距今的描述（诊断页用）
    public var lastContactText: String {
        guard let t = lastVehicleContactAt else { return "从未" }
        let s = Int(Date().timeIntervalSince(t))
        if s < 1 { return "刚刚" }
        if s < 60 { return "\(s) 秒前" }
        return "\(s / 60) 分 \(s % 60) 秒前"
    }

    /// 给手表的一句话结论（WatchConnectivity 回执用）。
    ///
    /// 手表只显示这一行文字，所以要把「成功/拒绝码/超时」都翻成人话 ——
    /// 不要把 `ActionResult` 原样丢过去。
    public var watchResultText: String {
        guard let result = measured.lastResult else {
            return "未执行（可在手机上看日志）"
        }
        switch result {
        case .success:
            return "「\(measured.lastSucceededAction?.label ?? "动作")」成功"
        case .refused(let code):
            return "车端拒绝（0x\(String(format: "%03X", code))）"
        case .timedOut:
            return "超时：车端没有回应"
        case .paired:
            return "配对完成"
        case .acceptedAwaitingNames:
            return "已受理"
        }
    }

    private func markVehicleContact() {        // 1 秒节流：一轮命令里 `01→02→03→04` 会连来好几帧，
        // 每次都给 `@Published` 赋值会带着整个主界面重算一遍。
        let now = Date()
        if let last = lastVehicleContactAt, now.timeIntervalSince(last) < 1 { return }
        lastVehicleContactAt = now
        // 离线 → 在线：锁屏卡片要立刻翻过来（否则它只能等下一次 linkState 变化）
        if !lastKnownOnline {
            lastKnownOnline = true
            refreshLiveActivity()
        }
    }

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
    /// ★ 置位后**任何**发送都会被 BLE 层拦下（`BLECentral.send` 里统一守卫）。
    ///
    /// 不能只在 `perform` 里判断 —— 预认证 `0x0C` 和配对 `0x0D` 不走 `perform`。
    @Published public var listenOnly = false {
        didSet { ble.listenOnly = listenOnly }
    }

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
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    BackgroundMonitor.shared.didEnterBackground()
                    // ★ 切后台前**趁还有前台执行权**补一帧（2026-10-29）。
                    //
                    // 进后台之后能不能再发，完全取决于系统还给不给广播唤醒。
                    // 如果距上次 `0x0C` 已经超期，就在这最后几秒里先补上 ——
                    // 相当于把「钥匙在场」的有效期从后台起点重新计时，
                    // 让进入后台后的第一段空窗期不至于过期。
                    //
                    // `tickIfNeeded` 自带 29 秒守卫，不会因为频繁切换而多发。
                    self.preAuth.tickIfNeeded()
                }
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
            .sink { [weak self] _ in
                Task { @MainActor in
                    BackgroundMonitor.shared.didBecomeActive()
                    // ★ 从后台挂起恢复 → 预认证若被中断，立刻续上（2026-10-29）
                    //
                    // iOS 挂起期间 29 秒的定时器不推进，而 v5.4 之后断连又不
                    // 清 `isInArea`，`updateArea(true)` 会因状态相同直接 return ——
                    // 结果就是**从后台回来后再也不发 0x0C**，
                    // 表现为「无感进入不可用」「拉门把手不解锁」。
                    self?.preAuth.resumeAfterSuspendIfNeeded()
                    // ★ 回前台是启动 Live Activity 的唯一可靠时机
                    //   （`Activity.request` 在后台会报 `Target is not foreground`）。
                    //   `force` 会清掉失败退避标记，重新尝试。
                    self?.refreshLiveActivity(force: true)
                }
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
        // ★★★ BLE 层也要转发（2026-10-29 补上）
        //
        // `ble` 是 `let`（不是 @Published），它自己的 `linkState` / `rssi` /
        // `rxHexStream` / `candidates` 变化原本**不会**触发 AppModel 刷新。
        // 界面此前能更新纯属巧合：`FileLogger.onNewLine → liveLogLines.append`
        // 顺带 publish 了 AppModel。一旦把日志级别调到 warning 以上
        // （`FileLogger` 直接丢弃低级别行），连接状态胶囊、RSSI、诊断页报文流
        // 就完全不刷新，看着像链路卡死。
        ble.objectWillChange
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
                // ★ 收到本车广播 = 车在附近（`ble.$rssi` 只在 `hit` 时发布）
                self.markVehicleContact()
                self.relayGuard.record(value)
                // ★ 中继告警要落到日志里，否则这段检测等于不存在
                //   （原来只 record 不读结果，每次 RSSI 回调都在做无用计算）。
                //   只在告警内容变化时记，避免每 0.5s 刷屏。
                if let alarm = self.relayGuard.alarm, alarm != self.lastRelayAlarm {
                    self.lastRelayAlarm = alarm
                    self.measured.recordNote("⚠️ 信号异常：\(alarm)")
                } else if self.relayGuard.alarm == nil {
                    self.lastRelayAlarm = nil
                }
                // ★ 点火位置验证：照原 App 的 `checkRssiForPassiveStart:`
                //
                // 反汇编 `rssisOneAndTwo` @`0x8954` 对**两路**天线值做 dB 合成
                // （`10×log10(√(10^(r1/10)² + 10^(r2/10)²) × pondOutToIn)`）。
                //
                // 2026-10-29 修复：广播里的 antenna 高 4 位（0x80/0x40）已经把
                // 两路分开了，`handleDualRSSI` 也一直在存 —— 但区域判定此前
                // 仍用同一个值填两路（等于退化成单天线）。现在两路都齐就用真值。
                let v = Double(value)
                if let one = self.rssiAntennaOne, let two = self.rssiAntennaTwo {
                    _ = self.passiveStart.check(rssiOne: one, rssiTwo: two)
                } else {
                    _ = self.passiveStart.check(rssiOne: v, rssiTwo: v)
                }
                // 未标定 → 只提示一次，避免日志刷屏
                if !self.passiveStart.isCalibrated, !self.didWarnUncalibrated {
                    self.didWarnUncalibrated = true
                    self.measured.recordNote(
                        "⚠️ RSSI 未标定（calibration/leaveOffset 缺失）：被动进入不会自动启动")
                }
                // ★ 把判定结果交给预认证控制器（对应 checkRssiForPassiveStart:
                //   的 launchPrehautentification / stopPreAuthentication 两条分支）
                self.preAuth.updateArea(self.passiveStart.isInPassiveStartArea)
                // ★★★ 事件驱动补发（2026-10-29，针对 iOS 27）
                //
                // 原厂 App 在 iOS 26 上点火稳定、在 iOS 27 上同样"抽奖"，
                // 说明 iOS 27 把后台 BLE 唤醒压得更狠，29 秒的 `Task.sleep`
                // 在后台基本不推进。但**广播还会来** —— 每来一帧就问一次
                // 「距上次 0x0C 是否已经超期」，超了就补，不再死等定时器。
                self.preAuth.tickIfNeeded()
            }
            .store(in: &cancellables)

        // ★ 预认证回调
        preAuth.onLog = { [weak self] line in
            self?.measured.recordNote(line)
        }
        preAuth.onSend = { [weak self] in
            // 后台执行权改在 `beginMeasuredAuth` 里统一申请（那是唯一入口，
            // 连「挂起后补发」和「手动发送」也覆盖到）。这里不再重复申请。
            self?.beginMeasuredAuth(asPreAuthentication: true)
        }

        // ★ 出范围（9 秒无车端数据）—— 只记日志，**不**复位预认证边沿
        //
        // 对应原 App `-[VCBDevice resetWithTimeout]` @`0x9fb4` →
        // `deviceWhentOutOfRange` → `-[IBVehicle vehicleWentOutOfRange]` @`0xa800`。
        //
        // ⚠️ 不能在这里 `resetEdge()`（2026-10-29）：预认证是 **29 秒一轮**，
        //   车端每轮发完就断开，所以「9 秒没有数据」在正常节奏下**必然成立**。
        //   拿它当「人走远了」会每轮都把 `isInArea` 清零，下一帧广播又重新
        //   launch —— 节奏照样被压成几秒一轮。
        //
        //   「是否在区域内」只由 RSSI 判定（`preAuth.updateArea`）负责，
        //   那才是和"人"有关的量；链路空闲不是。
        ble.onWentOutOfRange = { [weak self] in
            self?.measured.recordNote("出范围：9 秒无车端数据（链路空闲，不复位区域状态）")
        }

        // ★ 链路就绪 → ① 有挂起的控车动作则自动执行；② 配对流程在等则发 0x0D；③ 补发预认证
        //
        // ★★★ 顺序是关键（2026-10-29 修复）：**用户动作优先**。
        //
        // 原来 `pairingArmed` 判断在最前面，只要它为真就直接发配对帧并 return，
        // 挂起的控车动作永远轮不到执行。而 `autoConnect()` 在 `measured.keys == nil`
        // 时会反复把 `pairingArmed` 置真 —— 一旦内存里的 keys 没加载出来
        //（Keychain 首次解锁前、或 init 时读失败），
        // **用户每次点按钮都会被配对流程吞掉**，表现就是「指令没用」。
        //
        // 日志实证（2026-10-29）：`链路就绪` 出现 30 次，
        // 而「链路已就绪，自动执行」**0 次** —— 挂起机制从未生效过。
        ble.$linkState
            .filter { $0 == .ready }
            .sink { [weak self] _ in
                guard let self else { return }
                // 诊断：把三个等待标志的实际值记进会话日志，排查时有据可查
                self.measured.recordNote(
                    "链路就绪 → 挂起项：action=\(self.pendingActionAfterConnect?.label ?? "无")"
                    + " / pairing=\(self.pairingArmed)"
                    + " / preAuth=\(self.pendingPreAuth)")

                // ① 用户动作优先（明确意图 > 自动流程）
                if let action = self.pendingActionAfterConnect {
                    self.pendingActionAfterConnect = nil
                    // 取走了 → 看门狗收工，别再报一次「超时未执行」
                    self.cancelPendingActionWatchdog()
                    self.measured.recordNote("链路已就绪，自动执行「\(action.label)」")
                    self.perform(action)
                    return
                }
                // ② 配对流程在等
                if self.pairingArmed {
                    self.appendPairingLog("链路已就绪，自动发配对登记帧（0x0D）")
                    self.beginMeasuredAuthPairing()
                    return
                }
                // ★ 预认证在「未连接」时被挂起 → 这里补发。
                //
                // 不补这一步的话，预认证永远发不出去：它的触发点是"进入区域"，
                // 那时链路没连上，`beginMeasuredAuth` 的 `guard isWriteReady`
                // 会直接丢弃，之后没有任何地方会重试。
                if self.pendingPreAuth {
                    self.pendingPreAuth = false
                    // ★ 补发前复查条件（2026-10-29 全域审查补）。
                    //
                    // `pendingPreAuth` 可能在链路就绪前挂了很久，这段时间里
                    // 用户可能已经关掉保活、或人已经走远。原来无条件补发，
                    // 会出现「关掉预认证后仍然发了一帧 0x0C」——
                    // 用户看着开关是关的，车端却认为钥匙在场。
                    guard self.preAuth.isEnabled, self.passiveStart.isInPassiveStartArea else {
                        self.measured.recordNote(
                            "挂起的预认证已失效（保活=\(self.preAuth.isEnabled ? "开" : "关")"
                            + " / 在区域内=\(self.passiveStart.isInPassiveStartArea)）→ 放弃补发")
                        return
                    }
                    self.measured.recordNote("链路已就绪，补发预认证（0x0C）")
                    self.beginMeasuredAuth(asPreAuthentication: true)
                }
            }
            .store(in: &cancellables)

        // ★ 断连/失败 → 复位预认证的边沿状态。
        //   否则"断开时在区域内"会残留 `wasInsideArea = true`，
        //   重连后一直停在区域内，不会再触发一次 launch。
        //
        // ⚠️ **不能包含 `.idle`**（2026-10-29 修复）：`.idle` 只是"停止扫描"，
        //   不是"链路断了"。`connect(_:)` → `stopScan()` 会先把 `.scanning`
        //   改成 `.idle`，于是出现这条链：
        //   ```
        //   进入区域 → launch → 1s 后 onSend → 链路未就绪 → connectRemembered
        //   → connect → stopScan → .idle → resetEdge → didStart=false + cancelPending
        //   → .ready 补发 0x0C → 车端回 04 → didComplete() 里 guard didStart 直接 return
        //   → 29s 续发链断掉 → 车端只收到一次 0x0C → 点火不了
        //   ```
        //   实测日志里「start sending passive start commands」与
        //   「stop sending passive start commands」出现在**同一毫秒**，就是这个。
        // ★★★ 断连 **不**复位预认证的边沿状态（2026-10-29 修复）
        //
        // 原来这里调 `preAuth.resetEdge()`，它会把 `isInArea` 和 `didStart`
        // 一起清零。但车端**每执行完一条命令就主动断开**（发完 0x05 后 0.1 秒），
        // 于是每轮预认证都会触发这条链：
        //
        // ```text
        // 0x0C 完成 → didComplete() 排 29s 后重试
        //   → 车端断开 → resetEdge() → isInArea=false, didStart=false
        //   → 下一帧广播仍判「在区域内」→ true != false → 立刻再 launch
        //   → 29 秒的节奏被压成 3–5 秒一轮
        // ```
        //
        // 实测日志（21:14）就是这个样子：每 5 秒重连一次，连着发 5 轮后触发
        // 「连续 5 次 3 秒内断开 → 暂停重扫 30 秒」。用户感受到的就是
        // **「蓝牙一直在连、一直在断」**。
        //
        // 正确语义：**断连只说明链路没了，不说明人离开了区域。**
        // 区域状态只由 RSSI 判定驱动（`preAuth.updateArea`），它自己会在
        // 用户真的走远时收到 `false` 并 stop。
        ble.$linkState
            .filter { $0 == .disconnected || $0 == .failed }
            .sink { [weak self] _ in
                // ★ 只复位无感进入切换状态：避免切换请求悬空后开关一直转圈
                self?.passiveEntrySwitching = false
                self?.pendingPassiveEntryValue = nil
            }
            .store(in: &cancellables)

        // ★★★ Live Activity 跟随预认证开关
        //
        // 只在「需要后台 BLE」时才让它出现在锁屏上：开保活 → 启动，
        // 关保活 → 立即结束，不在用户锁屏上留没用的卡片。
        preAuth.$isEnabled
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.refreshLiveActivity() } else { self.liveActivity.end() }
            }
            .store(in: &cancellables)

        // ★ 链路 / 车辆状态变化 → 刷新锁屏卡片（内部有 2 秒节流）
        ble.$linkState
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshLiveActivity() }
            .store(in: &cancellables)

        // ★★★ **蓝牙就绪即自动连接** —— 这是"打开 App 就自动连上"的关键。        //
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

        // ★ 激活与 Apple Watch 的遥控通道（2026-10-30）
        //   手表不直接连车（BLE 绑定密钥导不出来），只发命令给这里执行。
        WatchRemoteBridge.shared.activate()

        // ★ 照原 App：有钥匙就该有心跳。原 App 26 天日志里 69 次 `0x0C` 没有断过，
        //   配对完就一直在跑；我们这个开关原来默认 false、又没有引导，
        //   等于「配对成功但从不保活」—— 那 29 秒节奏根本不会启动。
        autoEnablePreAuthIfNeeded(reason: "启动时已有钥匙")

        // ★ 「车辆在线」的定时重算（5 秒一次）
        //   只在需要让状态**自然过期**时才有意义：`lastVehicleContactAt` 变化会
        //   自己触发重绘，但"60 秒没联络"这件事没有事件可挂，必须靠 tick。
        //
        //   两个约束：
        //   ① 从没联络过就别 tick（否则空闲时每 5 秒空刷一次主界面）
        //   ② 在线状态翻转时顺手刷锁屏卡片 —— 否则卡片会一直停在"在线"，
        //      因为它的刷新原本只挂在 `linkState` 变化上
        onlineTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                // 从没联络过、或已经稳定离线 → 没有"过期"要算，别空刷界面。
                // （新联络到来时 `lastVehicleContactAt` 自己是 `@Published`，会自己重绘）
                guard self.lastVehicleContactAt != nil,
                      self.isVehicleOnline || self.lastKnownOnline else { continue }
                self.onlineTick = Date()
                if !self.isVehicleOnline, self.lastKnownOnline {
                    self.lastKnownOnline = false
                    self.refreshLiveActivity()
                }
            }
        }
    }

    /// 按原 App 行为打开预认证保活 —— 但**不覆盖用户显式关掉的选择**。
    ///
    /// 判据是 `PreAuthenticationController.hasExplicitPreference`：
    /// - `false`（从没动过开关）→ 自动开，对齐原 App「配对后一直心跳」
    /// - `true`（用户主动关过）→ 保持关闭，不再骚扰
    private func autoEnablePreAuthIfNeeded(reason: String) {
        guard hasLocalKey, !preAuth.isEnabled, !preAuth.hasExplicitPreference else { return }
        preAuth.setEnabled(true)
        measured.recordNote("预认证保活：已自动开启（\(reason)；原 App 配对后即持续心跳）")
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
        // ★ 不再要求 `isWriteReady`（2026-10-29 修复）。
        //
        // 原来未连接时直接拒绝（"需先连接车辆"），但 `perform` 本身支持
        // 「挂起动作 → 自动连接 → 就绪后执行」。同一个 App 里两套行为，
        // 用户刚点完控车（车端已断开）马上切开关就会被拒。
        // 现在统一交给 `perform` 的排队机制。
        passiveEntrySwitching = true
        // 记录本次期望值，供 04 回执时确认是否切换成功
        pendingPassiveEntryValue = enabled
        if !ble.isWriteReady {
            statusLine = "正在连接车辆，就绪后切换无感进入…"
        }
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

    private func appendPairingLog(_ s: String) {
        pairing.appendExternal("· \(s)")
        // ★ 必须同时落盘（2026-10-29 修复）。
        //
        // 原来只写 `pairing.log`（@Published 数组，内存），FileLogger 里一条都没有 ——
        // 于是「链路已就绪，自动发配对登记帧」这类**关键分支**在日志文件里
        // 完全不可见，排查时只能靠猜。配对流程的诊断价值恰恰最高。
        FileLogger.shared.info("[配对] \(s)", module: "配对")
    }

    /// 配对流程是否在等待链路就绪（就绪后自动发登记帧）
    ///
    /// 同时同步给 BLE 层：`pairingMode` 决定「连接失败后要不要无条件连
    /// 下一个扫到的设备」——平时不该这样（会连错车）。
    @Published public var pairingArmed = false {
        didSet { ble.pairingMode = pairingArmed }
    }

    /// 非空表示这次配对**被主动阻止**（典型：本地已有密钥）。
    /// `PairingView` 用它弹说明，避免用户以为"点了没反应"。
    @Published public var pairingBlockedReason: String?

    // MARK: - ★ 配对状态（单一判定口）

    /// 本地是否已有这台车的密钥 —— **所有"要不要允许配对 / UI 显示什么"都只看它**。
    ///
    /// ## 为什么要"双查"（内存 + Keychain）
    ///
    /// `MeasuredSession.keys` 是 `init` 时读一次 Keychain 的**内存缓存**。
    /// 两个方向都会不一致，而且危害相反：
    ///
    /// | 场景 | 内存 | Keychain | 只看内存的后果 |
    /// |---|---|---|---|
    /// | 重启后尚未首次解锁，init 读失败 | `nil` | 有 | 误判「未配对」→ 允许重复配对 → 车端零响应 |
    /// | 刚解绑（Keychain 已清，内存未刷） | 有 | 无 | 误判「已配对」→ **无法重新配对** |
    ///
    /// 所以两个都要看：任一有就算「已配对」；两个都空才是真的未配对。
    /// 解绑时由 `deleteVehicle()` 同时清 Keychain 和内存，保证回到双空。
    public var hasLocalKey: Bool {
        if measured.keys != nil { return true }
        return KeyStore.shared.communicationKey?.isEmpty == false
    }

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
    /// 关闭配对页时的收尾 —— 把「正在等配对」的状态放掉。
    ///
    /// ## 为什么需要（2026-10-29 全域审查）
    ///
    /// `startFullPairing()` 会置 `pairingArmed = true`（`didSet` 同步
    /// `ble.pairingMode`）。清它的地方原本只有四处：配对帧真发出去、
    /// 4 秒命令超时、`0x0E` 解析失败、解绑 —— **用户直接关掉配对页不在其中**。
    ///
    /// 而配对阶段没有独立看门狗（4 秒超时要等 `0x0D` 真正发出去才起表），
    /// 所以「车端没开配对窗口 / 车不在附近」时打开页面再关掉，会留下：
    /// - 顶部胶囊永久显示「配对中」（`linkStateText` 先判 `pairingArmed`）
    /// - 车图永久停在配对闪灯动画
    /// - `ble.pairingMode = true` → 连接失败后会无条件连「下一个扫到的设备」
    ///
    /// 已经配对成功（`hasLocalKey`）时**不清** —— 那是有效结果，必须保留。
    public func cancelPairingIfNeeded() {
        guard !hasLocalKey else { return }
        guard pairingArmed || ble.autoConnectWhilePairing || pairing.state != .idle else {
            return
        }
        pairingArmed = false                 // didSet → ble.pairingMode = false
        ble.autoConnectWhilePairing = false
        pairing.resetForNewAttempt()
        pairingBlockedReason = nil
        appendPairingLog("已关闭配对页 → 取消本次配对等待（未配对成功，不留残留状态）")
    }

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
        // ★ 用 `hasLocalKey`（内存 + Keychain 双查）而不是 `measured.keys`：
        //   后者是内存缓存，解绑后若没清干净会误判成"已配对"，
        //   于是解绑之后反而再也发不出配对帧。
        if !force, hasLocalKey {
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
        //
        // ⚠️ 判定统一走 `hasLocalKey`（内存 + Keychain 双查）：
        //   只看 `measured.keys`（内存缓存）会误判 —— 见 `hasLocalKey` 的注释。
        if !hasLocalKey {
            if !pairingArmed {
                pairingArmed = true
                appendPairingLog(
                    "本地无密钥（keys=0）→ 自动进入配对等待："
                    + "扫到本车广播即连接并发 0x0D（对齐原 App 的 didFoundVehicleRequestPairing 路径）")
            }
            // 配对必须「主动连接」：v4.4 起扫描命中不再自动连（避免空连接
            // 被车端 2 秒踢掉），所以这里显式置位。
            ble.forceConnectOnce = true
        } else if measured.keys == nil {
            // Keychain 里有密钥，只是内存没加载出来 → 重载，不进配对
            measured.reloadKeys()
            appendPairingLog("内存无密钥但 Keychain 有 → 已重载（不进配对流程）")
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
    ///
    /// `nonisolated`：它被 `startCommandTimeout` 的**默认参数**引用，
    /// 而默认参数在 nonisolated 上下文求值 —— 不加会被 Swift 6 判为错误。
    nonisolated static let commandTimeoutSeconds: TimeInterval = 4.0

    /// 配对命令（`0x55`）超时
    nonisolated static let pairingTimeoutSeconds: TimeInterval = 30.0

    private func startCommandTimeout(
        _ what: String,
        seconds: TimeInterval = AppModel.commandTimeoutSeconds
    ) {
        cancelCommandTimeout()
        commandTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.commandTimeoutTask = nil
            // ★ 先判断这一轮是不是预认证：预认证轮次 `pendingAction == nil`
            //   （`preparePreAuthentication()` 会把它清掉），用户命令则非 nil。
            let wasPreAuth = (self.measured.pendingAction == nil)
            self.measured.commandTimedOut()
            // 超时 = 本轮结束 → 释放后台执行权，别一直占着（见 `beginPreAuthBackgroundTask`）
            self.endPreAuthBackgroundTask()
            // ★★ 预认证轮次超时也要「排下一轮」（2026-10-30 修复）。
            //
            // 原来只有**收到 04** 的分支才调 `preAuth.didComplete()`。
            // 车端收下 `0x0C` 却不回 `04`（挑战不匹配 / 丢包 / 车端忙）时：
            // 没有 `04` → 没有 `didComplete()` → **没有下一次 29 秒定时器** →
            // 续发只能等下一帧广播来触发 `tickIfNeeded()`。
            // 前台没事（0.5 秒就有一帧），**后台广播稀疏到 10–31 秒甚至更久时，
            // 「位置没动、预认证却断了几分钟」就是这么来的** —— 点火抽奖的一个来源。
            if wasPreAuth {
                self.preAuth.didComplete()
            }
            self.statusLine = "❌ \(what) 超时（\(Int(seconds))s，code 690）"
            // ★★★ 超时必须**收口所有「等待中」的状态**（2026-10-29 修复）。
            //
            // 原来只改 statusLine，于是：
            //   · 无感进入开关：`passiveEntrySwitching` 永远不复位
            //     （只有"断连"才复位）→ 车端收下命令但不回 04 也不断开时，
            //     开关永久转圈，只能重启 App
            //   · Siri / 快捷指令：要一直等到 12 秒兜底才回话
            //   · 配对：`pairing.state` 停在「发送配对请求」
            if self.pendingPassiveEntryValue != nil {
                self.settlePassiveEntryToggle(.timedOut)
            }
            self.resolveIntent(false)
            self.pairingArmed = false
            if self.pairing.state == .requestingPairing {
                self.pairing.fail("命令超时（\(Int(seconds))s，code 690）")
            }
            // 控车超时不该写进「配对日志」，进会话日志即可
            self.measured.recordNote("超时：\(what)（\(Int(seconds))s, code 690）")
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
            // ★ 必须校验「真的落库了」再报成功（2026-10-29 修复）。
            //   原来无条件报「已保存，配对完成」，帧长不符时会话侧其实
            //   一个字段都没写，用户看到成功、主界面仍是「尚未绑定车辆」。
            guard measured.lastResult == .paired else {
                statusLine = "❌ 0x0E 密钥帧无法解析（\(payload.count)B），未写入密钥"
                appendPairingLog("❌ 0x0E 密钥帧长度不符（\(payload.count)B），配对失败")
                pairing.fail("密钥帧长度不符（\(payload.count)B）")
                pairingArmed = false
                return true
            }
            // ★ 配对后 cidpu 变了 → 重新读该车对应的标定值
            //   （`getCalibrationSavedValues` 用 "<cidpu>_CALIBRATION" 作 key）
            loadCalibration()
            // ★ 新密钥落库 → 立刻重算完整性指纹，避免下次启动才自愈
            verifyKeyIntegrity()
            // ★ 照原 App：配对成功即开始心跳（`callDidPairingSuccess` 之后
            //   预认证就一直跑，从不等用户去开开关）
            autoEnablePreAuthIfNeeded(reason: "配对成功")
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
    /// 本 App 单车辆槽位，清全部密钥即等于删除这辆车。
    ///
    /// ## 解绑必须做到「双空」才算真的回到未配对
    ///
    /// 内存里的 `measured.keys` 和 Keychain 是**两份副本**。只清 Keychain 的话：
    /// - 主界面仍按 `measured.keys != nil` 显示「数字钥匙已就绪」
    /// - `startFullPairing` 被「本地已有密钥」拦住 → **解绑后反而无法重新配对**
    ///
    /// 所以这里三步都做：清 Keychain（`clearAll`）+ 清内存（`forgetKeys`）
    /// + 清派生状态（`reset`），最后再把与该车绑定的偏好项一起抹掉。
    public func deleteVehicle() {
        let oldCidpu = KeyStore.shared.cidpuFullHex

        // ① 清与该车绑定的偏好项（按 cidpu 分键的，必须用旧 cidpu 取）
        if let cidpu = oldCidpu, !cidpu.isEmpty {
            UserDefaults.standard.removeObject(forKey: "\(cidpu)_CALIBRATION")
            UserDefaults.standard.removeObject(forKey: "\(cidpu)_PASSIVE_ENTRY")
        }
        UserDefaults.standard.removeObject(forKey: "gkuiblekey.calibration.default")
        UserDefaults.standard.removeObject(forKey: "gkuiblekey.passiveEntry.default")

        // ② 清密钥 —— 先 Keychain，再内存副本
        KeyStore.shared.clearAll()
        measured.forgetKeys()

        // ③ 链路与设备（避免解绑后误连旧车）
        ble.disconnect()
        ble.forgetRememberedPeripheral()

        // ④ 会话与协议状态
        measured.reset()
        passiveStart.cancelCalibration()
        passiveStart.calibration = nil
        // ★ 心跳也要停：解绑后没有密钥，29 秒一轮的 0x0C 只会一直失败；
        //   同时清掉「用户显式设置过」的痕迹，重新配对后才能自动开启。
        preAuth.resetForUnbind()
        passiveEntryEnabled = false
        pendingAction = nil
        pendingActionAfterConnect = nil
        cancelPendingActionWatchdog()
        pendingPreAuth = false
        pendingPassiveEntryValue = nil
        passiveEntrySwitching = false
        didWarnUncalibrated = false
        consecutiveAuthFailures = 0
        lockoutRemaining = 0
        rssiAntennaOne = nil
        rssiAntennaTwo = nil
        lastRelayAlarm = nil
        // ★ 解绑后不该再说「车辆在线」——否则顶栏会替一辆已经解除绑定的车
        //   继续显示在线，直到 60 秒窗口过期。
        lastVehicleContactAt = nil
        lastKnownOnline = false

        // ⑤ 配对状态必须复位 —— 否则下次打开配对页还停在「上一次配对失败」
        pairingArmed = false
        pairingBlockedReason = nil
        pairing.resetForNewAttempt()

        // ⑥ 完整性校验：此时必然「缺少 communicationKey」，那是未配对的正常态，
        //    不要让它把 statusLine 覆盖成一句像报错的话（所以放在最后重设文案）
        verifyKeyIntegrity()

        statusLine = "已解绑：密钥与标定已清除，可以重新配对"
        measured.recordNote(
            "解绑完成：Keychain 已清空、内存副本已清、标定/无感/配对状态已复位"
            + "（照 deleteVehicleWithCidpu:）")
    }

    // MARK: - 中继防护

    /// 中继攻击防护（基于 RSSI 突变检测）
    public let relayGuard = RelayGuard()

    /// 上一次记录过的中继告警，用于去重（nil = 当前无告警）
    private var lastRelayAlarm: String?

    // MARK: - ★ Live Activity（后台 BLE 权限的钥匙）

    /// 锁屏 / 灵动岛上的实时活动。
    ///
    /// **技术目的**：Apple 文档（iOS 26+）规定，App 有 `CBManager` 实例并启动
    /// Live Activity 后，后台可获得与前台相同的 Core Bluetooth 权限 ——
    /// 特别是后台扫描时 `AllowDuplicates` 仍然生效（不被系统合并成十几秒一次）。
    ///
    /// 用户实测原厂 App「iOS 26 稳定、iOS 27 抽奖」，差别就在这个权限上。
    public let liveActivity = LiveActivityController()

    /// 把当前状态推给锁屏卡片（预认证保活关闭时直接结束活动）
    ///
    /// 加 2 秒节流：`linkState` 在连接/断开时会连续变化多次，
    /// 而 Live Activity 的更新本身有系统级频率限制，没必要每次都推。
    ///
    /// ⚠️ **`Activity.request` 必须在前台调用**（实测报
    /// `Target is not foreground`）。App 被 Siri / 静默唤醒时是后台启动，
    /// 那时启动必然失败 —— 所以失败后 30 秒内不重试，等 `didBecomeActive`
    /// 用 `force` 参数重来。
    private var lastLiveActivityRefresh = Date.distantPast
    private var liveActivityFailedAt: Date?

    private func refreshLiveActivity(force: Bool = false) {
        guard preAuth.isEnabled else {
            liveActivity.end()
            return
        }
        if force { liveActivityFailedAt = nil }
        if let t = liveActivityFailedAt, Date().timeIntervalSince(t) < 30 { return }
        if liveActivity.isRunning,
           Date().timeIntervalSince(lastLiveActivityRefresh) < 2 {
            return
        }
        lastLiveActivityRefresh = Date()
        // ★ 与主界面同一套语义（2026-10-30）：锁屏卡片也只说「车在不在」。
        //
        // 原来这里写 `链路就绪 / 搜索车辆中`，而车端每条命令后都断开 ——
        // 锁屏卡片会跟着 29 秒一次地抖，和顶栏是同一个毛病。
        let text: String
        if isVehicleOnline {
            text = preAuth.lastSentAt != nil ? "在线 · 已向车端报到" : "车辆在线"
        } else if lastVehicleContactAt != nil {
            text = "离线（\(lastContactText)）"
        } else {
            text = "车辆离线"
        }
        let name = UserDefaults.standard.string(forKey: VehicleProfile.nicknameKey)
            ?? VehicleProfile.defaultNickname
        let ok = liveActivity.startOrUpdate(
            vehicleName: name,
            state: VehicleActivityAttributes.ContentState(
                isLocked: measured.status?.isLocked,
                isConnected: isVehicleOnline,
                lastPreAuthAt: preAuth.lastSentAt,
                statusText: text))
        if !ok {
            // 前台没启动成功通常只有两种原因：系统关了实时活动权限，
            // 或者当前不是前台（`Target is not foreground`）。
            // 记下时间做 30 秒退避，回前台时用 force 重试。
            liveActivityFailedAt = Date()
        }
    }

    /// 处理外部 URL —— 控制中心 / 锁屏控件（`gkuiblekey://lock` 等）与快捷指令共用。
    ///
    /// 控件声明在 Widget 扩展里，而车控逻辑只能跑在主 App，
    /// 所以路径是：`OpenURLIntent` → 打开 App → `onOpenURL` → 这里 → `perform`。
    ///
    /// 走到这里时 App 已在前台，`perform` 若是未连接会自动挂起并连接，
    /// 不会因为后台限制丢帧。
    /// - Parameter fromDelegate: 是否来自 UIKit 的 `application(_:open:)`。
    ///   该入口**只在 App 未运行时**参与，所以它出现就代表这是冷启动的首次投递。
    public func handleExternalURL(_ url: URL, fromDelegate: Bool = false) {
        guard url.scheme?.lowercased() == "gkuiblekey" else { return }

        // ★ 冷启动补发去重（只在这个窗口内生效，理由见 `coldStartURLWindowEnd`）
        if fromDelegate {
            coldStartURLWindowEnd = Date().addingTimeInterval(1.0)
        } else if let end = coldStartURLWindowEnd,
                  Date() < end,
                  lastExternalURL == url {
            measured.recordNote("控件 URL 重复投递（冷启动补发），已忽略：\(url.host ?? "-")")
            return
        }
        lastExternalURL = url

        let action: IBCommandType?
        switch url.host?.lowercased() {
        case "lock":    action = .lock
        case "unlock":  action = .unlock
        case "trunk":   action = .openCloseTrunk
        case "find":    action = .panic
        case "windowup":   action = .windowUp
        case "windowdown": action = .windowDown
        default:        action = nil
        }
        guard let action else {
            statusLine = "无法识别的控件指令：\(url.absoluteString)"
            return
        }
        measured.recordNote("控制中心控件 → \(action.label)")
        perform(action)
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 车控动作（统一入口）

    /// 当前正在执行的动作（供日志/界面显示）
    @Published public private(set) var pendingAction: IBCommandType?

    /// 用户点了按钮但当时链路未就绪 → 挂在这里，等 `.ready` 后自动执行。
    @Published public private(set) var pendingActionAfterConnect: IBCommandType?

    /// ★ 挂起动作的看门狗：**保证「点了按钮」永远不会静默悬空**。
    ///
    /// ## 为什么必须有
    ///
    /// 「挂起 + 等链路就绪后执行」这条路径依赖**别的组件**把链路推起来。
    /// 一旦那个组件不推进（看门狗漏挂、回调丢失、僵尸态判断错误），
    /// 动作就永远躺在 `pendingActionAfterConnect` 里，而 UI 只有一句
    /// 「正在连接，就绪后自动执行…」，用户看到的就是**点了没反应**。
    ///
    /// 实测（2026-10-29 22:00:32）：`adoptConnectedPeripheral` 接管了系统
    /// 遗留连接、置 `.discovering` 却没起超时 → 14 秒零事件零超时 →
    /// 控制中心点「闭锁」完全无响应。
    ///
    /// 这条看门狗是**最后一道**：不管上游因为什么原因没把链路带起来，
    /// 15 秒后一定给用户一个明确结论（成功在 `.ready` 里取走，失败在这里）。
    private var pendingActionWatchdog: Task<Void, Never>?

    /// 挂起动作最多等多久（秒）。连接 1–2s + 服务发现 0.2s + 鉴权 0.3s，
    /// 留足重连一次的余量。
    private static let pendingActionWaitSeconds: TimeInterval = 15

    /// 上一次处理过的控件 URL（用于冷启动双入口去重，见 `handleExternalURL`）。
    private var lastExternalURL: URL?

    /// 「冷启动补发窗口」的截止时刻。
    ///
    /// iOS 的 URL 投递规则决定了**只有冷启动**才会重复：
    /// - App 未运行 → `application(_:open:options:)`（UIKit）投递，
    ///   随后 SwiftUI 的 `.onOpenURL` 可能再补一次同一个 URL
    /// - App 已在运行 → URL 只经 `UIScene.openURLContexts` 投递，
    ///   **不经过** `application(_:open:)`，因此不可能重复
    ///
    /// 所以只在 delegate 参与（= 冷启动）后开一个短窗口去重；
    /// 热启动时窗口不存在，用户连点几次都会真的执行 ——
    /// 「点了没反应再点一次」是常见操作，不能被去重逻辑吃掉。
    private var coldStartURLWindowEnd: Date?

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
            // ★ 结束 Intent 等待（2026-10-29 全域审查补）。
            //   否则 Siri 会白等满 12 秒，最后报「请确认蓝牙已开启、且在车辆附近」——
            //   真实原因是「只读模式开着」，用户会去反复开关蓝牙。
            resolveIntent(false)
            return
        }
        // ★ 防爆破锁定：此前只记录 `lockoutRemaining` 却没有拦截，
        //   等于锁定形同虚设。这里在唯一入口处硬拦截。
        guard !isLockedOut else {
            statusLine = "已锁定：连续失败 \(consecutiveAuthFailures) 次，\(lockoutRemaining)s 后可重试"
            // ★ 同上：立刻让 Siri 拿到失败，并把真实原因说清楚
            resolveIntent(false)
            return
        }
        // ★★ 上一轮「用户命令」还在途 → 不要打断（2026-10-30 修复）。
        //
        // 链路就绪时连点两次按钮，原来会直接再走一遍 `beginMeasuredAuth`：
        // `resetCommandOnly()` + `resetPacketCounter()` 把 `lastPacket` 归零、
        // 把上一轮的 `rnd1` 冲掉。于是车端回的是**第一轮**的 `02`，
        // 而 `buildAuth3` 用的是**第二轮**的 `rnd1` → 挑战自校验必失败 →
        // 记一次 `recordAuthFailure`。连点 5 次即 60 秒锁定，
        // 用户看到「连续失败 N/5 → 已锁定」，以为钥匙坏了。
        //
        // 只拦**用户命令**在途（`measured.pendingAction != nil`）；
        // 预认证轮次（`pendingAction == nil`）允许被打断 —— 用户意图优先。
        if measured.pendingAction != nil, commandTimeoutTask != nil {
            statusLine = "上一轮「\(measured.pendingAction?.label ?? "命令")」仍在执行，请稍候"
            resolveIntent(false)
            return
        }
        guard ble.isWriteReady else {
            // ★ 未连接时不再只是弹提示 —— 记住动作、强制连一次，链路就绪后自动执行。
            //
            // 背景：v3.1 加了「扫描常开」，v3.3 又加了「断开后 15 秒内不自动重连」
            // 的冷却（防止「连→断→扫→连」死循环）。两者叠加会导致：车端刚断开、
            // 用户马上点按钮时链路还没就绪，原来是直接拒绝，体验很差。
            // 现在改成「挂起重试」。
            //
            // ⚠️ `pendingActionAfterConnect` 只能存**一个**动作。如果之前挂起的是
            //    无感进入切换，又被别的动作顶掉，`passiveEntrySwitching` 就没人
            //    复位了（开关永久转圈）。这里显式收口。
            if pendingPassiveEntryValue != nil,
               action != .enablePassiveEntry, action != .disablePassiveEntry {
                pendingPassiveEntryValue = nil
                passiveEntrySwitching = false
                measured.recordNote("无感进入切换被「\(action.label)」打断，已复位开关")
            }
            pendingActionAfterConnect = action
            ble.forceConnectOnce = true          // 无视冷却，扫到就立刻连
            armPendingActionWatchdog(action)
            // ★ 优先「直接连已知设备」——不等扫描广播，省掉 1–2 秒
            //   （车端每条命令执行完就断开，靠扫描等广播会很慢）
            if !ble.connectRemembered() {
                let st = ble.linkState
                if st != .scanning && st != .connecting && st != .discovering {
                    ble.startScan()
                }
            }
            // ★ 不再对用户说「未连接」（2026-10-30）：
            //   顶栏现在只说「车辆在线」，而链路在每条命令后都会断一次 ——
            //   这里再写「未连接」会和顶栏直接打架。原始状态留给日志。
            statusLine = "正在连接车辆，就绪后自动执行「\(action.label)」…"
            measured.recordNote("链路 \(ble.linkState.rawValue) → 挂起「\(action.label)」，就绪后自动执行")
            return
        }
        pendingAction = action
        beginMeasuredAuth(action: action)
    }

    /// 起「挂起动作」看门狗 —— 见 `pendingActionWatchdog` 的说明。
    private func armPendingActionWatchdog(_ action: IBCommandType) {
        pendingActionWatchdog?.cancel()
        pendingActionWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.pendingActionWaitSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingActionWatchdog = nil
            // 已经被 `.ready` 取走执行了 → 不打扰
            guard self.pendingActionAfterConnect == action else { return }

            self.pendingActionAfterConnect = nil
            self.statusLine = "❌ \(Int(Self.pendingActionWaitSeconds)) 秒内没连上车辆，"
                + "「\(action.label)」未执行。请靠近车辆后重试"
            self.measured.recordNote(
                "挂起动作超时（\(Int(Self.pendingActionWaitSeconds))s 链路未就绪）"
                + "→ 放弃「\(action.label)」，断开重扫")
            // 主动把僵住的链路拆掉，让下一次点击从干净状态开始。
            // 用 `resetLinkAndRescan()` 而不是 `disconnect()+startScan()`：
            // 后者的抑制标志会让 didDisconnect 直接 return，状态与扫描脱节。
            self.ble.resetLinkAndRescan()
        }
    }

    /// 取走/放弃挂起动作时都要取消看门狗，避免它事后再报一次超时。
    private func cancelPendingActionWatchdog() {
        pendingActionWatchdog?.cancel()
        pendingActionWatchdog = nil
    }

    // MARK: - 后台执行时间保障（预认证一轮往返）

    /// 正在持有的后台执行权（`.invalid` = 未持有）
    private var preAuthBGTask: UIBackgroundTaskIdentifier = .invalid

    /// 申请后台执行时间，保证这一轮 `01 → 02 → 03(0x0C) → 04` 能走完。
    ///
    /// ## 为什么必须有（2026-10-29，「切后台保持预认证」）
    ///
    /// 后台被广播唤醒时系统只给**几秒**。而一轮预认证是
    /// 「连接（1–2 秒）+ 鉴权往返（0.5–1 秒）」，中途被挂起就半途而废：
    /// `03` 没发出或 `04` 收不到 → `didComplete()` 不触发 →
    /// 这一轮白费，只能干等下一个广播。
    ///
    /// `beginBackgroundTask` 能争取约 30 秒，足够走完一整轮。
    /// 到期（系统收回）时主动结束，避免进程被强杀。
    private func beginPreAuthBackgroundTask() {
        guard preAuthBGTask == .invalid else { return }
        preAuthBGTask = UIApplication.shared.beginBackgroundTask(withName: "preAuthRound") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.measured.recordNote("预认证：后台执行时间到期，本轮未走完（系统收回）")
                self.endPreAuthBackgroundTask()
            }
        }
        if preAuthBGTask != .invalid {
            let where_ = BackgroundMonitor.shared.isInBackground ? "后台" : "前台"
            measured.recordNote("预认证：已申请后台执行时间（\(where_)，保证本轮 01→04 走完）")
        }
    }

    /// 一轮走完（收到 04）或失败/中止时释放后台执行权。
    private func endPreAuthBackgroundTask() {
        guard preAuthBGTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(preAuthBGTask)
        preAuthBGTask = .invalid
    }

    /// 是否正持有「预认证一轮往返」的后台执行权（供诊断页显示）。
    ///
    /// 排查「切后台预认证还在不在」时，这个值比「已发次数」更直接：
    /// 后台发帧的那一刻它应该是 true，收完 04 回到 false。
    public var isHoldingPreAuthBackgroundTime: Bool { preAuthBGTask != .invalid }

    /// **手动补发一次预认证 `0x0C`** —— 上车前点一下，提高点火命中率。
    ///
    /// ## 为什么需要它
    ///
    /// 预认证的自动节奏是 **29 秒一次**（`PreAuthenticationController.retryInterval`，
    /// 对齐原 App 实测的 30 秒周期）。但用户上车、踩刹车、按启动按钮是**随机时刻**，
    /// 如果车端只认「最近 N 秒内收到过 0x0C」，命中率就只有 N/30 —— 这正是
    /// 「试好多次才打得着火」的数学原因。
    ///
    /// 这个入口让用户在**上车前**主动打一次招呼，把等待窗口压到最短。
    /// 它不做任何新协议动作：只是把定时器该发的那一帧**提前**发出去。
    ///
    /// - Note: 复用当前链路；若链路未就绪，会走 `pendingPreAuth` 挂起并在
    ///   `.ready` 后补发，不会丢。
    public func sendPreAuthNow() {
        guard hasLocalKey else {
            statusLine = "尚未配对，无法预认证"
            return
        }
        guard preAuth.isEnabled else {
            statusLine = "预认证保活未开启：先到「开发者 → 预认证保活」打开"
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
        measured.recordNote("手动补发预认证（用户请求，不等 29s 定时）")
        statusLine = "正在向车端打招呼（预认证 0x0C）…"
        beginMeasuredAuth(asPreAuthentication: true)
    }

    /// 重新计算「点火位置验证」—— 纯本地 RSSI 判定，**不发送任何帧**。    ///
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
        // ★★ 实测协议优先：首字节就是命令号

        // ★ 能收到车端的帧 = 车就在旁边（无论后续解析成功与否）
        markVehicleContact()

        // 配对帧（0x0D / 0x0E）先交给配对流程
        if handlePairingFrame(bytes) {
            cancelCommandTimeout()
            return
        }

        // 0x01–0x05 是鉴权链；0x0F 是「已配对设备名」回执 ——
        // 少了 0x0F 的话，`requestPairedDevicesNames()` 发出去后回执会被
        // 下面的"未知帧"分支吞掉，功能永远不闭环。
        if let (cmd, _) = MeasuredFrame.decode(bytes),
           (0x01...0x05).contains(cmd) || cmd == 0x0F {
            // ★ 只在「本轮鉴权链的实质响应」上撤超时（2026-10-29 修复）。
            //
            // 原来在函数第一行**无条件** `cancelCommandTimeout()`，于是
            // 车端周期推送的 `0x05` 状态帧也能把 01→04 的超时撤掉，
            // 表现为「命令没回应也不报超时，界面一直挂着」。
            if cmd != 0x05 { cancelCommandTimeout() }
            if let next = measured.handle(bytes) {
                // 收到 02 后自动回 03 —— 事件驱动，不用等固定延时
                if ble.send(next) {
                    statusLine = "已自动回复鉴权3，等待结果"
                    // ★★★ 03 发出后**必须重新起表**（2026-10-29 修复）。
                    //
                    // 原来的 4s 超时只覆盖「01 → 第一帧」；02 一到就被取消，
                    // 回完 03 再没有任何计时器。车端收下 03 却不回 04 时
                    // （挑战不匹配 / 丢包 / 车端忙），`pendingAction` 与
                    // statusLine 永久停在"等待结果"，`preAuth.didComplete()`
                    // 永不触发 → 预认证续发链死掉。这是典型的静默失败。
                    startCommandTimeout("鉴权3")
                } else {
                    statusLine = "鉴权3 写入失败（写特征未就绪）"
                }
            } else {
                    // ★ 04 结果码 → 成功/失败分流（原 App `checkResultMessage:` 三种结局）
                if cmd == 0x04, let result = measured.lastResult {
                    // 预认证往返结束 → 交给控制器排下一次（29.0s 调度，实测约 30s）
                    // 依据：`didPassiveStartCompletedWithError:` @0xb6cc
                    let isPreAuth = (measured.pendingAction == nil)
                    switch result {
                    case .success:
                        recordAuthSuccess()
                        statusLine = isPreAuth
                            ? "✅ 钥匙已被车内认可，可踩刹车按启动按钮（约 30 秒后自动续发）"
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
                    //
                    // ⚠️ 预认证轮次必须排除（2026-10-29 修复）：预认证保活开着时，
                    //   一轮 `0x0C` 的 `04 00` 与用户意图的 `04 00` 长得一模一样。
                    //   原来不看来源就 `resolveIntent(true)`，于是 Siri 会说
                    //   「已解锁」而门根本没开。
                    if !isPreAuth {
                        switch result {
                        case .success, .paired, .acceptedAwaitingNames:
                            resolveIntent(true)
                        case .refused, .timedOut:
                            resolveIntent(false)
                        }
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
                        // 本轮走完了 → 释放后台执行权（见 `beginPreAuthBackgroundTask`）
                        endPreAuthBackgroundTask()
                    }
                    // ★ 收到 04 → 立刻恢复扫描（对齐原 App 06:25:14 的
                    //   `Data received {0x0400}` → `Start scan`，不等车端断开）。
                    //   持续扫描是 iOS 判定"后台仍在工作"最强的信号，
                    //   也是原 App 后台 30 秒节奏稳定的可能原因。
                    ble.resumeScanIfNeeded()
                    // 预认证往返结束 → 更新锁屏卡片的「最近报到」时间
                    refreshLiveActivity()
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
                // ★★ 帧被拒 → 本轮已死，必须收口（2026-10-29 全域审查补）。
                //
                // `measured.handle` 因乱序 / 长度不符 / 非法命令返回 nil 时
                // 只把 `phase` 设成 `.failed`；而上面已经 `cancelCommandTimeout()`
                // 撤掉了 4 秒超时。不收口的话：`pendingAction` 永不复位、
                // 预认证的 `didComplete()` 永不触发 → 29 秒续发链彻底停摆。
                if measured.phase == .failed {
                    // 先取「是不是预认证轮次」——`abortRound` 会把 pendingAction 清掉
                    let wasPreAuth = (measured.pendingAction == nil)
                    measured.abortRound("下行帧被拒（命令 0x\(String(format: "%02X", cmd))）")
                    resolveIntent(false)
                    // 本轮中止 → 释放后台执行权
                    endPreAuthBackgroundTask()
                    // ★ 同超时分支：预认证轮次中止也要排下一轮，否则续发链停摆
                    if wasPreAuth { preAuth.didComplete() }
                    if pendingPassiveEntryValue != nil {
                        settlePassiveEntryToggle(.refused(0x2BB))
                    }
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
        // ★★ 预认证**一进来就申请后台执行时间**（2026-10-30）。
        //
        // 必须放在最前面，包括「链路未就绪 → 挂起 → 等 `.ready` 补发」那条路 ——
        // 因为连接（1–2 秒）+ 鉴权往返（0.5–1 秒）全程都需要后台执行权。
        //
        // 原来只在 `preAuth.onSend` 里申请，于是有两条路径**没有保护**：
        //   · `.ready` 回调里的「补发预认证」—— 后台最常见的就是这条
        //   · 诊断页手动「立即发送预认证」
        // 表现为：后台唤醒后连接还没建完就被系统挂起，这一轮白费。
        //
        // 放在唯一入口后三条路径全覆盖，且 `beginPreAuthBackgroundTask`
        // 内部有 `guard preAuthBGTask == .invalid`，重复调用无副作用。
        if asPreAuthentication { beginPreAuthBackgroundTask() }

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

    /// 校验必需密钥是否存在、长度是否合理，并与记录的指纹比对。
    ///
    /// ## ⚠️ 指纹不匹配**不再拦截**控车（2026-10-29 修复）
    ///
    /// 原来的实现把「指纹变化」直接判为 `keyIntegrityOK = false`，而这个值
    /// 在 `perform` / `beginMeasuredAuth` 里是硬拦截。但指纹变化的**正常原因**
    /// 恰恰是合法写入：
    ///
    /// | 场景 | 结果（旧实现） |
    /// |---|---|
    /// | 自己配对成功 → `saveKeys` 写入新 `communicationKey` | 下次启动判「被篡改」→ **所有按钮失效** |
    /// | 点「重新应用内置钥匙」 | 同上 |
    /// | 从备份恢复 | 同上 |
    ///
    /// 而且 `verifyKeyIntegrity()` 只在 `init` 里调一次，因此**重启也无法恢复**，
    /// 唯一出路是解绑车辆（`clearAll` 删掉指纹）——用户会看到「配对成功但什么都点不动」。
    ///
    /// 现在：指纹不匹配时**自愈**（重算并写回），只在 `keyIntegrityDetail`
    /// 里留一条说明。真正的硬失败只剩「密钥缺失 / 长度异常」两种。
    public func verifyKeyIntegrity() {
        let store = KeyStore.shared
        var problems: [String] = []
        var notes: [String] = []

        let comm = store.communicationKey
        if comm == nil {
            problems.append("缺少 communicationKey（尚未配对或未导入）")
        } else if let c = comm, c.count < 16 {
            problems.append("communicationKey 长度异常（\(c.count) 字节）")
        }

        // 指纹比对：不一致就自愈（合法写入会改变它），不阻断功能
        if let c = comm, !c.isEmpty {
            let fp = CryptoBox.sha256(c).map { String(format: "%02x", $0) }.joined()
            let saved = store.getString(.integrityFingerprint)
            if saved != fp {
                store.setString(fp, for: .integrityFingerprint)
                if saved != nil {
                    notes.append("密钥已更新，指纹已刷新")
                    FileLogger.shared.info(
                        "communicationKey 指纹变化 → 已刷新（配对/应用内置/恢复备份属正常写入）",
                        module: "密钥")
                }
            }
        }

        keyIntegrityOK = problems.isEmpty
        keyIntegrityDetail = problems.isEmpty
            ? (notes.isEmpty ? "通过（密钥存在且指纹一致）" : "通过（\(notes.joined(separator: "；"))）")
            : problems.joined(separator: "；")
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

    /// Intent 调用代号 —— 兜底定时器据此判断「自己是否还是当前那一轮」。
    private var intentGeneration = 0

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
        // ★ 代号（generation）：兜底定时器只允许结束**自己那一轮**的 Intent。
        //
        // 原来 `Task { sleep(timeout); resolveIntent(false) }` 成功后不取消、
        // 也无法区分归属，于是连说两条指令（解锁 → 闭锁）时，
        // 第一条留下的定时器会把第二条的续体以 false 结束 —— Siri 报失败，
        // 而车其实执行了。
        intentGeneration &+= 1
        let gen = intentGeneration
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            intentContinuation = cont
            perform(action)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.intentGeneration == gen else { return }
                // ★ 超时即放弃这轮：顺手清掉「等连接后补发」的动作，
                //   否则 Siri 已经报失败，链路就绪后命令仍会发出 ——
                //   用户重试一次，后备箱这种 toggle 命令就会被翻两次。
                if self.pendingActionAfterConnect != nil {
                    self.pendingActionAfterConnect = nil
                    self.cancelPendingActionWatchdog()
                    self.measured.recordNote("Intent 超时，已放弃挂起的「\(action.label)」")
                }
                self.resolveIntent(false)
            }
        }
    }

    /// 结束 Intent 等待。幂等：已经 resume 过就直接返回。
    private func resolveIntent(_ ok: Bool) {
        guard let cont = intentContinuation else { return }
        intentContinuation = nil
        // ★★ 推进代号，让这一轮留下的 12 秒兜底定时器**立刻失效**
        //   （2026-10-29 全域审查修复）。
        //
        // 原来只清续体、不推进代号，于是定时器 12 秒后醒来时
        // `intentGeneration == gen` 仍然成立，会执行那段「放弃挂起动作」：
        // ```text
        // 0s   Siri「解锁」→ gen=1，定时器 T1 挂在 12s
        // 3s   收到 04 成功 → resolveIntent(true)，T1 仍活着
        // 5s   用户点「闭锁」→ pendingActionAfterConnect = 闭锁 + 15s 看门狗
        // 12s  T1 醒来 → 清掉「闭锁」并 cancelPendingActionWatchdog()
        //      → 命令一帧未发，界面又停在「正在连接，就绪后自动执行…」
        // ```
        // 症状和 v6.1 修的「点了没反应」一模一样，只是换了个入口。
        intentGeneration &+= 1
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
