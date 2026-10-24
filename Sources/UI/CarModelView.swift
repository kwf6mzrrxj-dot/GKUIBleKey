import SwiftUI

/// 车辆舞台视图 —— **使用原 App 的车辆模型帧序列**（从 `XiaoKa.app` 提取，
/// 全部透明背景），按连接状态自动切换：
///
/// | 状态 | 展示 | 资源 | 来源序列 |
/// |---|---|---|---|
/// | 未连接 | 静态车图（半透明）| `car_rotate_025` | front2quarter 末帧 |
/// | 配对中 | 车辆拼装动画（循环）| `car_build_000…024` | `dotcar`（25 帧）|
/// | 已连接 | 入场旋转一次 → 静止车图 | `car_rotate_000…025` | front2quarter（26 帧）|
///
/// 已连接状态下的车辆状态映射（`VehicleStatus`，广播解密）：
/// - `isTrunkClosed` 变化 → 播放后备箱开/关动画（`car_trunk_000…049`）
/// - 四门打开 → 车身对应位置叠加开门角标
/// - 未收到状态 → 显示默认车图
struct CarModelView: View {
    /// 车辆状态（`nil` = 尚未收到广播状态 → 显示默认车图）
    let status: VehicleStatus?
    /// 当前连接阶段（决定播放哪套动画）
    let stage: Stage

    enum Stage: Equatable {
        /// 未连接 / 扫描中 → 静态车图（半透明）
        case connecting
        /// 配对流程进行中 → 车辆拼装动画
        case pairing
        /// 已连接 → 静态车图 + 状态动画
        case ready
    }

    var body: some View {
        switch stage {
        case .connecting:
            // 未连接：正常显示静态车图（与已连接一致，仅无状态动画）
            Image("car_rotate_025")
                .resizable()
                .scaledToFit()
                .frame(height: 230)
        case .pairing:
            LoopingFrames(prefix: "car_build", count: 25, fps: 10)
                .frame(height: 220)
        case .ready:
            ReadyCarView(status: status)
        }
    }
}

// MARK: - 帧动画引擎（循环）

/// 无限循环的 PNG 帧序列动画。
private struct LoopingFrames: View {
    let prefix: String
    let count: Int
    let fps: Double

    @State private var index = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        Image(String(format: "%@_%03d", prefix, index))
            .resizable()
            .scaledToFit()
            .id(index)
            .onAppear { start() }
            .onDisappear { task?.cancel(); task = nil }
    }

    private func start() {
        guard task == nil else { return }
        let interval = UInt64(1_000_000_000 / fps)
        task = Task { @MainActor in
            var i = 0
            while !Task.isCancelled {
                index = i % count
                try? await Task.sleep(nanoseconds: interval)
                i += 1
            }
        }
    }
}

// MARK: - 已连接的车辆舞台

/// 已连接态：入场旋转（前视角 → 3/4 视角）→ 静态车图 + 后备箱/车门状态动画。
private struct ReadyCarView: View {
    let status: VehicleStatus?

    /// 入场帧：`nil` = 已播完（显示静态末帧）；非 nil = 显示 `car_rotate_XXX`
    @State private var entranceFrame: Int?
    /// 后备箱动画帧（动画进行中才使用）
    @State private var trunkFrame: Int?
    /// 上次入场是否已播（切回 ready 时只播一次）
    @State private var entrancePlayed = false

    var body: some View {
        ZStack {
            carImage
                .resizable()
                .scaledToFit()
                .shadow(color: .white.opacity(0.10), radius: 24)

            if let s = status, entranceFrame == nil {
                doorIndicators(s)
            }
        }
        .frame(height: 230)
        .task(id: "entrance") {
            guard !entrancePlayed else { return }
            entrancePlayed = true
            // 入场：前视角 → 3/4 视角旋转一次（原 App front2quarter 序列）
            for i in 0...25 {
                entranceFrame = i
                try? await Task.sleep(nanoseconds: 45_000_000)
            }
            entranceFrame = nil
        }
        .onChange(of: status?.isTrunkClosed) { old, new in
            guard entranceFrame == nil, old != new, let new else { return }
            Task { await playTrunk(opening: new == false) }
        }
    }

    private var trunkOpen: Bool { status?.isTrunkClosed == false }

    /// 车图：入场帧 → 后备箱动画帧 → 静态末帧
    private var carImage: Image {
        if let f = entranceFrame {
            return Image(String(format: "car_rotate_%03d", f))
        }
        if let f = trunkFrame {
            return Image(String(format: "car_trunk_%03d", f))
        }
        return Image("car_rotate_025")
    }

    /// 后备箱动画（开启正放 / 关闭倒放），约 1.6s
    private func playTrunk(opening: Bool) async {
        let steps = 24
        for i in 0..<steps {
            let p = Double(i) / Double(steps - 1)
            trunkFrame = opening ? Int(p * 49) : Int((1 - p) * 49)
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
        trunkFrame = nil
    }

    // MARK: 车门角标

    /// 在车身对应位置叠加四门状态指示（开门 = 琥珀色角标）。
    /// 车图是 3/4 前视角（车头朝左），位置按帧画面比例估放。
    private func doorIndicators(_ s: VehicleStatus) -> some View {
        let badges: [(label: String, open: Bool, x: CGFloat, y: CGFloat)] = [
            ("前左门", !s.isFLDoorClosed, 0.62, 0.66),
            ("前右门", !s.isFRDoorClosed, 0.36, 0.64),
            ("后左门", !s.isRLDoorClosed, 0.74, 0.48),
            ("后右门", !s.isRRDoorClosed, 0.26, 0.46),
        ]
        return GeometryReader { geo in
            ForEach(Array(badges.enumerated()), id: \.offset) { _, b in
                if b.open {
                    VStack(spacing: 2) {
                        Image(systemName: "door.open")
                            .font(.system(size: 12, weight: .bold))
                        Text(b.label)
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .position(x: geo.size.width * b.x, y: geo.size.height * b.y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
