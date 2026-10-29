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
/// ## 为什么必须保持 IDFV 不变
/// 车端会校验 `mobileId`（= IDFV）。IDFV 对「同一开发者签名 + 同一设备」稳定，
/// 因此本 App 必须与原 App 使用**相同的 bundle id 与签名证书**，
/// 否则会收到 `error_sdk_50003 数字钥匙校验mobileId错误`。
struct KeyInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var refreshTick = 0
    /// ★ 整包备份文本（导出/恢复用）
    @State private var backupText = ""
    @State private var backupResult = ""
    /// 解绑二次确认（不可逆操作，必须挡一下）
    @State private var confirmUnbind = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    idSection
                    keyStatusSection
                        .id(refreshTick)   // ★ 只重建密钥列表，不重建整个页面（避免丢 TextField 焦点）
                    backupSection
                    builtInSection
                    dangerSection
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
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
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
    }
}
