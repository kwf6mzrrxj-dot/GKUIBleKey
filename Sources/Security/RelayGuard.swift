import Foundation

/// 中继攻击（Relay Attack）防护。
///
/// ## 背景
/// PEPS 系统里最常见的攻击是**中继放大**：两个攻击者分别站在你身边和车边，
/// 用无线电把车端的蓝牙信号中继放大，让车以为"钥匙就在旁边"，从而解锁甚至点火。
/// 用户提供的功能清单里也点明：老 GKUI 对 RSSI 校验较弱，是老款数字钥匙的常见短板。
///
/// ## 做法
/// 1. 记录 RSSI 序列，检测**异常跳变**（中继的典型信号特征：距离和强度不符）
/// 2. 在控车/点火前给出信号强度告警，让用户自己判断是否可疑
///
/// **诚实的边界**：单靠 RSSI 无法彻底防中继（专业设备可以精确仿真强度），
/// 真正的防护要靠 UWB / 距离绑定测距。这里做的是**提高攻击成本 + 给用户可见提示**，
/// 不是密码学级别的保证。
@MainActor
public final class RelayGuard: ObservableObject {

    public struct Sample: Sendable {
        public let rssi: Int
        public let at: Date
    }

    @Published public private(set) var samples: [Sample] = []
    @Published public private(set) var alarm: String?

    /// 单次跳变超过该值就认为可疑（dBm）
    public var maxJump: Int = 25
    /// 弱于该值视为信号过弱
    public var weakThreshold: Int = -85
    /// 保留的样本数
    public var windowSize: Int = 30

    public init() {}

    public func record(_ rssi: Int) {
        samples.append(Sample(rssi: rssi, at: Date()))
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        evaluate()
    }

    public func reset() {
        samples.removeAll()
        alarm = nil
    }

    private func evaluate() {
        alarm = nil
        guard samples.count >= 3 else { return }

        // 1) 跳变检测：最近两次之间突变
        if let last = samples.last, let prev = samples.dropLast().last {
            let jump = abs(last.rssi - prev.rssi)
            if jump >= maxJump {
                alarm = "信号强度突变 \(jump) dBm（可能是中继放大）"
                return
            }
        }

        // 2) 偏差检测：当前值明显强于窗口均值（突然"贴近"）
        let avg = samples.map { $0.rssi }.reduce(0, +) / samples.count
        if let last = samples.last, last.rssi - avg >= maxJump {
            alarm = "信号突然增强 \(last.rssi - avg) dBm（距均值偏离过大）"
            return
        }

        // 3) 过弱提示
        if let last = samples.last, last.rssi < weakThreshold {
            alarm = "信号过弱（\(last.rssi) dBm），可能连接不稳"
        }
    }
}
