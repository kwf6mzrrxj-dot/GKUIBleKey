import Foundation
import CoreLocation
// CoreBluetooth 的 delegate 回调是非 Sendable 的旧式 API，
// 用 @preconcurrency 让 Swift 6 放宽隔离检查（回调实际都在主队列，语义不变）。
@preconcurrency import CoreBluetooth

@MainActor
public final class BLECentral: NSObject, ObservableObject {

    public enum LinkState: String, Sendable {
        case idle = "空闲"
        case scanning = "扫描中"
        case connecting = "连接中"
        case discovering = "发现服务"
        case ready = "链路就绪"
        case disconnected = "已断开"
        case failed = "失败"
    }

    @Published public private(set) var managerState: CBManagerState = .unknown
    @Published public private(set) var linkState: LinkState = .idle
    @Published public private(set) var candidates: [DiscoveredDevice] = []
    @Published public private(set) var lastMessage: String = ""
    @Published public private(set) var rxHexStream: [String] = []

    // ── 下列为 PEPS 场景必需的状态量 ──────────────────────────
    /// 最近一次 RSSI（用于信号强度展示与中继攻击提示）
    @Published public private(set) var rssi: Int?
    /// RSSI 最后一次被刷新的时刻
    @Published public private(set) var rssiUpdatedAt: Date?
    /// RSSI 的有效期（秒）。
    ///
    /// 取值依据是**实测广播间隔**，不是想当然的 1–2 秒：日志里同一台车的
    /// 广播间隔分别是 10s / 22s / 28s / 31s / 77s，最长到 17 分钟
    /// （车静止时系统会限流）。所以太短会导致正常扫描中 RSSI 反复消失，
    /// 120 秒既能清掉「已离开范围」的假值，又不会误伤正常间隔。
    public var rssiStaleSeconds: TimeInterval = 120
    /// RSSI 过期看门狗：每收到一次新值就重置，超时则清空
    private var rssiWatchdog: Task<Void, Never>?
    /// 是否启用「连接失败 → 改用扫描重试」的回退（原 App 无自动重连，仅保留扫描回退）
    public var autoReconnect = true

    /// 断连后要不要自动恢复常开扫描。
    ///
    /// 手机端必须为 `true`：原 App 的扫描**常开**（`Docs/evidence/xiaoka_vcc.log`
    /// 里断开事件发生时扫描已经在跑），无感进入的 RSSI 采样、预认证的广播驱动
    /// 全都依赖它。
    ///
    /// 手表端要设 `false`：手表电池只有手机的 1/6，而且手表端**不做**无感进入与
    /// 预认证心跳，只需要「用户点按钮 → 扫一次 → 连 → 发 → 停」。
    /// 常开扫描在手表上纯属耗电，没有对应的收益。
    public var autoScanOnDisconnect = true

    public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        public let isLikelyTarget: Bool
        /// ★ 原 App 的两级判定结果（魔数 → 归属）
        public let matchIdentity: ValeoAdvMatch.Identity
        /// `Gen02` / `Gen03` / `—`
        public let advGen: String
        /// 广播里的 `cryptedID`（归属校验材料，hex）
        public let cryptedID: String
        /// RSSI 低于 -91（原 App 会丢弃，这里只标记，仍展示）
        public let isWeakSignal: Bool

