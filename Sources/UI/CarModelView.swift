import SwiftUI
import UIKit

/// 车辆舞台视图 —— **吉利博越 PRO（NL3B）车型**，图源为原 App `Assets.car`
/// 里的 `Remote_pic_car_on/off_NL3B`（1125×675，透明背景，车头朝左 3/4 视角）。
///
/// ## 状态展示（2026-11-04 重做）
///
/// 之前只在「蓝牙已连接」时才画锁/后备箱角标，云端有数据也不显示 ——
/// 人在外面时整块是空的。现在状态与通道解耦：
///
/// | 层 | 内容 |
/// |---|---|
/// | 车图 | 锁 / 后备箱角标（有数据才画，没有就不画，绝不画一个猜的） |
/// | 胶囊 | 连接方式：蓝牙已连接 / 网络 / 蓝牙未连接 |
/// | 状态条 | 车门 / 车窗 / 引擎 三个 chip |
///
/// 数据来源优先级：**蓝牙状态 > 云端快照**。蓝牙是车端广播，秒级；
/// 云端有数秒延迟。但蓝牙只在车附近有，所以云端那份必须能顶上来。
struct CarModelView: View {
    /// 已归一好的状态（蓝牙优先、云端兜底，判定在 `AppModel.activeStatus`）。
    /// 这里不再自己判一遍 —— 两处判定迟早会不一致。
    let snapshot: VehicleSnapshot?
    let stage: Stage
    /// 当前走的通道 —— 决定胶囊文案，必须和按钮角标一致
    var channel: ControlChannel = .bluetooth
    /// 车图高度。**调用方传，视图内部不再写死** ——
    ///
    /// 之前这里写死 220，外层又套 `.frame(height: 196)` 想省空间。
    /// 结果是：内层内容（220 车图 + 胶囊 + 两行芯片 ≈ 316）比外层框高 120，
    /// 溢出部分画在框外，正好被下面的「准备点火」卡和按钮压住。
    /// 现在就一份尺寸，内外一致，不可能再压。
    var carHeight: CGFloat = 220

    enum Stage: Equatable {
        /// 未连接 / 扫描中 → 静态车图
        case connecting
        /// 配对流程进行中 → 车灯闪烁动画
        case pairing
        /// 已连接 → 静态车图 + 浮动动画
        case ready
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                switch stage {
                case .connecting:
                    CarImage(named: "car_on")
                case .pairing:
                    PairingCarView()
                case .ready:
                    FloatingCarView()
                }

                if let s = snapshot {
                    cornerBadges(s)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: carHeight)

            channelPill
            statusChips
        }
    }

    // MARK: - 车图上的角标

    /// 锁（左上）与后备箱（右上）。值为 nil 时整块不画。
    @ViewBuilder
    private func cornerBadges(_ s: VehicleSnapshot) -> some View {
        VStack {
            HStack {
                if let locked = s.isLocked {
                    badge(icon: locked ? "lock.fill" : "lock.open.fill",
                          text: locked ? "已锁" : "未锁",
                          color: locked ? .green : .orange)
                }
                Spacer()
                if let closed = s.isTrunkClosed {
                    badge(icon: "car.rear.open",
                          text: closed ? "后备箱关" : "后备箱开",
                          color: closed ? .green : .orange)
                }
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
        .glassPill()
    }

    // MARK: - 连接方式

    private var channelPill: some View {
        let connected = channel == .bluetooth && stage == .ready
        let icon: String
        let text: String
        let color: Color
        if connected {
            icon = "bolt.horizontal.circle.fill"; text = "蓝牙已连接"; color = .blue
        } else if channel == .network {
            icon = "wifi.circle.fill"; text = "网络"; color = .green
        } else {
            icon = "bolt.horizontal.circle"; text = "蓝牙未连接"; color = .secondary
        }

        return HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassPill()
        .accessibilityLabel(text)
    }

    // MARK: - 状态条

    /// 两行：四个车门 + 天窗 / 车窗 / 引擎。
    ///
    /// 四门是**独立**的（蓝牙 `parseDoorsStatus:` 和云端 `doorOpenStatus*` 都是四个字段），
    /// 所以能精确指出「右后门开着」而不是含糊的「有门开着」。
    /// 只有当某一扇真的开着时才上色强调 —— 全关时整排保持安静。
    private var statusChips: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                doorChip(index: 0, name: "左前")
                doorChip(index: 1, name: "右前")
                doorChip(index: 2, name: "左后")
                doorChip(index: 3, name: "右后")
            }
            HStack(spacing: 6) {
                chip(icon: "sun.max", text: sunroofText, tone: sunroofTone)
                chip(icon: "wind", text: windowText, tone: windowTone)
                chip(icon: "engine.combustion", text: engineText, tone: engineTone)
            }
        }
    }

    /// 单个车门的 chip。`doorClosed` 为 nil（没有数据）时显示问号，不猜。
    private func doorChip(index: Int, name: String) -> some View {
        let states = snapshot?.doorClosed
        let closed: Bool? = (states != nil && states!.count > index) ? states![index] : nil
        let tone: Tone = closed == nil ? .neutral : (closed! ? .good : .warn)
        return chip(
            icon: closed == nil ? "questionmark" : (closed! ? "door.left.hand.closed" : "door.left.hand.open"),
            text: name,
            tone: tone,
            emphasize: closed == false)
    }

    private var sunroofText: String {
        guard let open = snapshot?.isSunroofOpen else { return "天窗 —" }
        return open ? "天窗开" : "天窗关"
    }
    private var sunroofTone: Tone {
        guard let open = snapshot?.isSunroofOpen else { return .neutral }
        return open ? .warn : .good
    }

    /// 车窗只有云端能给（蓝牙广播里没有窗位）。
    /// 云端没带窗位时显示「—」，不假装全关。
    private var windowText: String {
        guard let s = snapshot, s.isWindowsKnown else { return "车窗 —" }
        return (s.isWindowsClosed ?? false) ? "车窗全关" : "车窗开着"
    }
    private var windowTone: Tone {
        guard let s = snapshot, s.isWindowsKnown else { return .neutral }
        return (s.isWindowsClosed ?? false) ? .good : .warn
    }

    private var engineText: String {
        guard let running = snapshot?.isEngineRunning else { return "引擎 —" }
        return running ? "引擎运行" : "引擎熄火"
    }
    private var engineTone: Tone {
        guard let running = snapshot?.isEngineRunning else { return .neutral }
        return running ? .active : .good
    }

    /// `emphasize` = 需要引起注意（门窗开着），给个淡色底
    private func chip(icon: String, text: String, tone: Tone,
                      emphasize: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            if emphasize {
                Capsule().fill(tone.color.opacity(0.16))
            } else {
                Capsule().fill(.clear)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private enum Tone {
        case good, warn, active, neutral

        var color: Color {
            switch self {
            case .good: return .green
            case .warn: return .orange
            case .active: return .cyan
            case .neutral: return .secondary
            }
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
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                blink = true
            }
        }
    }
}

// MARK: - 已连接（浮动）

/// 已连接：车图轻微浮动（悬浮感）。状态角标由外层叠加，这里只管动画。
private struct FloatingCarView: View {
    @State private var float = false

    var body: some View {
        CarImage(named: "car_on")
            .offset(y: float ? -5 : 5)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    float = true
                }
            }
    }
}
