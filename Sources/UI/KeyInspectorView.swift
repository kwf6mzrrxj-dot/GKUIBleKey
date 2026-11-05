import SwiftUI
import UniformTypeIdentifiers

/// 密钥检视 / 备份恢复。
///
/// ## 重要说明（写给使用者）
/// 该车的蓝牙钥匙是 **Cloudless（无云）** 方案：密钥在配对成功后由车端下发、
/// 存进本 App 的 Keychain。获取密钥的唯一途径是**配对**（诊断仪让模块进入配对模式，
/// 本 App 走 0x55 鉴权链拿 0x0E 密钥帧）。
///
/// 原 App（iOS 版 XiaoKa）**没有任何导出密钥的界面**，密钥无法从它迁移过来，
/// 因此本 App 不提供「从原 App 导入」（2026-10-25 移除，此前误以为可以）。
/// 「备份 / 恢复」导出的只是**本 App 自己的**密钥（升级/换机兜底）。
///
/// ## 关于 IDFV（mobileId）—— 2026-11-02 修正
///
/// 这里原来写：「车端会校验 `mobileId`，因此必须与原 App 用相同的 bundle id
/// 与签名证书，否则报 `error_sdk_50003`」。**这条结论是错的**，两层都不成立：
///
/// 1. **IDFV 由 bundle id 的 vendor 前缀（前两段）决定，与签名证书无关。**
///    我们是 `com.mmxisme.*`、原厂是 `cn.com.ecarx.*`，本来就不同；
///    换证书也换不来对方的 IDFV。
/// 2. **`mobileId` 不在 BLE 帧里。** 它只在 GLBLEAuthSDK / 云端接口层出现
///    （`error_sdk_50003` 就是那一层报的）。而 `0x0D` = 命令 + sidpu(16) + 名称(20)、
///    `0x01` = `sd + ed + RndTRx + RND1 + rights`，都不含 mobileId。
///    本 App 根本不走那个 SDK，用的是自己实现的 BLE 链路。
///
/// **实证**：本 App 用完全不同的 bundle id 与证书，解锁 / 预认证 / 点火都正常。
/// 若车端真在 BLE 上校验 IDFV，这些操作不可能成功。
///
/// 详见 `KeyStore.swift` 顶部注释与 `project.yml` 里 2026-10-29 的调查结论。
struct KeyInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var refreshTick = 0
    /// ★ 整包备份文本（导出/恢复用）
    @State private var backupText = ""
    @State private var backupResult = ""
    /// 解绑二次确认（不可逆操作，必须挡一下）
    @State private var confirmUnbind = false

    /// 自动解锁开关 —— 与 `ProximityUnlockController.isEnabled` 读同一个 key
    @AppStorage(ProximityUnlockController.enabledKey) private var autoUnlockEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    idSection
                    keyStatusSection
                    passiveEntrySection
                        .id(refreshTick)   // ★ 只重建密钥列表，不重建整个页面（避免丢 TextField 焦点）
                    backupSection
                    builtInSection
                    dangerSection
                }
                .padding(18)
            }
            .background(GlassScreenBackground())
            .navigationTitle("密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - 设备标识

    private var idSection: some View {
        card("设备标识") {
            VStack(alignment: .leading, spacing: 6) {
                Text("mobileID = IDFV").font(.caption).foregroundStyle(.secondary)
                Text(KeyStore.shared.idfvDisplay)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .textSelection(.enabled)
                Text("属于 GLBLEAuthSDK / 云端接口层；BLE 协议帧（0x0D / 0x01）不含此字段，"
                     + "所以它不影响本 App 的配对与控车链路。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 密钥状态

    private var keyStatusSection: some View {
        card("Keychain 中的密钥") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(KeyStore.Key.allCases, id: \.self) { k in
                    let d = KeyStore.shared.get(k)
                    HStack(spacing: 8) {
                        Image(systemName: d != nil ? "checkmark.seal.fill" : "circle.dashed")
                            .foregroundStyle(d != nil ? .green : .secondary)
                            .font(.caption)
                        Text(k.rawValue.replacingOccurrences(of: "com.glble.sdk.", with: ""))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(d.map { "\($0.count) B" } ?? "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 靠近解锁 / 远离闭锁

    /// 自动解锁的开关与标定入口。
    ///
    /// ## 为什么标定必须放在这里（2026-11-05）
    ///
    /// `AppModel.startCalibration()` 早就实现了，但**界面上从来没有入口** ——
    /// 也就是说这个功能一直只能靠改代码触发。
    ///
    /// 而标定是自动解锁的硬前提：`calibration` 是两个阈值的基准，
    /// 没有它就没有阈值（`ProximityUnlockController.update` 会直接返回，
    /// 一律不动作）。所以开关必须和标定放在一起，且未标定时明确警告。
    private var passiveEntrySection: some View {
        card("靠近解锁 / 远离闭锁") {
            VStack(alignment: .leading, spacing: 10) {
                // 实时区域状态（按**靠近解锁**自己的双阈值判，不是点火验证的圈）
                HStack(spacing: 6) {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 7, height: 7)
                    Text(model.proximityUnlock.summary)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%.0f dBm", model.proximityUnlock.lastCombinedRSSI))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                calibrationBlock

                // ★ 阈值可调（2026-11-05 用户要求）。
                //
                // 用户面对的是"多近才算靠近"，而不是 offset 这个内部量 ——
                // 所以 Stepper 调 offset，但显示的始终是**实际阈值（dBm）**，
                // 下面再实时对照当前 RSSI，让他自己找边界。
                if model.passiveStart.isCalibrated {
                    Divider()
                    thresholdBlock
                }

                Divider()

                Toggle(isOn: $autoUnlockEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动解锁")
                            .font(.system(size: 13, weight: .medium))
                        Text("进入解锁阈值并连续停留 2 秒后解锁；跌破闭锁阈值立即闭锁")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text("与「点火位置验证」共用车内标定值，但两套判定各有自己的阈值，互不影响")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!model.passiveStart.isCalibrated)

                if autoUnlockEnabled, !model.passiveStart.isCalibrated {
                    Text("⚠️ 还没标定，自动解锁不会生效")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if let action = model.proximityUnlock.lastAction,
                   let at = model.proximityUnlock.lastActionAt {
                    Text("最近一次：\(action.rawValue) · \(AppModel.hhmm(at))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                // 安全提醒 —— 这几条不是免责声明，是真实会踩到的坑
                if autoUnlockEnabled {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("离开后会自动闭锁。车里有小孩或宠物时请关掉这个开关。",
                              systemImage: "exclamationmark.triangle.fill")
                        Label("手机留在车里时不会闭锁（它一直在解锁阈值内侧）。",
                              systemImage: "info.circle")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 阈值调整：两个 offset，各自显示实际 dBm，并用一条刻度带对照实时 RSSI。
    ///
    /// 为什么是两个而不是一个（2026-11-05 第二轮）：
    /// 单个阈值在边界上必然抖 —— RSSI 本身就有 ±3 dB 的帧间波动，
    /// 人站门边侧个身就跨过去了。两个阈值之间留一段**迟滞带**，
    /// 带内不动作，才不会「解锁—闭锁—又解锁」。
    private var thresholdBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("判定阈值")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("迟滞 \(model.proximityUnlock.hysteresis) dB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            // 解锁阈值
            Stepper(value: Binding(
                get: { model.proximityUnlock.enterOffset },
                set: { model.setProximityEnterOffset($0) }
            ), in: ProximityUnlockController.enterRange) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("解锁 · 到车边")
                            .font(.system(size: 11))
                        Text("数值越小 → 要求越近")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(model.proximityUnlock.unlockThreshold.map { "\($0) dBm" } ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                }
            }

            // 闭锁阈值
            Stepper(value: Binding(
                get: { model.proximityUnlock.exitOffset },
                set: { model.setProximityExitOffset($0) }
            ), in: ProximityUnlockController.exitRange) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("闭锁 · 走远")
                            .font(.system(size: 11))
                        Text("数值越大 → 走得越远才闭锁")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(model.proximityUnlock.lockThreshold.map { "\($0) dBm" } ?? "—")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }

            thresholdBar

            // 实时对照：当前 RSSI 落在哪一段，调 Stepper 时直接看这三个数
            HStack(spacing: 6) {
                Text("当前")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(String(format: "%.0f", model.proximityUnlock.lastCombinedRSSI))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Text("dBm")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(phaseText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(phaseColor)
            }

            // 说明默认折叠 —— 上一版这四行常驻，把两个 Stepper 埋进了一堆文字里。
            DisclosureGroup {
                Text("站在你想触发解锁的位置，看上面「当前」的 dBm 落在哪一段。\n"
                     + "还没走到就解锁 → 解锁阈值调高（数值调小）；\n"
                     + "站到车边还不解锁 → 解锁阈值调低（数值调大）。\n"
                     + "两条阈值不能贴太近（至少差 3 dB），否则会在边界上反复开关。")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } label: {
                Text("怎么调？")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    /// 一条横向刻度带：从「车内标定值 - 60 dB」到「标定值」，
    /// 画出两个阈值与当前值的位置关系。纯展示，不参与判定。
    private var thresholdBar: some View {
        let cal: Double = Double(model.passiveStart.calibration ?? 0)
        let low: Double = cal - 60
        return VStack(spacing: 2) {
            GeometryReader { geo in
                let w: CGFloat = geo.size.width
                let lockX: CGFloat? = model.proximityUnlock.lockThreshold
                    .map { barX(Double($0), low: low, width: w) }
                let unlockX: CGFloat? = model.proximityUnlock.unlockThreshold
                    .map { barX(Double($0), low: low, width: w) }
                let curX: CGFloat = barX(model.proximityUnlock.lastCombinedRSSI, low: low, width: w)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.22))
                        .frame(height: 6)

                    if let lx = lockX, let ux = unlockX {
                        // 车边段（绿）
                        Rectangle()
                            .fill(Color.green.opacity(0.30))
                            .frame(width: max(0, w - lx), height: 6)
                            .offset(x: lx)
                        // 迟滞带（橙）
                        Rectangle()
                            .fill(Color.orange.opacity(0.55))
                            .frame(width: max(0, ux - lx), height: 6)
                            .offset(x: lx)
                    }

                    Circle()
                        .fill(Color.primary)
                        .frame(width: 7, height: 7)
                        .offset(x: max(0, curX - 3.5))
                }
            }
            .frame(height: 16)

            // 两端标数字：否则用户不知道这条带从哪到哪
            HStack(spacing: 0) {
                Text("\(Int(low))")
                Spacer()
                Text("灰=远处 · 橙=迟滞带 · 绿=车边")
                Spacer()
                Text("\(Int(cal))")
            }
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.quaternary)
        }
    }

    /// 把 dBm 值映射到条上的横向坐标（越靠右 = 信号越强）
    private func barX(_ value: Double, low: Double, width: CGFloat) -> CGFloat {
        let span: Double = 60
        let p: Double = (value - low) / span
        let clamped: Double = min(max(p, 0), 1)
        return CGFloat(clamped) * width
    }

    private var phaseText: String {
        guard model.proximityUnlock.calibration != nil else { return "未标定" }
        return model.proximityUnlock.phase.rawValue
    }

    private var phaseColor: Color {
        switch model.proximityUnlock.phase {
        case .inside:     return .green
        case .boundary:   return .orange
        case .far:        return .secondary
        }
    }

    @ViewBuilder
    private var calibrationBlock: some View {
        if model.passiveStart.isCalibrating {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: model.passiveStart.calibrationProgress)
                    .tint(.blue)
                // ★ 位置必须写「车内」：这个 calibration 与「点火位置验证」共用
                //   （`PassiveStartJudge.checkRssiForPassiveStart`），
                //   原厂语义就是「钥匙在车内」。
                //   我一开始写的是「站在车外 2–3 米」—— 那会把基准值拉低，
                //   点火判定区随之扩大到车外，等于破坏另一个功能。
                Text("采样中 \(model.passiveStart.calibrationSampleCount)/\(PassiveStartJudge.calibrationSampleTarget) —— 请把手机放在**车内靠近天线**的位置，保持不动")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("取消标定") { model.cancelCalibration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else if let cal = model.passiveStart.calibration {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text("已标定")
                        .font(.system(size: 12, weight: .medium))
                    Text("calibration=\(cal) · 点火验证阈值=\(model.passiveStart.threshold)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("重新标定") { model.startCalibration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("未标定 —— 自动解锁必须先标定，否则阈值不成立")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("开始标定") { model.startCalibration() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Text("需要在车辆连接状态下操作")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 导入

    /// ★ **整包备份 / 恢复** —— 升级或换机时保住密钥，不必重新配对。
    ///
    /// 背景：Keychain 现在已改为 `kSecAttrSynchronizable = true`（走 iCloud 钥匙串），
    /// 正常情况下重装 App 密钥会自动回来。这个卡片是**兜底**：
    /// iCloud 钥匙串没开、或要换到另一台设备时，用它手动搬运。
    private var backupSection: some View {
        card("备份 / 恢复密钥（升级不丢）") {
            VStack(alignment: .leading, spacing: 10) {
                Text("共 \(KeyStore.shared.backupItemCount) 项密钥。导出后请保存到备忘录或文件。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    let text = KeyStore.shared.exportBackup()
                    backupText = text
                    // ★ 不要把明文钥匙留在系统通用剪贴板里（2026-10-29 修复）。
                    //
                    // `UIPasteboard.general.string = text` 会进全局剪贴板，
                    // 还会通过「通用剪贴板」同步到同一 Apple ID 的其他设备 ——
                    // 一次导出，整把车钥匙（dk1 + CkTRxSP + tail）就散到别处了。
                    // 现在标记为仅本机（`.localOnly`）+ 60 秒后自动失效。
                    if !text.isEmpty {
                        UIPasteboard.general.setItems(
                            [[UTType.plainText.identifier: text]],
                            options: [
                                .localOnly: true,
                                .expirationDate: Date().addingTimeInterval(60),
                            ])
                    }
                    backupResult = text.isEmpty
                        ? "没有可导出的密钥"
                        : "已导出并复制（仅本机，60 秒后自动失效）"
                } label: {
                    Label("导出并复制（仅本机）", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                TextField("粘贴备份内容后点「恢复」", text: $backupText, axis: .vertical)
                    .font(.system(.caption2, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .glassPill()
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(3...6)

                Button {
                    let n = KeyStore.shared.importBackup(backupText)
                    backupResult = n > 0 ? "已恢复 \(n) 项密钥" : "恢复失败：内容无法识别"
                    // ★ 恢复成功后必须让会话重载密钥并重算完整性（2026-10-29 修复）。
                    //   原来只 `refreshTick += 1`（只重画 Keychain 列表），
                    //   于是主界面仍显示「尚未绑定车辆」，且若之前指纹校验为
                    //   失败态，恢复一把正确的钥匙后依然发不出任何帧。
                    if n > 0 {
                        model.measured.reloadKeys()
                        model.verifyKeyIntegrity()
                        backupResult = "已恢复 \(n) 项密钥，钥匙已生效"
                    }
                    refreshTick += 1
                } label: {
                    Label("从备份恢复", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                if !backupResult.isEmpty {
                    Text(backupResult).font(.caption2).foregroundStyle(.cyan)
                }
            }
        }
    }

    /// 内置钥匙（从原 App 的加密备份里提取的那把）
    ///
    /// 只在首次启动自动写入一次。这里提供一个手动入口，方便：
    /// - 解绑之后想立刻恢复内置钥匙（不用重启 App）；
    /// - 确认当前生效的是不是内置的那把。
    private var builtInSection: some View {
        card("内置钥匙") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: BuiltInKeys.isActive
                          ? "checkmark.seal.fill" : "seal")
                        .foregroundStyle(BuiltInKeys.isActive ? .green : .secondary)
                    // ★ 三态（2026-10-30 修复）。
                    //
                    // 原来只有「内置 / 非内置」两态，而 `BuiltInKeys.isActive`
                    // 在 dk1 为空时返回 false —— 于是**解绑车辆清空 Keychain 后**，
                    // 这里会显示「当前生效：非内置钥匙」，等于暗示"有一把别人的
                    // 钥匙正在生效"，和同卡片下面「字段不全」自相矛盾。
                    Text(!model.hasLocalKey
                         ? "当前没有钥匙（未绑定）"
                         : (BuiltInKeys.isActive
                            ? "当前生效：内置钥匙"
                            : "当前生效：自行配对的钥匙"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !BuiltInKeys.isComplete {
                        Label("字段不全", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text("内置的是原 App 最后一次配对成功（2026-10-28 21:12）拿到的那把，"
                     + "车端确认有效。本机原有的那把（10-04）车端从未写入槽位，"
                     + "所以鉴权必被拒、连上即断。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    if BuiltInKeys.apply() {
                        model.measured.reloadKeys()
                        // ★ 必须重算完整性（2026-10-29 全域审查修复）。
                        //
                        // 少了这一句会出现：解绑车辆 → `deleteVehicle()` 里
                        // `verifyKeyIntegrity()` 因 communicationKey 为空把
                        // `keyIntegrityOK` 置 false → 立刻点「重新应用内置钥匙」
                        // → 钥匙确实写进了 Keychain、`hasLocalKey` 也变 true，
                        // 但 `keyIntegrityOK` 仍是 false →
                        // `beginMeasuredAuth` 的 `guard keyIntegrityOK != false`
                        // 把**每一次控车**都拦下，只能重启 App 才能恢复。
                        // （「从备份恢复」那条分支早就这么做了，这里漏了。）
                        model.verifyKeyIntegrity()
                        refreshTick += 1
                        backupResult = "✅ 已写入内置钥匙"
                    } else {
                        backupResult = "❌ 内置钥匙写入失败"
                    }
                } label: {
                    Label("重新应用内置钥匙", systemImage: "arrow.down.to.line.compact")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var dangerSection: some View {
        card("危险操作") {
            Button(role: .destructive) {
                // ★ 二次确认（2026-10-29）：解绑会清空 Keychain 里的全部密钥，
                //   之后必须让车端重新开配对窗口才能再用，不可撤销。
                //   原来一点就执行，误触代价太大。
                confirmUnbind = true
            } label: {
                Label("解绑车辆（清除密钥与标定）", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .confirmationDialog(
                "确认解绑这台车？",
                isPresented: $confirmUnbind,
                titleVisibility: .visible
            ) {
                Button("解绑并清除密钥", role: .destructive) {
                    model.deleteVehicle()
                    refreshTick += 1
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将清除本地密钥、标定值与无感进入设置，并回到「未配对」状态。\n"
                     + "之后需要车端开配对窗口、重新配对才能再控车。\n"
                     + "密钥已备份的话，解绑后可用「从备份恢复」找回。")
            }
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                content()
            }
            .padding(Glass.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }
}
