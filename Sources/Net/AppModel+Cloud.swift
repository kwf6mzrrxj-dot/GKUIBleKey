import Foundation
import CryptoKit

/// 云端通道与 `AppModel` 的接合层。
///
/// 逻辑单独放一个文件，是为了让 `AppModel.swift` 里那段两年积累的 BLE 代码
/// 尽量少被搅动 —— 那里每一处注释都对应一次真机故障排查，改动风险高。
/// 这里只做「选哪条路」和「走网络时怎么做」，不碰蓝牙协议。
@MainActor
extension AppModel {

    // MARK: - 通道选择

    /// 界面角标 / 状态条要显示的通道。
    ///
    /// 注意它回答的是「**现在**点按钮会走哪条路」，不是「上次走了哪条」。
    /// 用户看到的角标必须和点下去的实际行为一致，否则角标就是误导。
    var preferredChannel: ControlChannel {
        if ble.isWriteReady { return .bluetooth }
        if cloudConfigured && !isVehicleOnline { return .network }
        return .bluetooth
    }

    // MARK: - 状态来源：蓝牙优先，网络兜底
    //
    // 规则只有一条，但「蓝牙有没有收到」这件事必须判两遍，缺一不可：
    //
    //   ① `measured.status != nil` —— 解析成功过至少一次
    //   ② `isVehicleOnline`（60 秒内收到过车端信号）—— 这份状态还新鲜
    //
    // 只判 ① 是不够的：车开走以后 `measured.status` **不会清空**，
    // 它会一直留着最后一次的值。不判新鲜度的话，人已经到公司了，
    // 界面还在显示「半小时前车在楼下时的门锁状态」，而这个值看起来跟实时无异。

    /// 蓝牙是否**明确收到了**可用的状态。
    ///
    /// 判定条件是「实际收到广播车辆数据」，不是「车在附近」，所以用
    /// `lastBluetoothStatusAt`（只在广播解析出 status 时更新），
    /// 而不是 `lastVehicleContactAt`（它还包含"命令成功""收到任意帧"）。
    ///
    /// 不这样分会出现一种很难查的错：蓝牙链路通了、命令也发成功了，
    /// 但这一轮没收到广播，`measured.status` 仍是上一次的旧值 ——
    /// 界面却按"蓝牙有效"把它当成实时状态显示。
    /// ★ 2026-11-05：判据从「60 秒内有广播」改成「链路此刻还活着」。
    ///
    /// 两处必须同源，否则会出现自相矛盾的界面：
    /// 顶栏说「蓝牙 · 离线」（3 秒判据），状态页却说「蓝牙实时」（60 秒判据）。
    ///
    /// `bluetoothLinkAlive` 已经包含了「链路就绪」这一支 —— 连接期间不扫描、
    /// 收不到广播是正常的，不会被误判成断联。
    var bluetoothStatusIsLive: Bool {
        measured.status != nil && bluetoothLinkAlive
    }

    /// 蓝牙状态的归一时点：最后一次收到广播的时间。
    /// 用它而不是 `Date()` —— 状态反映的是那一刻的车况，不是现在。
    private var bluetoothStatusTime: Date {
        lastBluetoothStatusAt ?? Date()
    }

