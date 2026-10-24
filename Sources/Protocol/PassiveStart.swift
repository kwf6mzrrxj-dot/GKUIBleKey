import Foundation

/// **点火位置验证（被动启动区域判定）** —— 照 `InBlue.framework` 反汇编实现。
///
/// ## 判定式（A 级证据）
///
/// `-[IBVehicle checkRssiForPassiveStart]` @`0xac04`：
/// ```asm
/// 0xafac: bl   [self rssisOneAndTwo]        ; 两路 RSSI 的合成值
/// 0xafcc: bl   [x0 intValue]                ; → w25
/// 0xafd4: mov  x25, x0
/// 0xafdc: ldr  x24, #0x276a0 ; calibration
/// ...    bl   [calibration intValue]
/// 0xb008: ldr  x20, #0x276a8 ; leaveOffset
/// ...    bl   [leaveOffset intValue]
/// 0xb02c: sub  w8, w22, w0                  ; w8 = calibration - leaveOffset
/// 0xb030: cmp  w25, w8
/// 0xb034: b.le 0xb230                       ; ≤ → setIsInPassiveStartArea:NO
/// ```
/// `0xb230` 分支首条指令是 `setIsInPassiveStartArea:NO`（`0xb24c` `mov w2,#0`），
/// 因此：
///
/// ```
/// 在区域内  ⟺  rssisOneAndTwo.intValue > (calibration.intValue - leaveOffset.intValue)
/// ```
///
/// ## 默认值（A 级证据）
///
/// `-[IBVehicle initWithKey:]` @`0x776c`：
/// ```asm
/// 0x7898: mov x9, #0x403d000000000000   ; _timeBetweenPassiveStart = 29.0
/// 0x78c8: mov w2, #0x1e                 ; [x0 numberWithInt:30]
/// 0x78e4: bl  setApproachOffset:        ; approachOffset = 30
/// 0x7900: mov w2, #0x20                 ; [x0 numberWithInt:32]
/// 0x791c: bl  setLeaveOffset:           ; leaveOffset = 32
/// ```
///
/// ## `calibration` 的来源（A 级证据）
///
/// `-[IBVehicle getCalibrationSavedValues]` @`0xb83c`：
/// ```asm
/// 0xb864: [NSUserDefaults standardUserDefaults]
/// 0xb8c0: adr x2, #0x20a48 ; CFSTR "%@_CALIBRATION"
/// 0xb8ec: objectForKey:                    ; key = "<cidpu>_CALIBRATION"
/// 0xb90c: setCalibration:
/// ```
/// 写入点在 `-[IBVehicle didCalibrationCompleted:error:]` @`0xa41c`：
/// `0xa5d0 CFSTR "%@_CALIBRATION"` → `0xa5f4 setObject:forKey:`。
///
/// ## `rssisOneAndTwo` 的自适应取值（A 级证据，已完整还原）
///
/// `-[IBVehicle rssisOneAndTwo]` @`0x8954` 对 `rssis` 数组做自适应取值：
/// 采样间隔均值 `avgInterval = span / count`，若 `> 0.3s` 只取最新一个值，
/// 否则对全部元素求和后除以 count 取均值。数组元素是两路 RSSI 合成后的
/// dB 距离值（`10×log10(√(10^(r1/10)²+10^(r2/10)²)×pondOutToIn)`），
/// 见 `addRSSI:` @`0xad90`。本实现已按此精确还原，不再使用近似。
public struct PassiveStartJudge: Sendable {

