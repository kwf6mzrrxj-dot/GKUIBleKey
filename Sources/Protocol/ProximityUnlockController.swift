import Foundation

/// **靠近解锁 / 远离闭锁**的状态机。
///
/// ## 它和 `PassiveStartJudge` 的分工
///
/// `PassiveStartJudge` 回答的是「钥匙在不在**点火判定区**里」，判定式严格照
/// `InBlue.framework` 的 `checkRssiForPassiveStart` 还原：
///
/// ```
/// 在区域内  ⟺  combined > (calibration - leaveOffset)
/// ```
///
/// 而 `calibration` 是**车内标定**的结果。`leaveOffset = 32` 意味着
/// 阈值比车内低 32 dB —— 那是个很宽的圈，车外好几米都算「在区域内」。
/// 用它来决定「要不要开车门」，等于车还没走到就解锁了。
///
/// 所以这里**不再复用它**，而是自己按 combined 值算两个阈值：
///
/// ```
/// 解锁阈值 = calibration - enterOffset     // 更严：真的到车边了
/// 闭锁阈值 = calibration - exitOffset      // 更松：明确走远了
/// 要求 enterOffset < exitOffset            // 迟滞，见下
/// ```
///
/// ## 为什么需要两个阈值（迟滞）
///
/// 单阈值 + 位置抖动 = 边界上反复进出。RSSI 本身就有 ±3 dB 的帧间波动，
/// 人站在门边稍微侧个身就跨过去了。状态机的 2 秒停留能挡住「频繁解锁」，
/// 但挡不住「解锁 → 闭锁 → 又解锁」的循环。
///
/// 双阈值给出一个**迟滞带**：进入要高于 unlock、退出要低于 lock，
/// 中间这段什么也不做。带越宽越稳，越窄越灵敏。
///
/// ## 为什么解锁要「停留」，闭锁不要
///
/// 两个方向的误判代价完全不同：
///
/// - 误**闭锁**：车被锁上，按一下钥匙就好 —— 可恢复
/// - 误**解锁**：车门对所有人开放 —— 不可撤销
///
/// 所以进门慢（要求 `dwellToUnlock` 秒连续在解锁阈值内侧），
/// 出门快（跌破闭锁阈值就执行）。这是有意的不对称，不是漏了对称处理 ——
/// 单帧 RSSI 掉 8 dB 以上基本只可能是人真走了，不是抖动。
///
/// ## 冷却
///
/// 两个方向各自留冷却窗口：解锁后 `unlockCooldown` 内不再解锁，
/// 闭锁后 `lockCooldown` 内不再闭锁。防止「在阈值附近来回走」导致车门
/// 反复开关 —— 那种情况用户会以为车坏了。
@MainActor
public final class ProximityUnlockController: ObservableObject {

    // MARK: - 对外状态

    public enum Phase: String, Sendable {
        /// 闭锁阈值之外 —— 明确在远处
        case far = "远处"
        /// 落在迟滞带里 —— 既不算靠近也不算离开，不动作
        case boundary = "边界"
        /// 在解锁阈值内侧（已解锁或已具备解锁条件）
        case inside = "车边"
    }

    public enum Action: String, Sendable {
        case unlock = "靠近解锁"
        case lock = "远离闭锁"
    }

    /// 当前阶段
    @Published public private(set) var phase: Phase = .far
    /// 最近一次动作（供界面显示）
    @Published public private(set) var lastAction: Action?
    @Published public private(set) var lastActionAt: Date?
    /// 已经连续在解锁阈值内侧多久 —— 界面显示「靠近中 1.2/2.0 秒」
    @Published public private(set) var dwellProgress: TimeInterval = 0

    // MARK: - 参数

    /// 开关。默认**关闭** —— 自动开车门这种事不该默认替用户做主。
    public static let enabledKey = "gkuiblekey.proximityUnlock"

