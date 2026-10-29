import SwiftUI

/// 配对页 —— **照原 App「蓝牙车控」配对页 1:1 重做**。
///
/// ## 原 App 的实际界面（截图实证）
/// ```
/// 蓝牙车控
/// 请绑定车辆
/// 【选择车型】              ← ★ 唯一的用户操作
///    （车辆图）
/// 暂无车辆
/// 请选择绑定对应的车型
/// 🔵 蓝牙正在连接车辆        ← ★★ 全自动，不需要点任何按钮
/// ```
///
/// ## 设计要点（都是被截图纠正过的）
/// 1. **只有「选择车型」一个操作** —— 没有扫描/连接/发送按钮
/// 2. **连接全自动** —— 打开页面就开始，底部实时显示进度
/// 3. **没有输入框** —— 6 位配对码是 iOS 系统弹窗，App 不参与
/// 4. **没有步骤条** —— 原 App 只给一行状态文字
///
/// ## 背后的自动流程（用户看不见）
/// ```
/// 打开页面 → 尝试连接系统已绑定设备 → 链路就绪 → 自动发 0x0D
///          → 车端回 0x0E（密钥）→ 自动保存 → 状态变为「已绑定」
/// ```
struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showLog = false
    /// 点击状态条但当前不可操作时的说明（替代原来的静默 return）
    @State private var statusHint: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                carArt
                Spacer(minLength: 0)
                bottomState
                logArea
            }
            .background(background)
            .navigationTitle("蓝牙车控")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // ★ 打开页面即自动开始配对（原 App 就是这样，用户不需要点）
        .onAppear {
            // ★ 已配对就**不发**配对帧，也不进等待流程（2026-10-29）
            //   原 App 在 keys=1 时绝不发 0x0D；我们之前照样走一遍，
            //   只会换来「车端零响应 → 30 秒超时」。
            if model.hasLocalKey {
                statusHint = """
                这台车已经绑定，无需再配对。

                如需重新配对（例如车端用诊断仪清过钥匙槽位），\
                请先在「开发者 → 密钥 → 解绑车辆」清除本地密钥，\
                之后再回到本页。
                """
                return
            }
            model.startFullPairing()
            // 其它阻止原因（如明确要求 force 的场景）直接展示，避免"打开页面没反应"。
            if let r = model.pairingBlockedReason { statusHint = r }
        }
        .onChange(of: model.pairingBlockedReason) { _, newValue in
            if let r = newValue { statusHint = r }
        }
        // ★ 关闭页面必须收尾（2026-10-29 全域审查补）。
        //
        // `startFullPairing()` 会置 `pairingArmed = true`（连带
        // `ble.pairingMode = true`），而清它的地方只有「配对帧真发出去」
        // 「30 秒命令超时」「0x0E 解析失败」「解绑」四处 ——
        // **用户直接关掉本页不在其中**，且配对阶段没有独立看门狗
        // （4 秒命令超时要等 0x0D 发出去才起表）。
        //
        // 于是车端没开配对窗口 / 车不在附近时打开再关掉，会留下：
        // - `RootView.linkStateText` 先判 `pairingArmed` → 顶部胶囊永久「配对中」
        // - `carStage` 同样 → 车图永久停在配对闪灯动画
        // - `ble.pairingMode = true` → 连接失败后会无条件连「下一个扫到的
        //   Valeo 设备」，停车场里可能连错车
        .onDisappear { model.cancelPairingIfNeeded() }
        .alert("提示", isPresented: Binding(
            get: { statusHint != nil },
            set: { if !$0 { statusHint = nil } }
        )) {
            Button("知道了", role: .cancel) { statusHint = nil }
        } message: {
            Text(statusHint ?? "")
        }
    }

    // MARK: - 背景（随浅色/深色自适应）

    private var background: some View {
        Group {
            if colorScheme == .dark {
                LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.16),
                                        Color(red: 0.07, green: 0.08, blue: 0.11)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 0.98),
                                        Color(red: 0.84, green: 0.87, blue: 0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部：请绑定车辆
    //
    // ⚠️ 原 App 这里有「选择车型」，但实测表明**不同车型的协议完全一致**
    // （同样的 InBlue 广播名、F000FF10 服务、同样的消息序列），反汇编里
    // 也没有任何车型分支 —— 所以那一步对配对没有实际作用，已去掉。

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("请绑定车辆")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("初始化车辆")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    // MARK: - 车辆图（原 App 车辆模型：配对中显示拼装动画，完成显示静态车图）

    private var carArt: some View {
        VStack {
            Spacer(minLength: 0)
            if hasVehicle {
                // 配对完成 → 静态博越 PRO 车图
                CarImage(named: "car_on")
                    .frame(maxHeight: 220)
                    .transition(.opacity)
            } else {
                // 配对进行中 → 车灯闪烁
                CarModelView(status: nil, stage: .pairing)
                    .frame(maxHeight: 240)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.4), value: hasVehicle)
    }

    // MARK: - 底部状态（原 App 只有这一行）

    private var bottomState: some View {
        VStack(spacing: 8) {
            Text(hasVehicle ? "已绑定车辆" : "暂无车辆")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(stateDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            // 底部连接状态条（对应原 App 的「蓝牙正在连接车辆」）
            // ★ 可点击：未绑定且不在配对中时，点击重新发起配对
            //   （statusText 里那句「点击此处以开始连接」此前是死文案，
            //   状态条没绑任何动作 —— 2026-10-25 修复为可点击重试）
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small).tint(.cyan)
                } else {
                    Image(systemName: hasVehicle ? "checkmark.circle.fill" : "bluetooth")
                        .foregroundStyle(hasVehicle ? .green : .cyan)
                }
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation { showLog.toggle() }
                } label: {
                    Image(systemName: showLog ? "chevron.down" : "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
            .onTapGesture {
                // 以前这里是静默 return，点了完全没反应。现在每种情况都给回应。
                if hasVehicle {
                    statusHint = "已绑定车辆。\n如需重新配对，请先在「开发者 → 密钥管理 → 解绑车辆」清除本地密钥。"
                    return
                }
                if model.pairingArmed {
                    statusHint = "配对正在进行中，请稍候…\n如果长时间没有结果，请确认诊断仪已开启配对窗口。"
                    return
                }
                model.startFullPairing()
            }
        }
        .padding(.bottom, 10)
    }

    // MARK: - 日志（默认折叠，原 App 没有这一块，仅作排查用）

    @ViewBuilder
    private var logArea: some View {
        if showLog {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if model.pairing.log.isEmpty {
                        Text("暂无记录").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.pairing.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 170)
        }
    }

    // MARK: - 状态推导

    /// 是否**已经绑定**这台车。
    ///
    /// ⚠️ 不能用 `receivedKeyData`（本次会话收到的 0x0E 帧）判断：
    /// 那是会话级数据，App 重启后为空 —— 已配对的用户打开本页会看到
    /// 「暂无车辆」，等于把已建立的配对关系又展示成未配对。
    /// 现在统一用 `AppModel.hasLocalKey`（内存 + Keychain 双查，持久判定）。
    private var hasVehicle: Bool {
        model.hasLocalKey
    }

    private var isWorking: Bool {
        // ★ 只有「配对进行中」（已发起配对 或 已连接正在登记）才显示进度圈；
        //   未发起/已失败时（pairingArmed==false 且未连接）显示「可点击重试」，
        //   此时不应再转圈。
        hasVehicle == false && (model.pairingArmed || model.ble.isWriteReady)
    }

    private var statusText: String {
        if hasVehicle { return "蓝牙已连接车辆" }
        if model.ble.isWriteReady { return "蓝牙已连接，正在登记…" }
        if model.pairingArmed { return "蓝牙正在连接车辆" }
        return "点击此处重新连接车辆"
    }

    private var stateDetail: String {
        if hasVehicle {
            return "配对完成，车端已下发密钥（\(model.measured.receivedKeyData.count)B）"
        }
        return "初次连接车辆，请在 4s 店工作人员的协助下完成配对"
    }
}
