import SwiftUI

/// 手表主界面：一眼看清车锁状态，抬手能点。
///
/// 屏幕就这么大，用户多半站在车旁 —— 只放三件事：解锁、闭锁、寻车。
/// 没钥匙时换成配对入口（手表自己配对，不是从手机同步）。
struct WatchRootView: View {
    @EnvironmentObject private var controller: WatchVehicleController
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPairing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                statusHeader

                if controller.hasKeys {
                    actionButtons
                    keyEntry
                } else {
                    pairEntry
                }

                Text(controller.statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
        .sheet(isPresented: $showPairing) {
            WatchPairingView()
                .environmentObject(controller)
        }
        .onChange(of: scenePhase) { _, phase in
            // 手腕放下＝退后台。链路留着只会变成「看起来连着、其实写不出去」，
            // 下次抬手点按钮会白等 4 秒超时。
            //
            // ⚠️ 只认 `.background`，**不认 `.inactive`**：watchOS 上
            //   「系统弹窗盖住 / 抬腕过渡 / 6 位码输入框出现」都会先走一段
            //   inactive，在那里 teardown 会把正在进行的配对直接掐掉。
            switch phase {
            case .background: controller.teardown()
            case .active:     controller.bootstrap()
            default:          break
            }
        }
    }

    // MARK: - 状态

    private var statusHeader: some View {
        VStack(spacing: 2) {
            Image(systemName: lockIcon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(lockColor)
            Text(lockText)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var lockIcon: String {
        guard let locked = controller.isLocked else { return "car" }
        return locked ? "lock.fill" : "lock.open.fill"
    }

    private var lockColor: Color {
        guard let locked = controller.isLocked else { return .secondary }
        return locked ? .green : .orange
    }

    private var lockText: String {
        guard controller.hasKeys else { return "未配对" }
        guard let locked = controller.isLocked else { return "车辆状态未知" }
        return locked ? "已闭锁" : "未闭锁"
    }

    // MARK: - 配对入口（没钥匙时）

    private var pairEntry: some View {
        VStack(spacing: 6) {
            Text("手表还没有钥匙")
                .font(.footnote.weight(.medium))
            Text("需要先用诊断仪开配对窗口")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showPairing = true
            } label: {
                Label("配对一个", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 配对 / 钥匙入口（有钥匙时）

    private var keyEntry: some View {
        Button {
            showPairing = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                Text("钥匙")
            }
            .font(.caption2)
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - 控车

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                actionButton(.unlock, "解锁", "lock.open.fill", .orange)
                actionButton(.lock, "闭锁", "lock.fill", .green)
            }
            actionButton(.panic, "寻车", "light.beacon.max.fill", .blue)
        }
        .disabled(controller.busy)
    }

    private func actionButton(
        _ action: IBCommandType, _ title: String, _ icon: String, _ tint: Color
    ) -> some View {
        Button {
            controller.perform(action)
        } label: {
            VStack(spacing: 2) {
                if controller.busy {
                    ProgressView()
                } else {
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                }
                Text(title).font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(tint)
        .buttonStyle(.borderedProminent)
    }
}