    /// 解锁阈值相对标定值的偏移（dB）。**数值越小 → 阈值越高 → 要求越近。**
    ///
    /// 默认 18：车内 → 车边 1–2 米，实测衰减大致 12–22 dB
    /// （受手机天线、手机壳、停车姿态影响，所以要能调）。
    public static let enterOffsetKey = "gkuiblekey.proximity.enterOffset"
    /// 闭锁阈值相对标定值的偏移（dB）。**必须大于 enterOffset**，差值就是迟滞带。
    public static let exitOffsetKey = "gkuiblekey.proximity.exitOffset"

    /// 允许范围：再小（阈值过高）会永远判不到靠近；再大（阈值过低）等于没判定。
    public static let offsetRange = 5...60
    /// 迟滞带最小宽度（dB）—— 低于这个值两个阈值会互相打架
    public static let minHysteresis = 3

    /// 解锁偏移的**有效**范围。
    ///
    /// UI 必须用它、而不是 `offsetRange`：enter 的上界要留出迟滞余量
    /// （`60 - 3 = 57`），否则用户能点到 58/59/60，但值会被 clamp 回去，
    /// Stepper 表现为"点了不动"。
    public static var enterRange: ClosedRange<Int> {
        offsetRange.lowerBound...(offsetRange.upperBound - minHysteresis)
    }

    /// 闭锁偏移的**有效**范围（下界要留出迟滞余量）
    public static var exitRange: ClosedRange<Int> {
        (offsetRange.lowerBound + minHysteresis)...offsetRange.upperBound
    }

    /// 在解锁阈值内侧持续多久才解锁。
    ///
    /// 2 秒的依据：走路从「刚进阈值」到「站到车边」通常 1.5–3 秒。
    /// 低于 1.5 秒会让「路过车尾」也触发；高于 3 秒则会让人觉得
    /// 「我明明站在这了怎么还不开」。
    public static let dwellToUnlock: TimeInterval = 2.0

    /// 解锁后的冷却（秒）—— 期间不再重复解锁
    public static let unlockCooldown: TimeInterval = 15
    /// 闭锁后的冷却（秒）—— 期间不再重复闭锁
    public static let lockCooldown: TimeInterval = 10

    /// 解锁偏移（dB）。由 `AppModel.applyProximityThresholds()` 从 UserDefaults 灌入。
    ///
    /// ★ 必须是 `@Published`：界面的 Stepper 直读这个值。之前它是普通 `var`，
    /// 改完只能靠 `measured.recordNote(...)` 顺带触发的 objectWillChange 刷新 ——
    /// 一旦把那行日志去掉，Stepper 就会"点了不动"。
    @Published public var enterOffset: Int = 18 {
        didSet { clampOffsets(changed: .enter) }
    }
    /// 闭锁偏移（dB）
    @Published public var exitOffset: Int = 28 {
        didSet { clampOffsets(changed: .exit) }
    }

    private enum ChangedOffset { case enter, exit }

    // MARK: - 内部

    private var insideSince: Date?
    private var lastUnlockAt: Date?
    private var lastLockAt: Date?

    public init() {}

    /// 开关是否打开（读 UserDefaults，界面的 Toggle 直接绑这个 key）
    public var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    // MARK: - 阈值

    /// 解锁阈值（dBm）。`combined > 此值` 才算「到车边」。
    public var unlockThreshold: Int? {
        guard let cal = calibration else { return nil }
        return cal - enterOffset
    }

    /// 闭锁阈值（dBm）。`combined < 此值` 才算「走远了」。
    public var lockThreshold: Int? {
        guard let cal = calibration else { return nil }
        return cal - exitOffset
    }

    /// 最近一次喂进来的标定值 / combined 值（界面显示用，避免再去问 `passiveStart`）
    @Published public private(set) var calibration: Int?
    @Published public private(set) var lastCombinedRSSI: Double = 0

    /// 迟滞带宽度（dB）
    public var hysteresis: Int { max(0, exitOffset - enterOffset) }

