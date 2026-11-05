import Combine
import Foundation
import LocalAuthentication
import WatchConnectivity

/// 手表端控制器 —— **纯云端，不含任何蓝牙代码**。
///
/// ## 为什么推倒重来
///
/// 旧版（`WatchVehicleController`，959 行）在手表上跑了一整套 BLE 协议栈：
/// 扫描、`01→02→03→04` 会话、`0x0D` 配对、`0x0C` 预认证保活、广播解密。
/// 代价是：
///
/// - 手表要**单独配一次对**（诊断仪开窗口 + 6 位码），用户几乎配不成功
/// - watchOS **没有** `bluetooth-central` 后台模式，熄屏就挂起 ——
///   「靠近解锁」在手表上根本不可能成立
/// - 协议栈一大半代码只为了证明「钥匙在场」，而这件事对一块表没有意义
///
/// 现在的定位很明确：**手表 = 手机的远程遥控器**，账号与手机共用，
/// 所有动作走云端 HTTPS。抬腕能看车况、能锁车解锁、能开空调，
/// 这就够了；「人不在车边也能用」本来就是云端的长处。
///
/// ## 数据从哪来
///
/// | 来源 | 内容 | 时机 |
/// |---|---|---|
/// | 手机推送（WCSession） | 账号、token、车况快照 | 手机登录 / 每次云端刷新 |
/// | 手表自己拉 | `GET /remote-control/vehicle/status/{vin}` | 打开 App、下拉刷新、命令执行后 |
///
/// 两条都要：推送让一抬腕就有内容（不用等网络），自己拉保证数据是当下的
/// —— 手机可能已经锁屏一整天，推来的快照早就过期了。
///
/// ## 账号
///
/// 手表**不做登录界面**。账号只有手机一个来源：
/// 在 iPhone 的「我的 → 网络通道」登录后，`PhoneWatchSync` 会推过来，
/// 存进手表自己的 Keychain。手机上清除配置时也会推一条空载荷，手表跟着退出。
@MainActor
final class WatchCloudController: NSObject, ObservableObject {

    // MARK: - 对外状态

    /// 是否已从手机同步到账号
    @Published private(set) var configured = false
    /// 脱敏手机号（138****8000）
    @Published private(set) var phoneMasked = ""
    /// 车况快照
    @Published private(set) var snapshot: VehicleSnapshot?
    /// 远程空调是否开着
    @Published private(set) var acOn: Bool?
    /// 空调温度（跟随手机上的设置）
    @Published private(set) var acTemperature = 22
    /// 正在下发命令
    @Published private(set) var busy = false
    /// 正在拉状态
    @Published private(set) var refreshing = false
    /// 有刷新在跑时又来了请求 —— 当前这轮结束后补做一次，
    /// 不把请求直接丢掉（见 `refresh()` 的说明）
    private var refreshPending = false
    /// 一句话状态（成功/失败都写这里）
    @Published private(set) var statusLine = "等待 iPhone 同步账号"
    /// 最近一次成功拿到车况的时间
    @Published private(set) var lastSyncAt: Date?

    private let cloud = GKCloudClient.shared
    private var cancellables = Set<AnyCancellable>()

    /// 最近一次**收到账号载荷**的时间。
    /// 「重新同步」要靠它判断这一步到底成没成 —— 没有它，
    /// 只能停在"已请求"这种既不是成功也不是失败的文案上。
    private var lastAccountAt: Date?

    // MARK: - 生命周期

