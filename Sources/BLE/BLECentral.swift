import Foundation
import CoreLocation
// CoreBluetooth 的委托回调仍是非 Sendable 的旧式 API，
// 用 @preconcurrency 让 Swift 6 放宽区域隔离检查（语义不变，因为回调实际都在主队列）。
@preconcurrency import CoreBluetooth

/// 连接时序埋点。
///
/// **这是为诊断「要点很多次才能打着火」而专门加的**：
/// 车端要求「连接后 2 秒内」发出 ID 1 确认帧（错误码 `0x6f00`），
/// 而 Apple 开发者论坛有实测报告指出 CoreBluetooth 从 `didConnect`
/// 到服务发现/订阅完成之间可能有约 900ms 延迟
/// （developer.apple.com/forums/thread/839638）。
/// 把这几段耗时打出来，就能立刻判断是否卡在时序上。
public struct ConnectTiming: Sendable {
    public var connectStart: Date?
    public var didConnect: Date?
    public var servicesDiscovered: Date?
    public var characteristicsDiscovered: Date?
    public var notifySubscribed: Date?

    public init() {}

    public var connectDuration: TimeInterval? { delta(connectStart, didConnect) }
    public var serviceDiscoveryDuration: TimeInterval? { delta(didConnect, servicesDiscovered) }
    public var characteristicDiscoveryDuration: TimeInterval? { delta(servicesDiscovered, characteristicsDiscovered) }
    public var subscribeDuration: TimeInterval? { delta(characteristicsDiscovered, notifySubscribed) }
    /// 从连接成功到链路就绪（订阅完成）——**这个值必须远小于 2 秒**。
    public var linkReadyDuration: TimeInterval? { delta(didConnect, notifySubscribed) }

    private func delta(_ a: Date?, _ b: Date?) -> TimeInterval? {
        guard let a, let b else { return nil }
        return b.timeIntervalSince(a)
    }

