import SwiftUI

/// 手表主界面 —— 纯云端遥控器。
///
/// 三个区块，从上到下：
/// 1. **状态**：车锁 + 空调，配一行「多久前同步」
/// 2. **动作**：解锁 / 闭锁 / 空调 / 寻车 / 启动熄火 / 刷新
/// 3. **账号**：脱敏手机号 —— 让人知道这是哪个账号在控车
///
/// 没同步到账号时整页换成一句说明 + 「重新同步」，
/// 不在手表上提供登录表单（输 17 位 VIN 不现实，见 `WatchCloudController`）。
struct WatchRootView: View {
    @EnvironmentObject private var controller: WatchCloudController
    @State private var confirmingEngine = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if controller.configured {
                    statusCard
                    actionGrid
                    footer
                } else {
                    notConfigured
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        // 不设 navigationTitle：watchOS 上它会渲染在右上角，
        // 和状态栏时钟叠在一起，而且这块屏幕只有一个用途，标题是多余的。
        .toolbar(.hidden, for: .navigationBar)
        .task { await controller.refresh() }
        .alert("远程启动引擎？", isPresented: $confirmingEngine) {
            Button("取消", role: .cancel) {}
            Button("启动") {
                Task { await controller.perform(.engine(on: true)) }
            }
        } message: {
            Text("请确认车辆不在密闭空间。")
        }
    }

    // MARK: - 状态

    private var statusCard: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: lockIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(lockColor)
                Text(lockText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(lockColor)
            }

            HStack(spacing: 6) {
                Image(systemName: "snowflake")
                    .font(.system(size: 10))
                    .foregroundStyle(controller.acOn == true ? .cyan : .secondary)
                Text(acText)
                    .font(.system(size: 11))
                    .foregroundStyle(controller.acOn == true ? .cyan : .secondary)
                Text("·").foregroundStyle(.tertiary)
                Text(syncText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var lockIcon: String {
        guard let locked = controller.snapshot?.isLocked else { return "questionmark.circle" }
        return locked ? "lock.fill" : "lock.open.fill"
    }

    private var lockColor: Color {
        guard let locked = controller.snapshot?.isLocked else { return .secondary }
        return locked ? .green : .orange
    }

    private var lockText: String {
        guard let locked = controller.snapshot?.isLocked else { return "状态未知" }
        return locked ? "已锁" : "未锁"
    }

    private var acText: String {
        guard let on = controller.acOn else { return "空调 —" }
        return on ? "空调 \(controller.acTemperature)°" : "空调关"
    }

    private var syncText: String {
        guard let at = controller.lastSyncAt else { return "未同步" }
        let s = Int(Date().timeIntervalSince(at))
        if s < 60 { return "\(s) 秒前" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        return "\(s / 3600) 小时前"
    }

    // MARK: - 动作

    private var actionGrid: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                action("解锁", "lock.open.fill", tint: .green) {
                    .unlock
                }
                action("闭锁", "lock.fill", tint: .blue) {
                    .lock
                }
            }
            HStack(spacing: 8) {
                action(controller.acOn == true ? "关空调" : "开空调",
                       "snowflake", tint: .cyan) {
                    .airConditioner(on: controller.acOn != true,
                                    temperature: controller.acTemperature)
                }
                action("寻车", "light.beacon.max.fill", tint: .orange) {
                    .find
                }
            }
            actionWide(engineTitle, "power", tint: .red) {
                if controller.snapshot?.isEngineRunning == true {
                    Task { await controller.perform(.engine(on: false)) }
                } else {
                    confirmingEngine = true
                }
            }
            actionWide("刷新", "arrow.clockwise", tint: .gray) {
                Task { await controller.refresh() }
            }
            if controller.busy || controller.refreshing {
                ProgressView()
                    .padding(.top, 2)
            }
        }
        .disabled(controller.busy)
    }

    private var engineTitle: String {
        controller.snapshot?.isEngineRunning == true ? "熄火" : "启动引擎"
    }

    private func action(_ title: String, _ icon: String, tint: Color,
                        _ command: @escaping () -> VehicleCommand) -> some View {
        Button {
            Task { await controller.perform(command()) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    private func actionWide(_ title: String, _ icon: String, tint: Color,
                            _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(tint)
    }

    // MARK: - 底栏 / 未登录

    private var footer: some View {
        VStack(spacing: 2) {
            Text(controller.statusLine)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Text(controller.phoneMasked)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var notConfigured: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("还没有账号")
                .font(.system(size: 14, weight: .semibold))
            Text("先在 iPhone 上登录\n「我的 → 网络通道」")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重新同步") { controller.requestResync() }
                .buttonStyle(.bordered)
                .tint(.blue)
            Text(controller.statusLine)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.top, 4)
    }
}
