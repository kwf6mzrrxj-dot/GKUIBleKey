import SwiftUI

/// 手表配对页 —— 让手表**自己**成为车端的一把钥匙。
///
/// ## 这不是「BLE 绑定 + 车机添加设备」
///
/// 完整的现场流程是（`Docs/INBLUE_PROTOCOL_SPEC.md` 5.10）：
///
/// ```
/// ① 诊断仪开窗口，登记一个手机槽位（一车可挂 5 台，不用解绑手机）
/// ② 手表连上车，watchOS 弹出 Passkey Entry，输入诊断仪显示的 6 位码
/// ③ 订阅成功（bonding 完成）后发 0x0D 登记帧（37B）
/// ④ 车端回 0x0E（62B 密钥）→ 写入手表 Keychain
/// ⑤ 主动断开 —— 车端这才判「配对完成」
/// ```
///
/// 本页负责 ②–⑤，① 只能在诊断仪上做。所以页面第一行就把话说清楚，
/// 避免用户在没开窗口时反复点「开始配对」然后等 30 秒超时。
struct WatchPairingView: View {
    @EnvironmentObject private var controller: WatchVehicleController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmUnbind = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                closeBar
                header
                steps
                primaryButton
                if let countdown = controller.countdown {
                    Text(countdown)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(controller.statusLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                logLines
                if controller.hasKeys {
                    heartbeatToggle
                }
                if controller.hasKeys {
                    unbindButton
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("配对")
        // 下滑关闭 / 点 × 关闭都要收尾：配对进行中关掉页面必须取消，
        // 否则 `autoConnectWhilePairing` 会留着（下次扫到任意 Valeo 设备就直连）。
        .onDisappear {
            controller.cancelPairing()
        }
        .alert("解绑这辆车？", isPresented: $confirmUnbind) {
            Button("解绑", role: .destructive) {
                controller.unbind()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除手表上的密钥。要再控车必须重新走一遍诊断仪配对。")
        }
    }

    // MARK: - 顶部

    private var closeBar: some View {
        HStack {
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(tint)
            Text(stageText)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var icon: String {
        switch controller.stage {
        case .idle:       return controller.hasKeys ? "key.fill" : "plus.circle"
        case .scanning:   return "dot.radiowaves.left.and.right"
        case .waitingKey: return "hourglass"
        case .succeeded:  return "checkmark.seal.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch controller.stage {
        case .succeeded: return .green
        case .failed:    return .orange
        default:         return .accentColor
        }
    }

    private var stageText: String {
        switch controller.stage {
        case .idle:              return controller.hasKeys ? "已配对" : "准备配对"
        case .scanning:          return "扫描车辆…"
        case .waitingKey:        return "等车端发密钥…"
        case .succeeded:         return "配对成功"
        case .failed(let why):   return why
        }
    }

    // MARK: - 步骤说明

    private var steps: some View {
        VStack(alignment: .leading, spacing: 3) {
            step(1, "诊断仪开配对窗口")
            step(2, "点下面「开始配对」，别放下手腕")
            step(3, "系统弹窗输入 6 位码")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(n).")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 主按钮

    @ViewBuilder
    private var primaryButton: some View {
        if controller.stage.isRunning {
            Button("取消配对") {
                controller.cancelPairing()
            }
            .buttonStyle(.bordered)
        } else if controller.stage == .succeeded {
            Button("完成") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        } else if !controller.hasKeys {
            Button {
                controller.beginPairing()
            } label: {
                Label("开始配对", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 日志

    private var logLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(controller.pairingLog.suffix(4).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 保活开关

    /// 前台保活心跳开关（预认证 `0x0C`）。
    ///
    /// 只在**前台**有效：watchOS 没有 `bluetooth-central` 后台模式，
    /// 熄屏即挂起，后台维持不了「持续在场」。所以文案里写清「仅前台」，
    /// 别让用户以为放下手腕还在保活。
    private var heartbeatToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { controller.heartbeatEnabled },
                set: { controller.setHeartbeat($0) }
            )) {
                Text("前台保活")
                    .font(.system(size: 11))
            }
            Text(controller.heartbeatEnabled
                 ? "在车附近时每约 30 秒发一次心跳（放下手腕即停）"
                 : "关闭后车端不会持续认为钥匙在场")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 解绑

    private var unbindButton: some View {
        Button(role: .destructive) {
            confirmUnbind = true
        } label: {
            Text("解绑这辆车")
                .font(.caption2)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .disabled(controller.stage.isRunning)
    }
}