    /// 两个 offset 的约束：都在范围内，且 exit 至少比 enter 大 `minHysteresis`。
    ///
    /// 只在**调整某一个**时修正另一个 —— 不能两个都强行写回去，
    /// 否则用户把 enter 调到 40 时 exit 会被顶到 43，再调 exit 又把 enter 顶回来，
    /// 两端互相推。所以：改 enter 就只保证 exit 跟着上移；改 exit 同理。
    private func clampOffsets(changed: ChangedOffset) {
        let lo = Self.offsetRange.lowerBound
        let hi = Self.offsetRange.upperBound

        switch changed {
        case .enter:
            let e = min(max(enterOffset, lo), hi - Self.minHysteresis)
            if e != enterOffset { enterOffset = e; return }
            if exitOffset < e + Self.minHysteresis {
                exitOffset = min(e + Self.minHysteresis, hi)
            }
        case .exit:
            let x = min(max(exitOffset, lo + Self.minHysteresis), hi)
            if x != exitOffset { exitOffset = x; return }
            if enterOffset > x - Self.minHysteresis {
                enterOffset = max(x - Self.minHysteresis, lo)
            }
        }
    }

    // MARK: - 驱动

    /// 喂一帧 RSSI 合成值。
    ///
    /// - Parameters:
    ///   - combinedRSSI: `PassiveStartJudge.combinedRSSI`（两路合成后的 dB 值）
    ///   - calibration: 车内标定值。**`nil`（未标定）时一律不动作** ——
    ///     没有基准就没有阈值，任何判定都是瞎猜。
    /// - Returns: 需要执行的动作，没有则 `nil`
    @discardableResult
    public func update(combinedRSSI: Double,
                       calibration: Int?,
                       now: Date = Date()) -> Action? {
        // 这两个只影响界面显示，但都是 `@Published`。
        // 每次回调无条件赋值 = 每 0.4 秒两次 publish → AppModel 转发 →
        // 整个 App 重绘。所以：值没变/变化小于 1 dB 就不写。
        if self.calibration != calibration {
            self.calibration = calibration
        }
        if abs(combinedRSSI - lastCombinedRSSI) >= 1 {
            lastCombinedRSSI = combinedRSSI
        }

        guard isEnabled, let cal = calibration else {
            // 关掉开关 / 未标定 → 状态清零，避免重新打开时带着上次的 inside
            insideSince = nil
            dwellProgress = 0
            if phase != .far {
                phase = .far
            }
            return nil
        }

        let unlockAt = Double(cal - enterOffset)
        let lockAt = Double(cal - exitOffset)

        // ── 迟滞判定：只有明确跨过某一侧才算数，中间带保持原状 ──
        if combinedRSSI > unlockAt {
            // ① 解锁阈值内侧
            if insideSince == nil { insideSince = now }
            let dwell = now.timeIntervalSince(insideSince ?? now)
            setDwell(min(dwell, Self.dwellToUnlock))

            guard phase != .inside else { return nil }
            guard dwell >= Self.dwellToUnlock else { return nil }
            if let last = lastUnlockAt,
               now.timeIntervalSince(last) < Self.unlockCooldown { return nil }

            phase = .inside
            lastAction = .unlock
            lastActionAt = now
            lastUnlockAt = now
            // ★ 清掉停留计时：解锁后 `phase == .inside` 已经表达了状态，
            //   若留着 `insideSince`，走进迟滞带时 `summary` 会显示
            //   「靠近中 2.0/2.0 秒」并卡住（min 封顶），看起来像卡死。
            insideSince = nil
            dwellProgress = 0
            return .unlock
        }

        // ② 闭锁阈值外侧 —— 走远了
        if combinedRSSI < lockAt {
            insideSince = nil
            dwellProgress = 0
            guard phase == .inside else {
                // 已经在远处（或从未靠近），只更新阶段显示
                if phase != .far { phase = .far }
                return nil
            }
            if let last = lastLockAt,
               now.timeIntervalSince(last) < Self.lockCooldown { return nil }

            phase = .far
            lastAction = .lock
            lastActionAt = now
            lastLockAt = now
            return .lock
        }

        // ③ 迟滞带内：什么都不做。
        //
        // 注意这里**不重置** `insideSince` —— 人站在门边，RSSI 在
        // 解锁阈值附近抖进抖出是常态。若在带内清零，2 秒停留永远攒不满，
        // 表现就是「站在车边一直不解锁」。带内不动作、但计时继续，
        // 只有真的跌破闭锁阈值才清零（上面那一支）。
        if phase != .inside, phase != .boundary {
            phase = .boundary
        }
        if insideSince != nil {
            setDwell(min(now.timeIntervalSince(insideSince ?? now), Self.dwellToUnlock))
        }
        return nil
    }