        public init(
            id: UUID, name: String, rssi: Int, isLikelyTarget: Bool,
            matchIdentity: ValeoAdvMatch.Identity = .notValeo,
            advGen: String = "—", cryptedID: String = "", isWeakSignal: Bool = false
        ) {
            self.id = id
            self.name = name
            self.rssi = rssi
            self.isLikelyTarget = isLikelyTarget
            self.matchIdentity = matchIdentity
            self.advGen = advGen
            self.cryptedID = cryptedID
            self.isWeakSignal = isWeakSignal
        }
    }

    /// 收到完整下行帧时回调（已在主线程）。
    public var onFrame: (([UInt8]) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// 扫描到的 CBPeripheral 对象缓存（绕开 iOS 500 条设备缓存淘汰问题）
    private var peripheralCache: [UUID: CBPeripheral] = [:]
    /// 同一设备 `didDiscover` 的节流：记录上次处理时间，避免 AllowDuplicates
    /// 导致的高频重复匹配/日志（同一 identifier 两次处理间隔 < 该值时跳过）。
    private var lastDiscoveryTime: [UUID: Date] = [:]
    /// 节流窗口（秒）—— AllowDuplicates=YES 下设备每秒广播数十次，
    /// 这个窗口内同一设备只做一次匹配与日志。
    private let discoveryThrottle: TimeInterval = 0.5
    /// 上次成功连接的设备标识（用于"不用扫描"的重连路径）
    private var rememberedPeripheralID: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "gkuiblekey.lastPeripheral") else { return nil }
            return UUID(uuidString: s)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "gkuiblekey.lastPeripheral") }
    }

    /// 清除记住的设备标识（解绑时调用，避免解绑后仍用旧车 identifier 重连）。
    public func forgetRememberedPeripheral() {
        UserDefaults.standard.removeObject(forKey: "gkuiblekey.lastPeripheral")
    }

    /// ★ **只读监听**（安全开关）：置位后 `send()` 直接拒绝任何写入。
    ///
    /// 由 `AppModel.listenOnly` 的 `didSet` 同步过来。放在 BLE 层是刻意的 ——
    /// 上层的发送路径不止 `perform` 一条（预认证、配对、被动回 03）。
    public var listenOnly = false

    /// 本次连接里成功写出的帧数。
    ///
    /// 用来区分「正常命令往返后的断开」（车端每条命令都断，属预期）
    /// 与「连上却一帧没发就被踢」（异常，需要计入防死循环的冷却）。
    private var sentFramesThisConnection = 0

    /// 当前设备的 CIDPU（从广播名解析，如 `InBlue3f26c66ac89ad4` → `c89ad4`）
    @Published public private(set) var currentCidpu = ""

    /// ★ **配对等待中自动连接**开关。
    ///
    /// 配对页启动配对流程时置 `true`：此时车端处于配对模式、模块正在广播，
    /// 扫描到第一个有名字的设备就直接连上，让 iOS 走完整 pairing 流程
    /// （弹出 6 位码框）—— 对应原 App「配对不用手动点设备」的行为。
    @Published public var autoConnectWhilePairing = false

    /// 上层是否处于「等待配对」状态（由 `AppModel.pairingArmed` 同步过来）。
    ///
    /// 只用于一个判断：连接失败后要不要无条件连"下一个扫到的设备"。
    /// 不区分的话，**平时**一次连接失败（车走远/缓存过期）也会把
    /// `autoConnectWhilePairing` 置真，下次扫描就会连上第一个 Valeo 设备
    /// —— 停车场里同款车不止一台时可能连错，还会绕过 `forceConnectOnce`
    /// 的按需连接设计。
    public var pairingMode = false

    /// 广播解密出车辆状态明文时的回调（由 AppModel 接到 MeasuredSession）
    public var onBroadcastStatus: (([UInt8]) -> Void)?
    /// ★ 分路 RSSI 回调（由 AppModel 接到标定流程）：
    /// `(antennaNumber, rssi)` —— 广播回调时按 antenna 字段高 4 位分路，
    /// `1`=天线1、`2`=天线2，配合 `PassiveStartJudge` 的标定采样。
    public var onDualRSSI: ((Int, Int) -> Void)?


    /// ★ `didDiscover` 回调计数 —— **诊断"扫描到底有没有工作"的关键指标**。
    ///
    /// - 计数为 0：系统根本没回调 → 权限/适配器/系统限流问题（不是过滤问题）
    /// - 计数 > 0：扫描是工作的，只是设备没进列表 → 逻辑问题
    @Published public private(set) var discoverCount = 0
    /// 最近一次回调到的设备名（诊断用）
    @Published public private(set) var lastDiscoveredName = ""
    /// ★ `centralManagerDidUpdateState` 的调用次数。
    /// **这个值如果是 0，说明 CBCentralManager 的状态回调根本没触发** ——
    /// 那么 `state` 会一直是 `.unknown`，扫描必然静默失败。
    @Published public private(set) var stateUpdateCount = 0

    // ── ★ 位置权限（BLE 扫"全部设备"时 iOS 强制要求）──────────────
    //
    // iOS 的规则：
    //   scanForPeripherals(withServices: [某服务])  → 不需要位置权限
    //   scanForPeripherals(withServices: nil)      → ★ 需要位置权限
    //
    // 而 PEPS 模块的广播包里常常不带 Service UUID，所以必须扫全部 ——
    // 于是位置权限就成了硬性前提。缺权限时 iOS **不会报错**，
    // 只是让 isScanning=true 却零回调，非常容易被误判成"设备不在广播"。
    private let locationManager = CLLocationManager()

    /// `CBCentralManager` 的状态恢复标识。
    ///
    /// 用途：App 被系统终止后，iOS 靠它把 BLE 现场（已连接的外设、
    /// 待投递的通知）交还给新进程，`willRestoreState` 里直接认领即可，
    /// 不用重新扫描连接 —— 这是「后台保持钥匙在线」的基础。
    ///
    /// ⚠️ 整个 App 只能有一个值，且 `resetCentral()` 重建时也必须带同一个，
    /// 否则重建出来的 manager 不受恢复保护。
    private static let restoreIdentifier = "com.mmxisme.gkuiblekey.central"

    /// 位置权限的可读文本（供界面显示）
    @Published public private(set) var locationAuthText = "未决定"

    /// 读取当前位置权限状态
    public func refreshLocationAuth() {
        let s: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            s = locationManager.authorizationStatus
        } else {
            s = CLLocationManager.authorizationStatus()
        }
        switch s {
        case .authorizedAlways: locationAuthText = "已授权（始终）"
        case .authorizedWhenInUse: locationAuthText = "已授权（使用期间）"
        case .denied: locationAuthText = "已拒绝"
        case .restricted: locationAuthText = "受限"
        case .notDetermined: locationAuthText = "未决定"
        @unknown default: locationAuthText = "未知"
        }
    }

    /// 位置权限是否足够用来扫全部设备
    public var hasLocationAuth: Bool {
        locationAuthText.hasPrefix("已授权")
    }

    /// 请求位置权限（iOS 会弹系统框）。
    ///
    /// ★ 后台「靠近解锁」需要 **Always 定位**（配合 `UIBackgroundModes: location`）：
    /// 后台 `scanForPeripherals` 扫描附近车辆依赖定位服务，仅 WhenInUse 无法在
    /// App 退后台后继续扫描。iOS 规则：必须先请求 WhenInUse，用户授权后才能
    /// 升级请求 Always。
    public func requestLocationPermission() {
        refreshLocationAuth()
        if locationAuthText == "未决定" {
            locationManager.requestWhenInUseAuthorization()
            lastMessage = "已请求位置权限，请在系统弹框中允许"
        } else if locationAuthText == "已授权（使用期间）" {
            // 升级到 Always（后台靠近解锁必需）
            locationManager.requestAlwaysAuthorization()
            lastMessage = "已请求「始终」定位权限（后台靠近解锁需要）"
        } else if locationAuthText == "已拒绝" {
            lastMessage = "位置权限已被拒绝，请到「设置 → 隐私与安全性 → 定位服务」里为「蓝牙钥匙」打开"
        } else {
            lastMessage = "位置权限：\(locationAuthText)"
        }
    }
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    /// ★ 照原 App `setReadCharacteristic:`：`peripheral:didDiscoverCharacteristics...`
    /// @`0xa8d4` 把 `F000FF12` **同时**登记为 readCharacteristic。
    /// 原 App 保存它用于后续按特征区分上行数据来源；我们同样保存，
    /// 以便 `didUpdateValue` 能区分「通知数据」与「读取结果」。
    private var readChar: CBCharacteristic?
    /// ★ 照原 App 的 `deviceDidReadyToExchangeData:`（@`0xaac0`）：
    /// 特征发现**一结束**就置位，不等订阅回调。
    ///
    /// 注意：它只是「可交换数据」的状态标记。真正发送仍以**订阅成功**
    /// 为准（原 App 的 `deviceDidSubscriptionDoneWithSuccess:` → `sendData`），
    /// 所以这里不改 `linkState`，避免打乱已验证的发送时机。
    public private(set) var characteristicsReady = false

    // ── 订阅耗时监控（bonding 状态的唯一量化判据）─────────────────────
    //
    // 原 App 日志（`Docs/evidence/xiaoka_vcc.log`）里 344 次订阅的耗时分布：
    //
    // ```
    //   < 0.3s   338 次   ← 中位数 0.056 秒！bonding 已建立，iOS 直接复用 LTK
    //   5–15s      5 次   ← 这 5 次正是「配对」，在等用户输入 PASSKEY
    //   失败       1 次   ← 2.95 秒后 code 15 "Encryption is insufficient."
    // ```
    //
    // 也就是说：
    //   · 订阅 **< 0.3 秒** = 链路已加密（bonding 正常）
    //   · 订阅 **5–15 秒** = 系统弹了 PASSKEY 框
    //   · 订阅 **约 3 秒后失败** = 车端 LTK 与手机不匹配（车端删了配对/清过槽位）
    //
    // 这条判据比 `error.localizedDescription` 更可靠：同样的失败，iOS 有时
    // 只报 "Encryption is insufficient"，有时报 "Failed to encrypt the
    // connection, the connection has timed out unexpectedly"。
    private var notifyRequestedAt: Date?

    // ── 扫描常开（对齐原 App 稳态）─────────────────────────────
    /// 本次连接建立时刻 —— 用于判断"是不是 3 秒内就被断开"
    private var connectedAt: Date?
    /// 连续快速断开次数（3 秒内断开算一次）
    private var quickDisconnectCount = 0
    /// 冷却定时器（连续快速断开 5 次后暂停重扫 30 秒）
    private var scanCooldownTask: Task<Void, Never>?

    /// 强制连接一次（用户点了控车按钮 / 需要发帧时由上层置位）。
    ///
    /// ## 为什么不是「扫到就立刻连」
    /// 原 App 每执行完一条命令，**车端会主动断开**（日志里 `0x05` 到达后 0.2 秒
    /// 就 `device is disconnected`），之后只重扫、不自动重连；下一次连接由
    /// 用户操作或预认证触发（日志里「断开 → Stopping scan → Request for
    /// connection」之间有 6 秒间隔）。
    ///
    /// 我们早期是「命中本车就无条件 connect」，配合扫描常开变成
    /// 「车端断开 → 重扫 → 立刻又连上 → 车端又断」的死循环，耗电且干扰车端会话。
    /// 现在改为按需连接：谁要发帧，谁先置这个标志。
    ///
    /// 置位后下一次扫到本车立刻连接，`didConnect` 里自动清掉。
    public var forceConnectOnce = false

    // ── 出范围判定（照 `-[VCBDevice resetWithTimeout]` @`0x9fb4`）──────
    /// 是否仍在「范围内」：每次收到车端数据都刷新，超过 `outOfRangeSeconds`
    /// 收不到就判定为已远离。
    @Published public private(set) var isInRange = false
    /// 接收超时（秒）。反汇编 `fmov d0, #9.0` → `performSelector:withObject:afterDelay:`
    /// 调 `deviceWhentOutOfRange`，所以原值是 **9 秒**。
    public var outOfRangeSeconds: TimeInterval = 9.0
    /// 判定出范围时的回调（上层据此复位被动进入/预认证的边沿状态）
    public var onWentOutOfRange: (() -> Void)?
    private var rangeTimeoutTask: Task<Void, Never>?

    public override init() {
        super.init()
        // ★★★ 带**状态恢复标识**初始化。
        //
        // `CBCentralManagerOptionRestoreIdentifierKey` 让 iOS 在 App 被系统
        // 回收后，**仍保留这条 BLE 连接**，并在合适时机唤醒 App 恢复现场
        // （配合 Info.plist 的 `UIBackgroundModes: bluetooth-central`）。
        //
        // 这正是"App 在后台一直保持连接"的关键：
        // 没有它，App 一被系统终止，连接就断了，下次打开又要重新连（慢）。
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey:
                        Self.restoreIdentifier])

        // ★ 后台「靠近解锁」需要后台定位（配合 `UIBackgroundModes: location`）。
        //   `allowsBackgroundLocationUpdates` 让 App 退后台后仍能接收定位事件，
        //   从而在后台扫描/发现靠近的车辆。原 App 同样开了这个（见其二进制
        //   `setAllowsBackgroundLocationUpdates:` 字符串）。
        // watchOS 不支持"后台定位更新"这套 API（手表没有常驻后台定位），
        // 手表端也不需要 —— 它只做前台控车。
        #if os(iOS)
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        #endif
        refreshLocationAuth()
    }

    /// ★ 系统恢复 BLE 现场时回调（配合上面的 RestoreIdentifier）。
    ///
    /// 系统会把之前连着的外设一并交还，这里直接认领，**不用重新扫描/连接** ——
    /// 这就是"秒连"的机制。
    public nonisolated func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        // CBPeripheral 不是 Sendable，但该回调由 CoreBluetooth 投递到我们指定的
        // 主队列（`queue: .main`），所以这里的跨隔离传递是安全的。
        nonisolated(unsafe) let restored =
            dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        MainActor.assumeIsolated {
            guard let p = restored.first else { return }
            peripheral = p
            p.delegate = self
            peripheralCache[p.identifier] = p
            rememberedPeripheralID = p.identifier
            linkState = .discovering
            lastMessage = "已从系统恢复连接（\(p.name ?? "无名")），无需重连"
            // 服务/特征可能已被系统缓存，直接走发现流程（发现已是幂等的）
            p.discoverServices([GATT.serviceUUID])
            // ★ 同样要看门狗（2026-10-29 全域审查补）。
            //
            // 当前**没有**启用 `CBCentralManagerOptionRestoreIdentifierKey`，
            // 所以 `willRestoreState` 这条路径在现有配置下不会触发；
            // 但代码在这儿、逻辑是活的 —— 一旦以后开启状态恢复，
            // 没有看门狗就会永久 `.discovering`（和 adopt 那个坑一模一样）。
            // 保持三条 discovering 入口的写法一致，避免下次再漏。
            armDiscoverTimeout()
        }
    }

    // MARK: - 扫描

    /// 开始扫描。
    ///
    /// ## ⚠️ 为什么**不能**用 `withServices` 过滤
    /// 之前写的是 `scanForPeripherals(withServices: [GATT.serviceUUID])`，
    /// 结果是**一个设备都扫不到**。
    /// ★★★ **照原 App 的扫描方式**：按广播里的 16-bit Service `0x10FF` 过滤。
    public func startScan() {
        // ★★★ 照原 App：按广播里的 16-bit Service `0x10FF` 过滤。
        //    之前先用 `F000FF10`（连接后的 GATT UUID）扫、又改成 nil（扫全部），
        //    两者都不对 —— 前者被系统过滤掉，后者需要位置权限且有额外限制。
        let st = stateText(central.state)
        guard central.state == .poweredOn else {
            lastMessage = "❌ 扫描被拒绝：蓝牙适配器 = 「\(st)」，需要「已开启」"
            linkState = .idle
            return
        }
        // ★ 已在连接态就别把状态改成 .scanning（2026-10-29 修复）：
        //   配对成功后 `finishPairingWithReconnect()` 会调本方法，但那时链路
        //   并没有断开，改状态会让 UI 显示「扫描中」、并让后续
        //   `autoConnect()` 对同一条连接重复 discoverServices + 重订阅。
        if linkState != .ready { linkState = .scanning }
        discoverCount = 0
        lastDiscoveredName = ""
        // ★★★ 照原 App：**必须带 `AllowDuplicatesKey: YES`**。
        //
        // 反汇编证据（`ValeoCoreCommunication` `-[VCBManager startScan]` @0x58dc）：
        // ```asm
        // ldr x8, _CBCentralManagerScanOptionAllowDuplicatesKey
        // [NSNumber numberWithBool:YES]
        // [NSDictionary dictionaryWithObjects:forKeys:count:]
        // [central scanForPeripheralsWithServices:arr options:dict]
        // ```
        //
        // 不带这个选项时，iOS 只在**首次发现**某设备时回调一次 `didDiscover`，
        // 之后即使设备还在广播也不再上报 —— 表现为"要等很久才能发现/弹窗"。
        // 原 App 之所以秒发现，就是靠它。
        let scanOptions: [String: Any] =
            [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        central.scanForPeripherals(withServices: [GATT.advServiceUUID],
                                   options: scanOptions)
        lastMessage = "✅ 扫描已启动（广播 Service = 10FF，AllowDuplicates=YES，适配器=\(st)）"
    }

    /// **命令完成后恢复扫描**（不改 `linkState`）。
    ///
    /// ## 对齐原 App 的时序（`xiaoka_vcc.log` @06:25:14）
    ///
    /// ```text
    /// 06:25:14:626  Data received {0x0400}      ← 收到 04 成功
    /// 06:25:14:631  Start scan
    /// 06:25:14:638  Scanning                    ← 立刻恢复，**不等断开**
    /// 06:25:14:828  device is disconnected      ← 车端 0.2 秒后才断
    /// ```
    ///
    /// 我们原来是等 `didDisconnectPeripheral` 才 `resumeScanAfterDisconnect()`，
    /// 所以从"发命令"到"断开"这 0.5–1.5 秒里扫描是停的。前台看不出差别，
    /// 但 iOS 判定后台活跃度时，**持续的 BLE 扫描是最强的"仍在工作"信号** ——
    /// 原 App 的后台节奏能稳定在 30 秒，和这个行为很可能有关。
    ///
    /// 这里直接调底层扫描，**不碰 `linkState`**（它此刻是 `.ready`，
    /// 改成 `.scanning` 会让 `connectRemembered()` 误判并触发重复 discoverServices）。
    public func resumeScanIfNeeded() {
        guard central.state == .poweredOn else { return }
        guard linkState == .ready || linkState == .discovering else { return }
        central.scanForPeripherals(
            withServices: [GATT.advServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    public func stopScan() {
        central.stopScan()
        if linkState == .scanning { linkState = .idle }
        // ★ 停止扫描后不再有 RSSI 来源，立刻清掉显示值，
        //   避免界面一直挂着最后一次扫到的信号强度（假信号）。
        clearRSSI()
    }

    /// 收到车端数据后重置「出范围」定时器。
    ///
    /// 对应 `-[VCBDevice resetWithTimeout]` @`0x9fb4`：
    /// ```objc
    /// [self cancelTimeout];
    /// [self performSelector:@selector(deviceWhentOutOfRange) withObject:nil afterDelay:9.0];
    /// ```
    /// 即**每收到一帧就重新计时 9 秒**，超时则判定设备已远离。
    /// 原 App 靠它复位被动进入的边沿判断；我们之前完全没有这条，
    /// 导致「连着但走远」时不会复位，回来可能不再触发一次。
    private func resetRangeTimeout() {
        if !isInRange { isInRange = true }
        rangeTimeoutTask?.cancel()
        let timeout = outOfRangeSeconds
        rangeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            guard self.isInRange else { return }
            self.isInRange = false
            self.note("\(Int(timeout)) 秒未收到车端数据 → 判定出范围"
                      + "（照 VCBDevice resetWithTimeout deviceWhentOutOfRange）",
                      level: .warning)
            self.onWentOutOfRange?()
        }
    }

    private func cancelRangeTimeout() {
        rangeTimeoutTask?.cancel()
        rangeTimeoutTask = nil
        isInRange = false
    }

    /// 清空 RSSI 显示值并停掉看门狗
    private func clearRSSI() {
        rssiWatchdog?.cancel()
        rssiWatchdog = nil
        rssi = nil
        rssiUpdatedAt = nil
    }

    /// 收到新 RSSI 后重启看门狗；`rssiStaleSeconds` 内没有新广播就清空。
    ///
    /// 为什么需要它：`rssi` 只有「扫描到本车广播」这一个来源（原 App 连接后
    /// 不做 readRSSI，我们也不做，避免干扰 bonding 协商）。所以必须靠超时
    /// 反推「已离开范围」，否则界面会永远停留在最后一次的值。
    private func armRSSIWatchdog() {
        rssiWatchdog?.cancel()
        let timeout = rssiStaleSeconds
        rssiWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.rssi = nil
            self?.rssiUpdatedAt = nil
        }
    }

    // MARK: - 连接

    /// ★ **不用扫描的连接方式**：取系统已经连接/配对的外设。
    ///
    /// 适用场景（也正是车主问的"被动匹配"）：
    /// 车辆模块已经和 iPhone 在**系统层**配对过（「设置 → 蓝牙」里能看到），
    /// 此时 App **不需要扫描**，直接把它取过来即可。
    ///
    /// 两条子路径：
    /// 1. `retrieveConnectedPeripherals` —— 系统当前已连接的（最快）
    /// 2. `retrievePeripherals(withIdentifiers:)` —— 用之前记住的 identifier
    @discardableResult
    public func connectSystemPaired() -> Bool {
        guard central.state == .poweredOn else {
            lastMessage = "蓝牙未就绪（\(central.state.rawValue)）"
            return false
        }

        // ① 系统已连接的外设
        let connected = central.retrieveConnectedPeripherals(withServices: [GATT.serviceUUID])
        if let p = connected.first {
            peripheralCache[p.identifier] = p
            lastMessage = "发现系统已连接的车辆模块（\(p.name ?? "无名")），正在连接…"
            connect(p)
            return true
        }

        // ② 之前记住的 identifier
        if let saved = rememberedPeripheralID {
            if let p = central.retrievePeripherals(withIdentifiers: [saved]).first {
                peripheralCache[p.identifier] = p
                lastMessage = "用已记住的设备标识重连…"
                connect(p)
                return true
            }
        }

        lastMessage = "系统里没有已连接的车辆模块 —— 需要先在「设置 → 蓝牙」配对，或改用扫描"
        return false
    }

    /// 连接所有候选设备中的第一个（回退路径）。
    public func connect(_ device: DiscoveredDevice) {
        // ⚠️ 关键：优先用扫描时缓存的 CBPeripheral 对象直接连。
        //
        // 不能只靠 retrievePeripherals(withIdentifiers:)：iOS 的蓝牙设备缓存
        // 上限是 500 条（日志实证 "Device cache size exceeded limit 500
        // (fDeviceLRUList size 501)"），超限即按 LRU 淘汰；车辆模块一旦被淘汰，
        // identifier 就查不到了，retrievePeripherals 返回空 → 连接失败 →
        // 只能重新扫描，白白耗掉时间（这正是"要点很多次"的一个隐藏成因）。
        if let cached = peripheralCache[device.id] {
            connect(cached)
            return
        }
        // 退路：真的没缓存时才走 retrieve
        if let p = central.retrievePeripherals(withIdentifiers: [device.id]).first {
            peripheralCache[device.id] = p
            connect(p)
            return
        }
        lastMessage = "设备已从系统缓存中淘汰，请重新扫描"
        linkState = .idle
    }

    /// 立刻连接「上次连过的车」—— **不等扫描广播**。
    ///
    /// ## 为什么需要
    ///
    /// 车端在每条命令执行完会**主动断开**（原 App 日志同样如此：
    /// `0x05` 状态包到达后约 0.2 秒就 `device is disconnected`）。
    /// 用户再点按钮时，如果走「扫描 → 等广播 → 连接」：
    ///
    /// ```
    /// AllowDuplicates = YES 下广播间隔 1–2 秒 → 最多等 2 秒才拿到 didDiscover
    /// + 连接握手 ~0.5 秒 + 订阅 ~0.05 秒
    /// ```
    ///
    /// 用户感知就是「点了以后断联几秒」。
    ///
    /// `CBCentralManager.retrievePeripherals(withIdentifiers:)` **不需要扫描**
    /// 就能拿到已绑定外设的 `CBPeripheral`，拿到即可 `connect`，
    /// 延迟降到一次连接握手。
    ///
    /// - Returns: `true` 表示已发起连接（或本来就在连/已连）；`false` 表示
    ///   没有已知设备，调用方应回退到扫描。
    @discardableResult
    public func connectRemembered() -> Bool {
        guard central.state == .poweredOn else { return false }
        switch linkState {
        case .ready:
            // ★ 「标记为就绪」不等于「真的可写」。
            //
            // `writeChar` 会在订阅失败、`prepareForPairingScan`、特征回调异常
            // 等场景下被清空，而 `linkState` 可能还停在 `.ready`。
            // 此时若直接返回 true，上层 `perform` 会挂起动作、等一个
            // **永远不会到来的** `.ready` 事件（状态没变就不会再发），
            // 只能靠 15 秒看门狗兜底 —— 白等，体验差。
            //
            // 这里直接判「假就绪」并拆链重连，把 15 秒缩短成 1 秒。
            guard writeChar != nil else {
                note("链路标记「就绪」但写特征缺失（假就绪）→ 断开重连", level: .warning)
                if let q = peripheral, q.state != .disconnected {
                    suppressAutoReconnect = false
                    central.cancelPeripheralConnection(q)
                }
                peripheral = nil
                notifyChar = nil
                linkState = .idle
                return false
            }
            return true                      // 已连且可写，无需重复
        case .connecting, .discovering:
            // ★★ 「看起来在忙」不等于「真的在推进」。
            //
            // 判据是**看门狗是否在跑**：只有超时任务存在，才说明这条流程
            // 有人管、到点会自动收尾。没有看门狗却停在 connecting/discovering
            // = 僵尸态（回调丢了、流程悬空），此时返回 true 就是欺骗上层：
            // `perform` 会以为「正在连」而跳过 `startScan()`，
            // **既不连接也不扫描，动作永久悬空** —— 用户看到「点了没反应」。
            //
            // 实测（22:00:32）：`adoptConnectedPeripheral` 接管了系统遗留连接，
            // 置 discovering 却没起看门狗 → 14 秒零事件、零超时。
            if connectTimeoutTask != nil || discoverTimeoutTask != nil {
                return true
            }
            note("链路停在「\(linkState.rawValue)」但没有超时看门狗（僵尸态）"
                 + " → 清理后重新发起连接", level: .warning)
            cancelConnectTimeout()
            cancelDiscoverTimeout()
            if let q = peripheral {
                suppressAutoReconnect = false   // 让 didDisconnect 正常收尾 + 重扫
                central.cancelPeripheralConnection(q)
            }
            peripheral = nil
            writeChar = nil
            notifyChar = nil
            linkState = .idle
            return false
        default:
            break
        }
        guard let id = rememberedPeripheralID else { return false }
        let p = peripheralCache[id]
            ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else { return false }
        peripheralCache[p.identifier] = p
        note("直接连接已知设备 \(p.name ?? id.uuidString)（不等扫描广播）")
        connect(p)
        return true
    }

    /// 同时更新界面文案与日志文件。
    ///
    /// 为什么必须双写：连接 / 服务发现 / 特征发现 / 订阅这四步原先**只写界面**
    /// （`lastMessage`），失败后日志里完全看不到"到底连上没、订阅成没成"。
    /// 而「订阅成功」是 BLE bonding（SMP 加密）已建立的**唯一可见证据**
    /// —— 对应原 App 的 `Notification updated for %@ device.`。
    /// 车端只在加密链路上受理业务帧，所以这一行有没有，直接决定成败判断。
    private func note(_ msg: String, level: LogLevel = .info) {
        lastMessage = msg
        switch level {
        case .debug:   FileLogger.shared.debug(msg, module: "链路")
        case .info:    FileLogger.shared.info(msg, module: "链路")
        case .warning: FileLogger.shared.warning(msg, module: "链路")
        case .error:   FileLogger.shared.error(msg, module: "链路", includeStack: false)
        }
    }

    public func connect(_ p: CBPeripheral) {
        // ★ 照原 App `-[VCBDevice connect]` @`0x8de4` 的前置检查（L3）：
        //   `if ([self isConnectable]) { if ([self state] != 0) → 报
        //   "The device is not disconnected" 并返回；否则才真正 connect }`
        //   即**只有断开态才发起连接**，已连接/连接中不重复 connect。
        if p.state != .disconnected {
            if p.state == .connected {
                // ★ 已经是同一条就绪链路 → 什么都不用做（2026-10-30 修复）。
                //
                // 原来这里无条件重新 `discoverServices` + `setNotifyValue`，
                // 导致 `.ready` 被**打回** `.discovering`。触发链：
                // ```text
                // ready 后 resumeScanIfNeeded() 仍在扫描（这是刻意的）
                //   → didDiscover 又扫到本车
                //   → forceConnectOnce 之前没清（复用分支不会走 didConnect）
                //   → 再进这里 → linkState 从 ready 打回 discovering
                //   → 重复 discoverServices / setNotifyValue
                //   → 若 didUpdateNotificationState 不回（已 notifying 的特征
                //      iOS 可能不回调）→ 15s 后把一条好链路 cancel 掉
                // ```
                if linkState == .ready, peripheral === p {
                    forceConnectOnce = false
                    return
                }
                // 已连接：直接进入服务发现（复用现有连接，不 cancel、不重连）
                note("设备已连接，直接发现服务")
                linkState = .discovering
                peripheral = p
                p.delegate = self
                p.discoverServices([GATT.serviceUUID])
                // ★ 必须清「一次性强制连接」标志：这条分支不会触发 `didConnect`，
                //   而 `didConnect` 曾是唯一的清零点 —— 标志残留会配合
                //   `resumeScanIfNeeded` 形成上面那个反复降级的循环。
                forceConnectOnce = false
                // ★ 必须起看门狗（2026-10-29 全域审查补）。
                //
                // 这是**高频活路径**：车端每条命令后主动断开，但 iOS 侧可能
                // 还认为「连着」（`p.state == .connected`），下次 `connect()`
                // 就走这条复用分支。若 `discoverServices` 的回调不来
                // （车端上一次会话没释放 / 信号弱到 GATT 请求无响应），
                // 就会永久停在 `.discovering`：
                // `connectRemembered()` 判僵尸态、`autoConnect()` 早退、
                // 用户点按钮全部石沉大海。
                armDiscoverTimeout()
            } else {
                note("设备状态 \(p.state.rawValue)（连接中），跳过重复连接", level: .warning)
            }
            return
        }
        // ★ 先把状态切到 .connecting，**再** stopScan()。
        //   反过来会让 stopScan 把 `.scanning` 改成 `.idle`，上层把 `.idle`
        //   当断连处理（复位预认证边沿态），预认证续发链被自己掐断。
        linkState = .connecting
        stopScan()
        peripheral = p
        p.delegate = self
        note("正在连接 \(p.name ?? p.identifier.uuidString)…")
        // 连接后系统如需 MITM 配对（6 位码）会自动弹窗，App 无需干预
        // 原 App 同款：`connectPeripheral:options: nil`（`0x5de0: mov x3, #0`）
        central.connect(p, options: nil)
        armConnectTimeout()
    }

    /// 起「连接阶段」看门狗。只覆盖 `.connecting`，不管 `.discovering`
    /// （订阅慢是正常现象，配对弹 PASSKEY 框时实测可到 5–15s）。
    /// 取消连接后若 1.5 秒仍停在 `.failed`，说明 `didDisconnect` /
    /// `didFailToConnect` **一个都没来** —— 自己收尾，别把链路留在无人看守的死态。
    ///
    /// ## 为什么需要（2026-10-30）
    ///
    /// 两个超时看门狗存在的**唯一理由**就是「回调一个都不来」。但同一段失败
    /// 同样会让 `cancelPeripheralConnection` 不产生回调（对**尚未建立**的
    /// `.connecting` 尤其如此）：此时看门狗已消耗完、`linkState = .failed`、
    /// 扫描没重启、也没有任何计时器 —— **完全无出路**。
    /// 日志里会写「放弃并重扫」，但实际并没有重扫。
    private func scheduleLinkCleanupFallback() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.linkState == .failed else { return }
            self.note("取消连接后 1.5s 未收到断开回调 → 自行收尾并重扫", level: .warning)
            self.peripheral = nil
            self.writeChar = nil
            self.notifyChar = nil
            self.linkState = .idle
            self.resumeScanAfterDisconnect()
        }
    }

    private func armConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.connectTimeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard self.linkState == .connecting else { return }
            self.note("连接超时（\(Int(Self.connectTimeoutSeconds))s 未完成），放弃并重扫",
                      level: .warning)
            self.linkState = .failed
            if let q = self.peripheral {
                self.suppressAutoReconnect = false   // 让 didDisconnect 正常收尾 + 重扫
                self.central.cancelPeripheralConnection(q)
                // ★ 回调可能永远不来（见 scheduleLinkCleanupFallback）
                self.scheduleLinkCleanupFallback()
            } else {
                self.resumeScanAfterDisconnect()
            }
        }
    }

    private func cancelConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    /// 起「服务发现」看门狗。`didConnect` 里调，`linkState = .ready` 时撤销。
    private func armDiscoverTimeout() {
        discoverTimeoutTask?.cancel()
        // 配对时要弹 PASSKEY 框，5–15s 属正常，给更宽的窗口
        let secs: TimeInterval = pairingMode ? 30 : 15
        discoverTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            discoverTimeoutTask = nil
            guard self.linkState == .discovering else { return }
            self.note("服务发现超时（\(Int(secs))s 未完成）→ 放弃并重扫", level: .warning)
            self.linkState = .failed
            if let q = self.peripheral {
                self.suppressAutoReconnect = false   // 让 didDisconnect 正常收尾 + 重扫
                self.central.cancelPeripheralConnection(q)
                // ★ 回调可能永远不来（见 scheduleLinkCleanupFallback）
                self.scheduleLinkCleanupFallback()
            } else {
                self.resumeScanAfterDisconnect()
            }
        }
    }

    private func cancelDiscoverTimeout() {
        discoverTimeoutTask?.cancel()
        discoverTimeoutTask = nil
    }

    public func disconnect() {
        // ★ 手动断开：抑制自动重连（否则 didDisconnectPeripheral 会立刻重连回来）
        //
        // ⚠️ 只在本机确实连着的时候置位（2026-10-29 修复）：
        //   对**已断开**的外设调 `cancelPeripheralConnection` 不会产生
        //   `didDisconnectPeripheral`，标志就永远没人消费 → 之后每次车端断开
        //   都被抑制 → 扫描再也不重启，点按钮永远停在「正在连接车辆…」。
        if let p = peripheral, p.state != .disconnected {
            suppressAutoReconnect = true
            central.cancelPeripheralConnection(p)
        } else {
            suppressAutoReconnect = false
        }
    }

    /// 强制拆掉当前链路并重新扫描 —— **不管链路处于什么状态**。
    ///
    /// ## 为什么不直接 `disconnect()` + `startScan()`
    ///
    /// `disconnect()` 在确实连着时会置 `suppressAutoReconnect = true`，
    /// 于是异步的 `didDisconnectPeripheral` 走抑制分支**直接 return，不重扫**；
    /// 而紧跟着的 `startScan()` 又把 `linkState` 改成 `.scanning`，
    /// 随后 `didDisconnect` 再把它覆盖成 `.disconnected` —— 扫描在跑、界面显示
    /// 「已断开」，状态自相矛盾。
    ///
    /// 这里按「有没有活跃连接」分成两条正确的路径：
    /// - 有连接 → 不抑制，取消后让 `didDisconnect` 走**正常收尾 + 重扫**
    /// - 无连接 → 直接清干净并立即重扫
    public func resetLinkAndRescan() {
        cancelConnectTimeout()
        cancelDiscoverTimeout()
        suppressAutoReconnect = false          // 让 didDisconnect 正常收尾 + 重扫
        if let p = peripheral, p.state != .disconnected {
            central.cancelPeripheralConnection(p)
            return                             // 交给 didDisconnect → resumeScanAfterDisconnect
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        linkState = .idle
        resumeScanAfterDisconnect()
    }

    /// 当前连接中的外设（供配对流程主动断开用）。
    public var currentPeripheral: CBPeripheral? { peripheral }

    /// 主动断开指定外设（不触发 `autoReconnect` 的自动重连）。
    public func cancelConnection(_ p: CBPeripheral) {
        // ★ 同 `disconnect()`：只在真的连着时置抑制位，避免标志残留
        guard p.state != .disconnected else {
            suppressAutoReconnect = false
            return
        }
        suppressAutoReconnect = true
        central.cancelPeripheralConnection(p)
    }

    /// ★ 是否抑制下一次断连的自动重连（手动断开/解绑/配对前重置时置位）。
    private var suppressAutoReconnect = false

    /// 连接阶段的看门狗（`connect()` 起表，`didConnect` / `didFailToConnect` 撤销）。
    ///
    /// 没有它的话，`didConnect` / `didFailToConnect` **一个都不来**时
    /// `linkState` 会永远停在 `.connecting`：`autoConnect()` 直接早退、
    /// `connectRemembered()` 又对 `.connecting` 返回 true 却不做事，
    /// 界面永久停在「正在连接车辆…」，只能杀 App。
    /// 连到已被系统淘汰的 `CBPeripheral` 时很容易出现。
    private var connectTimeoutTask: Task<Void, Never>?

    /// 连接阶段超时（秒）。正常连接 < 1s，留足余量。
    private static let connectTimeoutSeconds: TimeInterval = 10

    /// 服务发现阶段超时（秒）。
    ///
    /// 「发现服务」(`.discovering`) 正常只存在 **0.04–0.17 秒**（日志实证），
    /// 配对弹 PASSKEY 框时会拉长到 5–15 秒。所以这里给 15 秒（配对 30 秒）。
    ///
    /// 没有它的话，`didDiscoverServices` 回调不来（车端忙 / 上一次会话没释放 /
    /// 信号弱到 GATT 请求无响应）就会**永久停在「发现服务」**：
    /// `connectRemembered()` 对 `.discovering` 返回 true 却不做事，
    /// `autoConnect()` 早退，用户点任何按钮都变成「连接后自动执行」然后石沉大海。
    /// 实测 2026-10-29 19:05–19:06 就是这个状态。
    private var discoverTimeoutTask: Task<Void, Never>?

    /// 配对扫描前复位连接相关状态，确保进入「干净扫描」。
    ///
    /// 清空写/通知特征、置 idle，但不碰 `autoConnectWhilePairing`
    /// （由调用方在 `startScan` 前设置）。
    public func prepareForPairingScan() {
        writeChar = nil
        notifyChar = nil
        peripheral = nil
        // ★ 复位抑制标志：配对前 `cancelConnection` 置位的 `suppressAutoReconnect`
        //   会因「旧连接断开回调被忽略」而残留，若不复位会抑制「配对成功后车端
        //   断开」的自动重连。这里清掉，让配对后的重连走正常自动重连。
        suppressAutoReconnect = false
        linkState = .idle
    }

    // MARK: - 发送

    /// 写入一帧（走写特征 F000FF11）。
    ///
    /// ## ★ 只读监听在这里统一拦截（2026-10-29）
    ///
    /// `AppModel.listenOnly` 原来只在 `perform` / `setPassiveEntry` 里守卫，
    /// 但**预认证 `0x0C`**（`preAuth.onSend → beginMeasuredAuth`）和
    /// **配对 `0x0D`**（`beginMeasuredAuthPairing`）不走 `perform` ——
    /// 用户勾了「只读监听」，实际仍在发加密命令。这里放在唯一的写入口，
    /// 任何上层路径都绕不过去。
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        guard !listenOnly else {
            lastMessage = "只读监听：已拦截发送（\(bytes.count)B）"
            FileLogger.shared.info(
                "只读监听拦截发送：\(FrameCodec.hexString(bytes))", module: "TX")
            return false
        }
        guard let p = peripheral, let c = writeChar else {
            lastMessage = "写特征未就绪"
            return false
        }
        guard !bytes.isEmpty else { return false }
        let data = Data(bytes)
        // ★★★ 写入类型：优先 Write Command（`.withoutResponse`）。
        //
        // **反汇编依据**（`-[VCBDevice sendData:]` @`0x99c4`，已核对）：
        //   ```asm
        //   0x9bf4: bl  objc_msgSend        ; [self writeCharacteristic] → CBCharacteristic
        //   0x9c00: mov x23, x0             ; characteristic
        //   0x9c04: mov w4, #1              ; ★ type = 1 = CBCharacteristicWriteWithoutResponse
        //   0x9c0c: mov x1, #sel(writeValue:forCharacteristic:type:)
        //   0x9c10: mov x2, x27             ; data
        //   0x9c14: mov x3, x23             ; characteristic
        //   ```
        //   `writeValue:forCharacteristic:type:` 参数位是 x2=data / x3=char / x4=type，
        //   所以 `w4 = 1` 即 Write Command。
        //
        // 注：此前这里引用过一条「2026-10-04 HCI 抓包」的说法，该结论已按用户要求作废，
        // 现仅以反汇编为准。
        let type: CBCharacteristicWriteType
        if c.properties.contains(.writeWithoutResponse) {
            type = .withoutResponse
        } else if c.properties.contains(.write) {
            type = .withResponse
        } else {
            type = .withoutResponse
        }
        // iOS 27 SDK 已把 forCharacteristic: 重命名为 for:
        //
        // ★★★ 分包：对齐原 App `-[VCBTransportProtocolManager splitData:withMTU:]` @0xdcac
        //
        // 反汇编事实：
        //   · 包数 = `ceil((len + 4) / mtu)`（`add x8,x0,#4` → `fdiv` → `fcvtpu`）
        //   · **每包数据量 = MTU − 4**（`sub x8, x20, #4`）
        //   · 首包前置 **4 字节头 = 包数（小端 uint32）**
        //     （`str x23,[sp,#0x28]` 存包数 → `dataWithBytes:&count length:4`）
        //   · 首包 = 4B 头 + (MTU−4)B 数据 = 正好 MTU；后续每包 MTU 字节
        //
        // 注意：MTU 足够时（实测车端 182，最大帧 62B）**只会有 1 包**，
        // 此时保持「整帧直发、不加头」——这是已验证可用的路径（车端能正常回 0x0E），
        // 不引入额外 4 字节以免改变已工作行为。
        // ★ 按**实际写入类型**取 MTU（2026-10-29 修复）。
        //   原来固定取 `.withoutResponse`，若特征只有 `.write`（write request）
        //   会拿到 0/23，maxPayload 掉到 20，整条协议被塞进"多包路径"。
        let mtu = max(p.maximumWriteValueLength(for: type), 24)
        let maxPayload = mtu - 4
        if bytes.count <= maxPayload {
            p.writeValue(data, for: c, type: type)
        } else {
            // 多包路径（MTU 偏小时才触发）
            //
            // ★ 包数公式必须算上首包的 4 字节头（2026-10-29 修复）：
            //   反汇编是 `ceil((len + 4) / mtu)`，原来写成了 `ceil(len / mtu)`，
            //   于是 179 字节 @ mtu=182 会被算成 1 包（实际需要 2 包），
            //   车端按头里的包数只收首包 → 帧被截断。
            let packetCount = (bytes.count + 4 + mtu - 1) / mtu
            var header = UInt32(packetCount).littleEndian
            var first = Data(bytes: &header, count: 4)
            first.append(contentsOf: bytes[0..<maxPayload])
            p.writeValue(first, for: c, type: type)
            FileLogger.shared.debug("→ 分包 1/\(packetCount) 头=\(packetCount) "
                                   + FrameCodec.hexString([UInt8](first)), module: "TX")
            var offset = maxPayload
            var idx = 2
            while offset < bytes.count {
                let end = min(offset + mtu, bytes.count)
                let chunk = [UInt8](bytes[offset..<end])
                p.writeValue(Data(chunk), for: c, type: type)
                FileLogger.shared.debug("→ 分包 \(idx)/\(packetCount) "
                                       + FrameCodec.hexString(chunk), module: "TX")
                offset = end
                idx += 1
            }
        }
        rxHexStream.append("\(Self.stamp())  →  \(FrameCodec.hexString(bytes))"
                         + "  [\(type == .withoutResponse ? "Command" : "Request")]")
        FileLogger.shared.debug("→ \(FrameCodec.hexString(bytes))"
                               + " [\(type == .withoutResponse ? "Command" : "Request")]", module: "TX")
        trimStream()
        sentFramesThisConnection += 1
        lastMessage = "已发送 \(bytes.count) 字节"
        return true
    }

    public var isWriteReady: Bool { peripheral != nil && writeChar != nil }

    // MARK: - 内部

    private func trimStream() {
        if rxHexStream.count > 300 { rxHexStream.removeFirst(rxHexStream.count - 300) }
    }

    /// 统一时间戳（毫秒级），便于和使用抓包工具的时间对齐。
    static func stamp() -> String {
        Self.stampFormatter.string(from: Date())
    }

    /// 时间戳格式器（复用，避免高频收发时反复创建 DateFormatter 的开销）
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// 蓝牙适配器状态的可读文本（**供界面显示**）。
    ///
    /// ⚠️ 这个必须显示出来：如果状态是「未授权」或「未开启」，
    /// 扫描会**静默失败**（不报错、不回调、列表为空），
    /// 从界面上看就像"App 坏了"，其实只是权限/开关问题。
    public var bluetoothStatusText: String { stateText(central.state) }

    /// 蓝牙是否处于可用状态
    public var isBluetoothReady: Bool { central.state == .poweredOn }

    private func stateText(_ s: CBManagerState) -> String {
        switch s {
        case .poweredOn: return "已开启"
        case .poweredOff: return "未开启"
        case .unauthorized: return "未授权"
        case .unsupported: return "不支持"
        case .resetting: return "重置中"
        default: return "未知"
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentral: CBCentralManagerDelegate {

    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            stateUpdateCount += 1
            managerState = central.state
            lastMessage = "蓝牙状态：\(stateText(central.state))"
            if central.state != .poweredOn { linkState = .idle }
        }
    }

    /// ★ 重建 `CBCentralManager`。
    ///
    /// 当状态卡在 `.unknown`（`stateUpdateCount == 0`）时使用 ——
    /// 这种"回调从未触发"的情况，iOS 有时重建一次就好了。
    public func resetCentral() {
        central?.delegate = nil
        // ★ 重建时**必须**带上同一个 RestoreIdentifier，否则新的 manager
        //   不再受系统状态恢复保护：App 被终止后不会再被 BLE 事件唤醒，
        //   「后台保持连接」的能力就没了。
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
        managerState = central.state
        lastMessage = "已重建蓝牙管理器（当前状态：\(stateText(central.state))）"
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // 先在非隔离上下文里把需要的数据摘出来：
        // advertisementData 是 [String: Any]（非 Sendable），不能带进 MainActor。
        let advLocalName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let peripheralName = peripheral.name
        let peripheralID = peripheral.identifier
        let rssiValue = RSSI.intValue
        let advName = advLocalName ?? peripheralName ?? ""
        // 广播里的 Service UUID 也要摘出来 —— 有些模块广播名不合但 Service 对
        let advServiceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map { $0.uuidString.uppercased() } ?? []
        // ★ 厂商数据 = 加密的广播载荷（`parseBroadcastData:` 的输入）
        let mfgData = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
            .map { [UInt8]($0) } ?? []

        MainActor.assumeIsolated {
            // ★ 广播计数：给「后台保活」日志提供「还在不在收广播」的硬指标。
            //   进程被挂起时这个数会停止增长，是最直接的证据。
            //   （必须放在 MainActor 块里：`BackgroundMonitor` 是 @MainActor 隔离的）
            BackgroundMonitor.shared.noteBroadcast()
            // ★★★ 保存广播原始数据 + 解析 CIDPU —— 这是构造 01 帧的前提。
            //     原 App 的 `parseBroadcastData:` 会拿 cidpu 去 AES 解密这段数据。
            if !mfgData.isEmpty {
                // ★★★ CIDPU 的正确来源：**已保存的密钥帧（core）末尾 4 字节**。
                //
                // 实测密钥帧末尾 = `6A C8 9A D4` → CIDPU = `6ac89ad4`，
                // 与车辆详情页显示的「车辆 ID (CIDPU)」完全一致。
                //
                // ⚠️ 之前从**设备名**解析（`InBlue3f26c66ac89ad4` 取后 6 位 = `c89ad4`），
                //    只有 3 字节、不完整，导致 AES 解密的 key 是错的 → 解密必然失败。
                if let cid = BroadcastParser.cidpuFromStoredKey() {
                    currentCidpu = cid
                } else if let cid = BroadcastParser.parseCidpu(from: advName) {
                    currentCidpu = cid      // 兜底：还没配过对时只能从名字猜
                }
                // ★ 把原始数据完整打出来 —— 原 App 的标识信息在厂商数据里
                //   （`isValeoDeviceWithAdvertisingData:` 是拿它前几字节比魔数），
                //   所以必须先看清厂商数据长什么样，才能定位 cidpu / cryptedID。
                FileLogger.shared.debug(
                    "广播名=「\(advName)」 厂商数据 \(mfgData.count)B = "
                    + mfgData.map { String(format: "%02X", $0) }.joined(separator: " "),
                    module: "广播")
                // ★ reSynchro = 厂商数据 [4..6) 的 2 字节（反汇编确认：
                //   `parseAdvertisingGen03:` @`0xbd9c` `mov w2,#4 / mov w3,#2`
                //   → `subdataWithRange:` → 存进 `_reSynchro`）。
                //   原 App 的 `didFoundVehicleRequestPairing`（配对邀请）很可能
                //   就取决于这 2 字节 —— 实测时对比「车端正常态」与「诊断仪开
                //   配对窗口」两种情况下它的值，就能确定判据。
                if mfgData.count >= 6 {
                    let rs = mfgData[4..<6].map { String(format: "%02X", $0) }.joined(separator: " ")
                    let mode = mfgData.count > 6 ? String(format: "%02X", mfgData[6]) : "-"
                    FileLogger.shared.debug(
                        "reSynchro=[\(rs)] mode=\(mode) protocolVersion=\(mfgData.count > 2 ? String(format: "%02X", mfgData[2]) : "-")",
                        module: "广播")
                }
                FileLogger.shared.debug(
                    "cidpu=\(currentCidpu.isEmpty ? "(空)" : currentCidpu), "
                    + "广播Service=[\(advServiceUUIDs.joined(separator: ","))]",
                    module: "广播")
            }
            // ★ 诊断：先记下"回调确实来过"，再谈过滤
            discoverCount += 1
            lastDiscoveredName = advName.isEmpty ? "(无名)" : advName

            // ★ 缓存 CBPeripheral 对象本身，后续连接直接用，
            //   避免 iOS 500 条设备缓存淘汰导致的 retrievePeripherals 失败
            peripheralCache[peripheral.identifier] = peripheral

            // ★★★ 性能节流：AllowDuplicates=YES 下同一设备每秒广播数十次，
            //   每次回调都走 AES 匹配 + 刷多行日志会拖累主线程、撑大日志。
            //   这里对同一 identifier 在节流窗口内只处理一次。
            let now = Date()
            if let last = lastDiscoveryTime[peripheral.identifier],
               now.timeIntervalSince(last) < discoveryThrottle {
                return
            }
            lastDiscoveryTime[peripheral.identifier] = now
            // 节流表也做清理，避免长期扫描下无限增长
            if lastDiscoveryTime.count > 80 {
                let keep = Set(candidates.map { $0.id })
                lastDiscoveryTime = lastDiscoveryTime.filter { keep.contains($0.key) }
            }

            // ★★★ **照原 App 的匹配规则**（`+[VCBAdvertisingData isValeoDeviceWithAdvertisingData:]`
            //     → `-[IBVehicleManager updateVehicleWithDevice:]` → `-[IBDevice checkCryptedID:]`）
            //
            // ⚠️ 之前这里是「广播名包含 INBLUE/GKUI」—— 这是错的：
            //    原 App **从不看广播名**，名称只用于界面显示。真正的判定只有两步：
            //    ① 厂商数据前 2 字节 == `EE 01`（魔数）
            //    ② 用本车 cidpu 对 `cryptedID` 做 AES，密文 [2..6) 应等于广播里的 4 字节校验码
            let cidpuHex = KeyStore.shared.cidpuFullHex ?? ""
            let verdict = ValeoAdvMatch.identify(
                manufacturer: mfgData, cidpuHex: cidpuHex, rssi: rssiValue)
            let identity = verdict.identity
            let adv = verdict.advertisement
            // 原 App 会**直接丢弃**非 Valeo 设备；这里保留在列表里只为诊断，
            // 但 `isLikelyTarget` 严格按原规则给值。
            // ★★★ **只有「本车」和「归属未确认」才算命中**（2026-10-30 修复）。
            //
            // 原写法 `identity != .notValeo` 把 `.otherValeoVehicle`（cryptedID
            // 用本车 cidpu 校验**失败** = 确认是别人的同款车）也算成命中，后果：
            // 1. 停车场里只要有另一台同款车，用户点按钮就会**连上别人的车**；
            // 2. `didConnect` 会把 `rememberedPeripheralID` 覆盖成别人车的
            //    identifier → 此后 `connectRemembered()` 一直连错；
            // 3. 往未授权的车发 `01` 鉴权帧，4 秒超时 690，用户那条指令丢掉；
            // 4. 同一套 `hit` 还驱动 `rssi` 与 `onDualRSSI` → **邻居车的信号
            //    会污染本车的区域判定/标定**，误触发预认证。
            //
            // `.valeoTarget` 必须保留：它是「魔数命中但没有 cidpu，无法确认归属」，
            // 首次配对就是靠这条路径（没有 cidpu 就永远无法确认是本车）。
            let hit = (identity == .ownVehicle || identity == .valeoTarget)
            let weak = Double(rssiValue) <= ValeoAdvMatch.rssiFloor
            // ★ 命中本车时更新 RSSI 显示值。原 App 连接后从不 readRSSI，
            //   所以 RSSI 只能来自广播回调 —— 一旦停止扫描或离开覆盖范围，
            //   就必须靠看门狗把显示值清掉（否则会挂着过期值当实时信号）。
            if hit {
                rssi = rssiValue
                rssiUpdatedAt = Date()
                armRSSIWatchdog()
            }

            if let adv {
                FileLogger.shared.debug(
                    "匹配：\(adv.genLabel) 版本=\(adv.protocolVersion) "
                    + "cryptedID=\(adv.cryptedID.map { String(format: "%02X", $0) }.joined()) "
                    + "→ \(identity.rawValue)"
                    + (weak ? "（RSSI \(rssiValue) ≤ -91，原 App 会丢弃）" : ""),
                    module: "匹配")

                // ★ 分路 RSSI：按 antenna 字段高 4 位分路（0x80=天线1/0x40=天线2），
                //   供标定流程（addRSSI: @0x801c）采集两路 RSSI。
                // ★ 只喂「本车 / 归属未确认」的分路 RSSI（2026-10-30）。
                //   否则邻居同款车的 antenna/RSSI 会进到标定基准里，
                //   把本车的区域阈值带偏。
                if hit, let antennaNo = adv.antennaNumber {
                    onDualRSSI?(antennaNo, rssiValue)
                }

                // ★★★ 车辆状态：照原 App `parseBroadcastData:` @`0x4bc0`。
                //   广播里的 `broadcastData`（Gen03 = 厂商数据 [19,35) 16B）是
                //   用 cidpu 作 AES key 加密的状态密文；解密后明文 [4]/[6]/[7]
                //   分别喂给 parseStatus:/parseDoorsStatus:/parsePowerStatus:。
                //   解密成功就把明文回调给 AppModel → MeasuredSession 更新状态。
                if !adv.broadcastData.isEmpty, !cidpuHex.isEmpty,
                   let decrypted = VehicleStatus.decryptBroadcast(
                       cipher: adv.broadcastData, cidpuHex: cidpuHex) {
                    FileLogger.shared.debug(
                        "车辆状态明文：\(decrypted.plain.map { String(format: "%02X", $0) }.joined(separator: " "))",
                        module: "状态")
                    onBroadcastStatus?(decrypted.plain)
                }
            }

            let dev = DiscoveredDevice(
                id: peripheralID,
                name: advName.isEmpty ? "(无名)" : advName,
                rssi: rssiValue,
                isLikelyTarget: hit,
                matchIdentity: identity,
                advGen: adv?.genLabel ?? "—",
                cryptedID: adv.map { $0.cryptedID.map { String(format: "%02X", $0) }.joined() } ?? "",
                isWeakSignal: weak)
            if let i = candidates.firstIndex(where: { $0.id == dev.id }) {
                candidates[i] = dev
            } else {
                candidates.append(dev)
            }
            // ★★★ 强兜底（优先级最高）：**配对流程等待中**（配对页已 armed）时，
            //    车端正处在配对模式、模块一定在广播 —— 此时连第一个发现的设备，
            //    让 iOS 走完整的 pairing 流程（弹出 6 位码框）。
            //    这正是原 App「配对不用手点」的行为。
            //
            // 2026-10-25 修复：之前这里要求 `!advName.isEmpty` 且排在 hit 判定之后，
            // 导致「车端广播名空 / 配对模式下广播不带 EE 01 魔数」时永远不自动连，
            // 表现为「绑定页收不到配对、要去诊断页点扫描才连得上」。
            // 现在配对等待中时**无条件连第一个发现的设备**（名字空也连）。
            // ★★★ 2026-10-25 修复竞态：之前这里要求 `linkState == .scanning`，
            //     但 `startFullPairing` 里 `cancelConnection` 的异步 `didDisconnect`
            //     会把 `linkState` 从 `.scanning` 覆盖成 `.disconnected`，导致
            //     这个判断永远失败 → 扫描到了设备却不自动连接 → 用户要手动点
            //     状态条（第二次才连上）才弹 6 位码。
            //     现在去掉 linkState 条件：只要配对等待中，就无条件连第一个发现的
            //     设备（autoConnectWhilePairing 连接后即置 false，只连一次）。
            if autoConnectWhilePairing {
                // ★ 先确认 connect 会真的发起（2026-10-30 修复）。
                //
                // 原来先 `= false` 再 `connect()`，而 `connect()` 在 `p.state`
                // 处于 `.connecting`（上一次取消留下的残留）时只打一条 warning
                // 就返回 —— 连接从未发起，标志却已经没了。配对页此后不会再
                // 自动连，永久停在「配对中：扫描并连接车辆模块…」，
                // 而配对阶段本身没有独立看门狗。
                guard peripheral.state == .disconnected || peripheral.state == .connected else {
                    note("配对等待中但设备状态为 \(peripheral.state.rawValue)，保持标志等下一次广播",
                         level: .warning)
                    return
                }
                autoConnectWhilePairing = false       // 只连一次，避免连错多个
                lastMessage = "配对中：自动连接 \(advName.isEmpty ? peripheralID.uuidString : advName) 以触发系统配对…"
                connect(peripheral)
                return
            }

            // 原 App 没有「广播带 Service 就直连」这一步 —— 判定只看厂商数据，
            // 因此这里也只在**判定命中**时考虑连接（弱信号按原规则跳过）。
            //
            // ★★★ 关键修正（v4.4）：只有 `forceConnectOnce` 为真才连接。
            //
            // 之前是「命中本车 + 不在 15 秒冷却期」就连 —— 结果形成
            // **每 15 秒一次的空连接**：
            //
            // ```log
            // 17:33:02.512  正在连接
            // 17:33:03.252  链路就绪（订阅 0.06s）
            // 17:33:05.151  已断开：The specified device has disconnected from us.
            // ```
            //
            // 连上之后**一帧都没发**，车端等约 2 秒就把链路踢掉。用户看到的就是
            // 「总是断联」，而预认证/控车根本没机会执行。
            //
            // 原 App 从不这样：它每次连接都是为了发某个命令
            // （日志里「Request for connection → Data to send」总是成对出现）。
            // 所以改成**按需连接**：谁要发帧，谁先置 `forceConnectOnce`。
            if hit && !weak && forceConnectOnce {
                forceConnectOnce = false
                // 本车优先：已经有归属结论时直接连；未确认归属也连（这是配对新设备的场景）
                lastMessage = "发现目标设备 \(advName.isEmpty ? peripheralID.uuidString : advName)"
                    + "（\(adv?.genLabel ?? "?")·\(identity.rawValue)），正在连接…"
                connect(peripheral)
                return
            }
            // 缓存只在本次扫描会话内有效，避免无限增长
            if peripheralCache.count > 60 {
                let keep = Set(candidates.map { $0.id })
                peripheralCache = peripheralCache.filter { keep.contains($0.key) || $0.key == peripheralID }
            }
        }
    }

    /// ★★★ **接管系统已有的连接**（不做 connect、不做 cancel）。
    ///
    /// ## 为什么需要
    /// 实测现象：**系统蓝牙里显示"已连接"，但 App 卡在"连接中"**。
    /// 原因是 App 在"缓存命中"分支里调了 `cancelPeripheralConnection`
    /// （本意是断开重连以触发配对），结果把 iOS 那条**本来好好的连接也断了**，
    /// 重连又因对象过期而挂起 → 永远卡住。
    ///
    /// 正确做法：`retrieveConnectedPeripherals` 拿到的对象**本来就是已连接状态**，
    /// 直接设 delegate + `discoverServices` 接管即可，**不要 connect、不要 cancel**。
    ///
    /// - Returns: `true` 表示成功接管。
    @discardableResult
    public func adoptConnectedPeripheral() -> Bool {
        guard central.state == .poweredOn else { return false }
        guard let p = central.retrieveConnectedPeripherals(withServices: [GATT.serviceUUID]).first
        else { return false }

        // 已经在用这个对象就不重复接管
        if peripheral?.identifier == p.identifier, linkState == .ready { return true }

        p.delegate = self
        peripheral = p
        peripheralCache[p.identifier] = p
        rememberedPeripheralID = p.identifier
        linkState = .discovering
        lastMessage = "已接管系统连接（\(p.name ?? "无名")），发现服务中…"
        p.discoverServices([GATT.serviceUUID])
        // ★★ 必须和 `didConnect` 一样起看门狗（2026-10-29 实测漏了这条）。
        //
        // 「系统恢复的连接」是**上一个进程遗留**的：新进程的 `CBPeripheral`
        // 是重新 retrieve 出来的对象，`discoverServices` 的回调**不保证会来**
        // （服务已在系统缓存里 / 车端上一次会话没释放 / delegate 刚挂上）。
        //
        // 没有看门狗时实测后果（22:00:32 日志）：
        // ```text
        // 22:00:32.118  进程启动 #14
        // 22:00:32.232  控制中心控件 → 锁车
        // 22:00:32.232  未连接（discovering）→ 连接后自动执行「锁车」
        // 22:00:46.882  ［14 秒内零连接事件、零超时］→ 进后台，动作永久悬空
        // ```
        // 用户看到的就是「点了没反应」。
        armDiscoverTimeout()
        return true
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            BackgroundMonitor.shared.noteConnect()
            cancelConnectTimeout()
            sentFramesThisConnection = 0     // 每轮连接重新计数
            linkState = .discovering
            // ★ 连接已建立 → 消费掉「一次性强制连接」标志。
            //
            // 这个标志本来只在 `didDiscover` 的命中分支里清零，走
            // `connectRemembered()` 直连已知设备时**没人清**，于是一次操作
            // 结束后标志仍为 true：车端断链 → 重扫 → 扫到本车 →
            // `if hit && !weak && forceConnectOnce` 又成立 → 再连一次
            // **什么帧也不发**的空连接（车端 2 秒踢），用户看到「操作成功后
            // 信号又闪断一次」。
            forceConnectOnce = false
            connectedAt = Date()          // ← 「连接存活时长」计时起点（扫描常开的防抖用）
            // ★ 记住这个设备，之后可以「不用扫描」直接重连
            rememberedPeripheralID = peripheral.identifier

            // ★★★ 照原 App `didConnectPeripheral` @0x640c：连接成功后直接
            //     `discoverServices("F000FF10")` → 发现特征后 `setNotifyValue(FF12)`
            //     （访问加密特征时 iOS 自动触发 6 位码配对）+ `setWriteCharacteristic(FF11)`。
            //     **原 App 连接后从不 readRSSI**（readRSSI 只在主 App 层），
            //     所以这里也不做 RSSI 轮询 —— 周期 readRSSI 会干扰 6 位码配对协商。
            note("已连接，发现服务中（只查目标 Service 抢时间）")
            armDiscoverTimeout()
            // 只发现目标服务，避免枚举全部服务浪费时间
            peripheral.discoverServices([GATT.serviceUUID])
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            cancelConnectTimeout()
            cancelDiscoverTimeout()
            // ★ 清「手动断开」抑制标志（2026-10-30 修复）。
            //
            // `disconnect()` / `cancelConnection()` 会置
            // `suppressAutoReconnect = true`，而**只有 `didDisconnectPeripheral`
            // 会消费它**。如果那次取消走的是 `didFailToConnect`（pending 连接
            // 被取消时的常见结果），标志就残留了 —— 下一次**正常**连接执行完
            // 命令、车端主动断开时，`didDisconnect` 命中抑制分支直接 `return`：
            // 不重扫、也不清特征 → 链路显示"已断开"后不再恢复，
            // 预认证的广播驱动一起停摆，直到用户手动点按钮。
            suppressAutoReconnect = false
            // 清连接残留：失败后若 `writeChar` 还挂着，`isWriteReady` 会为真，
            // 上层就敢往一条死链路发帧（4 秒超时 690 的经典来源）。
            if self.peripheral === peripheral {
                self.peripheral = nil
                writeChar = nil
                notifyChar = nil
            }
            linkState = .failed
            note("连接失败：\(error?.localizedDescription ?? "未知")", level: .error)

            // ★★ 回退：连接失败就改用扫描。
            //    系统缓存里的 `CBPeripheral` 有时是过期的（iOS 会淘汰 500 条以上的
            //    设备缓存），直接 connect 会一直失败；此时必须重新扫描拿到新对象。
            guard autoReconnect else { return }
            // ★ 只有「配对等待中」才允许无条件连下一个设备（2026-10-29 修复）。
            //   原来无条件置真，任何一次普通连接失败都会留下这个状态，
            //   下次扫到任意 Valeo 设备就直接连，不校验是不是本车。
            if pairingMode {
                autoConnectWhilePairing = true
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard let self, self.linkState != .ready else { return }
                self.lastMessage = "已自动改用扫描重试…"
                self.startScan()
            }
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            // ★★★ 竞态修复（2026-10-25）：`startFullPairing` 会 `cancelConnection`
            //     旧连接 → 立即 `startScan` → `connect` 新连接。旧连接的**异步**
            //     断开回调若在新连接建立后才触发，会把新连接的 `.scanning/.
            //     discovering/.ready` 覆盖成 `.disconnected`，破坏「首次连接 →
            //     触发 6 位码配对」的时序（表现为首次不弹码，要退出重进才弹）。
            //     修复：只处理「当前连接」的断开，旧连接的异步回调直接忽略。
            guard peripheral === self.peripheral else { return }

            BackgroundMonitor.shared.noteDisconnect()
            cancelConnectTimeout()
            cancelDiscoverTimeout()
            linkState = .disconnected
            writeChar = nil
            notifyChar = nil
            let reason = error?.localizedDescription ?? "正常断开"
            note("已断开：\(reason)", level: .warning)

            // ★ 手动断开 → 消费抑制标志，不做自动重连
            if suppressAutoReconnect {
                suppressAutoReconnect = false
                return
            }

            // ★★★ 照原 App：VCB 层断开**只通知，不自动重连**（M3）。
            //
            // 反汇编 `-[VCBBluetoothManager centralManager:didDisconnectPeripheral:error:]`
            // @`0x69fc` 的完整行为：
            // ```objc
            // VCBDevice *dev = [VCBManager deviceWithIdentifier:p.identifier];
            // if (dev == nil) return;
            // NSLog(@"The %@ device is disconnected.", dev);
            // [dev setState:0];
            // if ([dev.delegate respondsToSelector:@selector(device:didDisconnectWithError:)])
            //     [dev.delegate device:didDisconnectWithError:error];   // 只回调
            // ```
            // 即**没有任何 `connect` 重试**。重连由上层 `autoConnect()`
            // （App 启动/蓝牙就绪/回前台时）或用户手动操作触发。
            //
            // 之前这里的「指数退避自动重连」是自造行为：配对成功后若车端主动断开，
            // 会被反复重连，干扰车端会话，与原 App 不一致。
            characteristicsReady = false
            cancelRangeTimeout()
            note("已断开：\(reason)（原 App 的扫描是常开的，见 resumeScanAfterDisconnect）", level: .warning)
            resumeScanAfterDisconnect()
        }
    }

    // MARK: - ★ 扫描常开（对齐原 App 的稳态）

    /// 原 App 的扫描是**常开**的，不是"用到才扫"。
    ///
    /// 日志证据（`Docs/evidence/xiaoka_vcc.log`）：
    ///
    /// ```text
    /// 17:46:06.988  Start scan
    /// 17:46:07.107  Data received 22B (0x05)
    /// 17:46:07.208  device is disconnected      ← 断开时扫描已经在跑
    /// 17:46:07.311  Stopping scan
    /// 17:46:07.313  Request for connection      ← 车端一广播就 2 毫秒内连上
    /// ```
    ///
    /// 也就是说：**原 App 在断开之前就已经 `Start scan` 了**，
    /// 所以下一条命令到来时无需"先扫再连"，直接命中。
    ///
    /// 我们原来是连接成功即 `stopScan()`、断开后停着不动，
    /// 只能等 `autoConnect()`（启动/回前台）或用户手动操作 ——
    /// 后果有两个：
    /// 1. 无感进入的 RSSI 采样断流（那条链路依赖持续扫描）
    /// 2. 点按钮要等 1–2 秒扫描 + 连接
    ///
    /// ### 防抖
    /// 原 App 没有这个限制，但完全无限制的重扫在车端异常时会形成
    /// 「连上→立刻断开→重扫→再连」的死循环（耗电且干扰车端会话）。
    /// 这里加一条温和的门槛：**3 秒内断开累计 5 次**就暂停 30 秒再恢复。
    /// 正常使用（每条命令一次连接）永远不会触发。
    private func resumeScanAfterDisconnect() {
        guard central.state == .poweredOn else {
            note("断开后未重扫：蓝牙适配器 \(stateText(central.state))", level: .warning)
            return
        }
        // ★ 本轮连接的统计先收尾，与「要不要重扫」无关。
        //   放在早退之前，否则 `connectedAt` 会一直挂着上一轮的值，
        //   下次真正重扫时 `lived` 算出来是个环数（假「快速断开」）。
        let now = Date()
        let lived = connectedAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        connectedAt = nil
        let sentThisRound = sentFramesThisConnection
        sentFramesThisConnection = 0
        guard autoScanOnDisconnect else {
            note("断开后不自动重扫（按需扫描模式）")
            return
        }
        // 连续快速断开计数
        // ★ 只有「**空连接**」（连上却一帧没发就被踢）才算异常快速断开（2026-10-29）
        //
        // 车端的正常行为是：**每执行完一条命令就主动断开**（发完 0x05 后约 0.1 秒），
        // 所以正常的命令往返也常常只有 0.5–1.5 秒存活。原来只看 `lived < 3.0`，
        // 会把每一次正常控车/预认证都记成「快速断开」—— 预认证每 29 秒一轮，
        // 5 轮（约 2.5 分钟）后必然触发「暂停重扫 30 秒」，
        // 表现为**扫描莫名其妙停半分钟、之后一直连不上**。
        if lived < 3.0 && sentThisRound == 0 {
            quickDisconnectCount += 1
        } else {
            quickDisconnectCount = 0
        }
        if quickDisconnectCount >= 5 {
            quickDisconnectCount = 0
            scanCooldownTask?.cancel()
            note("连续 \(5) 次「连上但一帧未发」就被断开 → 暂停重扫 30 秒（防死循环）",
                 level: .warning)
            scanCooldownTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.note("冷却结束，恢复常开扫描")
                self.resumeScanAfterDisconnect()
            }
            return
        }
        note("断开后自动重扫（对齐原 App 的扫描常开）")
        startScan()
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentral: CBPeripheralDelegate {

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            // ★ 照原 App：**必须**匹配目标服务 `F000FF10`，不匹配即失败（L4）。
            //   原 App 没有「用第一个服务兜底」的行为 —— 兜底会连到错误服务，
            //   后续特征发现必然失败且原因被掩盖。
            if let error {
                note("发现服务失败：\(error.localizedDescription)", level: .error)
                linkState = .failed
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == GATT.serviceUUID }) else {
                let all = (peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ",")
                note("未找到目标服务 F000FF10（现有：\(all.isEmpty ? "空" : all)）", level: .error)
                linkState = .failed
                return
            }
            note("已找到目标服务 F000FF10，发现特征中…")
            peripheral.discoverCharacteristics([GATT.writeCharUUID, GATT.notifyCharUUID], for: svc)
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            // ★ 照原 App 的 peripheral → device 映射（`sharedManager` + `deviceWithIdentifier:`
            //   @`0xa5c8`）：SDK 只认识自己跟踪的设备，否则回调
            //   `device:didNotReadyToExchangeDataWithError:` 并报
            //   "The device is nil. The SDK don't know this peripheral."
            //   我们是单设备模型，等价做法是：回调必须来自当前跟踪的那个外设。
            guard let tracked = self.peripheral,
                  peripheral.identifier == tracked.identifier else {
                note("特征发现来自未知外设（原 App：SDK don't know this peripheral）",
                     level: .error)
                linkState = .failed
                return
            }
            // ★ 照原 App 检查 error（L5）
            if let error {
                note("发现特征失败：\(error.localizedDescription)", level: .error)
                linkState = .failed
                return
            }
            for c in service.characteristics ?? [] {
                // ★★ 严格照原 App `peripheral:didDiscoverCharacteristicsForService:error:`
                //    @`0xa53c` 的分支：
                //      UUID == F000FF12-0451-4000-B000-000000000000
                //        → setReadCharacteristic:  (@0xa8d4)
                //        → requestSubcriptionToNotification / setNotifyValue:forCharacteristic:
                //        → setRequestSubcriptionToNotification:
                //      UUID == F000FF11-0451-4000-B000-000000000000
                //        → setWriteCharacteristic: (@0xa904)
                //
                // 之前这里漏了 `setReadCharacteristic:`（只登记了 notify），
                // 是与原 App 的实际差异，现已补齐。
                if c.uuid == GATT.writeCharUUID { writeChar = c }
                if c.uuid == GATT.notifyCharUUID {
                    notifyChar = c
                    readChar = c                      // ← 补：setReadCharacteristic:
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            if writeChar == nil || notifyChar == nil {
                note("特征不完整（write=\(writeChar != nil), notify=\(notifyChar != nil)）", level: .error)
                return
            }
            // ★ 照原 App：特征发现后立即置「可交换数据」并回调，
            //   不等 didUpdateNotificationState（原 App @`0xaa88` setState: +
            //   @`0xaac0` deviceDidReadyToExchangeData:）。
            characteristicsReady = true
            notifyRequestedAt = Date()             // ← 订阅耗时计时起点
            note("特征就绪：write=FF11 / read+notify=FF12，已请求订阅"
                 + "（照原 App 此刻即置 deviceDidReadyToExchangeData）")
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            // ★ 只处理「当前外设」的回调（2026-10-30 修复）。
            //
            // 配对页「退出→重进」或断开后立刻重连时，旧连接的 delegate 仍是 self，
            // 它迟到的 `isNotifying == true` 会被当成**当前**链路订阅成功，
            // 直接把 `linkState` 置成 `.ready` —— 于是上层以为可以发帧，
            // 实际上发出去的是那条已经废弃的链路。
            guard let tracked = self.peripheral,
                  peripheral.identifier == tracked.identifier else {
                note("忽略非当前外设的订阅回调（\(peripheral.identifier.uuidString.prefix(8))）",
                     level: .warning)
                return
            }
            // ★ 订阅耗时 —— 判断 bonding 状态最可靠的量化指标
            //   （原 App 日志 344 次订阅：中位数 0.056s，配对时 5–15s）
            let elapsed = notifyRequestedAt.map { Date().timeIntervalSince($0) } ?? -1
            notifyRequestedAt = nil
            let timing = elapsed >= 0 ? String(format: "%.2fs", elapsed) : "?"
            if error != nil {
                // ★ 这一行是「bonding 失败」的直接证据：原 App 的
                //   `device:didSubcriptionFailedWithError:` 走的就是这里，
                //   此时它**根本不会发 0x0D**。
                note("订阅失败（bonding 未建立）：耗时 \(timing)，\(error!.localizedDescription)",
                     level: .error)
                if elapsed >= 1.0 && elapsed <= 6.0 {
                    note("   ↳ 耗时落在 1–6s 且失败 = 车端 LTK 与手机不匹配。"
                         + "原 App 同一现象实测 2.95s 失败（code 15 Encryption is insufficient）。"
                         + "处置：iPhone 设置→蓝牙→忽略本车机，再由诊断仪重新配对。",
                         level: .error)
                }
                // ★★★ 必须复位链路（2026-10-29 修复）。
                //
                // 原来这里直接 `return`，什么都不改，于是：
                // - `linkState` 停在 `.discovering` → `autoConnect()` 早退、
                //   `connectRemembered()` 返回 true 却不做事（假死）
                // - `writeChar` 仍非 nil → `isWriteReady == true` → 用户点按钮
                //   直接被判"可以写"，往**未加密链路**发 01 → 4 秒超时 690
                // - 车端不踢的话永久卡死，只能杀 App
                //
                // 正确做法：清掉特征、置 failed、主动断开，让 didDisconnect
                // 走正常收尾（重扫 / 5 次快速断开进 30s 冷却）。
                writeChar = nil
                notifyChar = nil
                characteristicsReady = false
                linkState = .failed
                // 保留 self.peripheral，让 didDisconnectPeripheral 的
                // `guard peripheral === self.peripheral` 能通过 —— 由它负责
                // 收尾（清特征、置 .disconnected、重扫）。
                central.cancelPeripheralConnection(peripheral)
                return
            }
            // ★ 必须是「我们订阅的那个特征」且「写特征已就位」才置 ready。
            //
            // 原来只看 `isNotifying`：若车端固件里没有写特征 F000FF11（或服务
            // 发现被截断），仍会置 `.ready` 并广播出去 → 上层立刻取走挂起动作
            // → `perform` 发现 `isWriteReady == false` → 重新挂起 →
            // 15 秒后才由看门狗收口。用户看到「链路就绪」但点了没反应。
            if characteristic.isNotifying, characteristic === notifyChar, writeChar != nil {
                cancelDiscoverTimeout()
                linkState = .ready
                // ★ 对应原 App 的 `Notification updated for %@ device.`——
                //   订阅成功即链路已加密（SMP bonding 完成），是车端受理
                //   业务帧（0x0D / 0x01）的前提。
                if elapsed >= 5 {
                    note("链路就绪：订阅成功，耗时 \(timing)（5s+ = 系统弹了 PASSKEY 框，"
                         + "说明这次刚建立 bonding）")
                } else if elapsed >= 0.3 {
                    note("链路就绪：订阅成功，耗时 \(timing)（略慢，正常应 <0.3s；"
                         + "若车端无响应可从信号强度排查）", level: .warning)
                } else {
                    note("链路就绪：订阅成功，耗时 \(timing)（<0.3s = bonding 已复用，链路已加密）")
                }
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            // ★ 只接受「当前外设」的数据（2026-10-30 修复）。
            //
            // 旧连接迟到的帧会被喂进 `MeasuredSession`：单调序号校验失败 →
            // `abortRound` 把**当前这一轮**判成"乱序/非法"，或者更糟 ——
            // 一个迟到的 `02` 挑战让当前轮用错 rnd1 回 `03`。
            guard let tracked = self.peripheral,
                  peripheral.identifier == tracked.identifier else { return }
            guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
            let bytes = [UInt8](data)
            // ★ 收到数据即重置「出范围」计时（照 VCBDevice resetWithTimeout @0x9fb4）
            resetRangeTimeout()
            rxHexStream.append("\(Self.stamp())  ←  \(FrameCodec.hexString(bytes))")
            FileLogger.shared.debug("← \(FrameCodec.hexString(bytes))", module: "RX")
            trimStream()

            // ★★★ **直接把原始字节交给上层**。
            //
            // 之前这里是先喂给 `FrameCodec.tryExtractFrame`，只有它能切出"完整帧"
            // 才回调 `onFrame`。但 `tryExtractFrame` 是**旧协议**（`01 FE` 魔数 + CRC16）
            // 的解析器，而实测链路用的是 InBlue 的 **`[cmdId][payload]`** 格式 ——
            // 于是它**永远解不出帧**，`onFrame` 从不触发，
            // 表现为「车端明明回了，日志里却没有任何接收帧」。
            //
            // 现在无条件回调，由上层（`handleIncomingFrame` / `MeasuredSession`）
            // 按实测格式自行分发。
            onFrame?(bytes)
        }
    }
}
