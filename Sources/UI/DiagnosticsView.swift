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
                    preAuthSection
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

    // MARK: - ★ 预认证 / 点火（「打不着火」时第一个要看的地方）

    /// 预认证续发间隔的展示文案。
    ///
    /// `timeBetweenPassiveStart` 的初值是 **0**，只有一轮 `0x0C` 收到 `04`
    /// 之后 `PreAuthenticationController.didComplete()` 才会把它设成 29。
    /// 首轮未完成（甚至每轮都超时、永远完不成）时，原来会一直显示
    /// 「进行中（0s 周期）」—— 看起来像配错了一个零间隔。
    private var preAuthIntervalText: String {
        guard model.preAuth.didStart else { return "未启动" }
        let configured = model.preAuth.timeBetweenPassiveStart
        if configured > 0 {
            return String(format: "进行中（%.0fs 一轮）", configured)
        }
        return String(format: "进行中（首轮，之后 %.0fs 一轮）",
                      PreAuthenticationController.retryInterval)
    }

    /// 预认证（`0x0C`）是「让车端认出手机在场」的唯一手段，
    /// 它不发出去，踩刹车按启动按钮就是白按。
    ///
    /// 之前这些状态**一处都没显示**，用户只能问"是不是预认证的问题"、
    /// 而界面上完全看不出来 —— 现在全部摊开。
    private var preAuthSection: some View {
        card("预认证 / 点火") {
            VStack(alignment: .leading, spacing: 8) {
                readonlyRow("保活开关", model.preAuth.isEnabled ? "已开启" : "已关闭（不会发 0x0C）")
                // ★ 计数在「定时器到点、准备交帧」时就 +1，之后 `beginMeasuredAuth`
                        //   仍可能因「写特征未就绪 / 已锁定 / 密钥完整性未通过 / 只读监听」
                        //   根本没发出帧 —— 所以这是「发起次数」，不是「已发出帧数」。
                        readonlyRow("已发起次数", "\(model.preAuth.sentCount)（含未发出）")
                readonlyRow("在点火区域", !model.preAuth.isEnabled
                            ? "未判定（保活已关闭）"
                            : (model.preAuth.isInArea ? "是" : "否（自动续发需在区域内）"))
                readonlyRow("续发状态", preAuthIntervalText)
                Divider()
                // ★ 后台保活三件套（2026-10-29）：判断「切后台还在不在维持」
                //
                // 只看「已发次数」区分不出前台还是后台发的 ——
                // 而后台发出才说明保活真的在工作。
                readonlyRow("App 状态", BackgroundMonitor.shared.isInBackground
                            ? "后台（靠广播唤醒续发）"
                            : "前台")
                // ★「后台执行权」是**瞬时**的：只在一轮 01→04 往返期间持有，
                //   收到 04 / 超时 / 中止就立刻释放。空闲时显示「无」是正常的，
                //   不代表后台能力不可用 —— 所以标签写成「本轮后台保护」，
                //   避免被误解成一个常驻开关。
                readonlyRow("本轮后台保护", model.isHoldingPreAuthBackgroundTime
                            ? "进行中（01→04 受保护）"
                            : "无（空闲，正常）")
                readonlyRow("最近一次发送", model.preAuth.lastSentAt.map {
                    String(format: "%.0f 秒前", Date().timeIntervalSince($0))
                } ?? "还没发过")
                Divider()
                readonlyRow("RSSI 标定值", model.passiveStart.isCalibrated
                            ? "\(model.passiveStart.calibration ?? 0)"
                            : "未标定（区域判定永不成立）")
                readonlyRow("区域阈值", "\(model.passiveStart.threshold)")
                // ★ 判定用的是双天线**合成** dB 值，不是下面这个单值广播 RSSI。
                        //   两者可差 3 dB 以上，拿它跟阈值比对会得出相反结论。
                        readonlyRow("合成 RSSI（判定用）", model.passiveStart.summary)
                        readonlyRow("广播 RSSI（单天线）", model.ble.rssi.map { "\($0) dBm" } ?? "—")
                Text("判定式：合成 RSSI > 阈值 才算「在区域内」；"
                     + "在区域内且保活开启，才会按周期发 0x0C。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("「本轮后台保护」只在一轮 01→04 往返期间出现，"
                     + "收完 04 就释放 —— 空闲时是「无」属于正常。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    model.sendPreAuthNow()
                } label: {
                    Label("立即发送预认证（0x0C）", systemImage: "key.radiowaves.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
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
                // ★ 顶栏只说「在线/离线」，这里保留原始状态与最近联络时间 ——
                //   排查时要看的正是这两者的差值（例如"在线但链路 failed"）。
                readonlyRow("车辆在线", model.isVehicleOnline ? "是" : "否")
                readonlyRow("最近联络", model.lastContactText)
                readonlyRow("写特征", model.ble.isWriteReady ? "已就绪" : "未就绪")
                // ★ candidates 从不清空（全项目无 `candidates = []`），
                //   所以这是「本进程累计」，不是本次扫描的实时数量 ——
                //   否则会出现「扫描回调 0」+「发现 7 台」的自相矛盾。
                readonlyRow("累计设备（本进程）", "\(model.ble.candidates.count)")
                // ★ 扫描回调计数：0 = 系统根本没回调（权限/适配器问题），
                //   >0 但列表为空 = 回调来了、被过滤掉了（逻辑问题）。
                //   这个区分是「扫不到车」时最先要看的一条。
                readonlyRow("扫描回调", model.ble.discoverCount == 0
                            ? "0（系统未回调）" : "\(model.ble.discoverCount)")
                readonlyRow("最近广播", model.ble.lastDiscoveredName.isEmpty
                            ? "—" : model.ble.lastDiscoveredName)
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
