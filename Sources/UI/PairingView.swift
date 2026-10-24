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

    @State private var showLog = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                carArt
                Spacer(minLength: 0)
                bottomState
                logArea
            }
            .background(
                LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.16),
                                        Color(red: 0.07, green: 0.08, blue: 0.11)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
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
            // ★★★ 配对前先进入**静默模式**：连接成功后不主动发现服务/订阅/读 RSSI，
            //     把信道让给 iOS 与模块之间的 pairing 协商。
            //     否则这些操作会打断协商 → 诊断仪报「配对失败」。
            model.ble.quietMode = true
            model.startFullPairing()
        }
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
                .foregroundStyle(.white.opacity(0.65))

            Text("初始化车辆")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
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
                // 配对完成 → 静态 3/4 车图
                Image("car_rotate_025")
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 230)
                    .shadow(color: .white.opacity(0.10), radius: 24)
                    .transition(.opacity)
            } else {
                // 配对进行中 → 车辆拼装动画
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
                .foregroundStyle(.white)

            Text(stateDetail)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            // 底部连接状态条（对应原 App 的「蓝牙正在连接车辆」）
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small).tint(.cyan)
                } else {
                    Image(systemName: hasVehicle ? "checkmark.circle.fill" : "bluetooth")
                        .foregroundStyle(hasVehicle ? .green : .cyan)
                }
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Button {
                    withAnimation { showLog.toggle() }
                } label: {
                    Image(systemName: showLog ? "chevron.down" : "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 16)
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
                        Text("暂无记录").font(.caption2).foregroundStyle(.white.opacity(0.5))
                    } else {
                        ForEach(Array(model.pairing.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
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

    private var hasVehicle: Bool {
        !model.measured.receivedKeyData.isEmpty || !model.pairing.rawResponse.isEmpty
    }

    private var isWorking: Bool {
        !hasVehicle
    }

    private var statusText: String {
        if hasVehicle { return "蓝牙已连接车辆" }
        if model.ble.isWriteReady { return "蓝牙已连接，正在登记…" }
        if model.pairingArmed { return "蓝牙正在连接车辆" }
        return "点击此处或选择车型以开始连接"
    }

    private var stateDetail: String {
        if hasVehicle {
            return "配对完成，车端已下发密钥（\(model.measured.receivedKeyData.count)B）"
        }
        return "初次连接车辆，请在 4s 店工作人员的协助下完成配对"
    }
}
