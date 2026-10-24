import Foundation
import Combine

/// 协调 BLE 链路与 InBlue 会话，并实现**可靠的重试/恢复策略**。
///
/// ## 与原 App 的差异（均为体验/安全增强，不改变协议行为）
/// 1. **不再 5 次封顶**：原 App `_kRetryTimes = 5`（`0x40de0`），用满即报
///    `40001 控车指令重发次数已满`，用户必须从头再来。这里改为带退避的持续重试。
/// 2. **失败自动重建会话**：对应原 SDK 的 `destorySession` + 重新
///    `initializationDK:`，而不是把失败抛给用户。
/// 3. **时序可视化**：把 `ConnectTiming` 直接显示出来，让 2 秒窗口是否被挤压一目了然。
///
/// ## 2026-10-24 清理
/// 旧的「五步 DK 协议」（`FE 01` 帧、`DKSession`/`ExSession`/`DKTuning` 等 8 个文件、
/// 约 1400 行）已移除。它基于早期对 `GLBLEAuthSDK` 的假设，与实测链路
/// （`01/02/03`）无关，保留只会干扰判断。
@MainActor
public final class AppModel: ObservableObject {

    public let ble = BLECentral()
    /// InBlue 配对器（首次绑定用；日常认证走 `measured`）
    public let pairing = InBluePairing()

    /// ★ **点火位置验证判定器** —— 照 `IBVehicle` 的
    /// `checkRssiForPassiveStart` / `isInPassiveStartArea` 反汇编实现。
    @Published public var passiveStart = PassiveStartJudge()

    /// ★ **当前唯一使用的会话状态机**：`01 → 02 → 03 → 04`（+ 车端推送 `05`）。
    public let measured = MeasuredSession()

    /// ★ **预认证保活** —— 见 `PreAuthenticationController` 的逐行反汇编说明。
    /// 原 App 在被动进入流程里只发 `0x0C`，**不会**自动发 unlock/lock。
    public let preAuth = PreAuthenticationController()

