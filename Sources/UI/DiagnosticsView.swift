import SwiftUI

/// 诊断面板：自检、时序埋点、原始报文、会话日志、当前链路参数。
///
/// 这个界面存在的意义：把「2 秒窗口是否被挤压」直接量化出来，
/// 并把当前链路真正生效的参数（`01` 明文顺序、是否回 `03`）暴露出来。
///
/// 2026-10-24：删除了旧五步协议（`DKTuning`）的 10 个调参项 ——
/// 它们对新链路（`01/02/03`）完全无效，留着只会让人误判"协议没调对"。
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selfTestResults: [SelfTest.Result] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    bleStatusSection
                    selfTestSection
                    streamSection
                    logSection
                    linkParamsSection
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - BLE 状态（排查连接问题首先看这里）

    private var bleStatusSection: some View {
        card("BLE 连接状态") {
            VStack(alignment: .leading, spacing: 8) {
                readonlyRow("蓝牙适配器", model.ble.bluetoothStatusText)
                readonlyRow("位置权限", model.ble.locationAuthText)
                readonlyRow("链路状态", model.ble.linkState.rawValue)
                readonlyRow("写特征", model.ble.isWriteReady ? "已就绪" : "未就绪")
                readonlyRow("发现设备数", "\(model.ble.candidates.count)")
                Divider()
                Text(model.ble.lastMessage).font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.statusLine).font(.caption2)
                    .foregroundStyle(.cyan.opacity(0.8))
                Divider()
                HStack(spacing: 10) {
                    Button("重新扫描") { model.startScan() }
                        .buttonStyle(.glass)
                    Button("请求位置权限") { model.ble.requestLocationPermission() }
                        .buttonStyle(.glass)
                        .tint(model.ble.hasLocationAuth ? .green : .orange)
                    Button("重建蓝牙") { model.ble.resetCentral() }
                        .buttonStyle(.glass)
                        .tint(.orange)
                }
                .font(.caption)
            }
        }
    }

    // MARK: - 自检

    private var selfTestSection: some View {
        card("基础层自检") {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    selfTestResults = SelfTest.runAll()
                } label: {
                    Label("运行自检（标准测试向量）", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                if !selfTestResults.isEmpty {
                    let passed = selfTestResults.filter { $0.passed }.count
                    Text("通过 \(passed)/\(selfTestResults.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(passed == selfTestResults.count ? Color.green : Color.orange)
                    ForEach(selfTestResults) { r in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(r.passed ? Color.green : Color.red)
                                .font(.caption2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.caption).foregroundStyle(.secondary)
                                Text(r.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("自检通过说明密码学/编解码实现无误；若联调仍失败，问题就在"
                         + "「协议参数」而非「代码实现」。")
                        .font(.caption2).foregroundStyle(.cyan.opacity(0.8))
                }
            }
        }
    }

    // MARK: - 报文流

    private var streamSection: some View {
        card("原始报文（→ 发 / ← 收）") {
            if model.ble.rxHexStream.isEmpty {
                Text("暂无数据").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.ble.rxHexStream.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(line.hasPrefix("→") ? Color.cyan : Color.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    // MARK: - 会话日志

    private var logSection: some View {
        card("会话日志") {
            if model.measured.log.isEmpty {
                Text("暂无日志").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.measured.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    // MARK: - 当前链路参数

    /// 只展示**真正生效**的参数。`01` 明文顺序已由反汇编确定，不再提供切换。
    private var linkParamsSection: some View {
        card("当前链路参数") {
            VStack(alignment: .leading, spacing: 12) {
                Text("01 明文顺序（固定 · A 级证据）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("sd | ed | RndTRx | RND1 | rights")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)

                Toggle("收到 02 后自动回 03", isOn: Binding(
                    get: { model.measured.sendAuth3 },
                    set: { model.measured.sendAuth3 = $0 }))
                .font(.caption)

                Divider().overlay(Color.secondary)

                // 只读：密钥材料摘要（便于确认是否已配对成功）
                if let k = model.measured.keys {
                    readonlyRow("cidpu (16B)", k.tail.map { String(format: "%02X", $0) }.joined())
                    readonlyRow("CkTRxSP", String(FrameCodec.hexString(k.ckTRxSP).prefix(23)) + "…")
                    readonlyRow("Dk1", String(FrameCodec.hexString(k.dk1).prefix(23)) + "…")
                } else {
                    Text("尚无密钥材料（需先完成 0D→0E 配对）")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text("注：旧五步协议（ID 2/3/4/5、CRC 覆盖）的调参项已移除 —— 当前链路不使用它们。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readonlyRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 卡片容器

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