    func activate() {
        guard WCSession.isSupported() else {
            statusLine = "此设备不支持与 iPhone 同步"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()

        // ★ 启动初始化收敛成一条顺序链（2026-11-04 第二轮审查 M9）。
        //
        // 原来这里是两个并发路径：`Task { loadLocalAccount() }` 在后台读凭据，
        // 而下面同步设置 `statusLine = "等待 iPhone 同步账号"`。谁后跑谁赢 ——
        // 最坏情况是"已登录 138****8000"被覆盖回"等待同步"，或者并发跑两次
        // `refresh()`。现在只有一条路径，顺序确定。
        Task { [weak self] in
            guard let self else { return }
            // 先用本地已存的账号（上次同步过的），不必等手机
            await self.loadLocalAccount()
            // 本地真没有账号，才落到"等待同步"这句
            if !self.configured { self.statusLine = "等待 iPhone 同步账号" }
        }
    }

    private func loadLocalAccount() async {
        let creds = await cloud.snapshotOfCredentials()
        let token = await cloud.tokenSnapshot()

        // 用 `canMakeAuthedRequests` + 有 token，而不是 `isComplete`：
        // 手表**不再保存密码 MD5**（见 `syncAccountToWatch` 的说明），
        // 手表靠手机同步来的 token 工作。用 `isComplete` 判断会让手表永远
        // 显示"未配置"，连查状态都进不去。
        configured = creds.canMakeAuthedRequests && !(token.access ?? "").isEmpty
        phoneMasked = Self.mask(creds.phone)

        if configured {
            statusLine = "已登录 \(phoneMasked)"
            await refresh()
        } else if creds.canMakeAuthedRequests {
            // 有车但没 token —— 只能等手机推，或让用户回手机重登
            statusLine = "账号已同步但凭证已过期，请在 iPhone 上重新打开 App"
        }
    }

    // MARK: - 拉车况

    func refresh() async {
        guard configured else {
            statusLine = await unconfiguredHint()
            return
        }

        // ★ 已有刷新在跑时，记一次待办而不是直接丢弃（2026-11-04 第二轮审查 M10）。
        //
        // 原来是 `guard !refreshing else { return }`。而 `perform()` 在命令后
        // 等 3 秒再 `await refresh()` —— 如果那时恰好有另一轮在跑，这次就被
        // 静默丢了，用户看到的是**命令执行前**的状态，会以为命令没生效。
        // 现在改成排队：当前这轮结束后立刻补一次。
        if refreshing {
            refreshPending = true
            return
        }

        refreshing = true
        defer { refreshing = false }

        repeat {
            refreshPending = false
            await performRefresh()
        } while refreshPending && configured
    }

    /// 真正的那一次拉取。拆出来是为了让 `refresh()` 能循环补做排队的那次。
    private func performRefresh() async {
        do {
            let snap = try await cloud.fetchStatus()
            snapshot = snap
            // 空调状态不在 `VehicleSnapshot` 的公共子集里，从全量字段取
            acOn = await cloud.airConditionerOn()
            lastSyncAt = Date()
            statusLine = "已更新"
        } catch {
            statusLine = Self.describe(error)
            FileLogger.shared.warning("手表拉车况失败：\(error.localizedDescription)", module: "手表")
        }
    }

    // MARK: - 下发命令

    func perform(_ command: VehicleCommand) async {
        guard configured else {
            statusLine = await unconfiguredHint()
            return
        }
        guard !busy else { return }

        // ★ 破坏性命令先确认是本人（2026-11-04 第二轮审查 S3）。
        //
        // 手表是「抬腕即解锁」的设备：拿走一块未佩戴锁定的表，就等于拿到一把
        // 能开车门的钥匙。手机端的 Face ID 门槛在手表上没有对应物，
        // 所以在这里补一个 —— 用腕表密码，就是戴表的人平时解锁手表用的那位。
        //
        // 放在 `busy = true` 之前：认证面板弹出期间，界面不该显示"正在下发"。
        if Self.needsOwnerAuthentication(command) {
            guard await requireOwnerAuthentication(for: command) else { return }
        }

        busy = true
        statusLine = "正在下发「\(command.label)」…"
        defer { busy = false }

        do {
            try await cloud.send(command)
            statusLine = "已执行「\(command.label)」"
            FileLogger.shared.info("手表 → 云端 \(command.label) 成功", module: "手表")
            // 车端执行是异步的，立刻回读还是旧值
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await refresh()
        } catch let error as GKCloudError {
            statusLine = Self.describe(error)
            FileLogger.shared.warning("手表 → 云端 \(command.label) 失败：\(statusLine)", module: "手表")
        } catch {
            statusLine = error.localizedDescription
        }
    }

    /// 手表「不能用」有两种，得分开说。
    ///
    /// | 情况 | 原来都说 | 实际该说 |
    /// |---|---|---|
    /// | 从没同步过账号 | 请先在 iPhone 上登录云端账号 | 一样 |
    /// | 账号同步过、token 过期 | 请先在 iPhone 上登录云端账号 | **凭证已过期**，回手机打开一次 App 即可 |
    ///
    /// 混在一起说的后果：用户以为账号丢了，跑去重新输密码 —— 而其实
    /// 只要在 iPhone 上打开一次 App，`syncAccountToWatch` 就会把新 token 推过来。
    private func unconfiguredHint() async -> String {
        let creds = await cloud.snapshotOfCredentials()
        if creds.canMakeAuthedRequests {
            return "凭证已过期，请在 iPhone 上打开一次 App 重新同步"
        }
        return "请先在 iPhone 上登录云端账号"
    }

    // MARK: - 本人确认

    /// 哪些命令必须先过腕表密码。
    ///
    /// 判据是「这条命令会不会对车之外的世界产生影响」，而不是「重不重要」：
    ///
    /// | 命令 | 要不要确认 | 为什么 |
    /// |---|---|---|
    /// | 解锁 | **要** | 解锁之后车门对所有人开放，是唯一「打开」的动作 |
    /// | 启动引擎（on = true） | **要** | 尾气、误启动、密闭空间风险 |
    /// | 熄火（on = false） | 不要 | 只会让车停下来 |
    /// | 上锁 / 关窗 / 开窗 / 微开 | 不要 | 上锁更安全；窗位是用户的常见小动作 |
    /// | 寻车 / 空调 | 不要 | 鸣笛、耗电，不构成物理风险 |
    private static func needsOwnerAuthentication(_ command: VehicleCommand) -> Bool {
        switch command {
        case .unlock:
            return true
        case .engine(let on):
            return on
        case .lock, .windowUp, .windowDown, .windowVent, .find, .airConditioner:
            return false
        }
    }

    /// 要求用户输一次腕表密码。
    ///
    /// - 手表没设密码 → **拒绝执行**，并说明原因。没设密码意味着任何人都能拿起来用，
    ///   这种状态下不该允许解锁车门。实际影响很小：手表设了密码才能用 Apple Pay，
    ///   绝大多数设备都有。
    /// - 用户取消 / 认证失败 → 回到未执行状态，不留"正在下发"
    private func requireOwnerAuthentication(for command: VehicleCommand) async -> Bool {
        // 注意：`localizedCancelTitle` / `localizedFallbackTitle` 在 watchOS 上
        // 标记为 unavailable —— 手表的认证面板由系统接管，不接受自定义按钮文案。
        let context = LAContext()

        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            statusLine = "手表没有设置密码，无法确认是本人。请先在手表上设置密码。"
            FileLogger.shared.warning(
                "手表未设置密码，拒绝执行「\(command.label)」：\(policyError?.localizedDescription ?? "-")",
                module: "手表")
            return false
        }

        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "确认执行「\(command.label)」")
            if !ok { statusLine = "已取消「\(command.label)」" }
            return ok
        } catch {
            // 用户主动取消也走这里（LAError.userCancel），不该算错误日志
            statusLine = "已取消「\(command.label)」"
            FileLogger.shared.info(
                "手表执行「\(command.label)」未通过本人确认：\(error.localizedDescription)",
                module: "手表")
            return false
        }
    }

    /// 让手机补推一次账号（用户点「重新同步」时）。
    ///
    /// ## 三态结果，不撒谎（2026-11-04 第二轮审查 S1）
    ///
    /// 上一版发完消息就把状态写成"已请求 iPhone 重新同步" —— 但那句话既不表示成功，
    /// 也不表示失败，而且手机端当时压根不会重推（只回一个 Bool）。
    /// 用户等了半天没有账号，界面还停在"已请求"，无从判断。
    ///
    /// 现在分三种收尾：
    ///
    /// ```
    /// 6 秒内收到账号          → 由 applyAccount 置为「已同步账号（138****8000）」
    /// 收到回执但没收到账号      → 「iPhone 已收到请求，但没有推送账号」
    /// 消息没送达              → 「同步请求没送达：<原因>」
    /// ```
    func requestResync() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else {
            statusLine = "与 iPhone 的通道尚未就绪，请先在手机上打开一次 App"
            return
        }

        let sentAt = Date()
        statusLine = "正在请求 iPhone 重新同步…"

        WCSession.default.sendMessage(
            ["cmd": "resync"],
            replyHandler: { reply in
                // 回执只说明「手机收到了请求」，不代表账号已送达 ——
                // 真正的结果由下面的超时判断。
                let accepted = (reply["resyncAccepted"] as? Bool) ?? false
                guard !accepted else { return }
                // 这里强捕获 self：控制器是 @StateObject，生命周期与 App 一致，
                // 而且这段 Task 只活几毫秒。加 [weak self] 反而会和外层
                // 隐式强捕获打架（ImplicitStrongCapture 警告）。
                Task { @MainActor in
                    self.statusLine = "iPhone 没有接受同步请求，请升级两端的 App"
                }
            },
            errorHandler: { error in
                let reason = error.localizedDescription
                Task { @MainActor in
                    self.statusLine = "同步请求没送达：\(reason)"
                    FileLogger.shared.warning("手表同步请求失败：\(reason)", module: "手表")
                }
            })

        // 6 秒窗口：`transferUserInfo` 是排队必达的，正常情况下几秒内就到。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self else { return }
            // 收到了就走 applyAccount 的文案，不覆盖
            if let at = self.lastAccountAt, at >= sentAt { return }
            self.statusLine = self.configured
                ? "iPhone 已收到请求，但没有推送账号（可稍后再试）"
                : "同步失败：请在 iPhone 上打开 App 后再点一次"
            FileLogger.shared.warning("手表重新同步超时（6 秒内未收到账号）", module: "手表")
        }
    }

    // MARK: - 应用同步载荷

    private func applyAccount(_ payload: CloudAccountPayload) async {
        // 顺序不能反：updateCredentials 会把 token 清掉
        await cloud.updateCredentials(
            GKCloudCredentials(phone: payload.phone,
                               passMD5: payload.passMD5,
                               vin: payload.vin,
                               userId: payload.userId,
                               clientId: payload.clientId))
        await cloud.importToken(GKCloudClient.TokenSnapshot(
            access: payload.accessToken,
            refresh: payload.refreshToken,
            expiry: payload.tokenExpiry))

        configured = true
        phoneMasked = payload.maskedPhone
        lastAccountAt = Date()      // 「重新同步」靠它判断成功
        statusLine = "已同步账号（\(phoneMasked)）"
        FileLogger.shared.info("手表已接收账号：\(phoneMasked)", module: "手表")
        await refresh()
    }

    private func applyRemoval() async {
        await cloud.clearAllCredentials()
        configured = false
        phoneMasked = ""
        snapshot = nil
        acOn = nil
        lastSyncAt = nil
        statusLine = "iPhone 已退出登录"
        FileLogger.shared.info("手表已清除账号（手机端退出）", module: "手表")
    }

    private func applySnapshot(_ payload: CloudSnapshotPayload) {
        // 手机推来的可能比手表自己拉的旧，简单比一下时间
        if let current = snapshot, current.updatedAt > payload.updatedAt { return }
        snapshot = payload.snapshot
        acOn = payload.acOn
        acTemperature = payload.acTemperature ?? acTemperature
        lastSyncAt = payload.updatedAt
    }

    // MARK: - 小工具

    /// 手机号脱敏。按数字位数判断而不是"正好 11 位"——
    /// 带 `+86` 或空格的号码原来会原样显示出来（第二轮审查 L7）。
    private static func mask(_ phone: String) -> String {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return phone.isEmpty ? "" : "已登录" }
        return String(digits.prefix(3)) + "****" + String(digits.suffix(4))
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? GKCloudError {
            switch e {
            case .notConfigured:          return "凭证已失效，请在 iPhone 上重新打开 App"
            case .unsupportedOnNetwork(let w): return "\(w)暂不支持云端"
            case .http(let code):         return "网络错误 \(code)"
            case .business(_, let msg):   return msg.isEmpty ? "云端拒绝了这条命令" : msg
            case .badResponse(let d):     return "响应异常：\(d)"
            }
        }
        return error.localizedDescription
    }
}