    /// 把 `VehicleStatus`（蓝牙广播结构）翻译成通道无关的快照。
    ///
    /// ## 字段级合并（2026-11-04）
    ///
    /// 不是「整份二选一」，而是**逐字段**决定来源：
    ///
    /// | 字段 | 来源 | 原因 |
    /// |---|---|---|
    /// | 车锁 / 四门 / 后备箱 / 引擎 | 蓝牙 | 广播里有，且是秒级的 |
    /// | 车窗 / 天窗 | 云端（若能拿到） | 蓝牙 16 字节广播里**没有**这两个字段 |
    ///
    /// 以前这里把窗位硬写成 `isWindowsKnown = false`，于是「车在跟前、蓝牙实时」
    /// 这个最该看清楚的时刻，车窗反而显示「—」。而云端明明有窗位，
    /// 只是可能慢几秒 —— 那也比不知道强。
    ///
    /// ⚠️ 只有云端快照**还在新鲜期内**（180 秒）才拿来补。否则宁可不显示：
    /// 拿半小时前的窗位去填今天的空，比「—」更糟。
    private func snapshotFromBluetooth(
        _ s: VehicleStatus, cloud c: VehicleSnapshot?
    ) -> VehicleSnapshot {
        let cloudUsable = (c?.isFresh ?? false)
        return VehicleSnapshot(
            isLocked: s.isLocked,
            isTrunkClosed: s.isTrunkClosed,
            isDoorsClosed: s.isDoorClosed,
            isEngineRunning: s.isEngineRunning,
            doorClosed: [s.isFLDoorClosed, s.isFRDoorClosed,
                         s.isRLDoorClosed, s.isRRDoorClosed],
            // 蓝牙没有窗位 → 借云端；云端没数或过期 → 仍然是「未知」，不写成「全关」
            isWindowsKnown: cloudUsable ? (c?.isWindowsKnown ?? false) : false,
            isWindowsClosed: cloudUsable ? c?.isWindowsClosed : nil,
            isSunroofOpen: cloudUsable ? c?.isSunroofOpen : nil,
            updatedAt: bluetoothStatusTime)
    }

    /// **界面唯一应该读的状态入口。**
    ///
    /// 优先级：蓝牙实时 > 云端 > 无。
    /// 返回的 `source` 必须跟着展示出来，否则用户无法判断数据新旧。
    var activeStatus: (snapshot: VehicleSnapshot?, source: StatusSource) {
        if bluetoothStatusIsLive, let s = measured.status {
            return (snapshotFromBluetooth(s, cloud: cloudSnapshot),
                    .bluetooth(bluetoothStatusTime))
        }
        if let c = cloudSnapshot {
            return (c, .cloud(c.updatedAt))
        }
        return (nil, .none)
    }

    /// 兼容旧调用点的简写
    var displaySnapshot: VehicleSnapshot? { activeStatus.snapshot }

    /// 读云端某个字段是不是「1 / 是 / true」。
    ///
    /// `VehicleSnapshot` 只保留了公共子集（锁/门/窗/引擎），空调这类
    /// 只有云端才有的状态不在里面，只能从全量字段里取。
    /// 返回 `nil` = 这个字段没下发，界面据此显示「状态未知」而不是猜一个。
    func cloudFlag(_ path: String) -> Bool? {
        guard let field = cloudFields.first(where: { $0.id == path || $0.path == path })
        else { return nil }
        switch field.value {
        case "1", "是", "true":  return true
        case "0", "否", "false": return false
        default: return nil
        }
    }

    /// 云端「远程空调」是否开着（`climateStatus.preClimateActive`）
    var cloudAirConditionerOn: Bool? {
        cloudFlag("additionalVehicleStatus.climateStatus.preClimateActive")
    }

    // MARK: - 路由

    /// 尝试把一条指令转到云端。
    ///
    /// - Returns: `true` 表示已由云端接管（调用方应直接 return）
    func routeToCloudIfNeeded(_ action: IBCommandType) -> Bool {
        // 只能走蓝牙的指令（配对 / 无感进入 / 查询设备）不受影响
        guard let cmd = action.asVehicleCommand else { return false }

        // ① 链路已就绪 → 蓝牙，延迟几十毫秒，不用想
        if ble.isWriteReady { return false }

        // ② 车就在附近 → 等蓝牙连上，别急着走云
        //    云端一次往返 1–3 秒，而蓝牙重连通常只要 1–2 秒，且不吃流量。
        //
        // ★ 判据用 `bluetoothStatusIsLive`（收到过广播），不是 `isVehicleOnline`
        //   （含"命令成功""收到任意帧"）—— 2026-11-04 第二轮审查 M12。
        //   两者不一致会出现一种很别扭的状态：界面已经因为蓝牙不新鲜而显示云端数据，
        //   点按钮时路由却仍认为"车在附近"，把动作挂起等蓝牙，用户点完没反应。
        //   现在展示和路由判定同源，界面说什么，点下去就是什么。
        if bluetoothStatusIsLive { return false }

        // ③ 云端没配 → 保持原行为（挂起动作 + 强制重连）
        guard cloudConfigured else { return false }

        // ④ 云端不支持的动作 → 也保持原行为，让它走蓝牙
        guard cmd.isSupportedOnNetwork else { return false }

        performOnCloud(cmd)
        return true
    }