    /// 广播静默 —— **人走远了**（或车休眠了）。
    ///
    /// ## 为什么必须有这个入口（2026-11-09 真机反馈「进电梯了没锁车」）
    ///
    /// `update(combinedRSSI:)` 只在**收到新 RSSI 时**被调用。
    /// 人走进电梯、信号突然消失时，根本没有"最后一帧"可用 ——
    /// controller 会一直停在 `.inside`，自动闭锁永远触发不了。
    /// `purgeStaleRSSI()` 清掉过期 RSSI 也只是让它"没有新输入"，不是"输入为零"。
    ///
    /// 信号消失等价于「RSSI 掉到听不见」，所以走的是闭锁那一支；
    /// 但**不动 `lastCombinedRSSI`** —— 界面上不该突然出现一个 -127 dBm 的读数。
    ///
    /// - Note: 调用方拿到 `.lock` 后要自己决定走哪条通道发命令。
    ///   这条路径通常发生在**蓝牙已经断了**之后，所以多半只能走云端。
    public func signalLost(now: Date = Date()) -> Action? {
        guard isEnabled, calibration != nil else { return nil }

        insideSince = nil
        dwellProgress = 0

        guard phase == .inside else {
            // 本来就在远处（或从未靠近）→ 只把阶段归位，不产生动作
            if phase != .far { phase = .far }
            return nil
        }

        // 刚刚锁过就别再锁 —— 和 `update` 里那一支用同一个冷却
        if let last = lastLockAt, now.timeIntervalSince(last) < Self.lockCooldown {
            return nil
        }

        phase = .far
        lastAction = .lock
        lastActionAt = now
        lastLockAt = now
        return .lock
    }

    /// 只在变化 ≥ 0.05 秒时写 `dwellProgress`（它是 `@Published`）。
    ///
    /// 攒满 2 秒期间会回调 5 次左右，每次都写就是 5 次全 App 重绘；
    /// 攒满之后 `min()` 恒等于 2.0，仍会无条件赋值 —— 那才是真正的浪费。
    private func setDwell(_ value: TimeInterval) {
        guard abs(value - dwellProgress) >= 0.05 else { return }
        dwellProgress = value
    }

    /// 关掉开关 / 解绑时重置
    public func reset() {
        phase = .far
        insideSince = nil
        dwellProgress = 0
        // 保留 lastAction / lastActionAt，方便事后回查刚才是谁触发的
    }

    /// 界面用的一句话
    public var summary: String {
        guard isEnabled else { return "未开启" }
        guard calibration != nil else { return "未标定" }

        if phase == .inside { return "车边 · 已解锁" }
        // 已进入解锁阈值内侧、正在攒 2 秒停留 —— 这个优先级要高于「迟滞带」，
        // 否则人已经站到车边了，界面还写「迟滞带内 · 不动作」。
        if insideSince != nil {
            return String(format: "靠近中 %.1f/%.0f 秒",
                          dwellProgress, Self.dwellToUnlock)
        }
        return phase == .boundary ? "迟滞带内 · 不动作" : "远处"
    }
}