    public var summary: String {
        func f(_ v: TimeInterval?) -> String { v.map { String(format: "%.0fms", $0 * 1000) } ?? "-" }
        return """
        连接 \(f(connectDuration)) │ 服务发现 \(f(serviceDiscoveryDuration)) \
        │ 特征发现 \(f(characteristicDiscoveryDuration)) │ 订阅 \(f(subscribeDuration))
        链路就绪总计 \(f(linkReadyDuration))（红线 2000ms）
        """
    }
}

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
    @Published public private(set) var timing = ConnectTiming()
    @Published public private(set) var lastMessage: String = ""
    @Published public private(set) var rxHexStream: [String] = []

    // ── 下列为 PEPS 场景必需的状态量 ──────────────────────────
    /// 协商后的单次写入上限（MTU 相关）。
    /// 老车 PEPS 模块对大包敏感，超长必须分包发送。
    @Published public private(set) var maxWriteLength: Int = 0
    /// 最近一次 RSSI（用于信号强度展示与中继攻击提示）
    @Published public private(set) var rssi: Int?
    /// 自动重连状态
    @Published public private(set) var reconnectAttempt = 0
    /// 是否启用自动重连
    public var autoReconnect = true
    /// 自动重连上限（避免死循环）
    public var maxReconnectAttempts = 6

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
    /// 收到任意原始数据时回调（用于观察未分帧的数据，例如车端广播随机数）。
    public var onRawData: (([UInt8]) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rssiTask: Task<Void, Never>?
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

    /// 是否显示**全部**扫描到的设备（关闭时只显示疑似目标）
    @Published public var showAllDevices = false

    /// 是否解析 Tbox 广播码（默认关 —— 已从主链路移除，见 `TboxBroadcastCode`）
    public nonisolated(unsafe) static var debugTboxBroadcastCode = false

    /// ★★★ **设备广播的原始数据**（`CBAdvertisementDataManufacturerDataKey`）。
    ///
    /// ## 为什么关键（反汇编证据）
    /// `-[IBDevice parseBroadcastData:]` @0x4bc0：
    /// ```objc
    /// +[IBNSString cidpu]
    /// [x0 stringToData:]
    /// [x0 decryptData:withKey:]      // ★ 用 cidpu 解密广播数据
    /// [x0 subdataWithRange:]
    /// [x0 parseStatus:]
    /// ```
    /// 即：**广播数据是加密的，要用 `cidpu` 作 key、AES-CBC 解密**，
    /// 明文里含 `cryptedID` / 随机数等 —— 那些才是 `01` 帧该用的真实值。
    ///
    /// 之前 App 现场生成随机数发给车端，车端不认 → 立刻断开（"点了就断"）。
    @Published public private(set) var lastManufacturerData: [UInt8] = []
    /// 当前设备的 CIDPU（从广播名解析，如 `InBlue3f26c66ac89ad4` → `c89ad4`）
    @Published public private(set) var currentCidpu = ""
    /// 解密后的广播明文（诊断用）
    @Published public private(set) var parsedBroadcast: [UInt8] = []

    /// ★ **配对静默模式**。
    ///
    /// 置 `true` 时，连接成功后**不做任何主动 BLE 操作**（不发现服务、
    /// 不订阅通知、不读 RSSI），只保持链路。
    ///
    /// ## 为什么需要
    /// iOS 的 pairing 是模块与系统之间的协商。如果 App 在协商期间
    /// 同时发起 `discoverServices` / `setNotifyValue` / `readRSSI`，
    /// 这些操作会打断协商 → **诊断仪报「配对失败」**。
    ///
    /// 原 App 配对期间是静默的，所以能一次成功。
    @Published public var quietMode = false
    /// 静默模式的超时任务
    private var quietTask: Task<Void, Never>?
    /// 待重连的外设（配对流程要求"断开→重连"以触发系统 pairing）
    private var pendingPairingReconnect: CBPeripheral?

    /// ★ **配对等待中自动连接**开关。
    ///
    /// 配对页启动配对流程时置 `true`：此时车端处于配对模式、模块正在广播，
    /// 扫描到第一个有名字的设备就直接连上，让 iOS 走完整 pairing 流程
    /// （弹出 6 位码框）—— 对应原 App「配对不用手动点设备」的行为。
    @Published public var autoConnectWhilePairing = false

    /// ★ **Tbox 广播码解析结果**（`01` 帧第一段的来源）。
    ///
    /// 反汇编：`isTboxBluetoothBroadcastWithBroadcastCode:` 要求 25 字节，
    /// 切出 `code[17..25)` 作为 `broadcastRandom`。
    @Published public private(set) var broadcastCodeRandom: [UInt8] = []
    /// 解析出的广播码原文（诊断）
    @Published public private(set) var broadcastCode: [UInt8] = []
    /// 收到广播码时的回调（由 AppModel 接到 MeasuredSession）
    public var onBroadcastCode: (([UInt8]) -> Void)?


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

    /// 请求位置权限（iOS 会弹系统框）
    public func requestLocationPermission() {
        refreshLocationAuth()
        if locationAuthText == "未决定" {
            locationManager.requestWhenInUseAuthorization()
            lastMessage = "已请求位置权限，请在系统弹框中允许"
        } else if locationAuthText == "已拒绝" {
            lastMessage = "位置权限已被拒绝，请到「设置 → 隐私与安全性 → 定位服务」里为「蓝牙钥匙」打开"
        } else {
            lastMessage = "位置权限：\(locationAuthText)"
        }
    }
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

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
                        "com.mmxisme.gkuiblekey.central"])
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
            startRSSIPolling(p)
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
        linkState = .scanning
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

    /// 手动清空设备列表（扫描不再自动清空，避免"扫一次列表就空"的误判）
    public func clearCandidates() {
        candidates.removeAll()
        discoverCount = 0
        lastDiscoveredName = ""
        lastMessage = "已清空设备列表"
    }

    public func stopScan() {
        central.stopScan()
        if linkState == .scanning { linkState = .idle }
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

    public func connect(_ p: CBPeripheral) {
        stopScan()
        timing = ConnectTiming()
        timing.connectStart = Date()
        linkState = .connecting
        peripheral = p
        p.delegate = self
        lastMessage = "正在连接 \(p.name ?? p.identifier.uuidString)…"
        // 连接后系统如需 MITM 配对（6 位码）会自动弹窗，App 无需干预
        central.connect(p, options: nil)

    }

    public func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: - 发送

    /// 写入一帧（走写特征 F000FF11）。
    @discardableResult
    public func send(_ bytes: [UInt8]) -> Bool {
        guard let p = peripheral, let c = writeChar else {
            lastMessage = "写特征未就绪"
            return false
        }
        guard !bytes.isEmpty else { return false }
        let data = Data(bytes)
        // ★★★ 写入类型：**必须优先用 Write Command（`.withoutResponse`）**。
        //
        // 实测证据（2026-10-04 真机 HCI 抓包）：
        //   数据写入一律是 ATT **Write Command（opcode 0x52）**，
        //   只有 CCCD 订阅用 Write Request（0x12）。
        //
        // 而 `F000FF11` 的属性是 `0x0C`（同时含 `.write` 与 `.writeWithoutResponse`），
        // 之前的代码优先挑 `.write` → 发出的是 **Write Request** →
        // 模块不认这种写法，**收到就断开连接** —— 表现为"一点按钮就跳未连接"。
        let type: CBCharacteristicWriteType
        if c.properties.contains(.writeWithoutResponse) {
            type = .withoutResponse
        } else if c.properties.contains(.write) {
            type = .withResponse
        } else {
            type = .withoutResponse
        }
        // iOS 27 SDK 已把 forCharacteristic: 重命名为 for:
        p.writeValue(data, for: c, type: type)
        rxHexStream.append("\(Self.stamp())  →  \(FrameCodec.hexString(bytes))"
                         + "  [\(type == .withoutResponse ? "Command" : "Request")]")
        FileLogger.shared.append("→ \(FrameCodec.hexString(bytes))"
                               + " [\(type == .withoutResponse ? "Command" : "Request")]", tag: "TX")
        trimStream()
        lastMessage = "已发送 \(bytes.count) 字节"
        return true
    }

    public var isWriteReady: Bool { peripheral != nil && writeChar != nil }
    public var isNotifyReady: Bool { notifyChar?.isNotifying == true }

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
        central = CBCentralManager(delegate: self, queue: .main)
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
        // ★★★ **Service 数据** —— 原 App 的 Tbox 广播码可能由它补齐。
        //
        // 反汇编：`-[XXX centralManager:didDiscoverPeripheral:advertisementData:RSSI:]`
        // 把 `advertisementData[@"kCBAdvDataManufacturerData"]` 交给
        // `-[ViewModel isTboxBluetoothBroadcastWithBroadcastCode:]`，
        // 后者要求**长度正好 25 字节**（`cmp x0, #0x19`），才能切出
        // `broadcastRandom = data[17..25)`。
        //
        // 实测厂商数据只有 **19 字节**（差 6），怀疑缺的就在 Service 数据里。
        let svcDataPairs: [(String, [UInt8])] = {
            guard let d = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
            else { return [] }
            return d.map { ($0.key.uuidString.uppercased(), [UInt8]($0.value)) }
                    .sorted { $0.0 < $1.0 }
        }()

        MainActor.assumeIsolated {
            // ★★★ 保存广播原始数据 + 解析 CIDPU —— 这是构造 01 帧的前提。
            //     原 App 的 `parseBroadcastData:` 会拿 cidpu 去 AES 解密这段数据。
            if !mfgData.isEmpty {
                lastManufacturerData = mfgData
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
                parsedBroadcast = BroadcastParser.parse(mfgData, cidpu: currentCidpu)
                // ★ 把原始数据完整打出来 —— 原 App 的标识信息在厂商数据里
                //   （`isValeoDeviceWithAdvertisingData:` 是拿它前几字节比魔数），
                //   所以必须先看清这 19 字节长什么样，才能定位 cidpu / cryptedID。
                FileLogger.shared.append(
                    "广播名=「\(advName)」 厂商数据 \(mfgData.count)B = "
                    + mfgData.map { String(format: "%02X", $0) }.joined(separator: " "),
                    tag: "广播")
                FileLogger.shared.append(
                    "cidpu=\(currentCidpu.isEmpty ? "(空)" : currentCidpu), "
                    + "解密=\(parsedBroadcast.isEmpty ? "失败" : "\(parsedBroadcast.count)B"), "
                    + "广播Service=[\(advServiceUUIDs.joined(separator: ","))]",
                    tag: "广播")
                // ★ Service 数据（可能是广播码缺的那 6 字节）
                for (u, bytes) in svcDataPairs {
                    FileLogger.shared.append(
                        "ServiceData[\(u)] \(bytes.count)B = "
                        + bytes.map { String(format: "%02X", $0) }.joined(separator: " "),
                        tag: "广播")
                }
                if svcDataPairs.isEmpty {
                    FileLogger.shared.append("ServiceData（无）", tag: "广播")
                }

                // ⚠️ Tbox 广播码（`code[17..25)`）已从主链路移除。
                //
                // 它曾被认为是 `01` 帧的第一段，但复核后确认 `01` 帧是
                // `AES(明文, CkTRxSP)` 的两段结构，**不含 broadcastRandom 字段**。
                // 保留 `TboxBroadcastCode` 文件仅供诊断，默认不参与解析，
                // 避免每次广播都刷两行无用日志。
                if Self.debugTboxBroadcastCode {
                    let svcAll = svcDataPairs.flatMap { $0.1 }
                    let code = TboxBroadcastCode.assemble(manufacturer: mfgData, service: svcAll)
                    if let parsed = TboxBroadcastCode.parse(code) {
                        broadcastCode = code
                        broadcastCodeRandom = parsed.broadcastRandom
                        FileLogger.shared.append(
                            "Tbox 广播码 25B → broadcastRandom = "
                            + parsed.broadcastRandom.map { String(format: "%02X", $0) }.joined(separator: " "),
                            tag: "广播")
                    }
                }
                if !parsedBroadcast.isEmpty {
                    FileLogger.shared.append(BroadcastParser.describe(parsedBroadcast), tag: "广播明文")
                }
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

            // ★ 诊断：先记下"回调确实来过"，再谈过滤
            discoverCount += 1
            lastDiscoveredName = advName.isEmpty ? "(无名)" : advName

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
            let hit = (identity != .notValeo)
            let weak = Double(rssiValue) <= ValeoAdvMatch.rssiFloor

            if let adv {
                FileLogger.shared.append(
                    "匹配：\(adv.genLabel) 版本=\(adv.protocolVersion) "
                    + "cryptedID=\(adv.cryptedID.map { String(format: "%02X", $0) }.joined()) "
                    + "→ \(identity.rawValue)"
                    + (weak ? "（RSSI \(rssiValue) ≤ -91，原 App 会丢弃）" : ""),
                    tag: "匹配")
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
            // 原 App 没有「广播带 Service 就直连」这一步 —— 判定只看厂商数据，
            // 因此这里也只在**判定命中**时自动连接（弱信号按原规则跳过）。
            if hit && !weak {
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

            // ★★ 强兜底：**配对流程等待中**（配对页已 armed）时，
            //    车端正处在配对模式、模块一定在广播 —— 此时连第一个
            //    发现的设备，让 iOS 走完整的 pairing 流程（弹出 6 位码框）。
            //    这正是原 App「配对不用手点」的行为。
            if autoConnectWhilePairing, !advName.isEmpty, linkState == .scanning {
                autoConnectWhilePairing = false       // 只连一次，避免连错多个
                lastMessage = "配对中：自动连接 \(advName) 以触发系统配对…"
                connect(peripheral)
            }
        }
    }

    /// 退出配对静默模式：恢复正常的服务发现 + RSSI 轮询。
    ///
    /// 由两处触发：① 用户点「我已输完配对码」；② 静默超时兜底。
    public func exitQuietMode() {
        quietTask?.cancel()
        quietTask = nil
        guard quietMode else { return }
        quietMode = false
        lastMessage = "配对静默结束，恢复服务发现"
        if let p = peripheral {
            p.discoverServices([GATT.serviceUUID])
            startRSSIPolling(p)
        }
    }

    /// 静默模式的超时兜底。
    ///
    /// ⚠️ 时间不能太长：车端很可能只在**配对完成后的短窗口**内接受登记帧
    /// （`0x0D`）。之前给 20 秒，等静默结束才发帧，可能已经错过窗口，
    /// 表现为「卡在等待下发密钥」。
    /// 现在给 8 秒 —— 足够输 6 位码，又不至于拖过窗口。
    private func scheduleQuietModeExit() {
        quietTask?.cancel()
        quietTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.quietMode else { return }
            self.lastMessage = "配对静默超时（8s），自动恢复并发送登记帧"
            self.exitQuietMode()
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
        return true
    }

    /// ★ **为配对而重连**：先断开当前链路，再重新连接。
    ///
    /// 为什么需要：iOS 只在**建立新连接**时才与模块协商 pairing。
    /// 如果链路早已连着（例如用户进配对页前 App 就自动连上了），
    /// 系统**不会再次配对**，车端也就不认这次"登记"。
    ///
    /// 断开后重连，就能让 iOS 重新走一遍完整流程（含 6 位码弹窗）。
    public func reconnectForPairing() {
        // ★ 照原 App `closeConnexionForCommand`：关掉旧连接，然后重新连一次。
        //
        // ⚠️ 之前这里设了 `autoReconnect = false` 并依赖 `didDisconnectPeripheral`
        //    回调去重连。但**设备已断开时 `cancelPeripheralConnection` 不会触发
        //    `didDisconnect`** → 状态永远停在 `.connecting` → **表现为"连不上"**。
        //
        // 现在**不依赖任何回调**：关连接 → 立刻清理本地状态 → 重新扫描。
        if let p = peripheral {
            lastMessage = "为配对关闭旧连接…"
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        stopRSSIPolling()
        linkState = .idle

        autoConnectWhilePairing = true
        lastMessage = "重新扫描以建立新连接（触发系统配对）…"
        startScan()
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            timing.didConnect = Date()
            linkState = .discovering
            reconnectAttempt = 0
            // ★ 记住这个设备，之后可以「不用扫描」直接重连
            rememberedPeripheralID = peripheral.identifier
            // MTU / 单次写入上限：老车 PEPS 模块对大包敏感，必须先拿到这个值
            maxWriteLength = peripheral.maximumWriteValueLength(for: .withoutResponse)

            // ★★★ 配对静默模式：连接后**什么都不做**，把时间让给 iOS 的 pairing 协商。
            //     一旦我们在这期间 discoverServices / setNotifyValue / readRSSI，
            //     就可能打断协商 → 诊断仪报「配对失败」。
            // ★★★ 配对静默：**只跳过"额外"操作，但不阻塞主流程**。
            //
            // 反汇编证据（`-[IBDevice openConnexionForCommand:]` @0x4988）：
            // 原 App 是「stopScan → (0x55 时 closeConnexion) → 开连接 → **立即发帧**」，
            // **并不会等 pairing 完成**。pairing 弹窗由 iOS 在连接过程中并行处理。
            //
            // 所以这里立刻退出静默、走正常的服务发现 + 发帧流程，
            // 不再做"等 8 秒让用户输码"这种阻塞 —— 那反而会错过车端的响应窗口。
            if quietMode {
                lastMessage = "已连接（配对中），立即发现服务并发送登记帧…"
                exitQuietMode()
                return
            }

            lastMessage = "已连接（写上限 \(maxWriteLength)B），发现服务中（只查目标 Service 抢时间）"
            // 只发现目标服务，避免枚举全部服务浪费时间
            peripheral.discoverServices([GATT.serviceUUID])
            // 启动 RSSI 周期读取（无感靠近 / 中继攻击提示都依赖它）
            // ★ 它同时起"保活"作用：周期性读操作让 iOS 不把这条链路
            //   判为空闲 —— 原 App 之所以"秒连"，就是链路在后台一直被系统保持。
            startRSSIPolling(peripheral)
        }
    }

    /// 周期性读取 RSSI。原先只读一次，无法做「信号突变」这类中继检测。
    private func startRSSIPolling(_ peripheral: CBPeripheral) {
        rssiTask?.cancel()
        rssiTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.peripheral === peripheral else { return }
                peripheral.readRSSI()
            }
        }
    }

    private func stopRSSIPolling() {
        rssiTask?.cancel()
        rssiTask = nil
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            rssi = RSSI.intValue
        }
    }

    public nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            linkState = .failed
            lastMessage = "连接失败：\(error?.localizedDescription ?? "未知")"

            // ★★ 回退：连接失败就改用扫描。
            //    系统缓存里的 `CBPeripheral` 有时是过期的（iOS 会淘汰 500 条以上的
            //    设备缓存），直接 connect 会一直失败；此时必须重新扫描拿到新对象。
            guard autoReconnect else { return }
            // 允许下次发现时再自动连（配对兜底开关可能已被消费掉）
            autoConnectWhilePairing = true
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
            // ★★★ 配对重连优先处理：断开是为了重连以触发系统 pairing。
            //     必须在自动重连逻辑**之前**处理，否则会被它抢走。
            if let p = pendingPairingReconnect {
                pendingPairingReconnect = nil
                self.peripheral = p            // ★ 必须显式 self.：参数名 peripheral 遮蔽了属性
                p.delegate = self
                linkState = .connecting
                lastMessage = "断开完成，正在重连以触发系统配对…"
                central.connect(p, options: nil)
                return
            }

            linkState = .disconnected
            writeChar = nil
            notifyChar = nil
                stopRSSIPolling()
            rssi = nil
            let reason = error?.localizedDescription ?? "正常断开"
            lastMessage = "已断开：\(reason)"

            // 意外断开按退避自动重连；限制次数避免死循环
            guard autoReconnect, reconnectAttempt < maxReconnectAttempts else {
                if reconnectAttempt >= maxReconnectAttempts {
                    lastMessage = "重连已达上限（\(maxReconnectAttempts) 次），请手动重试"
                }
                return
            }
            let attempt = reconnectAttempt
            reconnectAttempt += 1
            let delay = min(5.0, 0.4 * pow(2.0, Double(attempt)))
            lastMessage = "断开后 \(String(format: "%.1f", delay))s 自动重连"
                + "（第 \(reconnectAttempt)/\(maxReconnectAttempts) 次）"
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, self.autoReconnect else { return }
                self.central.connect(peripheral, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLECentral: CBPeripheralDelegate {

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            timing.servicesDiscovered = Date()
            guard error == nil, let svc = peripheral.services?.first(where: { $0.uuid == GATT.serviceUUID })
                    ?? peripheral.services?.first else {
                lastMessage = "未找到目标服务：\(error?.localizedDescription ?? "空")"
                linkState = .failed
                return
            }
            peripheral.discoverCharacteristics([GATT.writeCharUUID, GATT.notifyCharUUID], for: svc)
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            timing.characteristicsDiscovered = Date()
            for c in service.characteristics ?? [] {
                // 与原 App 一致：按 UUID 硬编码判定读写角色
                // （反汇编 0xa950 比 F000FF12 → setReadCharacteristic + setNotifyValue；
                //   0xa9fc 比 F000FF11 → setWriteCharacteristic）
                if c.uuid == GATT.writeCharUUID { writeChar = c }
                if c.uuid == GATT.notifyCharUUID {
                    notifyChar = c
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            if writeChar == nil || notifyChar == nil {
                lastMessage = "特征不完整（write=\(writeChar != nil), notify=\(notifyChar != nil)）"
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            if error != nil {
                lastMessage = "订阅失败：\(error!.localizedDescription)"
                return
            }
            if characteristic.isNotifying {
                timing.notifySubscribed = Date()
                linkState = .ready
                lastMessage = "链路就绪 —— \(timing.summary)"
            }
        }
    }

    public nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
            let bytes = [UInt8](data)
            rxHexStream.append("\(Self.stamp())  ←  \(FrameCodec.hexString(bytes))")
            FileLogger.shared.append("← \(FrameCodec.hexString(bytes))", tag: "RX")
            trimStream()
            onRawData?(bytes)

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