// MARK: - 与 iPhone 的通道

extension WatchCloudController: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if let error {
                self.statusLine = "与 iPhone 同步失败：\(error.localizedDescription)"
            }
        }
    }

    /// 账号走这条（必达，手表 App 没跑也会补投）
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // 只把 Data 带进 MainActor —— `[String: Any]` 不是 Sendable，
        // 直接捕获会触发 Swift 6 的 data race 检查。
        guard let data = userInfo[CloudSyncKey.account] as? Data else { return }
        Task { @MainActor in
            guard let payload = try? JSONDecoder().decode(CloudAccountPayload.self, from: data)
            else { return }
            await self.applyAccount(payload)
        }
    }

    /// 车况走这条（覆盖式，只留最新一份）
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        // 同上：先把两个 Data 取出来，再把它们带进 MainActor
        let accountData = applicationContext[CloudSyncKey.account] as? Data
        let snapshotData = applicationContext[CloudSyncKey.snapshot] as? Data
        Task { @MainActor in
            if let accountData,
               let payload = try? JSONDecoder().decode(CloudAccountPayload.self, from: accountData),
               !self.configured {
                // applicationContext 里也可能带账号（首次安装时最快到手）
                await self.applyAccount(payload)
            }
            if let snapshotData,
               let payload = try? JSONDecoder().decode(CloudSnapshotPayload.self, from: snapshotData) {
                self.applySnapshot(payload)
            }
        }
    }
}
