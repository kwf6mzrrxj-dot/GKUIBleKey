import SwiftUI

/// 主页 —— 照原 App「蓝牙车控」主页精简。
///
/// ## 设计原则（本轮重写）
/// 1. **主界面只给「用户真正要用的」**：解锁/闭锁两大键 + 后备箱/车窗/寻车，
///    去掉十六进制控制码、`05` 帧 hex 等调试信息。
/// 2. **依赖标定的高级功能（点火验证、预认证保活）移出主界面**，
///    收进「开发者」菜单 —— 它们未标定时几乎不触发，放在主页只会造成困惑。
/// 3. **调试/诊断/密钥/日志/设备统一进右上角菜单**，不再散落底部栏。
/// 4. 状态用用户能懂的语言表达（已连接/未连接、上一次成功动作），
///    不暴露协议细节。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @State private var showDeveloper = false
    @State private var showPairing = false
    /// 点击「当前不可执行」的按钮时，用它弹出明确原因。
    ///
    /// 之前控车按钮直接 `.disabled(!isWriteReady)`：未连接时按钮变灰、
    /// 点了毫无反馈，用户分不清是"没连上"还是"App 坏了"。
    /// 现在改成**可点击 + 弹提示**，每次点击都有回应。
    @State private var actionHint: String?

    /// 车辆爱称（详情页可改，持久化在 UserDefaults）
    ///
    /// 本 App 只服务这一台车，所以不做「按 cidpu 分键」的多车抽象 ——
    /// 一个全局键就够，换车时重新配对会覆盖同一台车的密钥，爱称手动改即可。
    @AppStorage(VehicleProfile.nicknameKey) private var vehicleNickname = VehicleProfile.defaultNickname
    private let vehicleModelName = "博越 PRO"

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                vehicleHeader
                carArt
                statusChips
                Spacer(minLength: 0)
                controlSection
                statusSection
            }
            .padding(.horizontal, 20)
        }
        .onAppear { model.autoConnect() }
        .onChange(of: model.ble.bluetoothStatusText) { _, _ in
            if model.ble.isBluetoothReady { model.autoConnect() }
        }
        .sheet(isPresented: $showDeveloper) { DeveloperMenuView() }
        .sheet(isPresented: $showPairing) { PairingView() }
        .alert("暂时无法执行", isPresented: Binding(
            get: { actionHint != nil },
            set: { if !$0 { actionHint = nil } }
        )) {
            Button("去连接") { actionHint = nil; model.autoConnect() }
            Button("知道了", role: .cancel) { actionHint = nil }
        } message: {
            Text(actionHint ?? "")
        }
    }

    // MARK: - 背景（随浅色/深色自适应）

    private var background: some View {
        Group {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [Color(red: 0.11, green: 0.12, blue: 0.16),
                             Color(red: 0.06, green: 0.07, blue: 0.10)],
                    startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(
                    colors: [Color(red: 0.93, green: 0.95, blue: 0.98),
                             Color(red: 0.84, green: 0.87, blue: 0.92)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部标题栏

    private var topBar: some View {
        HStack(spacing: 10) {
            // 连接状态胶囊（点色 + 文案）
            HStack(spacing: 6) {
                Circle()
                    .fill(linkStateColor)
                    .frame(width: 7, height: 7)
                Text(linkStateText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(glassFill, in: Capsule())

            // RSSI 信号值：只在「扫描中且最近 10 秒内收到过本车广播」时显示。
            // 停止扫描 / 离开覆盖范围 / 车机停止广播后会自动消失，
            // 不会把过期值当实时信号挂着（v2.2 之前就是永久冻结的假值）。
            if let r = model.ble.rssi {
                HStack(spacing: 3) {
                    Image(systemName: "cellularbars")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(r) dBm")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(rssiColor(r))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(glassFill, in: Capsule())
            }

            Spacer()
            Menu {
                // ★ 已配对就**不再展示「绑定车辆」**（2026-10-29）
                //   原来这一项常驻，已配对用户点进去只会弹「本地已有密钥」，
                //   等于把已建立的配对关系重复展示成"可以再配一次"。
                if model.hasLocalKey {
                    Button { showDeveloper = true } label: {
                        Label("车辆已绑定 · 管理与解绑", systemImage: "key.fill")
                    }
                } else {
                    Button { showPairing = true } label: {
                        Label("绑定车辆", systemImage: "link.badge.plus")
                    }
                }
                Divider()
                Button { showDeveloper = true } label: {
                    Label("开发者", systemImage: "wrench.and.screwdriver")
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// 玻璃底填充色（浅色模式用深色半透明，深色模式用白色半透明）
    private var glassFill: Color {
        colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.06)
    }

    /// RSSI 信号颜色：强 → 绿，中 → 黄，弱 → 橙/红
    private func rssiColor(_ r: Int) -> Color {
        switch r {
        case ...(-85): return .red
        case ..<(-70): return .orange
        case ..<(-55): return .yellow
        default:       return .green
        }
    }

    private var linkStateColor: Color {
        switch model.ble.linkState {
        case .ready:        return .green
        case .connecting, .discovering, .scanning: return .yellow
        case .failed:       return .red
        case .disconnected, .idle: return .gray
        }
    }

    // MARK: - 车辆标题

    private var vehicleHeader: some View {
        VStack(spacing: 2) {
            Text(vehicleModelName)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.primary)
            Text(vehicleNickname)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var linkStateText: String {
        if model.pairingArmed { return "配对中" }
        switch model.ble.linkState {
        case .ready:        return "已连接"
        case .connecting:   return "连接中"
        // 「发现服务」是 BLE 术语（GATT 服务发现），对用户太黑话。
        // 正常只存在 0.04–0.17 秒，一闪而过；诊断页仍显示原始名。
        case .discovering:  return "正在握手…"
        case .scanning:     return "扫描中"
        case .disconnected: return "未连接"
        case .failed:       return "连接失败"
        case .idle:         return "待机"
        }
    }

    // MARK: - 车辆图（原 App 车辆模型帧 + 状态动画）

    /// 车辆舞台状态：连接阶段 → 对应动画
    private var carStage: CarModelView.Stage {
        // ★ 配对优先（2026-10-29 修复）：配对时链路通常已经 `.ready`，
        //   原来先判 `.ready` 会让 `.pairing` 永远走不到，车图不闪灯，
        //   但顶部胶囊写着「配对中」，两边自相矛盾。
        if model.pairingArmed { return .pairing }
        if model.ble.linkState == .ready { return .ready }
        return .connecting
    }

    private var carArt: some View {
        CarModelView(status: model.measured.status, stage: carStage)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 200)
            .padding(.horizontal, 10)
    }

    // MARK: - 状态芯片（车门/后备箱/上电/发动机/ACC，广播解密状态）

    /// 状态芯片「新鲜度」阈值（秒）。超过就标橙，提示可能已不是当前状态。
    ///
    /// 依据：车机广播**不是实时流**，实测间隔从 10 秒到十几分钟不等
    /// （见日志 21:14:50 → 21:15:00 → 21:15:31 → 21:35:32），
    /// 所以 2 分钟没收到新广播就足以提示「这条快照可能已经变了」。
    private let statusStaleSeconds: TimeInterval = 120

    /// 车辆状态是否「新鲜」——只有新鲜时才在按钮上做「下一步推荐」。
    ///
    /// 车机广播间隔不固定（实测 10s–17min），所以状态随时可能是旧的。
    /// 拿过期状态去推荐操作（比如 18 分钟前"已锁"就高亮"解锁"）会误导用户。
    private var isStatusFresh: Bool {
        guard let t = model.measured.statusUpdatedAt else { return false }
        return Date().timeIntervalSince(t) <= statusStaleSeconds
    }

    @ViewBuilder private var statusChips: some View {
        if let s = model.measured.status {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    chip(icon: s.isLocked ? "lock.fill" : "lock.open.fill",
                         text: s.isLocked ? "已锁" : "未锁",
                         good: s.isLocked)
                    chip(icon: "door.left.hand.closed",
                         text: s.isDoorClosed ? "门关" : "门开",
                         good: s.isDoorClosed)
                    chip(icon: "car.rear.open",
                         text: s.isTrunkClosed ? "后备箱关" : "后备箱开",
                         good: s.isTrunkClosed)
                    chip(icon: "engine.combustion",
                         text: s.isEngineRunning ? "已启动" : "未启动",
                         good: true)
                    chip(icon: "bolt.fill",
                         text: s.isAccOn ? "ACC开" : "ACC关",
                         good: true)
                }

                // ★ 时效标记：明确告诉用户这是「最后一次收到」的快照，
                //   而不是实时状态。过期就标橙，避免「显示已锁、实际已解锁」的误判。
                if let t = model.measured.statusUpdatedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let age = max(0, ctx.date.timeIntervalSince(t))
                        let stale = age > statusStaleSeconds
                        HStack(spacing: 4) {
                            Image(systemName: stale ? "exclamationmark.triangle.fill" : "clock")
                                .font(.system(size: 9, weight: .semibold))
                            Text(stale
                                 ? "\(ageText(age))收到，可能已不是当前状态"
                                 : "\(ageText(age))更新")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(stale ? Color.orange : Color.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    private func ageText(_ age: TimeInterval) -> String {
        if age < 60 { return "\(Int(age)) 秒前" }
        if age < 3600 { return "\(Int(age / 60)) 分钟前" }
        return "\(Int(age / 3600)) 小时前"
    }

    private func chip(icon: String, text: String, good: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(good ? Color.primary : Color.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(glassFill, in: Capsule())
    }

    // MARK: - 控车区

    private var controlSection: some View {
        VStack(spacing: 12) {
            // 两大键：解锁 / 闭锁 —— 车锁状态直接体现在按钮上
            HStack(spacing: 12) {
                // ★ 只有状态**新鲜**（≤ `statusStaleSeconds`）时才做「下一步推荐」。
                //
                // 之前不管状态多旧都高亮：截图里状态是 18 分钟前收到的，
                // 却仍在推荐「解锁」，很可能与实车相反。过期状态只展示、不推荐。
                primaryAction(.unlock, "解锁", .green, "lock.open.fill",
                              isCurrentState: isStatusFresh && model.measured.status?.isLocked == true,
                              stateBadge: isStatusFresh && model.measured.status?.isLocked == true
                                  ? "当前已锁" : nil)
                primaryAction(.lock, "闭锁", .blue, "lock.fill",
                              isCurrentState: isStatusFresh && model.measured.status?.isLocked == false,
                              stateBadge: isStatusFresh && model.measured.status?.isLocked == false
                                  ? "当前未锁" : nil)
            }

            // 次要动作：后备箱 / 车窗 / 寻车
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible())], spacing: 8) {
                secondaryAction(.openCloseTrunk, "后备箱", "car.side.rear.open")
                secondaryAction(.windowUp, "关窗", "arrow.up.square")
                secondaryAction(.windowDown, "开窗", "arrow.down.square")
                secondaryAction(.panic, "寻车", "light.beacon.max.fill")
            }

            // 上一次成功动作（用户可理解，不暴露控制码）
            if let a = model.measured.lastSucceededAction {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption2)
                    Text("上一次成功：\(a.label)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 16)
    }

    /// 主按钮 —— `isCurrentState` 为 `true` 时（车正处于该按钮对应的状态）
    /// 加亮边框和状态角标，提示用户「下一步该按哪个」：
    /// 已锁 → 高亮「解锁」；未锁 → 高亮「闭锁」。
    private func primaryAction(
        _ action: IBCommandType, _ title: String, _ tint: Color, _ icon: String,
        isCurrentState: Bool = false, stateBadge: String? = nil
    ) -> some View {
        // ★ 形状只定义一次，玻璃底与高亮描边共用同一个 path。
        //
        // 之前是 `.buttonStyle(.glass)` + 独立的 `RoundedRectangle(cornerRadius: 22)` 描边，
        // 两者形状不同源，四角必然错位：
        //   ① `RoundedRectangle` 默认 `.circular` 圆角，系统玻璃用的是 continuous 超椭圆，
        //      同样 22pt 半径下两者在四个角的曲率明显不同；
        //   ② `.glass` buttonStyle 会在 label frame 内再留一圈 rim，
        //      贴着 frame 画的描边就浮在玻璃外面。
        // 改成自绘玻璃后，底色与描边是同一个 shape 的同一个 path，物理上不可能错开。
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        return Button {
            // ★ 不再在 UI 层拦「未连接」——交给 `AppModel.perform` 处理。
            //
            // 车端在每条命令执行完会主动断开链路（原 App 日志同样如此），
            // 所以"点完一次就无法再点"是常态。v3.4 起 `perform` 已经能做到
            // 「挂起动作 → 立刻重连已知设备 → ready 后自动执行」，
            // 但如果 UI 先 guard 掉，那段逻辑就永远走不到（v3.4 的实际缺陷）。
            //
            // 现在只在**蓝牙不可用**时才提示，其余情况都由 perform 接管。
            guard model.ble.managerState == .poweredOn else {
                actionHint = "蓝牙未开启，无法连接车辆。\n请先在系统设置里打开蓝牙。"
                return
            }
            model.perform(action)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 26, weight: .medium))
                Text(title).font(.headline)
                if let badge = stateBadge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint.opacity(0.25), in: Capsule())
                        .foregroundStyle(tint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(.vertical, 8)
            // 玻璃底：参数与描边用同一个 shape
            .glassEffect(.regular.tint(tint.opacity(0.16)).interactive(), in: shape)
            // 高亮描边：贴着同一个 shape 的内边描（`strokeBorder` 向内，不改变尺寸）
            .overlay {
                shape.strokeBorder(isCurrentState ? tint : .clear, lineWidth: 2)
            }
        }
        .buttonStyle(.plain)
        // ★ 不再按任何状态调暗（2026-10-29）。
        //
        // 之前是 `.opacity(isWriteReady ? 1 : 0.55/0.7)` —— 未连接时按钮发灰，
        // 用户第一反应就是"按钮坏了/不能点"。但 v5.0 之后点它真的有效：
        // `perform` 会挂起动作、自动连接、就绪后执行。
        // **能点的按钮就不该画成不能点**，否则等于把功能藏起来。
        // 连接状态请看顶部胶囊（未连接/连接中/已连接），那才是它该在的地方。
    }

    private func secondaryAction(
        _ action: IBCommandType, _ title: String, _ icon: String
    ) -> some View {
        Button {
            // ★ 不再在 UI 层拦「未连接」——交给 `AppModel.perform` 处理。
            //
            // 车端在每条命令执行完会主动断开链路（原 App 日志同样如此），
            // 所以"点完一次就无法再点"是常态。v3.4 起 `perform` 已经能做到
            // 「挂起动作 → 立刻重连已知设备 → ready 后自动执行」，
            // 但如果 UI 先 guard 掉，那段逻辑就永远走不到（v3.4 的实际缺陷）。
            //
            // 现在只在**蓝牙不可用**时才提示，其余情况都由 perform 接管。
            guard model.ble.managerState == .poweredOn else {
                actionHint = "蓝牙未开启，无法连接车辆。\n请先在系统设置里打开蓝牙。"
                return
            }
            model.perform(action)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.glass)
        // 同主按钮：不调暗。能点就画成能点。
    }

    // MARK: - 状态区

    private var statusSection: some View {
        VStack(spacing: 10) {
            // 蓝牙适配器异常提示（排在最前，因为它一错后面全白搭）
            if !model.ble.isBluetoothReady {
                alertCard(icon: "exclamationmark.triangle.fill",
                          color: .orange,
                          title: "蓝牙\(model.ble.bluetoothStatusText)",
                          detail: hintForBluetoothState)
            }

            // 无感进入（PE：靠近车辆拉门把手解锁）总开关
            passiveEntryCard

            // ★ 点火前主动打招呼（2026-10-29）
            //
            // 预认证的自动节奏是 29 秒一次，而用户上车按按钮是随机时刻 ——
            // 这就是「试好多次才打不着」的数学原因。这个按钮把该发的
            // 0x0C 提前发一次，不做任何新协议动作。
            if model.hasLocalKey, model.preAuth.isEnabled {
                Button {
                    model.sendPreAuthNow()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.radiowaves.forward.fill")
                            .font(.system(size: 15, weight: .semibold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("准备点火").font(.subheadline.weight(.medium))
                            Text("上车前点一下，让车端先认出手机")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.glass)
            }

            // 密钥状态（未配对时整行可点，引导去绑定）
            //
            // ★ 用 `hasLocalKey`（内存 + Keychain 双查）而不是 `measured.keys`：
            //   解绑后如果内存副本没清干净，这里会继续显示「数字钥匙已就绪」，
            //   用户以为没解绑成功。
            statusRow(icon: model.hasLocalKey ? "key.fill" : "key",
                      iconColor: model.hasLocalKey ? .green : .orange,
                      text: model.hasLocalKey ? "数字钥匙已就绪" : "尚未绑定车辆",
                      trailing: model.hasLocalKey ? nil : "去绑定",
                      action: model.hasLocalKey ? nil : { showPairing = true })

            // ★★★ 动作结果 / 拒绝原因（2026-10-29 补上）
            //
            // `perform` 的所有反馈都只写 `model.statusLine`：
            // 未连接、锁定中、密钥完整性失败、鉴权1 构造失败、写入失败、
            // 4 秒超时、预认证是否已被车内认可……
            // 之前主界面**一处都没渲染**，只有「开发者 → 诊断」里能看到，
            // 用户点解锁后界面零回应，以为按钮坏了。
            if !model.statusLine.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: statusLineIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.top, 1)
                    Text(model.statusLine)
                        .font(.caption2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(statusLineColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusLineColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.15), value: model.statusLine)
    }

    /// 状态行的图标 / 颜色 —— 按内容粗分类，不做协议层判断
    private var statusLineIcon: String {
        let s = model.statusLine
        if s.contains("✅") || s.contains("成功") { return "checkmark.circle.fill" }
        if s.contains("❌") || s.contains("失败") || s.contains("未通过") { return "exclamationmark.circle.fill" }
        if s.contains("锁定") || s.contains("超时") { return "lock.circle.fill" }
        return "info.circle"
    }

    private var statusLineColor: Color {
        let s = model.statusLine
        if s.contains("✅") || s.contains("成功") { return .green }
        if s.contains("❌") || s.contains("失败") || s.contains("未通过") { return .red }
        if s.contains("锁定") || s.contains("超时") { return .orange }
        return .secondary
    }

    /// 无感进入开关卡片：靠近车辆时拉门把手解锁。
    private var passiveEntryCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.passiveEntryEnabled
                  ? "figure.walk.arrival" : "figure.walk.departure")
                .font(.system(size: 18))
                .foregroundStyle(model.passiveEntryEnabled ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("无感进入")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(model.passiveEntryEnabled
                     ? "靠近车辆时拉门把手解锁"
                     : "手动控车（不自动解锁）")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.passiveEntrySwitching {
                ProgressView()
            } else {
                Toggle("", isOn: Binding(
                    get: { model.passiveEntryEnabled },
                    set: { model.setPassiveEntry($0) }
                ))
                .labelsHidden()
                .tint(.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var hintForBluetoothState: String {
        switch model.ble.bluetoothStatusText {
        case "未授权":
            return "请到「设置 → 隐私与安全性 → 蓝牙」里允许本 App 使用蓝牙"
        case "未开启":
            return "请在控制中心或「设置 → 蓝牙」里打开蓝牙"
        case "不支持":
            return "此设备不支持 BLE"
        case "重置中":
            return "蓝牙正在重置，请稍候再试"
        default:
            return "蓝牙状态异常，请稍候再试"
        }
    }

    private func alertCard(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func statusRow(
        icon: String, iconColor: Color, text: String, trailing: String?,
        action: (() -> Void)? = nil
    ) -> some View {
        let row = HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
            if let t = trailing {
                Text(t).font(.caption2).foregroundStyle(.cyan)
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)

        return Group {
            if let action {
                Button(action: action) {
                    row
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                row
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// MARK: - 开发者菜单

/// 开发者菜单 —— 把诊断、日志、密钥、设备、点火验证、预认证等
/// 调试/高级功能集中到这里，主界面保持简洁。
struct DeveloperMenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showDiagnostics = false
    @State private var showKeys = false
    @State private var showLogs = false
    @State private var showVehicleDetail = false

    var body: some View {
        NavigationStack {
            List {
                Section("车辆") {
                    Button { showVehicleDetail = true } label: {
                        menuRow("车辆详情", "car.side", "查看 CIDPU、连接状态")
                    }
                }

                Section("钥匙") {
                    // 副标题去掉「导入」——从原 App 导入密钥的功能早已移除
                    // （KeyInspectorView 顶部注释：不提供从原 App 导入），
                    // 留着「导入」是死描述，会让人去找不存在的能力。
                    Button { showKeys = true } label: {
                        menuRow("密钥管理", "key.horizontal", "检视 / 备份 / 恢复")
                    }
                }

                Section("高级（依赖标定）") {
                    // 点火位置验证：纯本地 RSSI 判定
                    NavigationLink {
                        PassiveStartDetailView()
                    } label: {
                        menuRow("点火位置验证", "engine.combustion",
                                model.passiveStart.summary)
                    }
                    // 预认证保活开关
                    Toggle(isOn: Binding(
                        get: { model.preAuth.isEnabled },
                        set: { model.preAuth.setEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("预认证保活").font(.subheadline).foregroundStyle(.primary)
                            Text(preAuthDetail)
                                .font(.caption2)
                                .foregroundStyle(model.preAuth.isEnabled ? Color.secondary : Color.orange)
                        }
                    }
                }

                Section("调试") {
                    // ★ 实时日志浮窗开关
                    Toggle(isOn: $model.liveLogFloatingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("实时日志浮窗").font(.subheadline).foregroundStyle(.primary)
                            Text("在主页面悬浮显示实时日志，可拖动、折叠")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Button { showDiagnostics = true } label: {
                        menuRow("诊断", "waveform.path.ecg", "自检、时序、原始报文")
                    }
                    Button { showLogs = true } label: {
                        menuRow("日志", "text.alignleft", "会话 / 报文 / 配对日志")
                    }
                }

                Section {
                    Button(role: .destructive) { model.disconnect() } label: {
                        Label("断开连接", systemImage: "xmark.circle")
                    }
                }

                // 版本信息：原「关于」页只显示版本号，已并入这里（少一次跳转）
                Section {
                    HStack {
                        Text("版本").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(AppInfo.versionString) (\(AppInfo.buildNumber))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("开发者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showKeys) { KeyInspectorView() }
            .sheet(isPresented: $showLogs) { LogView() }
            .sheet(isPresented: $showVehicleDetail) { VehicleDetailView() }
        }
    }

    private func menuRow(_ title: String, _ icon: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// 预认证保活的实时状态说明 —— 直接告诉用户「现在能不能点火」。
    ///
    /// 点火的完整前提（缺一不可）：
    /// 1. 钥匙已配对（`0x0E` 密钥已落库）
    /// 2. RSSI 已标定（`<cidpu>_CALIBRATION`），否则区域判定恒 false
    /// 3. 本开关打开，且当前处于被动启动区域（`0x0C` 才会发出）
    /// 4. App 进程活着（后台被系统回收后定时器停摆）
    private var preAuthDetail: String {
        if !model.passiveStart.isCalibrated {
            return "未标定 RSSI：区域判定不会成立，先在「点火位置验证」里标定"
        }
        guard model.preAuth.isEnabled else {
            return "已关闭：车端不会认钥匙在场，只能遥控解锁、无法点火"
        }
        if model.preAuth.isInArea {
            return model.preAuth.sentCount > 0
                ? "保活中：已在区域内心，已发 \(model.preAuth.sentCount) 次 0x0C"
                : "保活中：在区域内，正在发第一轮 0x0C…"
        }
        return "已开启：进入标定区域后自动发 0x0C（已发 \(model.preAuth.sentCount) 次）"
    }
}

// MARK: - 点火位置验证详情

/// 点火位置验证详情 —— 从主界面移出的高级功能。
/// 纯本地 RSSI 判定，展示标定状态与当前判定结果。
struct PassiveStartDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 未连接时点「开始标定」的提示（替代原来的静默 disabled）
    @State private var calibHint: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 标定状态
                    card("标定状态") {
                        if model.passiveStart.isCalibrated {
                            Label("已标定", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            row("标定值", "\(model.passiveStart.calibration ?? 0)")
                        } else if model.passiveStart.isCalibrating {
                            Label("标定中…", systemImage: "waveform.path.ecg")
                                .foregroundStyle(.cyan)
                            // 采样进度（采满 90 次完成）
                            ProgressView(value: model.passiveStart.calibrationProgress)
                                .tint(.cyan)
                            Text("已采 \(model.passiveStart.calibrationSampleCount)/90 次，请保持手机在车内靠近天线")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Label("未标定", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text("点火位置验证依赖标定值。连接车辆后点击下方「开始标定」，"
                                 + "保持手机在车内，采集 90 次双天线 RSSI 后自动完成。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 当前判定
                    card("当前判定") {
                        row("合成 RSSI", model.passiveStart.summary)
                        row("判定基准", "\(model.passiveStart.threshold)")
                        row("是否在区域内",
                            model.passiveStart.isInPassiveStartArea ? "是" : "否")
                    }

                    // 标定操作
                    if model.passiveStart.isCalibrating {
                        Button(role: .destructive) {
                            model.cancelCalibration()
                        } label: {
                            Label("取消标定", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    } else {
                        Button {
                            guard model.ble.isWriteReady else {
                                calibHint = "标定需要连接车辆后才能开始。\n请确认蓝牙已开启、手机在车辆附近。"
                                return
                            }
                            model.startCalibration()
                        } label: {
                            Label("开始标定", systemImage: "location.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        // 不按连接状态调暗：点它会给出明确原因（calibHint），
                        // 比把按钮画灰让人以为坏了要好。
                    }

                    Button {
                        model.refreshPassiveStartVerdict()
                    } label: {
                        Label("重新判定", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("点火位置验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("暂时无法执行", isPresented: Binding(
                get: { calibHint != nil },
                set: { if !$0 { calibHint = nil } }
            )) {
                Button("知道了", role: .cancel) { calibHint = nil }
            } message: {
                Text(calibHint ?? "")
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }
}

// MARK: - 车辆详情（照原 App，含 CIDPU）

/// 车辆详情页 —— 对应原 App 的「车辆详情」。
struct VehicleDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// 本页自己的提示（蓝牙不可用等原因）—— 不能复用主界面的 `actionHint`
    @State private var hint: String?

    /// 车辆爱称（与主界面共用同一个 UserDefaults 键，改完立刻同步）
    @AppStorage(VehicleProfile.nicknameKey) private var nickname = VehicleProfile.defaultNickname
    /// 编辑爱称的弹窗开关与草稿
    @State private var showRename = false
    @State private var draftNickname = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // ★ 博越 PRO 车图（原 App NL3B 模型）
                    CarImage(named: "car_on")
                        .frame(maxHeight: 160)
                        .padding(.top, 10)

                    VStack(spacing: 0) {
                        Button {
                            draftNickname = nickname
                            showRename = true
                        } label: {
                            HStack {
                                Text("车辆爱称")
                                    .font(.subheadline).foregroundStyle(.primary)
                                Spacer()
                                Text(nickname)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "pencil")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .alert("车辆爱称", isPresented: $showRename) {
                            TextField("比如「小白」", text: $draftNickname)
                                .textInputAutocapitalization(.never)
                            Button("保存") {
                                nickname = VehicleProfile.sanitize(draftNickname)
                            }
                            Button("恢复默认") {
                                nickname = VehicleProfile.defaultNickname
                            }
                            Button("取消", role: .cancel) { }
                        } message: {
                            Text("最多 \(VehicleProfile.maxNicknameLength) 个字。只改本机显示，不影响车端。")
                        }
                        Divider()
                        row("CIDPU（后 8 位）", cidpuText, mono: true)
                        Divider()
                        row("连接状态", model.ble.isWriteReady ? "蓝牙连接 iPhone" : "未连接")
                        Divider()
                        row("车辆型号", "博越 PRO")
                        Divider()
                        row("最近动作", model.measured.lastSucceededAction?.label ?? "—")
                        Divider()
                        row("状态帧 (05)", model.measured.vehicleState.isEmpty
                            ? "—" : model.measured.vehicleState.hexDescription, mono: true)
                        Divider()
                        row("已登记手机", model.measured.pairedDeviceNames.isEmpty
                            ? (model.measured.isQueryingDeviceNames ? "查询中…" : "未知（点下方「查询」）")
                            : model.measured.pairedDeviceNames.joined(separator: ", "))
                        Divider()
                        Button {
                            // ★ 不在这里拦「未连接」：查询同样走 `01→02→03(0x0D)`
                            //   完整鉴权链，`AppModel.perform` 会自动连接后补发。
                            //   之前 `.disabled(!isWriteReady)` 让这个按钮在未连接时
                            //   变灰不可点，用户只能先手动触发一次控车把链路拉起来，
                            //   属于「点了没反应」的同类问题。
                            guard model.ble.managerState == .poweredOn else {
                                hint = "蓝牙未开启，无法查询车端名册。\n请先在系统设置里打开蓝牙。"
                                return
                            }
                            model.requestPairedDeviceNames()
                        } label: {
                            Label(model.measured.isQueryingDeviceNames
                                  ? "正在查询…" : "查询车端已配对手机",
                                  systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                        // ⚠️ 不加 `.disabled`：`pendingAction` 在极少数路径下
                        //    （未收到 0x0F 就断开）可能残留，disabled 会让按钮
                        //    永久变灰、再也点不动。重复点只是重发一次幂等查询。
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))

                    // ★★★ 车辆状态（照原 App parseBroadcastData: 广播解密）
                    if let st = model.measured.status {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("车辆状态")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            statusGrid(st)
                            Text(st.fullDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }

                    if cidpuText == "未获取" {
                        Text("CIDPU 由车端在连接后下发；配对成功或鉴权通过后即可看到。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("车辆详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("提示", isPresented: Binding(get: { hint != nil },
                                            set: { if !$0 { hint = nil } })) {
                Button("知道了", role: .cancel) { hint = nil }
            } message: {
                Text(hint ?? "")
            }
        }
    }

    private var cidpuText: String {
        if let s = KeyStore.shared.cidpuDisplayHex, !s.isEmpty { return s }
        return "未获取"
    }

    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            Text(v)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// 车辆状态栅格：门锁 / 后备箱 / 上电 / 发动机 / ACC / 四门
    private func statusGrid(_ s: VehicleStatus) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        let items: [(String, String, Bool)] = [
            ("门锁", s.isLocked ? "已锁" : "未锁", s.isLocked),
            ("车门", s.isDoorClosed ? "已关" : "未关", s.isDoorClosed),
            ("后备箱", s.isTrunkClosed ? "已关" : "打开", s.isTrunkClosed),
            ("上电", s.isIgnitionOn ? "已上电" : "未上电", s.isIgnitionOn),
            // 发动机取 bit6:bit5 两位编码，==2 才运行（照原 App strtol(base2)==2）；
            // 未运行时把原始编码带出来，方便判断是车端没报还是位映射问题。
            ("发动机", s.isEngineRunning ? "运行中" : "停止 (e\(s.engineStateCode))", s.isEngineRunning),
            ("ACC", s.isAccOn ? "开" : "关", s.isAccOn),
        ]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 4) {
                    Text(item.1)
                        .font(.subheadline.bold())
                        .foregroundStyle(item.2 ? Color.green : Color.primary)
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