    /// 车窗微开入口。蓝牙没有这个档位，所以**只能走云端**。
    /// 云端也没配就给明确说法，不要静默失败。
    func ventWindow() {
        guard cloudConfigured else {
            statusLine = "车窗微开只能用网络通道，请先配置云端账号"
            measured.recordNote("微开被拦：云端未配置（蓝牙协议无中间档）")
            return
        }
        performOnCloud(.windowVent)
    }

    // MARK: - 云端执行

    func performOnCloud(_ cmd: VehicleCommand) {
        guard !cloudState.isBusy else {
            statusLine = "云端请求进行中，请稍候"
            return
        }
        cloudState = .sending(cmd.label)
        statusLine = "通过云端下发「\(cmd.label)」…"
        measured.recordNote("通道=网络 → \(cmd.label)")

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.cloud.send(cmd)
                self.lastChannelUsed = .network
                self.cloudState = .idle
                self.statusLine = "已通过云端\(cmd.label)"
                self.showControlBanner("✓ 已通过云端\(cmd.label)")
                ActionHistory.shared.record(cmd.label, channel: "云端", success: true)
                self.resolveIntent(true)

                // 车端执行是异步的（云端下发 → T-Box → 车），
                // 立刻回读拿到的还是旧状态，等 3 秒再刷新。
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self.refreshCloudStatus()
            } catch {
                self.cloudState = .failed(error.localizedDescription)
                self.statusLine = "云端\(cmd.label)失败：\(error.localizedDescription)"
                // 车控页没有状态行，失败必须弹出来 —— 否则点完毫无反馈
                self.showControlBanner("⚠️ \(cmd.label)失败：\(error.localizedDescription)")
                ActionHistory.shared.record(cmd.label, channel: "云端", success: false,
                                            note: error.localizedDescription)
                self.resolveIntent(false)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if case .failed = self.cloudState { self.cloudState = .idle }
            }
        }
    }

    /// 拉一次云端车况。**只读**，随时可以调。
    func refreshCloudStatus() async {
        guard cloudConfigured else { return }
        cloudState = .refreshing
        do {
            cloudSnapshot = try await self.cloud.fetchStatus()
            cloudFields = await self.cloud.lastFields
            cloudState = .idle
            // 锁屏 / 灵动岛跟着更新（现在它的数据源就是这里）
            refreshLiveActivity()
            // 手表端纯云端，车况也由手机推过去
            syncSnapshotToWatch()
        } catch {
            cloudState = .failed(error.localizedDescription)
        }
    }

    /// 给 Siri / 快捷指令 / 控制中心用的**强制网络**入口。
    ///
    /// 这些入口在后台执行，不保证蓝牙链路在场；而且用户念一句
    /// 「解锁车」时通常人不在车边。统一走网络最可靠。
    func runNetworkCommand(_ cmd: VehicleCommand) async -> Bool {
        guard cloudConfigured else {
            statusLine = "网络通道未配置，无法执行「\(cmd.label)」"
            return false
        }
        cloudState = .sending(cmd.label)
        do {
            try await cloud.send(cmd)
            lastChannelUsed = .network
            cloudState = .idle
            statusLine = "已通过云端\(cmd.label)"
            measured.recordNote("Intent → 网络通道 → \(cmd.label)")
            ActionHistory.shared.record(cmd.label, channel: "快捷指令", success: true)
            return true
        } catch {
            cloudState = .failed(error.localizedDescription)
            statusLine = "云端\(cmd.label)失败：\(error.localizedDescription)"
            ActionHistory.shared.record(cmd.label, channel: "快捷指令", success: false,
                                        note: error.localizedDescription)
            // 4 秒后复位，和 `performOnCloud` 保持一致 ——
            // 原来这里不复位，设置页「当前」一栏会永久停在最后一次失败原因。
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .failed = cloudState { cloudState = .idle }
            return false
        }
    }

    // MARK: - 配置

    /// 保存云端凭据并试登录。返回 `nil` 表示成功，否则是错误文案。
    func configureCloud(phone: String, password: String, vin: String) async -> String? {
        let trimmedPhone = phone.trimmingCharacters(in: .whitespaces)
        let trimmedVIN = vin.trimmingCharacters(in: .whitespaces).uppercased()

        guard !trimmedPhone.isEmpty, !password.isEmpty, !trimmedVIN.isEmpty else {
            return "手机号、密码、车架号都要填"
        }
        guard trimmedVIN.count == 17 else {
            return "VIN 应该是 17 位，现在填了 \(trimmedVIN.count) 位"
        }

        // 只存 MD5（32 位小写 hex，服务端收的就是这个），本地不留明文
        var creds = await cloud.snapshotOfCredentials()
        creds.phone = trimmedPhone
        creds.vin = trimmedVIN
        creds.passMD5 = Self.md5Hex(password)
        creds.userId = ""
        creds.clientId = ""
        await cloud.updateCredentials(creds)
        cloudConfigured = creds.isComplete

        do {
            await cloud.invalidateToken()
            try await cloud.login()
            await afterCloudConfigured()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 只改手机号 / VIN，密码沿用已存的 MD5。
    ///
    /// 界面拿不到明文（本地只存了 MD5），所以「改个手机号」不该逼用户重输密码。
    func configureCloudKeepingPassword(phone: String, vin: String) async -> String? {
        var creds = await cloud.snapshotOfCredentials()
        guard !creds.passMD5.isEmpty else { return "没有已保存的密码，请重新输入一次" }

        let p = phone.trimmingCharacters(in: .whitespaces)
        let v = vin.trimmingCharacters(in: .whitespaces).uppercased()
        guard !p.isEmpty, !v.isEmpty else { return "手机号和车架号都要填" }
        guard v.count == 17 else { return "VIN 应该是 17 位，现在填了 \(v.count) 位" }

        creds.phone = p
        creds.vin = v
        creds.userId = ""
        creds.clientId = ""
        await cloud.updateCredentials(creds)
        cloudConfigured = creds.isComplete

        do {
            await cloud.invalidateToken()
            try await cloud.login()
            // ★ 和 configureCloud 走同一套收尾（2026-11-04 第二轮审查 S2）。
            //   这里原来只补了 startCloudAutoRefresh，漏了 syncAccountToWatch ——
            //   换账号后手表还在用旧 VIN 发命令。
            await afterCloudConfigured()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 配置成功之后**必须**做的三件事，集中在这一个地方。
    ///
    /// ## 为什么必须收成方法（2026-11-04 第二轮审查 S2）
    ///
    /// 这两个入口原本各自写一遍收尾：
    ///
    /// ```
    /// configureCloud                  → refresh + 开轮询 + 推手表   ✅
    /// configureCloudKeepingPassword   → refresh + 开轮询             ❌ 漏推手表
    /// ```
    ///
    /// 上一轮修「冷启动不刷新」时就在这个位置漏过一次 `startCloudAutoRefresh`，
    /// 这一轮又漏了 `syncAccountToWatch`。同一处漏两次，说明问题不在"手滑"，
    /// 而在"该做的事散在多处、没有单一清单"。
    ///
    /// 漏推手表的后果不是"手表连不上"，是**手表继续用旧 VIN 和旧 token 发命令** ——
    /// 换了账号之后，手表的解锁会作用到另一辆车上。
    private func afterCloudConfigured() async {
        await refreshCloudStatus()
        startCloudAutoRefresh()
        syncAccountToWatch()
    }

    // MARK: - 手表同步

    /// 把账号（含 token）推给手表。
    ///
    /// 手表端没有登录界面 —— 它的账号来源就是这里。
    /// 清除配置时也调它，传 `nil` 会把手表那边的账号一起抹掉，
    /// 避免出现「手机已退出、手表还能开锁」。
    func syncAccountToWatch() {
        Task { [weak self] in
            guard let self else { return }
            let creds = await self.cloud.snapshotOfCredentials()
            guard creds.isComplete else {
                PhoneWatchSync.shared.pushAccount(nil)
                return
            }
            let token = await self.cloud.tokenSnapshot()
            PhoneWatchSync.shared.pushAccount(
                CloudAccountPayload(phone: creds.phone, vin: creds.vin,
                                    userId: creds.userId, clientId: creds.clientId,
                                    // ★ 不再同步密码 MD5（2026-11-04 第二轮审查 S3）。
                                    //
                                    //   它是可离线撞库的资产，同步过去等于把一份凭据
                                    //   复制到「抬腕即解锁」的手表上 —— 手机端的 Face ID
                                    //   门槛被这份副本绕过了。
                                    //
                                    //   手表只需要 token：token 有效就能干活，
                                    //   彻底失效时提示用户回手机重登一次即可
                                    //   （refresh token 通常以月计，很少走到这一步）。
                                    passMD5: "",
                                    accessToken: token.access,
                                    refreshToken: token.refresh,
                                    tokenExpiry: token.expiry))
        }
    }

    /// 把最新车况推给手表（只在云端刷新成功后调，不推过期数据）
    func syncSnapshotToWatch() {
        guard let snap = cloudSnapshot else { return }
        let temp = CloudPrefs.currentACTemperature
        PhoneWatchSync.shared.pushSnapshot(
            CloudSnapshotPayload(snapshot: snap, acOn: cloudAirConditionerOn,
                                 acTemperature: temp))
    }

    /// 等云端凭据从 Keychain 读出来（最多 `timeout` 秒）。
    ///
    /// ## 为什么需要（2026-11-05）
    ///
    /// `reloadCloudConfig()` 是异步的。从控制中心/锁屏/Siri 这类
    /// **App 可能没在运行**的入口进来时，进程刚被拉起，
    /// `cloudConfigured` 还是初始的 `false` —— 直接判它会把「已配置的云端账号」
    /// 误判成「没配」，于是退到蓝牙路径，而后台根本来不及完成一次鉴权。
    ///
    /// 轮询 50ms 一次、最多等 2 秒：Keychain 读取是毫秒级的，
    /// 2 秒只会在极端情况（首次安装、Keychain 卡住）才用满。
    @discardableResult
    func awaitCloudConfigReady(timeout: TimeInterval = 2) async -> Bool {
        if cloudConfigReady { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
            if cloudConfigReady { return true }
        }
        return cloudConfigReady
    }

    /// 清空云端配置：停自动刷新、丢 token、抹凭据、清快照。
    ///
    /// 之前没有这个入口 —— 换账号只能覆盖，旧 VIN 的缓存状态会一直挂在界面上。
    func clearCloudConfig() async {
        stopCloudAutoRefresh()
        await cloud.clearAllCredentials()
        cloudConfigured = false
        cloudSnapshot = nil
        cloudFields = []
        cloudState = .idle
        statusLine = "云端配置已清除"
        refreshLiveActivity()
        syncAccountToWatch()      // 手表那边也要跟着退出
    }

    /// 启动时调一次：读本地凭据，如果是齐的就标记为已配置。
    ///
    /// ★ 2026-11-04 修复：这里原来只管「标记已配置」，不启动自动刷新。
    /// 而 `startCloudAutoRefresh()` 只挂在 `willEnterForegroundNotification` 上 ——
    /// **冷启动不会发这个通知**（它只在「从后台回前台」时发）。
    /// 结果是：配好云端、下次直接打开 App，状态页永远是上一个进程留下的数据，
    /// 直到用户切一次后台再回来。这正是「状态页与云端保持一致」失效的原因。
    func reloadCloudConfig() {
        Task { [weak self] in
            guard let self else { return }
            let c = await self.cloud.snapshotOfCredentials()
            self.cloudConfigured = c.isComplete
            self.cloudConfigReady = true
            if c.isComplete {
                self.startCloudAutoRefresh()
            }
        }
    }

    /// 密码要的是 32 位小写 hex MD5（与 App 一致），不是上面签名用的 base64。
    /// 两个都要，别混。
    static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 自动刷新
//
// 「状态页展示的内容与云端保持一致」靠这个：定时拉，拉到就覆盖。
// 触发时机刻意分成三段：
//   ① 首次配好云端后立刻拉一次（用户马上要看到数据）
//   ② 前台每 90 秒一次（看一眼车况的合理节奏）
//   ③ 从后台回前台立刻补一次（回来那一刻最想看到最新状态）
// 后台不跑 —— 省流量省电，而且后台请求容易被系统掐断。
@MainActor
extension AppModel {

    func startCloudAutoRefresh() {
        guard cloudConfigured else { return }
        cloudAutoRefreshTask?.cancel()
        cloudAutoRefreshTask = Task { [weak self] in
            // 立刻先拉一次，别让用户干等 90 秒
            await self?.refreshCloudStatus()
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(Self.cloudRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self, self.cloudConfigured else { break }
                await self.refreshCloudStatus()
            }
        }
    }

    func stopCloudAutoRefresh() {
        cloudAutoRefreshTask?.cancel()
        cloudAutoRefreshTask = nil
    }

    // MARK: - 下拉刷新

    /// 下拉刷新：把两条通道都刷一遍，并给一句明确结果。
    ///
    /// ## 为什么两页共用一个（2026-11-05）
    ///
    /// 车控页和状态页看的是同一份数据，只是角度不同。各刷各的会出现
    /// 「下拉车控页刷新了蓝牙、下拉状态页刷新了云端」—— 用户下次不知道该在哪一页下拉。
    ///
    /// 顺序是**先云端、后蓝牙**：
    /// - 云端是请求-响应，能明确 `await` 到结果
    /// - 蓝牙重连是异步的，只能给一个窗口等它
    /// 先做能确定的，再做尽力而为的。
    @discardableResult
    func refreshAll() async -> Bool {
        // ① 云端 —— 能等到结果的那条
        if cloudConfigured {
            await refreshCloudStatus()
        }

        // ② 蓝牙 —— 触发重连，最多等 3 秒。
        //    没有钥匙也没有在配对时不必触发：连上了也没有可用的车。
        if !ble.isWriteReady, hasLocalKey || pairingArmed {
            autoConnect()
        }
        for _ in 0..<30 {
            if ble.isWriteReady { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // ③ 一句话结果 —— 下拉的 spinner 收起后，用户得知道到底刷到了什么
        let text: String
        if ble.isWriteReady {
            text = "已刷新 · 蓝牙就绪"
        } else if bluetoothStatusIsLive {
            text = "已刷新 · 蓝牙在线"
        } else if let snap = cloudSnapshot {
            text = snap.isFresh
                ? "已刷新 · 云端 " + Self.hhmm(snap.updatedAt)
                : "已刷新 · 云端数据已过期"
        } else if cloudConfigured {
            text = "没拿到数据：云端请求失败"
        } else {
            text = "没刷新到：蓝牙未连接，云端也未配置"
        }

        statusLine = text
        measured.recordNote("下拉刷新 → " + text)

        let ok = ble.isWriteReady || cloudSnapshot != nil
        showControlBanner((ok ? "✓ " : "⚠️ ") + text)
        return ok
    }
}
