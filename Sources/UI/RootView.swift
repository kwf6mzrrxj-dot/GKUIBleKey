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

    @State private var showDeveloper = false
    @State private var showPairing = false

    /// 车辆爱称（原 App 可自定义，这里先用固定值）
    private let vehicleNickname = "爱车"
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
    }

    // MARK: - 背景

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.11, green: 0.12, blue: 0.16),
                     Color(red: 0.06, green: 0.07, blue: 0.10)],
            startPoint: .top, endPoint: .bottom
        )
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
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())

            // RSSI 信号值（连接后显示）
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
                .background(.white.opacity(0.08), in: Capsule())
            }

            Spacer()
            Menu {
                Button { showPairing = true } label: {
                    Label("绑定车辆", systemImage: "link.badge.plus")
                }
                Divider()
                Button { showDeveloper = true } label: {
                    Label("开发者", systemImage: "wrench.and.screwdriver")
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
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
                .foregroundStyle(.white)
            Text(vehicleNickname)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
    }

    private var linkStateText: String {
        if model.pairingArmed { return "配对中" }
        switch model.ble.linkState {
        case .ready:        return "已连接"
        case .connecting:   return "连接中"
        case .discovering:  return "发现服务"
        case .scanning:     return "扫描中"
        case .disconnected: return "未连接"
        case .failed:       return "连接失败"
        case .idle:         return "待机"
        }
    }

    // MARK: - 车辆图（原 App 车辆模型帧 + 状态动画）

    /// 车辆舞台状态：连接阶段 → 对应动画
    private var carStage: CarModelView.Stage {
        if model.ble.linkState == .ready { return .ready }
        if model.pairingArmed { return .pairing }
        return .connecting
    }

    private var carArt: some View {
        CarModelView(status: model.measured.status, stage: carStage)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 200)
            .padding(.horizontal, 10)
    }

    // MARK: - 状态芯片（车门/后备箱/上电/发动机/ACC，广播解密状态）

    @ViewBuilder private var statusChips: some View {
        if let s = model.measured.status {
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
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
        }
    }

    private func chip(icon: String, text: String, good: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(good ? Color.white.opacity(0.85) : Color.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(0.07), in: Capsule())
    }

    // MARK: - 控车区

    private var controlSection: some View {
        VStack(spacing: 12) {
            // 两大键：解锁 / 闭锁 —— 车锁状态直接体现在按钮上
            HStack(spacing: 12) {
                primaryAction(.unlock, "解锁", .green, "lock.open.fill",
                              isCurrentState: model.measured.status?.isLocked == true,
                              stateBadge: model.measured.status?.isLocked == true ? "当前已锁" : nil)
                primaryAction(.lock, "闭锁", .blue, "lock.fill",
                              isCurrentState: model.measured.status?.isLocked == false,
                              stateBadge: model.measured.status?.isLocked == false ? "当前未锁" : nil)
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
                        .foregroundStyle(.white.opacity(0.55))
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
        Button { model.perform(action) } label: {
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
        }
        .buttonStyle(.glass)
        .tint(tint)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(isCurrentState ? tint.opacity(0.9) : .clear,
                              lineWidth: isCurrentState ? 2 : 0)
        )
        .opacity(isCurrentState ? 1 : (stateBadge == nil && model.measured.status != nil ? 0.75 : 1))
        .disabled(!model.ble.isWriteReady)
    }

    private func secondaryAction(
        _ action: IBCommandType, _ title: String, _ icon: String
    ) -> some View {
        Button { model.perform(action) } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.glass)
        .disabled(!model.ble.isWriteReady)
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

            // 密钥状态（未配对时整行可点，引导去绑定）
            statusRow(icon: model.measured.keys != nil ? "key.fill" : "key",
                      iconColor: model.measured.keys != nil ? .green : .orange,
                      text: model.measured.keys != nil ? "数字钥匙已就绪" : "尚未绑定车辆",
                      trailing: model.measured.keys == nil ? "去绑定" : nil,
                      action: model.measured.keys == nil ? { showPairing = true } : nil)
        }
        .padding(.bottom, 12)
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
                Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.65))
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
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            if let t = trailing {
                Text(t).font(.caption2).foregroundStyle(.cyan)
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
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
                    Button { showKeys = true } label: {
                        menuRow("密钥管理", "key.horizontal", "检视 / 备份 / 恢复 / 导入")
                    }
                    Button { model.verifyKeyIntegrity() } label: {
                        HStack {
                            menuRow("校验密钥完整性", "checkmark.shield",
                                    model.keyIntegrityDetail)
                        }
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
                            Text("进入区域后周期发 0x0C，默认关闭")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("调试") {
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
}

// MARK: - 点火位置验证详情

/// 点火位置验证详情 —— 从主界面移出的高级功能。
/// 纯本地 RSSI 判定，展示标定状态与当前判定结果。
struct PassiveStartDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 标定状态
                    card("标定状态") {
                        if model.passiveStart.isCalibrated {
                            Label("已标定", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("未标定", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                            Text("未标定时基准为 -32，几乎不会触发。标定写入端跨底层 GLBLE 协议，"
                                 + "当前尚未实现，因此此功能实际不可用。")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }

                    // 当前判定
                    card("当前判定") {
                        row("合成 RSSI", model.passiveStart.summary)
                        row("判定基准", "\(model.passiveStart.threshold)")
                        row("是否在区域内",
                            model.passiveStart.isInPassiveStartArea ? "是" : "否")
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
            .background(Color.black.opacity(0.92).ignoresSafeArea())
            .navigationTitle("点火位置验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(v).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "car.side.fill")
                        .resizable().scaledToFit().frame(maxHeight: 150)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 10)

                    VStack(spacing: 0) {
                        row("车辆爱称", "爱车")
                        Divider().overlay(Color.white.opacity(0.1))
                        row("车辆 ID (CIDPU)", cidpuText, mono: true)
                        Divider().overlay(Color.white.opacity(0.1))
                        row("连接状态", model.ble.isWriteReady ? "蓝牙连接 iPhone" : "未连接")
                        Divider().overlay(Color.white.opacity(0.1))
                        row("车辆型号", "博越 PRO")
                        Divider().overlay(Color.white.opacity(0.1))
                        row("最近动作", model.measured.lastSucceededAction?.label ?? "—")
                        Divider().overlay(Color.white.opacity(0.1))
                        row("状态帧 (05)", model.measured.vehicleState.isEmpty
                            ? "—" : model.measured.vehicleState.hexDescription, mono: true)
                        Divider().overlay(Color.white.opacity(0.1))
                        row("已登记手机", model.measured.pairedDeviceNames.isEmpty
                            ? "未知（点下方「查询」）" : model.measured.pairedDeviceNames.joined(separator: ", "))
                        Divider().overlay(Color.white.opacity(0.1))
                        Button {
                            model.requestPairedDeviceNames()
                        } label: {
                            Label("查询车端已配对手机", systemImage: "arrow.down.circle")
                                .font(.caption)
                        }
                        .disabled(!model.ble.isWriteReady)
                    }
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))

                    // ★★★ 车辆状态（照原 App parseBroadcastData: 广播解密）
                    if let st = model.measured.status {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("车辆状态")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.9))
                            statusGrid(st)
                            Text(st.fullDescription)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    }

                    if cidpuText == "未获取" {
                        Text("CIDPU 由车端在连接后下发；配对成功或鉴权通过后即可看到。")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.horizontal, 4)
                    }
                }
                .padding(20)
            }
            .background(Color(red: 0.08, green: 0.09, blue: 0.12).ignoresSafeArea())
            .navigationTitle("车辆详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var cidpuText: String {
        if let s = KeyStore.shared.cidpuDisplayHex, !s.isEmpty { return s }
        return "未获取"
    }

    private func row(_ k: String, _ v: String, mono: Bool = false) -> some View {
        HStack {
            Text(k).font(.subheadline).foregroundStyle(.white.opacity(0.85))
            Spacer()
            Text(v)
                .font(mono ? .system(.subheadline, design: .monospaced) : .subheadline)
                .foregroundStyle(.white.opacity(0.6))
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
            ("发动机", s.isEngineRunning ? "运行中" : "停止", s.isEngineRunning),
            ("ACC", s.isAccOn ? "开" : "关", s.isAccOn),
        ]
        return LazyVGrid(columns: cols, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(spacing: 4) {
                    Text(item.1)
                        .font(.subheadline.bold())
                        .foregroundStyle(item.2 ? Color.green : Color.white.opacity(0.85))
                    Text(item.0)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