    /// 一次 RSSI 采样（对应 `rssis` 数组里的一项）。
    ///
    /// 反汇编 `addRSSI:` @`0xad90` 证明：塞进数组的是**两路合成后的 dB 距离值**，
    /// 而非原始单路 RSSI：
    /// ```asm
    /// 0xaeac: fmul d8,d8,d0    ; distance = √(10^(r1/10)²+10^(r2/10)²) × pondOutToIn
    /// 0xaf50: STUB _log10      ; log10(distance)
    /// 0xaf58: fmul d0,d0,d1    ; × 10 → 转回 dB
    /// 0xaf68: numberWithDouble: ; 包成 NSNumber 塞进 rssis
    /// ```
    public struct Sample: Sendable, Equatable {
        public let date: Date
        public let rssiOne: Double
        public let rssiTwo: Double
        /// 该次采样按反汇编浮点链算出的距离（`addRSSI:` 前计算）
        public let distance: Double
        /// 塞进 `rssis` 数组的合成 dB 值 = `10 × log10(distance)`
        public var combinedDB: Double { 10.0 * log10(distance) }
    }

    // ── 属性（对应 IBVehicle 的 ivar，默认值来自 initWithKey:）──

    /// 从外到内的加权系数
    public var pondOutToIn: Double = 1.0
    /// 从内到外的加权系数
    public var pondInToOut: Double = 1.0
    /// 两次判定的最小间隔 —— `0x7898` 初始值 29.0
    public var timeBetweenPassiveStart: TimeInterval = 29.0
    /// 接近偏移 —— `0x78c8 mov w2,#0x1e` → 30
    public var approachOffset: Int = 30
    /// 离开偏移 —— `0x7900 mov w2,#0x20` → 32
    public var leaveOffset: Int = 32

    /// 标定值 —— `NSUserDefaults["<cidpu>_CALIBRATION"]`，**未标定时为 `nil`**。
    ///
    /// 原 App 在未标定时 `calibration` 为 `nil`，`[nil intValue]` 返回 `0`。
    /// 本项目保留 `nil` 以便界面区分"未标定"与"标定值为 0"，
    /// 判定时按 `0` 处理（与原 App 的 `nil` 语义一致）。
    public var calibration: Int?

    /// RSSI 历史（对应 `rssiDates`）
    public private(set) var samples: [Sample] = []
    /// 最近一次判定结果（对应 `isInPassiveStartArea`）
    public private(set) var isInPassiveStartArea = false

    /// 采样稀疏阈值 —— `0x1fba0` 处的 double 常量 `0.3`
    public static let sparseIntervalThreshold: TimeInterval = 0.3

    public init() {}

    // MARK: - ① 两路 RSSI 的合成值（对应 `-[IBVehicle rssisOneAndTwo]` @`0x8954`）

    /// 反汇编还原（`rssisOneAndTwo` @`0x8954`，对 `rssis` 数组做自适应取值）：
    /// ```asm
    /// 0x89f8: timeIntervalSinceDate:          ; last.date - first.date
    /// 0x8a38: [rssis count]
    /// 0x8a44: fdiv  d8, d8, d0                ; avgInterval = span / count
    /// 0x8a5c: ldr   d0, #0x1fba0              ; 0.3
    /// 0x8a60: fcmp  d8, d0
    /// 0x8a64: b.le  #0x8bc0                   ; ≤0.3 → fast-enum 求和分支
    /// 0x8ab8: sub   x24, x0, #1               ; >0.3 → 下标 = count-1（只取最后一个）
    /// ...
    /// 0x8c48: fadd  d8, d8, d0                ; 密集：∑ rssis[i].doubleValue
    /// 0x8cb8: fdiv  d0, d8, d0                ; 密集：÷ count → 均值
    /// ```
    /// 结论：**采样稀疏（avgInterval > 0.3s）时只取最新一个合成 dB 值，
    /// 密集（≤ 0.3s）时取均值**。数组元素是合成 dB 值，不是原始 RSSI。
    public var combinedRSSI: Double {
        guard let last = samples.last, let first = samples.first else { return 0 }
        let count = Double(samples.count)
        let span = last.date.timeIntervalSince(first.date)
        let avgInterval = count > 0 ? span / count : 0

        if avgInterval > Self.sparseIntervalThreshold {
            // 稀疏 → 只取最新一次的合成 dB 值
            return last.combinedDB
        }
        // 密集 → 取所有合成 dB 值的均值
        return samples.reduce(0.0) { $0 + $1.combinedDB } / count
    }

