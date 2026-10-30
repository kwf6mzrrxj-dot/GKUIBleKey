import SwiftUI

/// 手表主界面：一眼看清「车锁没锁」，抬手能点三下以内的操作。
///
/// 刻意不做花活 —— 手表屏幕就这么大，且用户多半站在车旁边，
/// 需要的是「一抬手就能按对」。
struct WatchRootView: View {
    @EnvironmentObject private var controller: WatchVehicleController

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                statusHeader

                if !controller.hasKeys {
                    syncCard
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
        guard let locked = controller.isLocked else { return "car" }
        return locked ? "lock.fill" : "lock.open.fill"
    }

    private var lockColor: Color {
        guard let locked = controller.isLocked else { return .secondary }
        return locked ? .green : .orange
    }

    private var lockText: String {
        guard let locked = controller.isLocked else { return "车辆状态未知" }
        return locked ? "已闭锁" : "未闭锁"
    }

    // MARK: - 没有钥匙时的引导

    private var syncCard: some View {
        VStack(spacing: 6) {
            Text("还没有钥匙")
                .font(.footnote.weight(.medium))
            Text("先在 iPhone 上绑定车辆，再点下面同步")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("同步钥匙") {
                controller.requestKeysFromPhone()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
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
