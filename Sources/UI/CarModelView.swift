import SwiftUI

/// 车辆模型视图 —— **使用原 App 的车辆模型帧**（从 `XiaoKa.app` 提取的
/// `trunkopen` PNG 序列，透明背景，车尾 3/4 视角）。
///
/// ## 资源说明
/// 原 App 的车辆展示就是这套 PNG 帧序列动画：
/// - `car_trunk_000.png` = 后备箱**关闭**（常态展示帧）
/// - `car_trunk_049.png` = 后备箱**打开**（动画末帧）
/// - 中间帧 = 后备箱开启过程动画（执行「后备箱」动作时播放）
///
/// ## 状态映射（`VehicleStatus`，广播解密）
/// - `isTrunkClosed` == false → 后备箱打开：显示末帧
/// - `isTrunkClosed` == true  → 后备箱关闭：显示首帧
/// - 四门（`isFL/FR/RL/RRDoorClosed`）→ 在车身对应位置叠加开门指示
/// - `isIgnitionOn` / `isEngineRunning` → 顶部状态点
struct CarModelView: View {
    /// 车辆状态（`nil` = 尚未收到广播状态 → 显示默认车图）
    let status: VehicleStatus?

    /// 动画帧总数（Resources/CarModel 里的 car_trunk_000…049）
    private static let frameCount = 50
    /// 动画帧名
    private static func frameName(_ i: Int) -> String {
        String(format: "car_trunk_%03d", i)
    }

    /// 是否正在播放后备箱动画
    @State private var animating = false
    @State private var animationFrame = 0

    var body: some View {
        ZStack {
            carImage
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 240)
                .shadow(color: .white.opacity(0.10), radius: 24)

            if let s = status {
                doorIndicators(s)
            }
        }
        .onChange(of: status?.isTrunkClosed) { old, new in
            // 后备箱状态变化 → 播放原 App 的开启/关闭动画
            guard old != new else { return }
            playTrunkAnimation(opening: new == false)
        }
    }

    // MARK: - 车图

    private var carImage: Image {
        if animating {
            return Image(Self.frameName(animationFrame))
        }
        // 静止：按当前后备箱状态取首/末帧
        let open = status?.isTrunkClosed == false
        return Image(Self.frameName(open ? Self.frameCount - 1 : 0))
    }

    /// 播放后备箱动画（开启 = 正放；关闭 = 倒放）
    private func playTrunkAnimation(opening: Bool) {
        animating = true
        let total = Self.frameCount
        let duration: Double = 1.6   // 与原 App 动画时长接近
        let step = Int(duration * 30) // 每 33ms 一帧
        Task { @MainActor in
            for i in 0..<step {
                let progress = Double(i) / Double(step - 1)
                let frame = opening
                    ? Int(progress * Double(total - 1))
                    : Int((1 - progress) * Double(total - 1))
                animationFrame = frame
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            animationFrame = opening ? total - 1 : 0
            animating = false
        }
    }

    // MARK: - 车门指示

    /// 在车身对应位置叠加四门状态指示（开门 = 琥珀色圆点 + 图标）。
    ///
    /// 车图是车尾 3/4 视角：前门在画面右侧（车头朝右），
    /// 后门在中间偏左，位置按 750×1000 帧的比例估放。
    private func doorIndicators(_ s: VehicleStatus) -> some View {
        let badges: [(label: String, open: Bool, x: CGFloat, y: CGFloat)] = [
            ("前左门", !s.isFLDoorClosed, 0.30, 0.62),
            ("前右门", !s.isFRDoorClosed, 0.62, 0.60),
            ("后左门", !s.isRLDoorClosed, 0.22, 0.48),
            ("后右门", !s.isRRDoorClosed, 0.55, 0.46),
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
                    .position(x: geo.size.width * b.x,
                              y: geo.size.height * b.y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
