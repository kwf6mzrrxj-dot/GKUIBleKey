import SwiftUI
import UIKit

/// 车辆舞台视图 —— **吉利博越 PRO（NL3B）车型**，图源为原 App `Assets.car`
/// 里的 `Remote_pic_car_on/off_NL3B`（1125×675，透明背景，车头朝左 3/4 视角）。
///
/// ## 状态展示
/// | 状态 | 展示 |
/// |---|---|
/// | 未连接 | 车图（正常显示）|
/// | 配对中 | 车图 + 车灯闪烁（car_light 叠加呼吸动画）|
/// | 已连接 | 车图淡入 + 缓微浮动动画；收到状态后锁定/后备箱状态叠加 |
///
/// ⚠️ 用 `UIImage(named:)` 加载，规避 colormap/CgBI 解码问题。
struct CarModelView: View {
    let status: VehicleStatus?
    let stage: Stage

    enum Stage: Equatable {
        /// 未连接 / 扫描中 → 静态车图
        case connecting
        /// 配对流程进行中 → 车灯闪烁动画
        case pairing
        /// 已连接 → 静态车图 + 浮动动画
        case ready
    }

    var body: some View {
        switch stage {
        case .connecting:
            CarImage(named: "car_on")
                .frame(height: 220)
        case .pairing:
            PairingCarView()
        case .ready:
            ReadyCarView(status: status)
        }
    }
}

/// 用 `UIImage(named:)` 加载并包成 `Image`，规避 colormap/CgBI 解码问题。
struct CarImage: View {
    let named: String

    var body: some View {
        if let img = UIImage(named: named) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "car.side")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .onAppear {
                    FileLogger.shared.warning("车辆模型帧加载失败：\(named)", module: "UI")
                }
        }
    }
}

// MARK: - 配对中（车灯闪烁）

/// 配对中：车图 + 车灯光斑呼吸闪烁（寻车灯效果，对应原 App 配对时车辆被唤醒）
private struct PairingCarView: View {
    @State private var blink = false

    var body: some View {
        ZStack {
            CarImage(named: "car_on")

            // 车灯光斑（叠加在车头上方，随呼吸明暗）
            CarImage(named: "car_light")
                .opacity(blink ? 0.9 : 0.15)
        }
        .frame(height: 220)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                blink = true
            }
        }
    }
}

// MARK: - 已连接（浮动 + 状态）

/// 已连接：车图轻微浮动（悬浮感），锁车/后备箱状态用角标叠加。
private struct ReadyCarView: View {
    let status: VehicleStatus?
    @State private var float = false

    var body: some View {
        ZStack {
            CarImage(named: "car_on")
                .offset(y: float ? -6 : 6)

            if let s = status {
                statusBadges(s)
            }
        }
        .frame(height: 220)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                float = true
            }
        }
    }

    /// 锁车状态角标（车图左上）与后备箱状态角标（车图右上）
    private func statusBadges(_ s: VehicleStatus) -> some View {
        VStack {
            HStack {
                // 锁状态：已锁 = 绿锁；未锁 = 橙开锁
                badge(icon: s.isLocked ? "lock.fill" : "lock.open.fill",
                      text: s.isLocked ? "已锁" : "未锁",
                      color: s.isLocked ? .green : .orange)
                Spacer()
                // 后备箱
                badge(icon: "car.rear.open",
                      text: s.isTrunkClosed ? "后备箱关" : "后备箱开",
                      color: s.isTrunkClosed ? .green : .orange)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .allowsHitTesting(false)
    }

    private func badge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
