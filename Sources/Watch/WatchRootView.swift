import SwiftUI

/// 手表主界面：一眼看清车锁状态，抬手能点。
///
/// 屏幕就这么大，用户多半站在车旁 —— 需要的是「一抬手就能按对」，
/// 所以只有三件事：解锁、闭锁、寻车。
struct WatchRootView: View {
    @EnvironmentObject private var controller: WatchRemoteController

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                statusHeader
                if !controller.reachable {
                    phoneHint
                }
                actionButtons
                Text(controller.statusLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 4)
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
        guard controller.online else { return "car" }
        guard let locked = controller.isLocked else { return "car" }
        return locked ? "lock.fill" : "lock.open.fill"
    }

    private var lockColor: Color {
        guard controller.online else { return .secondary }
        guard let locked = controller.isLocked else { return .secondary }
        return locked ? .green : .orange
    }

    private var lockText: String {
        guard controller.online else { return "车辆离线" }
        guard let locked = controller.isLocked else { return "状态未知" }
        return locked ? "已闭锁" : "未闭锁"
    }

    // MARK: - iPhone 不可达提示

    private var phoneHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone.slash")
            Text("iPhone 不在附近")
        }
        .font(.caption2)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity)
    }

    // MARK: - 控车

    private var actionButtons: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                actionButton(.unlock, "解锁", "lock.open.fill", .orange)
                actionButton(.lock, "闭锁", "lock.fill", .green)
            }
            actionButton(.find, "寻车", "light.beacon.max.fill", .blue)
        }
        .disabled(controller.busy)
    }

    private func actionButton(
        _ action: WatchAction, _ title: String, _ icon: String, _ tint: Color
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
