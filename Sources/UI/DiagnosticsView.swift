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
                    selfTestSection
                    timingSection
                    streamSection
                    logSection
                    linkParamsSection
                }
                .padding(18)
            }
            .background(Color.black.opacity(0.92).ignoresSafeArea())
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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
                                Text(r.name).font(.caption).foregroundStyle(.white.opacity(0.9))
                                Text(r.detail).font(.caption2).foregroundStyle(.white.opacity(0.5))
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

    // MARK: - 时序

    private var timingSection: some View {
        card("连接时序（关键）") {
            let t = model.ble.timing
            VStack(alignment: .leading, spacing: 6) {
                row("connect → didConnect", t.connectDuration)
                row("didConnect → 服务发现", t.serviceDiscoveryDuration)
                row("服务发现 → 特征发现", t.characteristicDiscoveryDuration)
                row("特征发现 → 订阅完成", t.subscribeDuration)
                Divider().overlay(Color.white.opacity(0.12))
                row("★ 链路就绪总计", t.linkReadyDuration, highlight: true)
                Text("红线：链路就绪应远小于 2000ms。超过约 1500ms 时，2 秒窗口会被挤压，"
                     + "车端将回 0x6f00（2s 内未发送确认码），从而出现「点很多次才成功」。")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.9))
                    .padding(.top, 4)
            }
        }
    }

    private func row(_ title: String, _ v: TimeInterval?, highlight: Bool = false) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(v.map { String(format: "%.0f ms", $0 * 1000) } ?? "—")
                .font(.caption.monospacedDigit().weight(highlight ? .bold : .regular))
                .foregroundStyle(highlight ? Color.cyan : .white)
        }
    }

    // MARK: - 报文流

    private var streamSection: some View {
        card("原始报文（→ 发 / ← 收）") {
            if model.ble.rxHexStream.isEmpty {
                Text("暂无数据").font(.caption).foregroundStyle(.white.opacity(0.5))
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
                Text("暂无日志").font(.caption).foregroundStyle(.white.opacity(0.5))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(model.measured.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.85))
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
                    .foregroundStyle(.white.opacity(0.7))
                Text("sd | ed | RndTRx | RND1 | rights")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))

                Toggle("收到 02 后自动回 03", isOn: Binding(
                    get: { model.measured.sendAuth3 },
                    set: { model.measured.sendAuth3 = $0 }))
                .font(.caption)

                Divider().overlay(Color.white.opacity(0.1))

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
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func readonlyRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption2).foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(v).font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // MARK: - 卡片容器

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
