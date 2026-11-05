import SwiftUI

/// 网络通道（云端）配置页。
///
/// ## 为什么需要这一页
/// 蓝牙钥匙只在车附近有效；云端通道靠账号登录，人不车边也能控车。
/// 两者共用同一台车，但**凭据完全独立** —— 云端要的是 GKUI 账号
/// （手机号 + 密码）加车架号，蓝牙要的是本地密钥。
///
/// 密码只存 MD5：服务端收的就是这个，本地不留明文。
struct CloudSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var password = ""
    @State private var vin = ""
    /// 已经存过密码时不回填（也没法回填，只存了 MD5），给个「保持原值」的提示
    @State private var hasStoredPass = false

    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    /// 「清除配置」二次确认
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("手机号", text: $phone)
                        .keyboardType(.numberPad)
                        .textContentType(.telephoneNumber)
                    SecureField(hasStoredPass ? "密码（留空则不变）" : "密码", text: $password)
                    TextField("车架号 VIN（17 位）", text: $vin)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("GKUI 账号")
                } footer: {
                    Text("和「吉利 GKUI」App 登录用的是同一个账号。密码只在本地算成 MD5 后保存，不存明文。")
                        .font(.caption)
                }

                Section {
                    HStack {
                        Text("通道状态")
                        Spacer()
                        Text(model.cloudConfigured ? "已配置" : "未配置")
                            .foregroundStyle(model.cloudConfigured ? .green : .secondary)
                    }
                    if let t = model.cloudState.text {
                        HStack {
                            Text("当前")
                            Spacer()
                            Text(t).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    if let s = model.cloudSnapshot {
                        HStack {
                            Text("最近车况")
                            Spacer()
                            Text(s.updatedAt.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("网络通道")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("蓝牙已连接时优先走蓝牙（更快、不耗流量）；")
                        Text("蓝牙不通时自动切到网络。")
                        Text("Siri / 快捷指令 / 控制中心固定走网络。")
                    }
                    .font(.caption)
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }

                Section {
                    Button {
                        Task { await saveAndTest() }
                    } label: {
                        HStack {
                            if busy { ProgressView().padding(.trailing, 4) }
                            Text(busy ? "正在验证…" : "保存并测试连接")
                        }
                    }
                    .disabled(busy || phone.isEmpty || vin.isEmpty)

                    if model.cloudConfigured {
                        Button {
                            Task { await refreshOnly() }
                        } label: {
                            Text("刷新一次车况")
                        }
                        .disabled(busy)

                        // 之前没有出口：换账号只能覆盖，旧凭据永远留在设备上
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Text("清除云端配置")
                        }
                        .disabled(busy)
                    }
                }
            }
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            .scrollContentBackground(.hidden)
            .background(GlassScreenBackground())
            .navigationTitle("网络通道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await loadExisting() }
            .confirmationDialog("清除后无法远程控车，直到重新登录",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除配置", role: .destructive) {
                    Task { await clearAll() }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func loadExisting() async {
        let c = await model.cloud.snapshotOfCredentials()
        phone = c.phone
        vin = c.vin
        hasStoredPass = !c.passMD5.isEmpty
    }

    private func saveAndTest() async {
        busy = true
        message = nil
        defer { busy = false }

        // 留空表示沿用已存的 MD5 —— 界面上拿不到明文，也没必要拿
        let pass = password
        if pass.isEmpty && !hasStoredPass {
            message = "请输入密码"
            isError = true
            return
        }

        let err: String?
        if pass.isEmpty {
            err = await model.configureCloudKeepingPassword(phone: phone, vin: vin)
        } else {
            err = await model.configureCloud(phone: phone, password: pass, vin: vin)
        }

        if let err {
            message = err
            isError = true
        } else {
            // 登录成功 ≠ 车况读到了。`configureCloud` 里那次 fetch 失败也会返回 nil，
            // 原来一律报「车况读取成功」，用户以为一切正常，其实状态页是空的。
            if model.cloudSnapshot != nil {
                message = "已连接，车况读取成功"
            } else {
                message = "账号已验证；车况暂时没读到，稍后会自动重试"
            }
            isError = false
            password = ""
            hasStoredPass = true
        }
    }

    private func clearAll() async {
        busy = true
        defer { busy = false }
        await model.clearCloudConfig()
        phone = ""
        vin = ""
        password = ""
        hasStoredPass = false
        message = "云端配置已清除（本机不再保存凭据）"
        isError = false
    }

    private func refreshOnly() async {
        busy = true
        defer { busy = false }
        await model.refreshCloudStatus()
        if case .failed(let e) = model.cloudState {
            message = e
            isError = true
        } else if model.cloudSnapshot != nil {
            message = "车况已更新"
            isError = false
        }
    }
}