    @Published public var statusLine = "未连接"
    @Published public var isBusy = false
    /// 是否已提示过「RSSI 未标定」（只提示一次）
    private var didWarnUncalibrated = false

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
        ble.onFrame = { [weak self] bytes in
            self?.handleIncomingFrame(bytes)
        }
        ble.onRawData = { [weak self] bytes in
            self?.handleRawData(bytes)
        }
        // ★★★ 扫描时解析出的 Tbox 广播码 → 喂给实测会话，作 `01` 帧的第一段。
        //    反汇编：`isTboxBluetoothBroadcastWithBroadcastCode:` 取广播码 [17..25)。
        ble.onBroadcastCode = { [weak self] rand in
            self?.measured.updateBroadcastRandom(rand)
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

        // ★ 链路就绪 → 若配对流程在等，自动发登记帧（一键配对的关键）
        ble.$linkState
            .filter { $0 == .ready }
            .sink { [weak self] _ in
                guard let self, self.pairingArmed else { return }
                self.appendPairingLog("链路已就绪，自动发送登记帧")
                self.sendPairingRequest()
            }
            .store(in: &cancellables)

        // ★ 断连/失败 → 复位预认证的边沿状态。
        //   否则"断开时在区域内"会残留 `wasInsideArea = true`，
        //   重连后一直停在区域内，不会再触发一次 launch。
        ble.$linkState
            .filter { $0 == .disconnected || $0 == .failed || $0 == .idle }
            .sink { [weak self] _ in
                self?.preAuth.resetEdge()
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

    /// **一键配对** —— 用户唯一需要做的操作。
    ///
    /// 内部自动串联：
    /// ```
    /// ① 若已连接 → 直接发登记帧（0x0D）
    /// ② 若未连接 → 先尝试系统已配对设备，失败则扫描
    /// ③ 链路一就绪 → 自动发 0x0D（由 linkState 订阅驱动）
    /// ④ 车端回 0x0E（62B 密钥帧）→ 自动保存
    /// ```
    /// 依据原 App 反汇编：`pairingMessage` @`0x13afc`（37B 登记帧）、
    /// `saveKeysData:` @`0x12660`（62B 密钥帧切分）。
    ///
    /// ★ 系统配对框是 iOS 自动弹的（访问加密特征时要求输 6 位码），App 不参与。
    public func startFullPairing() {
        pairing.resetForNewAttempt()
        pairingArmed = true

        // 已有一条链路（就绪/发现中/连接中）→ 关掉它重连；否则扫描。
        let hasLink = ble.linkState == .ready
            || ble.linkState == .discovering
            || ble.linkState == .connecting
        if hasLink {
            statusLine = "配对中：关闭旧连接后重新连接（触发系统配对）…"
            ble.reconnectForPairing()
            return
        }

        statusLine = "配对中：扫描并连接车辆模块…"
        ble.autoConnectWhilePairing = true
        ble.startScan()
    }

    /// **自动连接** —— App 启动 / 蓝牙就绪 / 回到前台时调用。
    ///
    /// 只保留「扫描 → 发现 → 连接」这一条路径（原 App 也是这条）：
    /// ① 已在就绪/连接中 → 什么都不做
    /// ② 尝试接管已连接设备，失败则扫描
    public func autoConnect() {
        guard ble.linkState != .ready,
              ble.linkState != .connecting,
              ble.linkState != .discovering else { return }
        ble.adoptConnectedPeripheral()      // 已连着就直接用（不 connect、不 cancel）
        if ble.linkState == .discovering || ble.linkState == .ready { return }
        statusLine = "扫描车辆模块…"
        ble.startScan()
    }

    /// 发送 0x0D 登记帧（内部使用；链路就绪后自动调用）
    private func sendPairingRequest() {
        pairingArmed = false
        let frame = pairing.buildPairingMessage()
        guard ble.send(frame) else {
            statusLine = "配对失败：写特征未就绪"
            return
        }
        statusLine = "登记帧已发送（\(frame.count)B），等待车端下发密钥…"
    }
    /// 处理配对**请求回显**帧（`0x0D`）。
    ///
    /// ⚠️ `0x0E`（密钥）**不在这里处理** —— 它归 `MeasuredSession`（对应原 App
    /// 在 `analyzeMessage:` 的 `case 14` 里调 `saveKeysData:`）。
    /// 两边都处理会导致密钥被存两次、日志重复。
    /// 处理配对相关帧：`0x0D`（配对请求回显）与 **`0x0E`（密钥下发）**。
    ///
    /// ⚠️ 之前这里只判 `cmd == 0x0D`，导致 **`0x0E` 两边都不匹配**
    /// （配对分支不收、`0x01...0x05` 鉴权分支也不收）→ **密钥帧被直接丢弃**。
    /// 现在把 `0x0E` 收进来，并真正走 `saveKeysData:` 那条路。
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
            statusLine = "收到车端密钥（\(payload.count)B）已保存，标定值已重读"
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

    // MARK: - 中继防护

    /// 中继攻击防护（基于 RSSI 突变检测）
    public let relayGuard = RelayGuard()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 车控动作（统一入口）

    /// 当前正在执行的动作（供日志/界面显示）
    @Published public private(set) var pendingAction: IBCommandType?

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
            statusLine = "写特征未就绪，无法执行「\(action.label)」"
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
                            ? "预认证成功（6.5s 后继续）"
                            : "「\(measured.lastSucceededAction?.label ?? "动作")」执行成功（04 00）"
                    case .acceptedAwaitingNames:
                        statusLine = "已受理，等待车端回 0x0F 设备名"
                    case .refused(let code):
                        // 失败码：记入防爆破计数（原 App 无此逻辑，属安全增强）
                        recordAuthFailure(ErrorCodeTable.describeResultByte(code))
                    }
                    if isPreAuth {
                        if case .success = result { preAuth.didComplete(success: true) }
                        else { preAuth.didComplete(success: false) }
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
            statusLine = "写特征未就绪，无法发起鉴权"
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
        measured.reset()
        // ★ 每次鉴权前从 Keychain 重载 —— 配对刚写入的密钥能立刻用上
        measured.reloadKeys()
        if asPreAuthentication {
            measured.preparePreAuthentication()
        } else if let target {
            measured.perform(target)
        }
        let frame = measured.buildAuth1()
        guard !frame.isEmpty else {
            statusLine = "鉴权1 构造失败：缺少密钥材料（先用 0D 帧配对拿 0E）"
            return
        }
        guard ble.send(frame) else {
            statusLine = "鉴权1 写入失败"
            return
        }
        statusLine = "已发鉴权1（\(frame.count)B），等待车端 02 挑战…"

        // 超时提示（不换顺序、不改帧内容）。
        //
        // `01` 的 5 段顺序已由 `-[VCLSManager requestParametersforCidpu:]` @`0x11bec`
        // 完全确定（sd / ed / RndTRx / RND1 / rights），原 App 也没有"多顺序尝试"，
        // 因此这里只报超时，不做任何协议层面的变通。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.measured.phase == .sentAuth1 else { return }
            self.statusLine = "鉴权1 超时：车端未响应（密钥不被接受时会静默丢弃）"
        }
    }

    private func handleRawData(_ bytes: [UInt8]) {
        // 未构成标准帧的裸数据：只记录，不臆测含义。
        // （早期版本会把它们当作「广播随机数」喂给 ID 1 帧 —— 该做法已被推翻：
        //   `01` 帧是 AES 两段，不含广播随机数字段。）
        guard !bytes.isEmpty else { return }
        FileLogger.shared.append(
            "裸数据 \(bytes.count)B = \(FrameCodec.hexString(bytes))", tag: "DK")
    }

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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

        if let k = store.identityKey, k.count < 8 {
            problems.append("identityKey 长度异常（\(k.count) 字节）")
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
