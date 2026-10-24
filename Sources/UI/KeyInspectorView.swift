import SwiftUI

/// 密钥检视 / 导入。
///
/// ## 重要说明（写给使用者）
/// 该车的蓝牙钥匙是 **Cloudless（无云）** 方案：密钥在你换用本 App **之前**
/// 就已经存在于原 App 的 Keychain 里。要让本 App 能开锁点火，有两条路：
/// 1. **用诊断仪重新匹配**（推荐，无需越狱）：诊断仪让蓝牙钥匙模块进入配对模式，
///    之后本 App 走 §7.2 的配对流程写入密钥；
/// 2. **从原 App 的 Keychain 导出后粘贴到下面**（需要越狱设备）：
///    - 原 App 的键名：`com.glble.sdk.communication.key` / `.auth.key` / `.ID.key` / `.core`
///    - ⚠️ 注意：密钥在 **Keychain**，不在 `NSUserDefaults`/plist 里
///      （`GLBLEStorageManager` 走的是 NSUserDefaults，只存普通配置）。
///
/// ## 为什么必须保持 IDFV 不变
/// 车端会校验 `mobileId`（= IDFV）。IDFV 对「同一开发者签名 + 同一设备」稳定，
/// 因此本 App 必须与原 App 使用**相同的 bundle id 与签名证书**，
/// 否则会收到 `error_sdk_50003 数字钥匙校验mobileId错误`。
struct KeyInspectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var importTarget: KeyStore.Key = .communicationKey
    @State private var importHex = ""
    @State private var refreshTick = 0
    /// ★ 整包备份文本（导出/恢复用）
    @State private var backupText = ""
    @State private var backupResult = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    idSection
                    keyStatusSection
                    backupSection
                    importSection
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
        .id(refreshTick)
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
                Text("车端用它校验「数字钥匙是否属于本机」。重写 App 时必须保持同一签名，IDFV 才不会变。")
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
                    UIPasteboard.general.string = text
                    backupResult = text.isEmpty ? "没有可导出的密钥" : "已导出并复制到剪贴板"
                } label: {
                    Label("导出并复制到剪贴板", systemImage: "square.and.arrow.up")
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

    private var importSection: some View {
        card("手动导入（从原 App 导出）") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("目标键", selection: $importTarget) {
                    ForEach(KeyStore.Key.allCases, id: \.self) { k in
                        Text(k.rawValue.replacingOccurrences(of: "com.glble.sdk.", with: ""))
                            .tag(k)
                    }
                }
                .pickerStyle(.menu)
                .tint(.cyan)

                TextField("十六进制，如 00112233…（也可粘贴 base64）", text: $importHex, axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                HStack(spacing: 10) {
                    Button {
                        importValue()
                    } label: {
                        Label("写入 Keychain", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        importHex = ""
                    } label: {
                        Label("清空", systemImage: "eraser").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private var dangerSection: some View {
        card("危险操作") {
            Button(role: .destructive) {
                KeyStore.shared.clearAll()
                refreshTick += 1
            } label: {
                Label("清除本 App 的全部密钥", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - 工具

    private func importValue() {
        let hex = importHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hex.isEmpty else { return }
        var data: Data?
        // 先按 hex 解析
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "0x", with: "")
        if cleaned.count % 2 == 0,
           cleaned.allSatisfy({ $0.isHexDigit }),
           let d = dataFromHex(cleaned) {
            data = d
        } else if let d = Data(base64Encoded: hex) {
            data = d
        }
        guard let final = data else { return }
        KeyStore.shared.set(final, for: importTarget)
        importHex = ""
        refreshTick += 1
    }

    private func dataFromHex(_ s: String) -> Data? {
        var out = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
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
