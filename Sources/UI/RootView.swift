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
    /// 密钥详情（点「数字钥匙已就绪」进入）
    @State private var showKeys = false
    /// 网络通道配置（2026-11-04）
    @State private var showCloud = false
    /// 底部标签栏当前页（0 控制 / 1 状态 / 2 我的）
    ///
    /// 默认 0。DEBUG 下可以用启动参数 `-startTab 1` 直达某一页 ——
    /// 状态页的字段表要验证排版时，省得每次手动去点。
    @State private var tab: Int = {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "startTab")
        #else
        return 0
        #endif
    }()
    /// 「我的」页要展示的账号信息（异步从云端凭据读）
    @State private var account: GKCloudCredentials?
    /// 点击「当前不可执行」的按钮时，用它弹出明确原因。
    ///
    /// 之前控车按钮直接 `.disabled(!isWriteReady)`：未连接时按钮变灰、
    /// 点了毫无反馈，用户分不清是"没连上"还是"App 坏了"。
    /// 现在改成**可点击 + 弹提示**，每次点击都有回应。
    @State private var actionHint: String?

    /// 远程启动引擎的二次确认（着车有实际后果：尾气、误启动）
    @State private var confirmingEngineStart = false
    /// 熄火确认。标签固定是「启动引擎」，所以运行时点它要明确说清
    /// "这一下是熄火"，不能让标签和行为对不上。
    @State private var confirmingEngineStop = false
    /// 空调温度选择面板
    @State private var showACPicker = false
    /// 上次设定的空调温度（抓包里 `rce` 的值，摄氏度）
    @AppStorage(CloudPrefs.acTemperature) private var acTemperature = CloudPrefs.defaultACTemperature

    /// 自动解锁开关 —— 与密钥详情页的 Toggle 读同一个 key，两处永远同步
    @AppStorage(ProximityUnlockController.enabledKey) private var autoUnlockOn = false

    /// 危险动作是否需要长按确认（默认开启）
    ///
    /// 覆盖：后备箱、开窗、微开、寻车 —— 这四个误触的后果都要人去现场收拾。
    /// 闭锁 / 关窗 / 解锁不在其中（前两个是"更安全"方向；解锁有二次确认的替代方案，
    /// 但单击解锁是最高频操作，加长按会让每次上车都变慢）。
    @AppStorage("gkuiblekey.holdToConfirm") private var holdToConfirm = true

    /// 未锁车本地提醒（`VehicleNotifier` 读同一个 key）
    @AppStorage(VehicleNotifier.enabledKey) private var notificationEnabled = true

    @State private var showActionHistory = false

    /// 「其余字段」折叠区是否展开。
    ///
    /// 常态收起（三十多条会把页面拉长一倍）。DEBUG 下 `-expandLeftover 1`
    /// 可以直接展开，用来验证翻译后的排版。
    #if DEBUG
    @State private var leftoverExpanded = UserDefaults.standard.bool(forKey: "expandLeftover")
    #else
    @State private var leftoverExpanded = false
    #endif

    /// 车辆爱称（详情页可改，持久化在 UserDefaults）
    ///
    /// 本 App 只服务这一台车，所以不做「按 cidpu 分键」的多车抽象 ——
    /// 一个全局键就够，换车时重新配对会覆盖同一台车的密钥，爱称手动改即可。
    @AppStorage(VehicleProfile.nicknameKey) private var vehicleNickname = VehicleProfile.defaultNickname
    private let vehicleModelName = VehicleProfile.defaultModelName

    var body: some View {
        ZStack(alignment: .top) {
            background

            // ★ 三页标签栏（2026-11-04）
            //
            // 原来所有内容堆在一页，设置项挂在右上角的汉堡菜单里 ——
            // 一个入口能到达的东西有两个入口，用户还得先记住"设置在哪"。
            //
            // 现在按「控制 / 状态 / 我的」拆开：
            //   控制 = 车图 + 一键控车（高频，要一眼看到）
            //   状态 = 全部车辆数据与链路诊断（低频，但要看全）
            //   我的 = 账号 + 设置（几乎不点，但必须有）
            //
            // 标签栏用系统 `TabView`：iOS 26 起系统会把它渲染成 Liquid Glass
            // （半透明材质 + 边缘折射 + 内容滚动时收窄），自己画反而做不像。
            TabView(selection: $tab) {
                controlPage
                    .tag(0)
                    .tabItem { Label("控制", systemImage: "car.fill") }
                statusPage
                    .tag(1)
                    .tabItem {
                        Label("状态", systemImage: "gauge.with.dots.needle.67percent")
                    }
                profilePage
                    .tag(2)
                    .tabItem { Label("我的", systemImage: "person.crop.circle") }
            }
            // 标签切换的触感（2026-11-07 用户要求）。
            //
            // 用 `Haptics.select`（`SensoryFeedback.selection`）而不是 `Haptics.tap`：
            // 换页是"选中项变了"，不是"执行了一个动作"，系统对这两种交互的
            // 手感有明确区分 —— selection 更轻、更短，连续点几个标签也不会烦。
            //
            // 注意不能每个 tab 的 `.tabItem` 里各挂一个手势：`.tabItem` 只接受
            // 纯 label，任何修饰符都会被丢弃。所以只能挂在 `TabView` 上，
            // 用 selection 的变化做触发源。
            .sensoryFeedback(trigger: tab) { _, _ in Haptics.select }

            // ★ 控件反馈横幅（2026-11-02）：控制中心点下去后，至少让人看见"收到了"。
            if let banner = model.controlBanner {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text(banner).font(.footnote.weight(.medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassPill()
                    // 它盖在所有内容之上 1.5 秒，没有投影就只是"一块糊在文字上的色块"，
                    // 用户读不清它压住的是什么，也读不清自己。
                    .glassElevation(.floating)
                    Spacer()
                }
                .padding(.top, 54)
                .padding(.horizontal, Glass.pageMargin)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.controlBanner)
        .onAppear { model.autoConnect() }
        .onChange(of: model.ble.bluetoothStatusText) { _, _ in
            if model.ble.isBluetoothReady { model.autoConnect() }
        }
        .sheet(isPresented: $showDeveloper) { DeveloperMenuView() }
        .sheet(isPresented: $showPairing) { PairingView() }
        .sheet(isPresented: $showKeys) { KeyInspectorView() }
        .sheet(isPresented: $showCloud) { CloudSettingsView() }
        .sheet(isPresented: $showACPicker) {
            ACTemperatureSheet(temperature: $acTemperature) {
                showACPicker = false
                model.performOnCloud(.airConditioner(on: true, temperature: acTemperature))
            }
        }
        .alert("暂时无法执行", isPresented: Binding(
            get: { actionHint != nil },
            set: { if !$0 { actionHint = nil } }
        )) {
            Button("去连接") { actionHint = nil; model.autoConnect() }
            Button("知道了", role: .cancel) { actionHint = nil }
        } message: {
            Text(actionHint ?? "")
        }
        // 远程启动引擎的二次确认
        .alert("远程启动引擎？", isPresented: $confirmingEngineStart) {
            Button("取消", role: .cancel) {}
            Button("启动") { model.performOnCloud(.engine(on: true)) }
        } message: {
            Text("车辆会启动发动机。请确认车门已关闭、车辆不在密闭空间（车库、室内）。")
        }
        // 发动机正在转时，同一个按钮执行的是熄火 —— 必须在这里说清楚
        .alert("发动机正在运行，要熄火吗？", isPresented: $confirmingEngineStop) {
            Button("取消", role: .cancel) {}
            Button("熄火", role: .destructive) { model.performOnCloud(.engine(on: false)) }
        } message: {
            Text("这个按钮在运行状态下是「熄火」，与标签写的「启动引擎」相反。不确定的话点取消。")
        }
        // ★ 外部链接来的「开后备箱 / 解锁 / 寻车」必须先确认。
        //   自定义 URL 无法校验来源，不拦就等于允许任意网页开车门。
        .alert("确认操作", isPresented: Binding(
            get: { model.pendingExternalAction != nil },
            set: { if !$0 { model.cancelExternalAction() } }
        )) {
            Button("取消", role: .cancel) { model.cancelExternalAction() }
            Button("确认执行", role: .destructive) { model.confirmExternalAction() }
        } message: {
            Text(model.externalActionPrompt)
        }
    }

    // MARK: - 三页

    /// 第一页：控车。车图 + 状态芯片 + 一键按钮，全都在首屏，不用滚。
    private var controlPage: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    vehicleHeader

                    // ★ 车图 + 状态浮标 + 能源读数，全在一张舞台里（2026-11-07）
                    //
                    // 原来是「车图 / 通道胶囊 / 四门一行 / 天窗车窗引擎一行 / 能源三格」
                    // 五段纵向堆叠，说明部分比车还高。现在状态全部收进车图四周，
                    // 能源悬浮在车图下沿，整块高度从约 320 降到约 205。
                    carArt
                        .padding(.top, 6)
                        // 10 不是 14：能源带自身有 5pt 内边距，视觉上已经隔开一段，
                        // 再用 sectionSpacing 会让车图区和下面两张卡变成三段等距，
                        // 反而看不出"车图 + 能源"是一组。
                        .padding(.bottom, 10)

                    // ★ 车辆位置（2026-11-07 用户要求挪到车控页）
                    //
                    // 位置放在「车图」与「控制按钮」之间，是这一页的语义分界：
                    // 上面回答"车是什么状态、在哪"，下面回答"要它做什么"。
                    //
                    // 用紧凑版（横排小地图 + 两行字，约 76 高），不用状态页那张
                    // 完整卡 —— 完整卡会把「启动引擎」挤到第二屏，而它是这一页
                    // 最重的动作。点一下仍然进全屏地图 + 导航。
                    if let coord = model.activeStatus.snapshot?.coordinate {
                        VehicleLocationCard(
                            coordinate: coord,
                            title: VehicleProfile.displayName(custom: vehicleNickname),
                            style: .compact
                        )
                        .padding(.horizontal, 6)
                        .padding(.bottom, Glass.sectionSpacing)
                    }

                    // 点火 / 启动引擎已经并进控制区网格（与其余按钮同构），
                    // 这里不再单独占一行卡片。
                    controlSection
                }
                // 底部留白给悬浮标签栏（见 `Glass.tabBarInset`）
                .padding(.bottom, Glass.tabBarInset)
            }
            // 下拉刷新两条通道（见 `AppModel.refreshAll`）
            .refreshable { await model.refreshAll() }
        }
        .padding(.horizontal, Glass.pageMargin)
        .background(background)
    }

    /// 第二页：详细状态。链路诊断、无感进入、点火验证这些低频但要看全的东西。
    private var statusPage: some View {
        VStack(spacing: 0) {
            pageHeader("车辆状态", subtitle: statusPageSubtitle)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 12) {
                    // 这里原来还有一排「已锁 / 门关 / 后备箱关 / 未启动 / ACC关」芯片。
                    // 俯视图卡片已经把同样八项按瓦片排好了，再叠一排等于同一份数据看两遍，
                    // 而且五个芯片挤在 362 宽里经常折行。删掉。
                    statusSection
                }
                .padding(.bottom, Glass.tabBarInset)
            }
            .refreshable { await model.refreshAll() }
        }
        .padding(.horizontal, Glass.pageMargin)
        .background(background)
    }

    /// 第三页：我的。账号 + 设置 —— 原先汉堡菜单里的东西全在这里。
    private var profilePage: some View {
        VStack(spacing: 0) {
            pageHeader("我的", subtitle: nil)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    accountCard
                    settingsCard
                    aboutCard
                }
                .padding(.bottom, Glass.tabBarInset)
            }
        }
        .padding(.horizontal, Glass.pageMargin)
        .background(background)
        .task { await loadAccount() }
        .onChange(of: model.cloudConfigured) { _, _ in
            Task { await loadAccount() }
        }
        // 两个新的二级页挂在这一页上（而不是和另外 5 个 sheet 挤在最外层）：
        // 同一层叠太多 `.sheet(isPresented:)` 会互相覆盖，分散挂载更稳。
        .sheet(isPresented: $showActionHistory) {
            ActionHistoryView()
        }
    }

    /// 状态页的「靠近解锁」详情卡片。
    ///
    /// 只在**开启且已标定**时出现 —— 关掉时它只会变成一张「未启用」的噪音卡。
    private var proximityDetailCard: some View {
        let prox = model.proximityUnlock
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(prox.phase == .inside ? Color.green : Color.secondary)
                Text("靠近解锁")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(prox.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(prox.phase == .inside ? Color.green : Color.secondary)
            }

            HStack(spacing: 16) {
                proximityMetric("解锁阈值",
                                prox.unlockThreshold.map { "\($0) dBm" } ?? "—", .cyan)
                proximityMetric("闭锁阈值",
                                prox.lockThreshold.map { "\($0) dBm" } ?? "—", .orange)
                proximityMetric("当前",
                                String(format: "%.0f", prox.lastCombinedRSSI), .primary)
                Spacer()
            }

            if let a = prox.lastAction, let at = prox.lastActionAt {
                Text("最近一次：\(a.rawValue) · \(AppModel.hhmm(at))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(radius: Glass.controlRadius, elevated: false)
    }

    private func proximityMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    /// 状态页排版调试：隐藏顶部的俯视图与地图，让字段区直接出现在首屏。
    ///
    /// 真机和模拟器都没法"滚屏截图"，而字段区恰好在下半页 ——
    /// 没有这个开关，改一次字段排版就得靠用户帮忙滚一下。
    /// Release 下恒为 false。
    private var hideStatusTop: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "hideStatusTop")
        #else
        return false
        #endif
    }

    // MARK: - 背景

    /// 全屏底统一走 `GlassScreenBackground`（渐变 + 氛围光）。
    ///
    /// 之前这段渐变只在本页有，二级页用的是纯 `systemBackground` ——
    /// 同一块 `.ultraThinMaterial` 在两种底上看起来像两种材质，
    /// 这是"风格不统一"最根本的一处。
    private var background: some View {
        GlassScreenBackground()
    }

    // MARK: - 顶部标题栏

    private var topBar: some View {
        HStack(spacing: 10) {
            // 蓝牙状态胶囊（点色 + 文案）—— 只说车在不在。
            // 第二行补上「钥匙状态 + 最近一次车辆数据的时间」：
            // 这两条原来在状态页那张俯视图的底部，属于同一个问题
            // （「我的钥匙现在能不能跟车说上话」），拆到两页反而要来回翻。
            bluetoothStatusPill

            // RSSI 信号值。
            //
            // ★ 抽成独立的 `RSSIPill` 订阅 `BLECentral`（2026-11-07）。
            //
            // 它每收到一帧广播就变（0.5 秒一次）。原来这个值直接读
            // `model.ble.rssi`，而 RootView 只订阅了 AppModel —— 也就是说
            // 这里**根本收不到 ble 的 objectWillChange**。
            // 当时它能刷新，靠的是 `lastBluetoothStatusAt` 每帧赋值触发的
            // AppModel 全量重绘（一个无意的副作用）。
            //
            // 现在把那个副作用去掉（它让整个 RootView 每秒重建 2 次），
            // 改成这个小视图自己订阅：2Hz 只重绘一个胶囊。
            RSSIPill(ble: model.ble)

            Spacer()
            // 汉堡菜单已移除（2026-11-04）：设置项全部搬到「我的」页。
            // 这里只留一个通道指示 —— 它回答"现在点按钮会走哪条路"，
            // 点一下直接跳到「我的」。
            Button {
                tab = 2
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.preferredChannel == .bluetooth
                          ? "bolt.horizontal.circle.fill" : "wifi.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(model.preferredChannel.label)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(model.preferredChannel == .bluetooth ? Color.blue : .green)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .glassPill()
            }
            .buttonStyle(.plain).tactile()
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: - 蓝牙状态胶囊

    /// 顶栏的蓝牙状态胶囊：第一行「蓝牙 · 已连接」，第二行「钥匙就绪 · 19:28」，
    /// 第三行（仅靠近解锁开启且已标定时）显示自动解锁的实时阶段。
    private var bluetoothStatusPill: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(vehicleStatusColor)
                    .frame(width: 7, height: 7)
                Text(vehicleStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 3) {
                Image(systemName: model.hasLocalKey ? "key.fill" : "key.slash")
                    .font(.system(size: 9, weight: .bold))
                Text(keyStatusText)
                    .font(Glass.Typo.micro.weight(.medium))
                    .monospacedDigit()
            }
            .foregroundStyle(model.hasLocalKey ? Color.secondary : Color.orange)

            // 第三行：靠近解锁正在做什么。
            //
            // 之前这个功能只在「我的 → 钥匙 → 密钥管理」第三层能看到状态，
            // 用户站在车边不解锁时，界面上没有任何线索说明它到底在跑没有。
            // 只显示"有信息量"的三种情况，远处时为 nil，不占位。
            if let p = proximityStatusText {
                HStack(spacing: 3) {
                    Image(systemName: "hand.wave.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(p)
                        .font(Glass.Typo.micro.weight(.medium))
                        .monospacedDigit()
                }
                .foregroundStyle(model.proximityUnlock.phase == .inside ? Color.green : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassPill()
    }

    /// 顶栏第三行的文案。`nil` = 不显示。
    private var proximityStatusText: String? {
        guard model.proximityUnlock.isEnabled,
              model.proximityUnlock.calibration != nil else { return nil }
        switch model.proximityUnlock.phase {
        case .inside:
            return "已自动解锁"
        case .boundary:
            return "迟滞带 · 待定"
        case .far:
            // 只在「正在攒停留时间」时显示，纯远处不占位置
            let s = model.proximityUnlock.summary
            return s.hasPrefix("靠近中") ? s : nil
        }
    }

    // MARK: - 车辆标题

    private var vehicleHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // ★ 没改过昵称时不显示「爱车」（2026-11-07 用户要求）
            //
            // 那两个字是**占位词**，不是信息：只服务一台车的人不需要被告知
            // "这是你的车"。现在没自定义昵称就直接把车型当标题，
            // 改过昵称才显示"昵称 + 车型标签"两级结构。
            Text(VehicleProfile.displayName(custom: vehicleNickname))
                .font(Glass.Typo.page)
                .foregroundStyle(.primary)
                .lineLimit(1)

            if VehicleProfile.hasCustomName(vehicleNickname) {
                Text(vehicleModelName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .surfaceChip()
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    /// 顶栏第一行：只回答"车现在能不能聊上"。
    ///
    /// 三态而不是两态 —— 蓝牙没连但云端可用时，用户点按钮仍然能控车，
    /// 写「离线」会让他以为按键无效。
    private var vehicleStatusText: String {
        if model.bluetoothLinkAlive { return "蓝牙 · 已连接" }
        if model.isVehicleOnline { return "蓝牙 · 最近在线" }
        if model.cloudConfigured { return "云端 · 可用" }
        return "离线"
    }

    private var vehicleStatusColor: Color {
        if model.bluetoothLinkAlive { return Glass.Tone.success }
        // 「最近在线」原用 yellow，与 warning(orange) 是同一语义的两档 —— 合并
        if model.isVehicleOnline { return Glass.Tone.warning }
        if model.cloudConfigured { return .gray }
        return .secondary
    }

    /// 「钥匙就绪 · 19:28」/「钥匙未绑定」/「钥匙就绪」
    ///
    /// 时间取 `activeStatus` 的时点 —— 蓝牙时是最后一次收到广播的时间，
    /// 云端时是这次拉取的时间。**不写 `Date()`**：状态反映的是那一刻的车况。
    private var keyStatusText: String {
        guard model.hasLocalKey else { return "钥匙未绑定" }
        guard let at = model.activeStatus.source.at else { return "钥匙就绪" }
        return "钥匙就绪 · " + AppModel.hhmm(at)
    }

    /// 可以用来做「下一步推荐」的状态快照。
    ///
    /// 判据从 `measured.status` 换成了 `activeStatus`（2026-11-04）：
    /// 只有云端数据时，主控页原来永远不推荐任何按钮，而状态页明明显示着「未锁」。
    /// 现在两条通道共用一套数据，只是**推荐**比**展示**更保守
    /// （`recommendationWindow` 120s < `cloudWindow` 180s）。
    private var recommendableSnapshot: VehicleSnapshot? {
        let active = model.activeStatus
        guard let snap = active.snapshot, let at = active.source.at else { return nil }
        return Date().timeIntervalSince(at) <= StatusFreshness.recommendationWindow ? snap : nil
    }

    /// 状态页副标题。文案统一由 `StatusSource.displayText` 生成，
    /// 这里只补两处这一页特有的信息。
    private var statusPageSubtitle: String {
        let active = model.activeStatus
        switch active.source {
        case .bluetooth:
            var text = active.source.displayText
            // 车窗 / 天窗蓝牙广播里没有，是用云端补的 —— 说出来，
            // 否则用户会以为整页都是秒级数据
            if active.snapshot?.isWindowsKnown == true {
                text += " · 窗位来自云端"
            }
            return text
        case .cloud:
            return (active.snapshot?.isFresh ?? false)
                ? active.source.displayText
                : "云端数据过期"
        case .none:
            return active.source.displayText
        }
    }

    /// 二级页的统一标题（没有汉堡菜单，右侧留给通道状态）
    private func pageHeader(_ title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Glass.Typo.page)
            if let subtitle {
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .glassPill()
            }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 「我的」页组件

    private func loadAccount() async {
        account = await model.cloud.snapshotOfCredentials()
    }

    /// 手机号脱敏：138****8000。完整号码没有展示价值，反而容易被人瞄到。
    private func phoneMasked(_ phone: String) -> String {
        guard phone.count >= 7 else { return phone }
        return "\(phone.prefix(3))****\(phone.suffix(4))"
    }

    /// 账号卡：云端账号状态 + 入口
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: model.cloudConfigured
                      ? "person.crop.circle.badge.checkmark"
                      : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 28))
                    .foregroundStyle(model.cloudConfigured ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.cloudConfigured ? "云端账号" : "未配置云端账号")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.cloudConfigured
                         ? (account.map { phoneMasked($0.phone) } ?? "读取中…")
                         : "配置后可在任何地方远程控车")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button { showCloud = true } label: {
                Text(model.cloudConfigured ? "管理账号" : "去配置")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).tactile()
        }
        .padding(Glass.cardPadding)
        .contentCard()
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            settingRow(icon: "wifi",
                       title: "网络通道",
                       detail: model.cloudConfigured ? "已配置" : "未配置") {
                showCloud = true
            }
            divider
            // 靠近解锁的总开关与阈值都在密钥详情页 —— 这里只做状态提示与入口，
            // 避免同一个开关出现在两处、状态还各读各的（2026-11-05）
            settingRow(icon: "key.radiowaves.forward",
                       title: "靠近解锁",
                       detail: proximityDetail) {
                if model.hasLocalKey { showKeys = true } else { showPairing = true }
            }
            divider
            settingRow(icon: "key.fill",
                       title: model.hasLocalKey ? "车辆已绑定" : "绑定车辆",
                       detail: model.hasLocalKey ? "管理与解绑" : nil) {
                if model.hasLocalKey { showKeys = true } else { showPairing = true }
            }
            divider
            settingToggle(icon: "hand.raised.fill",
                          title: "危险动作长按确认",
                          detail: "后备箱 / 开窗 / 微开 / 寻车 需按住 0.6 秒",
                          isOn: $holdToConfirm)
            divider
            settingToggle(icon: "bell.badge.fill",
                          title: "未锁车提醒",
                          detail: "离开时若发现未锁 / 门未关，发一条本地通知",
                          isOn: $notificationEnabled)
            divider
            settingRow(icon: "clock.arrow.circlepath",
                       title: "操作历史",
                       detail: ActionHistory.shared.records.isEmpty
                           ? "还没有记录" : "最近 \(ActionHistory.shared.records.count) 条") {
                showActionHistory = true
            }
            divider
            settingRow(icon: "gearshape",
                       title: "设置",
                       // 菜单实际有四个分组：车辆 / 钥匙 / 高级（依赖标定）/ 调试。
                       detail: "车辆 · 钥匙 · 高级 · 调试") {
                showDeveloper = true
            }
        }
        .contentCard()
    }

    /// 设置页里「靠近解锁」那一行的说明
    private var proximityDetail: String {
        guard autoUnlockOn else { return "未开启" }
        guard model.passiveStart.isCalibrated else { return "需先标定" }
        return "已开启"
    }

    private var aboutCard: some View {
        VStack(spacing: 6) {
            Text("蓝牙钥匙")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("版本 \(appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("蓝牙通道在车边、不耗流量；网络通道在任何地方都可用")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    private var divider: some View {
        Divider().padding(.leading, 50)
    }

    private func settingRow(icon: String, title: String, detail: String?,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(title).font(.body)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).tactile()
    }

    /// 开关型设置行 —— 与 `settingRow` 同样的图标/内边距，只是右边是 Toggle
    private func settingToggle(icon: String, title: String, detail: String,
                               isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 车辆图（原 App 车辆模型帧 + 状态动画）

    /// 车辆舞台状态：连接阶段 → 对应动画
    private var carStage: CarModelView.Stage {
        // ★ 配对优先（2026-10-29 修复）：配对时链路通常已经 `.ready`，
        //   原来先判 `.ready` 会让 `.pairing` 永远走不到，车图不闪灯，
        //   但顶部胶囊写着「配对中」，两边自相矛盾。
        if model.pairingArmed { return .pairing }
        // ★ 判据从「链路就绪」改成「车辆在线」（2026-10-30）：
        //   车端每条命令后都断开，`linkState` 每 29 秒回落一次，
        //   车图会跟着一秒「等待连接」→ 一秒「就绪」地闪。
        //   在线是 60 秒窗口，抖动被吸收。
        if model.isVehicleOnline { return .ready }
        return .connecting
    }

    private var carArt: some View {
        // ★ 车图高度由这里显式传入，视图内部不再写死（2026-11-04 的教训：
        //   内外两套高度必然对不上，溢出部分会被下面的按钮压住）。
        //
        // 178 是「车图本体 + 上下两条浮标轨」的合计高度：
        // 车图按 1125×675 等比缩放到 338 宽时约 203 高，被 178 框住后
        // 实际渲染 297×178，左右各留约 20pt 给浮标呼吸。
        CarModelView(
            snapshot: displaySnapshot,
            stage: carStage,
            carHeight: 178,
            energy: energyReadout
        )
        .frame(maxWidth: .infinity)
        // 6pt 是给车图左右留的呼吸位（车图是 3/4 视角，边缘本身就是斜的）。
        // 能源读数带在这个 padding 内侧，会比标题多缩进 6pt —— 可接受：
        // 再往外顶会和车图轮眉贴上，反而显脏。
        .padding(.horizontal, 6)
    }

    /// 车图区实际渲染的状态。
    ///
    /// 正常就是 `activeStatus.snapshot`；DEBUG 下带 `-mockVehicle 1` 启动时
    /// 换成样张，用来在模拟器里检查"所有字段都有值"时的排版
    /// （理由见 `UIMockVehicle`）。
    private var displaySnapshot: VehicleSnapshot? {
        #if DEBUG
        if UIMockVehicle.isEnabled { return UIMockVehicle.snapshot }
        #endif
        return model.activeStatus.snapshot
    }

    // MARK: - 能源读数

    /// 三项**都来自云端**：蓝牙广播协议里没有油量和电压，所以只配了云端账号才有。
    ///
    /// 取不到的项不显示，三项都取不到时整条不出现 —— 不留一条写满「—」的空壳。
    private var energyReadout: EnergyReadout {
        #if DEBUG
        if UIMockVehicle.isEnabled { return UIMockVehicle.energy }
        #endif
        return EnergyReadout(
            // 只显示百分比：接口只给百分比，不给油箱容积。
            // 早前用 58 L 折算过升数并标了「估算」，但那是猜的容量，
            // 算出来的数字看着像实测值 —— 没有确切数据就不显示。
            fuelPercent: StatusFieldCatalog.number(StatusFieldCatalog.fuelLevelPath,
                                                   from: model.cloudFields),
            rangeKM: StatusFieldCatalog.number(StatusFieldCatalog.rangePath,
                                               from: model.cloudFields),
            batteryVolts: StatusFieldCatalog.number(StatusFieldCatalog.batteryVoltagePath,
                                                    from: model.cloudFields)
        )
    }

    // MARK: - 控车区

    private var controlSection: some View {
        VStack(spacing: Glass.sectionSpacing) {
            // 3 列网格，10 个按钮同一规格（图标 18 + caption + minHeight 62 + 玻璃胶囊）。
            //
            // ★ 解锁 / 闭锁也在这里面（2026-11-07 用户要求统一）。
            //   原来是"两大键"单独一行：圆角矩形、图标 26、headline、
            //   minHeight 78 —— 一屏里只它俩长得不一样，像另一套设计。
            //   现在形状、尺寸、字号全部一致，主次只由**图标颜色**区分
            //   （解锁绿 / 闭锁蓝）。形状表达"这是什么控件"，颜色表达
            //   "这个动作属于哪一类"，两个维度不该混用。
            //
            // 排布按语义分组，每行三个：
            //   锁相关 → 窗与找车 → 舒适与启动准备 → 启动引擎
            // 10 个不能被 3 整除，最后一行落一个 —— 引擎是"一次性的重量级动作"，
            // 单独一行反而合适，不硬凑。
            //
            // 「下一步推荐」的表达也从"高亮描边"改成了第三行文字
            // （`stateBadge`），与「点火」「启动引擎」的第三行同构。
            // 只在状态**新鲜**（≤ `StatusFreshness.recommendationWindow`）时给，
            // 过期状态只展示、不推荐 —— 否则可能推荐与实车相反的动作。
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible())], spacing: 10) {
                primaryAction(.unlock, "解锁", .green, "lock.open.fill",
                              stateBadge: recommendableSnapshot?.isLocked == true
                                  ? "当前已锁" : nil)
                primaryAction(.lock, "闭锁", .blue, "lock.fill",
                              stateBadge: recommendableSnapshot?.isLocked == false
                                  ? "当前未锁" : nil)

                // 误触代价高的三个走长按确认（`requiresHold`）；
                // 关窗是"更安全"方向，保持单击。
                secondaryAction(.openCloseTrunk, "后备箱", "car.side.rear.open", requiresHold: true)
                secondaryAction(.windowUp, "关窗", "arrow.up.square")
                secondaryAction(.windowDown, "开窗", "arrow.down.square", requiresHold: true)
                secondaryAction(.panic, "寻车", "light.beacon.max.fill", requiresHold: true)
                // 微开只能用网络：蓝牙协议里车窗只有开/关两态
                ventAction()
                // 空调 / 引擎启停：车端 BLE 协议里没有，**只能走云端**
                airConditionerAction
                // 点火（BLE 预授权）与启动引擎（云端）
                ignitionAction
                engineAction
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

    /// 主按钮 —— 解锁 / 闭锁。
    ///
    /// ## 与次要按钮同规格（2026-11-07 用户要求）
    ///
    /// 原来是自绘玻璃：圆角矩形 20、图标 26pt、标题 `.headline`、minHeight 78、
    /// 外加一圈 2pt 高亮描边 —— 一屏里就它俩长得不一样，像另一套设计。
    ///
    /// 现在改成与 `secondaryLabel` **完全同构**：
    /// 图标 18 + `.caption` 标题 + minHeight 62 + `.buttonStyle(.glass)` 胶囊，
    /// 并且并进同一个 3 列网格。
    ///
    /// **主次的区分改由颜色承担**：图标染 `tint`（解锁绿 / 闭锁蓝），
    /// 而不是靠尺寸和形状 —— 形状是"这是什么控件"的层级，
    /// 颜色才是"这个动作属于哪一类"的层级。之前混用了这两个维度。
    ///
    /// `stateBadge` 放在第三行（与「点火」「启动引擎」的第三行同构）。
    /// 没有它时用空格占位，保证与有第三行的按钮等高。
    private func primaryAction(
        _ action: IBCommandType, _ title: String, _ tint: Color, _ icon: String,
        stateBadge: String? = nil
    ) -> some View {
        Button {
            // ★ 不在 UI 层拦「未连接」——交给 `AppModel.perform` 处理。
            //   车端每条命令执行完会主动断开链路，"点完一次就无法再点"是常态；
            //   `perform` 能做「挂起动作 → 重连 → ready 后自动执行」。
            //   UI 先 guard 掉的话，那段逻辑永远走不到。
            guard model.ble.managerState == .poweredOn || model.preferredChannel == .network else {
                actionHint = "蓝牙未开启，且云端通道未配置。\n请先打开蓝牙，或在设置里配置云端账号。"
                return
            }
            model.perform(action)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                Text(title).font(.caption)
                // 第三行：有状态就显示，没有就用空格占位保持等高
                Text(stateBadge ?? " ")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .overlay(alignment: .topTrailing) {
                channelBadge(model.preferredChannel)
            }
        }
        .buttonStyle(.glass).tactile(Haptics.commit)
        // 不按连接状态调暗：能点的按钮不该画成不能点（见 v5.0 的说明）
    }

    /// 次要动作按钮。
    ///
    /// - Parameter requiresHold: 误触代价高的动作（后备箱 / 开窗 / 寻车）传 `true`，
    ///   走 `HoldToConfirmButton` 长按 0.6 秒；用户可在设置里关掉这个保护。
    @ViewBuilder
    private func secondaryAction(
        _ action: IBCommandType, _ title: String, _ icon: String,
        requiresHold: Bool = false
    ) -> some View {
        if requiresHold && holdToConfirm {
            HoldToConfirmButton(action: { runSecondaryAction(action) }) {
                secondaryLabel(icon, title)
            }
        } else {
            Button { runSecondaryAction(action) } label: {
                secondaryLabel(icon, title)
            }
            .buttonStyle(.glass).tactile()
        }
    }

    private func secondaryLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18))
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .overlay(alignment: .topTrailing) {
            channelBadge(model.preferredChannel)
        }
    }

    /// 次要动作的统一入口（原 `secondaryAction` 里的闭包体）。
    ///
    /// ★ 不在 UI 层拦「未连接」——交给 `AppModel.perform` 处理。
    ///
    /// 车端在每条命令执行完会主动断开链路（原 App 日志同样如此），
    /// 所以"点完一次就无法再点"是常态。v3.4 起 `perform` 已经能做到
    /// 「挂起动作 → 立刻重连已知设备 → ready 后自动执行」，
    /// 但如果 UI 先 guard 掉，那段逻辑就永远走不到（v3.4 的实际缺陷）。
    /// 现在只在**蓝牙不可用**时才提示，其余情况都由 perform 接管。
    private func runSecondaryAction(_ action: IBCommandType) {
        guard model.ble.managerState == .poweredOn || model.preferredChannel == .network else {
            actionHint = "蓝牙未开启，且云端通道未配置。\n请先打开蓝牙，或在设置里配置云端账号。"
            return
        }
        model.perform(action)
    }


    /// 通道角标 —— 蓝牙时是蓝色闪电，网络时是绿色 wifi。
    ///
    /// 需求只要求"蓝牙时显示角标"，但两种状态都给一个标记更实用：
    /// 用户能看出「现在这一下会走哪条路」，而不是在蓝牙时看到角标、
    /// 网络时什么都没有，只能靠猜。
    @ViewBuilder
    private func channelBadge(_ channel: ControlChannel) -> some View {
        let isBT = channel == .bluetooth
        Image(systemName: isBT ? "bolt.horizontal.circle.fill" : "wifi.circle.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isBT ? Glass.Tone.bluetooth : Glass.Tone.network)
            .padding(2.5)
            .surfaceBadge()
            .padding(6)
            .accessibilityLabel(isBT ? "将走蓝牙通道" : "将走网络通道")
    }

    /// 车窗微开 —— 只有云端支持（蓝牙协议只有开/关两态）。
    /// 按钮常驻，但会明确标出"需网络"。
    /// 微开 —— 只能走云端（蓝牙协议里车窗只有开/关两态，没有中间档）。
    ///
    /// 与「开窗」同类：开着窗离开 = 进水风险，所以同样走长按确认。
    @ViewBuilder
    private func ventAction() -> some View {
        if holdToConfirm {
            HoldToConfirmButton(action: { runVentWindow() }) { ventLabel }
        } else {
            Button { runVentWindow() } label: { ventLabel }
                .buttonStyle(.glass).tactile()
        }
    }

    private var ventLabel: some View {
        VStack(spacing: 6) {
            Image(systemName: "wind.circle").font(.system(size: 18))
            Text("微开").font(.caption)
            Text("需网络").font(.system(size: 9, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .overlay(alignment: .topTrailing) {
            channelBadge(.network)
        }
    }

    private func runVentWindow() {
        guard model.ble.managerState == .poweredOn || model.cloudConfigured else {
            actionHint = "蓝牙未开启，且云端通道未配置。\n请先打开蓝牙，或在设置里配置云端账号。"
            return
        }
        model.ventWindow()
    }

    // MARK: - 空调 / 引擎（仅云端）

    /// 远程空调。
    ///
    /// 车端 BLE 协议里**没有**空调命令（原厂 App 也做不到），所以这个按钮
    /// 只走云端。状态取自云端 `climateStatus.preClimateActive`；
    /// 没拿到就显示「开空调」，点下去按当前状态取反。
    private var airConditionerAction: some View {
        let on = model.cloudAirConditionerOn
        let title = on == true ? "关空调" : "开空调"

        return Button {
            guard model.cloudConfigured else { return ackNoCloud() }
            if on == true {
                // 关空调：服务端同样要求带 `rce` 参数，用本地记住的温度。
                // 注意这不是「车内实际设定温度」—— 那个值云端有，但字段不固定，
                // 拿本地值更稳（服务端对关命令的 rce 基本只做格式校验）。
                model.performOnCloud(.airConditioner(on: false, temperature: acTemperature))
            } else {
                // 开空调：温度是必填参数，先让用户选
                showACPicker = true
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "snowflake").font(.system(size: 18))
                Text(title).font(.caption)
                // 副标题只保留温度：参数已固化，不再有"待配置"这个状态
                Text("\(acTemperature)°" + (on == true ? "" : " 起步"))
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .foregroundStyle(.primary)
            .overlay(alignment: .topTrailing) {
                channelBadge(.network)      // 明确告诉用户：这一下走网络
            }
        }
        .buttonStyle(.glass).tactile()
    }

    /// 远程启动引擎（云端）。
    ///
    /// ## 标签为什么固定写「启动引擎」
    /// 原来这个按钮会随状态改成「熄火 / 启动引擎」。但在一屏胶囊里，
    /// 一个会自己改标签的按钮反而更迷惑 —— 用户扫一眼不知道该点哪个。
    /// 现在标签固定，状态放进第三行（运行中 / 已熄火），
    /// 运行状态下点它仍然执行熄火，但会弹一次明确写"熄火"的确认框。
    private var engineAction: some View {
        let running = model.activeStatus.snapshot?.isEngineRunning

        return Button {
            guard model.cloudConfigured else { return ackNoCloud() }
            if running == true {
                confirmingEngineStop = true
            } else {
                confirmingEngineStart = true
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "power").font(.system(size: 18))
                Text("启动引擎").font(.caption)
                Text(running == true ? "运行中"
                     : (running == false ? "已熄火" : "状态未知"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .overlay(alignment: .topTrailing) {
                channelBadge(.network)
            }
        }
        .buttonStyle(.glass).tactile()
    }

    private func ackNoCloud() {
        actionHint = "「空调 / 启动熄火」只能走网络通道。\n请先在「我的 → 网络通道」配置 GKUI 账号。"
    }

    // MARK: - 状态区

    private var statusSection: some View {
        let active = model.activeStatus
        return VStack(spacing: Glass.sectionSpacing) {
            // ★ 俯视图 + 全量标注（2026-11-04）
            //
            // 侧视图（car_on）好看但看不出哪里开着 —— 3/4 视角下四门互相遮挡。
            // 俯视图四门四窗在平面上,可以把状态直接标在位置上。
            // ★ 蓝牙优先、云端兜底（2026-11-04）
            //
            // 判定在 `AppModel.activeStatus`：蓝牙**新鲜**（收到过且 60 秒内还在线）
            // 就用蓝牙，否则用云端。俯视图底部会把来源和时间标出来。
            if !hideStatusTop {
                VehicleTopView(snapshot: active.snapshot,
                               // 上电 / ACC 只有蓝牙有。蓝牙不活跃时必须传 nil ——
                               // `measured.status` 车走了也不清空，会把最后一次
                               // 蓝牙看到的上电状态一直挂在页面上。
                               status: model.bluetoothStatusIsLive ? model.measured.status : nil,
                               onOpenKey: {
                                   if model.hasLocalKey { showKeys = true } else { showPairing = true }
                               },
                               onOpenCloud: { showCloud = true })
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentCard()

                // 车辆位置：只有云端车况带坐标，纯蓝牙时整卡不出现。
                // 放在俯视图之后 —— 一个回答"车什么状态"，一个回答"车在哪"。
                if let coord = active.snapshot?.coordinate {
                    VehicleLocationCard(coordinate: coord,
                                        title: VehicleProfile.displayName(custom: vehicleNickname))
                }
            }

            // 靠近解锁：只在功能开启且已标定时出现。
            // 状态页是"看全"的地方，这里给阈值和实时值，排障时不用进三层菜单。
            if model.proximityUnlock.isEnabled, model.proximityUnlock.calibration != nil {
                proximityDetailCard
            }

            // ★ 精选字段（2026-11-04）
            //
            // 服务端回了七十多个字段，其中一半是车厂调试用的原始位。
            // 这里只列对用户有判断价值的，每项带一句「这个值意味着什么」。
            // 白名单之外的收进底部折叠区，保证不丢数据。
            if !model.cloudFields.isEmpty {
                curatedFieldsSection
            }

            // 蓝牙适配器异常提示（一错后面全白搭，排在状态图之后）
            if !model.ble.isBluetoothReady {
                alertCard(icon: "exclamationmark.triangle.fill",
                          color: .orange,
                          title: "蓝牙\(model.ble.bluetoothStatusText)",
                          detail: hintForBluetoothState)
            }

            // ★ 动作结果 / 拒绝原因
            //
            // `perform` 的所有反馈都只写 `model.statusLine`：未连接、锁定中、
            // 密钥完整性失败、鉴权构造失败、4 秒超时……
            // 之前主界面一处都没渲染，用户点解锁后界面零回应，以为按钮坏了。
            if !model.statusLine.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: statusLineIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(statusLineColor)
                        .padding(.top, 1)
                    Text(model.statusLine)
                        .font(.caption2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                // 图标保留色相（形状 + 颜色双重编码），文字回到 primary。
                //
                // 原来整条都用 `statusLineColor` —— 浅色模式下系统 `green` 对浅底
                // 只有约 2:1、`orange` 约 2:1，低于可读下限。而这行恰恰是
                // 「失败 / 超时 / 被锁定」的唯一反馈，是最该看清的地方。
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(statusLineColor.opacity(0.13),
                            in: RoundedRectangle(cornerRadius: Glass.pillRadius, style: .continuous))
            }
        }
        .padding(.bottom, 12)
        .animation(.easeInOut(duration: 0.15), value: model.statusLine)
    }

    /// 精选字段 —— **按语义分组，全部直接展示**。
    ///
    /// ★ 2026-11-07 重做分组方式。
    ///
    /// 之前只有一刀切：白名单里的平铺，其余全塞进「其他原始字段」折叠区。
    /// 那是按**代码结构**分组，不是按内容 —— 结果胎压预警、防盗布防这些
    /// 最该一眼看到的字段被折起来了，而"平均车速"这种看一眼就够的反而常驻。
    ///
    /// 现在白名单之外的字段按语义归到同一组里（`StatusFieldCatalog.bucket`）：
    /// 例如 `drivingSafetyStatus.safetyBeltStatusDriver` 会跟在「安全」组里，
    /// 而不是躲在折叠区。折叠只留给真正次要的东西（出厂配置、认不出的 key）。
    private var curatedFieldsSection: some View {
        VStack(spacing: Glass.innerSpacing) {
            ForEach(StatusFieldCatalog.sections, id: \.title) { section in
                let rows = fieldRows(for: section)
                if !rows.isEmpty {
                    fieldSectionCard(title: section.title, rows: rows)
                }
            }

            foldableSection
        }
    }

    /// 一个语义分组里所有要显示的行：白名单精译过的在前，同族的在后。
    private func fieldRows(for section: (title: String, specs: [StatusFieldSpec])) -> [FieldRow] {
        var rows: [FieldRow] = section.specs.compactMap { spec -> FieldRow? in
            guard let v = StatusFieldCatalog.resolve(spec, from: model.cloudFields) else { return nil }
            return FieldRow(id: spec.path,
                            title: spec.title,
                            note: spec.note,
                            value: v,
                            tone: valueTone(spec, v),
                            resolved: true)
            // 白名单的 `resolve` 已经做过格式化（单位、布尔转中文），
            // 所以这里 kind 保持默认 .text，不要再转一次。
        }

        rows += StatusFieldCatalog.extras(for: section.title, from: model.cloudFields).map { f in
            let m = FieldGlossary.meaning(for: f)
            return FieldRow(id: f.id,
                            title: m.title,
                            note: m.note,
                            value: f.value,
                            // 没有语义色规则可用：Extra 字段的取值域未知，
                            // 按"不知道就中性"处理，不用颜色暗示好坏。
                            tone: .primary,
                            resolved: m.resolved,
                            kind: m.kind)
        }
        return rows
    }

    /// 一行可展示的字段。
    private struct FieldRow: Identifiable {
        let id: String
        let title: String
        let note: String
        let value: String
        let tone: Color
        /// 中文名是否完整（false 时标「未译」）
        let resolved: Bool
        /// 值的语义形态 —— 决定要不要把 1 / 1792403199 翻成人话
        var kind: FieldGlossary.Meaning.Kind = .text
    }

    private func fieldSectionCard(title: String, rows: [FieldRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(title, count: rows.count)

            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.title)
                            .font(Glass.Typo.body)
                            .foregroundStyle(.primary)
                        if !row.resolved {
                            Text("未译")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Glass.Tone.warning)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 0.5)
                                .background(Glass.Tone.warning.opacity(0.14), in: Capsule())
                        }
                        Spacer(minLength: 6)
                        Text(displayValue(row.value, row.kind))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(row.tone)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    // 每项都说明它是什么 —— 少了这句，用户只能靠猜
                    Text(row.note)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(idx.isMultiple(of: 2) ? Color.clear : Glass.zebra(colorScheme))
            }
        }
        .padding(.bottom, 8)
        .contentCard(radius: Glass.controlRadius, elevated: false)
    }

    /// **可折叠的次要字段** —— 这是整个状态页里唯一默认收起的一块。
    ///
    /// ## 为什么会折叠的只剩这些
    /// 上一版把「不在白名单里」等同于「次要」，于是三十多条全被折了起来。
    /// 但白名单是按"值不值得精译"定的，不是按"该不该展示"定的 ——
    /// 胎压预警、防盗布防恰恰是最该一眼看到的。
    ///
    /// 现在语义明确的分组都直接展开（见 `curatedFieldsSection`），
    /// 留在这里的只有两类：
    /// 1. **出厂配置**（`configuration.*`）—— 与日常用车无关，只在核对配置时看
    /// 2. **认不出的字段** —— 中文名都拼不出来的 key，放正文里只是噪音
    ///
    /// 两类都保留完整内容（中文名、值、用途、原始 key），一条都没丢。
    private var foldableSection: some View {
        let rest = StatusFieldCatalog.foldables(from: model.cloudFields)
        return Group {
            if !rest.isEmpty {
                DisclosureGroup(isExpanded: $leftoverExpanded) {
                    VStack(spacing: 0) {
                        ForEach(groupedLeftovers(rest), id: \.name) { group in
                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .padding(.bottom, 3)

                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, f in
                                leftoverRow(f, zebra: !idx.isMultiple(of: 2))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("原始与配置字段")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("\(rest.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .glassPill()
                        Spacer(minLength: 0)
                        Text("系统位 · 出厂参数")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentCard(radius: Glass.controlRadius, elevated: false)
            }
        }
    }

    /// 折叠区里的一行：中文名 / 原始 key / 用途。
    private func leftoverRow(_ f: StatusField, zebra: Bool) -> some View {
        let meaning = FieldGlossary.meaning(for: f)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(meaning.title)
                    .font(Glass.Typo.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !meaning.resolved {
                    Text("未译")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Glass.Tone.warning)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(Glass.Tone.warning.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 6)
                Text(displayValue(f.value, meaning.kind))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(meaning.note)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            // 原始 key 放最后一行：排障时要拿它去对接口文档，
            // 但对日常阅读它是噪音，所以压到最低权重。
            Text(f.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(zebra ? Glass.zebra(colorScheme) : Color.clear)
    }

    /// 按 `group`（摊平时保留了第一层 key）分组，顺序按字段表里首次出现的顺序。
    private func groupedLeftovers(_ rest: [StatusField])
        -> [(name: String, title: String, items: [StatusField])] {
        var order: [String] = []
        var map: [String: [StatusField]] = [:]
        for f in rest {
            if map[f.group] == nil { order.append(f.group) }
            map[f.group, default: []].append(f)
        }
        return order.map { key in
            (name: key, title: FieldGlossary.groupTitle(key), items: map[key] ?? [])
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .glassPill()
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// 异常值上色：胎压报警、未锁、门窗开这些要跳出来
    /// 把**原始值**翻成人话。
    ///
    /// 和「把字段名翻成中文」同等重要：`副驾车门锁状态 = 1` 与
    /// `副驾车门锁状态 = 已锁` 是两种完全不同的可读性。
    /// 转换规则来自 `FieldGlossary.Meaning.Kind`，不在这里猜字段名。
    private func displayValue(_ raw: String, _ kind: FieldGlossary.Meaning.Kind) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()

        switch kind {
        case .flag(let on, let off):
            if ["1", "true", "yes", "on"].contains(v) { return on }
            if ["0", "false", "no", "off"].contains(v) { return off }
            // 枚举字符串（如 engine_on）原样返回 —— 硬套会造出假信息
            return raw

        case .timestamp:
            guard let n = Double(v), n > 0 else { return raw }
            // 13 位是毫秒。用 3×10¹⁰ 作分界：10 位秒级到 2286 年才到这个量级。
            let seconds = n > 3e10 ? n / 1000 : n
            let date = Date(timeIntervalSince1970: seconds)
            // 车端时钟经常是错的（1970、2100 之类），离谱的时间不如显示原值
            let age = date.timeIntervalSinceNow
            guard age < 3 * 366 * 24 * 3600, age > -10 * 366 * 24 * 3600 else { return raw }
            return Self.stampFormatter.string(from: date)

        case .number, .text:
            return raw
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func valueTone(_ spec: StatusFieldSpec, _ value: String) -> Color {
        let alarming = ["报警", "未锁", "开", "告警", "未布防"]
        if alarming.contains(value) { return .orange }
        switch value {
        case "正常", "已锁", "关", "已布防", "已拉起": return .primary
        default: return .primary
        }
    }

    private func alertCard(icon: String, color: Color, title: String, detail: String) -> some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Glass.Typo.cardTitle).foregroundStyle(color)
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass).tactile()
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

    private var statusLineIcon: String {
        let s = model.statusLine
        if s.contains("✅") || s.contains("成功") { return "checkmark.circle.fill" }
        if s.contains("❌") || s.contains("失败") || s.contains("未通过") { return "exclamationmark.circle.fill" }
        if s.contains("锁定") || s.contains("超时") { return "lock.circle.fill" }
        return "info.circle"
    }

    private var statusLineColor: Color {
        let s = model.statusLine
        if s.contains("✅") || s.contains("成功") { return Glass.Tone.success }
        if s.contains("❌") || s.contains("失败") || s.contains("未通过") { return Glass.Tone.danger }
        if s.contains("锁定") || s.contains("超时") { return Glass.Tone.warning }
        return .secondary
    }

    /// 点火 —— 提前把预认证的 0x0C 发一次。
    ///
    /// 预认证是 29 秒一次的自动节奏，而用户上车按按钮是随机时刻 ——
    /// 这就是「试好多次才打不着」的数学原因。这个按钮不发任何新协议动作，
    /// 只是把该发的 0x0C 提前一次。
    ///
    /// 原来是通栏卡片（整行 88pt、标题 15pt semibold、右侧还带 chevron），
    /// 和下面 8 个胶囊按钮不是一个物种。现在改成同样的网格按钮：
    /// 图标 18 + 标题 caption + 一行 9pt 状态，与「微开」结构完全一致。
    ///
    /// **显示条件从"有钥匙且预认证开启"改为常显**：原先没配对时整块消失，
    /// 用户既不知道有这个能力，也没有入口去配对。现在恒在，
    /// 未就绪时第三行写「需配对 / 已关闭」，点击给出明确指引。
    /// 代价是控制区多一个当前不可用的按钮 —— 但对「点火」这种主路径能力，
    /// 可发现性比纯净度更重要。
    private var ignitionAction: some View {
        Button {
            guard model.hasLocalKey else {
                actionHint = "还没有本车钥匙。先把手机与车配对，才能发送点火授权。"
                return
            }
            guard model.preAuth.isEnabled else {
                actionHint = "预认证已关闭。到「我的 → 设置 → 预认证」打开后再试。"
                return
            }
            model.sendPreAuthNow()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 18))
                Text("点火").font(.caption)
                ignitionHint
            }
            .frame(maxWidth: .infinity, minHeight: 62)
            .overlay(alignment: .topTrailing) {
                channelBadge(.bluetooth)
            }
        }
        .buttonStyle(.glass).tactile()
    }

    /// 点火按钮的第三行：优先显示剩余可启动时间（它有时效，是这里唯一会变的信息）
    @ViewBuilder
    private var ignitionHint: some View {
        // ★ 判断和构造 Range 必须用**同一个** `now`。
        //
        // 写成 `end > Date()` … `Date()...end` 时取了两次当前时间：
        // 若 end 恰好落在两次调用之间（授权到期的那一帧），
        // `ClosedRange(lowerBound:upperBound:)` 会直接 fatalError ——
        // 不是"显示错"，是崩在渲染里。概率极低但那是必现的一帧。
        let now = Date()
        // 优先显示**点火窗口**（用户点的就是它，5 分钟），
        // 没有点火窗口时才退回解锁授权窗口（2 分钟）。
        //
        // 原来只读 `unlockWindowEndsAt` —— 而 `startIgnitionWindow()` 设的是
        // `ignitionWindowEndsAt`，两者不是一回事。结果是：点了点火之后，
        // 只要解锁授权还没刷新完，这一行就一直是「预授权」不变，
        // 用户完全看不出刚才那一下有没有生效。
        if let end = model.ignitionWindowEndsAt ?? model.unlockWindowEndsAt, end > now {
            HStack(spacing: 2) {
                Text("剩")
                Text(timerInterval: now...end, countsDown: true)
            }
            .font(.system(size: 9))
            .foregroundStyle(.green)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else if !model.hasLocalKey {
            Text("需配对")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        } else if !model.preAuth.isEnabled {
            Text("已关闭")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        } else {
            Text("预授权")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
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
    /// 网络通道配置（2026-11-04）
    @State private var showCloud = false
    @State private var showLogs = false
    @State private var showVehicleDetail = false

    var body: some View {
        NavigationStack {
            List {
                Section("车辆") {
                    Button { showVehicleDetail = true } label: {
                        menuRow("车辆详情", "car.side", "查看 CIDPU、连接状态")
                    }
                    .tactile()

                    // 无感进入（PE：靠近车辆拉门把手解锁）
                    //
                    // 原来在「状态」页用一个自绘玻璃按钮 —— 但它是个开关，
                    // 不是状态指示器，放在设置里用系统 Toggle 才符合预期。
                    Toggle(isOn: Binding(
                        get: { model.passiveEntryEnabled },
                        set: { model.setPassiveEntry($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("无感进入")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(model.passiveEntrySwitching
                                 ? "正在切换…"
                                 : "靠近车辆拉门把手即解锁")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.passiveEntrySwitching)
                }

                Section("钥匙") {
                    // 副标题去掉「导入」——从原 App 导入密钥的功能早已移除
                    // （KeyInspectorView 顶部注释：不提供从原 App 导入），
                    // 留着「导入」是死描述，会让人去找不存在的能力。
                    Button { showKeys = true } label: {
                        menuRow("数字钥匙",
                                model.hasLocalKey ? "key.fill" : "key",
                                model.hasLocalKey ? "已就绪 · 检视 / 备份 / 恢复"
                                                  : "尚未绑定 · 去配对")
                    }
                    .tactile()
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
                        set: { model.setPreAuthEnabled($0) }
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
                            Text("悬浮在界面左上角显示实时日志，可折叠；不会阻挡其他区域的操作")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Button { showDiagnostics = true } label: {
                        menuRow("诊断", "waveform.path.ecg", "自检、时序、原始报文")
                    }
                    .tactile()
                    Button { showLogs = true } label: {
                        menuRow("日志", "text.alignleft", "会话 / 报文 / 配对 / 全模块")
                    }
                    .tactile()
                }

                Section {
                    Button(role: .destructive) { model.disconnect() } label: {
                        Label("断开连接", systemImage: "xmark.circle")
                    }
                    .tactile(Haptics.warn)
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
            .listRowBackground(GlassListRowBackground())
            .scrollContentBackground(.hidden)
            .background(GlassScreenBackground())
            .navigationTitle("开发者")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.tactile()
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
            // 标定入口实际在密钥详情页（「靠近解锁 / 远离闭锁」卡片）。
            // 原来写「点火位置验证」—— 那个页面没有标定按钮，用户会找不到。
            return "未标定 RSSI：区域判定不会成立，先到「我的 → 设置 → 钥匙 → 密钥管理」里标定"
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
                        .buttonStyle(.glass).tactile()
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
                        .buttonStyle(.glassProminent).tactile(Haptics.commit)
                        // 不按连接状态调暗：点它会给出明确原因（calibHint），
                        // 比把按钮画灰让人以为坏了要好。
                    }

                    Button {
                        model.refreshPassiveStartVerdict()
                    } label: {
                        Label("重新判定", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).tactile(Haptics.commit)
                }
                .padding(Glass.pageMargin)
            }
            .background(GlassScreenBackground())
            .navigationTitle("点火位置验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.tactile()
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Glass.Typo.cardTitle).foregroundStyle(.primary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
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
                        .buttonStyle(.plain).tactile()
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
                        row("车辆在线", model.isVehicleOnline
                            ? "在线 · 最近联络 \(model.lastContactText)"
                            : "离线 · 最近联络 \(model.lastContactText)")
                        Divider()
                        // 开发者页保留原始链路状态 —— 主界面只说在线/离线，
                        // 排 GATT 层问题时仍需要看到 scanning/connecting/discovering。
                        row("链路状态（原始）", model.ble.linkState == .ready
                            ? "已连接车辆（可发命令）"
                            : (model.ble.isWriteReady
                               ? "已握手，未就绪"
                               : "未连接（\(model.ble.linkState.rawValue)）"))
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
                        .tactile()
                        // ⚠️ 不加 `.disabled`：`pendingAction` 在极少数路径下
                        //    （未收到 0x0F 就断开）可能残留，disabled 会让按钮
                        //    永久变灰、再也点不动。重复点只是重发一次幂等查询。
                    }
                    .contentCard(radius: Glass.controlRadius)

                    // ★★★ 车辆状态（照原 App parseBroadcastData: 广播解密）
                    if let st = model.measured.status {
                        VStack(alignment: .leading, spacing: Glass.sectionSpacing) {
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
                        .contentCard(radius: Glass.controlRadius)
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
            .background(GlassScreenBackground())
            .navigationTitle("车辆详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.tactile()
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

// MARK: - 空调温度选择

/// 开空调前选温度。
///
/// 为什么要有这一步：抓包显示云端命令必须带 `rce`（目标温度），
/// 而温度是用户当场决定的，写死 22 会和他在车里设的温度打架。
/// 关空调不需要它 —— 那条命令照抄当前温度即可。
struct ACTemperatureSheet: View {
    @Binding var temperature: Int
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let range = Array(16...32)

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("\(temperature)°C")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Picker("温度", selection: $temperature) {
                    ForEach(range, id: \.self) { t in
                        Text("\(t)°").tag(t)
                    }
                }
                .pickerStyle(.wheel)
                .frame(height: 120)

                HStack(spacing: 10) {
                    Button("取消") { dismiss() }
                        .buttonStyle(.glass).tactile()
                    Button("开启空调") { onConfirm() }
                        .buttonStyle(.glassProminent).tactile(Haptics.commit)
                }
                .padding(.top, 4)
            }
            .padding(20)
            .navigationTitle("远程空调")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 顶栏 RSSI

/// 顶栏的 RSSI 胶囊。
///
/// **独立订阅 `BLECentral`**：它每 0.5 秒更新一次，但只有这一个胶囊需要跟着变。
/// 如果让 AppModel 代为转发，代价是整个 RootView（车图 + 10 个按钮 + 能源条）
/// 每秒重建两次 —— 那是 2026-11-07 审查里发现的真实问题：
/// 它当时靠 `lastBluetoothStatusAt` 每帧赋值触发的全量重绘「搭便车」刷新，
/// 而那个副作用本身就是最大的性能浪费。
///
/// 值为 `nil` 时**不占位**：停止扫描 / 离开覆盖 / 车机停播时
/// `BLECentral` 的看门狗会把它置空，这里跟着消失。
private struct RSSIPill: View {
    @ObservedObject var ble: BLECentral

    var body: some View {
        if let r = ble.rssi {
            HStack(spacing: 3) {
                Image(systemName: "cellularbars")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(r) dBm")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(color(r))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassPill()
        }
    }

    /// -60 以上算强，-75 以下算弱
    private func color(_ r: Int) -> Color {
        if r >= -60 { return .green }
        if r >= -75 { return .yellow }
        return .red
    }
}