    // MARK: - ① 距离（对应 addRSSI: 前的那段浮点运算）

    /// `0xad90`–`0xaeac`：
    /// ```asm
    /// fmov d9, #10.0 ; fdiv d0,d0,d9 ; bl ___exp10 ; fmul d10,d0,d0
    /// fmov d9, #10.0 ; fdiv d0,d0,d9 ; bl ___exp10 ; fmul d0,d0,d0
    /// fadd d0, d10, d0 ; fsqrt d0,d0 ; fmul d8, d8, d0
    /// ```
    /// 即 `√(10^(r1/10)² + 10^(r2/10)²) × pondOutToIn`。
    public func distance(rssiOne: Double, rssiTwo: Double) -> Double {
        let p1 = pow(10.0, rssiOne / 10.0)
        let p2 = pow(10.0, rssiTwo / 10.0)
        return (p1 * p1 + p2 * p2).squareRoot() * pondOutToIn
    }

    // MARK: - ② 区域判定

    /// 记录一次采样并判定。
    ///
    /// 判定式（`checkRssiForPassiveStart` @`0xac04`）：
    /// ```asm
    /// 0xafac: [self rssisOneAndTwo]        ; → w25
    /// 0xafcc: [x0 intValue]                ; w25 = rssisOneAndTwo.intValue
    /// 0xb02c: sub w8, w22, w0              ; w8 = calibration - leaveOffset
    /// 0xb030: cmp w25, w8
    /// 0xb034: b.le setIsInPassiveStartArea:NO
    /// ```
    /// 即 `在区域内 ⟺ rssisOneAndTwo.intValue > (calibration - leaveOffset)`。
    /// `rssisOneAndTwo` 用 `combinedRSSI` 还原（稀疏取最新 / 密集取均值）。
    @discardableResult
    public mutating func check(rssiOne: Double, rssiTwo: Double) -> Bool {
        let dist = distance(rssiOne: rssiOne, rssiTwo: rssiTwo)

        // 距上次判定太近就跳过（对应 timeBetweenPassiveStart）
        if let last = samples.last,
           Date().timeIntervalSince(last.date) < timeBetweenPassiveStart {
            return isInPassiveStartArea
        }

        samples.append(Sample(date: Date(), rssiOne: rssiOne,
                              rssiTwo: rssiTwo, distance: dist))
        if samples.count > 20 { samples.removeFirst(samples.count - 20) }

        // rssisOneAndTwo.intValue（自适应取值的合成 dB 值取整）
        let combined = Int(combinedRSSI.rounded())
        // 未标定时 calibration 按 0 处理（与原 App `[nil intValue]` 一致）
        let base = (calibration ?? 0) - leaveOffset

        isInPassiveStartArea = combined > base
        return isInPassiveStartArea
    }

    /// 停止预认证时清零（对应 `stopPreAuthentication` 里的
    /// `setIsInPassiveStartArea:NO` + `setDidRequestWelcome:NO`）
    public mutating func reset() {
        isInPassiveStartArea = false
        samples.removeAll()
    }

    /// 判定基准（`calibration - leaveOffset`），供界面展示
    public var threshold: Int { (calibration ?? 0) - leaveOffset }

    /// 是否已标定
    public var isCalibrated: Bool { calibration != nil }

    /// 供界面展示的摘要
    public var summary: String {
        guard !samples.isEmpty else { return "未采样" }
        let combined = Int(combinedRSSI.rounded())
        return String(format: "RSSI=%.0f  基准=%d  %@",
                      Double(combined), threshold,
                      isInPassiveStartArea ? "在区域内" : "区域外")
    }
}
