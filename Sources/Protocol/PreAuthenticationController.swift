import Foundation
import Combine

/// **预认证（`prehauthentication`）保活** —— 逐行照 `IBVehicle` 反汇编还原。
///
/// ## 这不是"自动解锁"
///
/// 原 App 在被动进入流程里**只做一件事**：周期性发预认证命令 `0x0C`。
/// 真正的开锁由车端 PEPS 在预认证有效期内完成，App 不发送 `unlock`。
///
/// 证据链（全部为 `InBlue.framework` 内指令）：
///
/// ### ① 进入区域 → 启动预认证
/// `-[IBVehicle checkRssiForPassiveStart]` @`0xac04`：
/// ```asm
/// 0xb21c: ldr  x1, #0x27658   ; @selector(setIsInPassiveStartArea:)
/// 0xb220: mov  w2, #0         ;   inArea == NO  → 置 0
/// ...
/// 0xb278: ldr  x1, #0x276b8   ; @selector(launchPrehautentification)
/// 0xb284: ldr  x1, #0x27650   ; @selector(stopPreAuthentication)
/// 0xb304: ldr  x1, #0x27658   ; @selector(setIsInPassiveStartArea:)
/// 0xb308: mov  w2, #1         ;   inArea == YES → 置 1
/// ```
///
/// ### ② 启动预认证（带防重入）
/// `-[IBVehicle launchPrehautentification]` @`0xb32c`：
/// ```asm
/// 0xb348: ldr  x1, #0x276c0   ; @selector(didStartSendPassiveStartCommand)
/// 0xb350: tbz  w0, #0, ...    ; 已启动 → 直接 return（防重入）
/// ...
/// 0xb3ec: adr  x2, #0x20ac8   ; CFSTR "start sending passive start commands"
/// 0xb408: mov  w2, #1         ; setDidStartSendPassiveStartCommand:YES
/// 0xb418: bl   cancelPreviousPassiveStartCommands
/// 0xb428: bl   launchPassiveEntryCommands
/// ```
///
/// ### ③ 发起连接（延迟 1 秒）
/// `-[IBVehicle launchPassiveEntryCommands]` @`0xb54c`：
/// ```asm
/// 0xb560: ldr  x1, #0x273a0   ; @selector(isDisconnected)
/// 0xb570: tbz  w0, #0, ...    ; 已连接则走延迟分支
/// 0xb584: b    _objc_msgSend  ; 断开时立即 openConnectionWithPassiveStart
/// 0xb58c: ldr  x1, #0x27620   ; @selector(performSelector:withObject:afterDelay:)
/// 0xb590: fmov d0, #1.00000000; 已连接 → 延迟 1 秒
/// ```
///
/// ### ④ 真正发出的命令是 `0x0C`
/// `-[IBVehicle openConnectionWithPassiveStart]` @`0xb5a8`：
/// ```asm
/// 0xb610: adr  x2, #0x20b08   ; CFSTR "send prehauthentification command to cidpu : %@"
/// 0xb680: ldr  x1, #0x27358   ; @selector(openConnexionForCommand:)
/// 0xb684: mov  w2, #0xc       ; ★ 预认证控制码
/// ```
///
/// ### ⑤ 下一次的间隔：成功 6.5 秒 / 失败 29.0 秒
/// `-[IBVehicle didPassiveStartCompletedWithError:]` @`0xb6cc`：
/// ```asm
/// 0xb7d0: ldr  x1, #0x276e0   ; @selector(setTimeBetweenPassiveStart:)
/// 0xb7d4: cbz  x20, #0xb7e0   ; error == nil ?
/// 0xb7d8: fmov d0, #6.50000000;  成功 → 6.5s
/// 0xb7e0: fmov d0, #29.00000000; 失败 → 29.0s
/// 0xb7f0: bl   cancelPreviousPassiveStartCommands
/// 0xb800: ldr  x2, #0x276d0   ; @selector(launchPassiveEntryCommands)
/// 0xb80c: ldr  d0, [x19, _timeBetweenPassiveStart]
/// 0xb814: bl   performSelector:withObject:afterDelay:
/// ```
///
/// ### ⑥ 停止
/// `-[IBVehicle stopPreAuthentication]` @`0xb444`：
/// ```asm
/// 0xb460: ldr  x1, #0x276c0   ; didStartSendPassiveStartCommand
/// 0xb468: cbz  w0, #0xb538    ; 未启动 → return
/// 0xb47c: adr  x2, #0x20ae8   ; CFSTR "stop sending passive start commands"
/// 0xb50c: mov  w2, #0         ; setDidStartSendPassiveStartCommand:NO
/// 0xb51c: bl   cancelPreviousPassiveStartCommands
/// ```
///
/// ## 抓包交叉验证
///
/// `btsnoop_ctl_20261004_210011.log` 里静止状态下 `0x0C` 每 **28 秒**一次，
/// 共 51 次；`0x01`/`0x02` 各 1 次。
/// 28 秒 ≈ 反汇编里的 **29.0 秒**（失败路径）减去定时器启动与执行开销，
/// 两者一致 —— 说明当时预认证一直没成功（车端未响应预认证）。
@MainActor
public final class PreAuthenticationController: ObservableObject {

    // MARK: - 常量（地址见类型注释）

    /// 一次预认证往返结束后的重试间隔。
    ///
    /// 取 **29.0 秒**，不是反汇编里的 `6.5`——
    /// 原因见 `didComplete()` 的完整说明：`0xb7d4: cbz x20` 判的是
    /// **self 是否为 nil**（不是 error），`6.5` 是固定值；而日志里 339 次
    /// `0x01` 的间隔主导值是 **30 秒**（29 秒等待 + 约 1 秒执行）。
    ///
    /// 若按 6.5 秒跑会快 4.5 倍，且会撞上车端「7 秒内不接受第二次加密重连」。
    public static let retryInterval: TimeInterval = 29.0

    /// 反汇编 `0xb7d8` 的立即数，**仅作记录，不参与调度**
    /// （`setTimeBetweenPassiveStart:6.5`，实际节奏被 RSSI 窗口拉到 30 秒）
    public static let disassemblyInterval: TimeInterval = 6.5

    /// 已连接时再发起连接的延迟 —— `0xb590: fmov d0, #1.0`
    public static let connectedDelay: TimeInterval = 1.0

    // MARK: - 状态（对应 IBVehicle 的 ivar）

    /// 对应 `_didStartSendPassiveStartCommand`
    @Published public private(set) var didStart = false
    /// 对应 `_isInPassiveStartArea`
    @Published public private(set) var isInArea = false
    /// 对应 `_timeBetweenPassiveStart`（初始 0）
    @Published public private(set) var timeBetweenPassiveStart: TimeInterval = 0
    /// 是否启用（本地开关，原 App 无此字段；默认关闭以免后台发帧）
    @Published public private(set) var isEnabled = false
    /// 已发出的预认证次数
    @Published public private(set) var sentCount = 0

    // MARK: - 回调

    /// 到点发 `0x0C`
    public var onSend: (() -> Void)?
    public var onLog: ((String) -> Void)?

    // MARK: - 内部

    private var pendingTask: Task<Void, Never>?
    private static let enabledKey = "gkuiblekey.preAuth.enabled"

    public init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// 用户是否**显式**动过这个开关。
    ///
    /// 用途：原 App 配对成功后心跳就是常开的（26 天日志里 69 次 `0x0C` 没有断过），
    /// 而我们这个开关默认 `false`、又没有 UI 引导，等于「配对完了但不保活」。
    /// 但也不能每次启动都强行打开 —— 那会把用户主动关掉的选择覆盖掉。
    /// 所以只在 `UserDefaults` 里**没有这个键**时自动开启（`hasExplicitPreference == false`）。
    public var hasExplicitPreference: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) != nil
    }

    public func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            onLog?("预认证已开启（进入区域后每约 30 秒发一次 0x0C）")
            // ★ 人已经在区域内 → 立刻启动一轮（2026-10-29）
            //
            // 否则 `updateArea(true)` 会因 `inArea == isInArea` 直接 return，
            // 用户必须走出区域再走回来才会触发 —— 表现为「开关打开了但一点动静没有」。
            // 之前靠「断连时 resetEdge 清 isInArea」歪打正着掩盖了这个问题，
            // 那个 resetEdge 已经因为把节奏压成 5 秒一轮而被移除。
            if isInArea { launchPreAuthentication() }
        } else {
            stop()
        }
    }

    /// 解绑专用：关掉心跳，并**清掉「用户显式设置过」的痕迹**。
    ///
    /// 为什么不能只调 `setEnabled(false)`：那会把 `enabledKey` 写成 `false`，
    /// 于是 `hasExplicitPreference == true` —— 重新配对后**再也不会自动开启**，
    /// 又回到「配好了但从不保活」的老问题。
    ///
    /// 解绑意味着这辆车的所有状态都该归零（标定、无感、密钥都清了），
    /// 预认证的偏好也不例外。想关掉心跳的用户会在开关上再关一次。
    public func resetForUnbind() {
        stop()
        isEnabled = false
        retryIntervalOverride = nil
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
    }

    // MARK: - ① 区域判定（checkRssiForPassiveStart: 的两条分支）

    public func updateArea(_ inArea: Bool) {
        guard isEnabled else { return }
        guard inArea != isInArea else { return }
        isInArea = inArea
        if inArea {
            onLog?("进入被动启动区域 → launchPrehautentification")
            launchPreAuthentication()
        } else {
            onLog?("离开被动启动区域 → stopPreAuthentication")
            stop()
        }
    }

    // MARK: - ② launchPrehautentification

    public func launchPreAuthentication() {
        guard isEnabled else { return }
        // `0xb350: tbz w0, #0` —— 已启动直接返回
        guard !didStart else { return }
        didStart = true
        didStartAt = Date()
        onLog?("start sending passive start commands")
        launchEntryCommands()
    }

    // MARK: - ③ launchPassiveEntryCommands

    /// 上一次真正把 `0x0C` 交出去的时刻（事件驱动补发的判据，同时供锁屏卡片显示）
    public private(set) var lastSentAt: Date?
    /// `didStart` 置真的时刻 —— 用于「首帧还没交出去就被挂起」的补救
    private var didStartAt: Date?
    /// 正在排/发（防止广播高频触发反复 cancel 定时器）
    private var isSending = false

    private func launchEntryCommands() {
        guard isEnabled, didStart else { return }
        cancelPending()
        isSending = true
        // `0xb584` 断开立即发；`0xb590` 已连接延迟 1 秒
        schedule(after: Self.connectedDelay) { [weak self] in
            guard let self, self.didStart else {
                self?.isSending = false
                return
            }
            self.sentCount += 1
            self.lastSentAt = Date()
            self.onLog?("send prehauthentication command（0x0C，#\(self.sentCount)）")
            self.onSend?()
            self.isSending = false
        }
    }

    /// **事件驱动补发** —— 每收到一帧广播就调一次。
    ///
    /// ## 为什么不能只靠定时器（2026-10-29，关键教训）
    ///
    /// 原厂 App 在 **iOS 26 上能稳定点火，在 iOS 27 上同样"抽奖"**
    /// （用户实测）。同一个 App、同一辆车，差别只在系统版本 ——
    /// 说明 iOS 27 把后台的 BLE 唤醒压得更狠，**`Task.sleep` 在后台基本不推进**。
    ///
    /// 定时器不可靠，但**广播还会来**（`bluetooth-central` 后台模式保证
    /// 收到广播会唤醒 App 一小段时间）。所以把「该不该发」从"等时间到"
    /// 改成"有广播就看一眼"：
    ///
    /// - 前台：广播 0.5 秒一帧，补发精度 ≈ 0.5 秒
    /// - 后台：广播可能 10 秒一帧，最坏晚 10 秒补发 —— 仍在车端有效期内
    ///
    /// 定时器保留作兜底（前台精确、后台失效都不影响结果）。
    public func tickIfNeeded() {
        guard isEnabled, isInArea, didStart else { return }
        guard !isSending else { return }
        guard let last = lastSentAt else {
            // ★ 首帧补救（2026-10-29，后台保活）。
            //
            // `lastSentAt` 为 nil 说明**一次都没交出去过**。最常见的原因是：
            // `launchPreAuthentication` 刚把 `didStart` 置真、进入
            // `schedule(1.0)` 的 1 秒延迟，App 就被系统挂起了 ——
            // `Task.sleep` 不推进，这一帧永远发不出去。
            //
            // 而原来的写法在这里直接 `return`，于是后台**永远不补发**，
            // 表现为「后台一帧都没发，回前台才突然好了」。
            // 现在只要「启动后超过 1 秒延迟 + 1 秒余量」就主动补一发。
            if let startedAt = didStartAt,
               Date().timeIntervalSince(startedAt) >= Self.connectedDelay + 1.0 {
                onLog?("广播唤醒：首帧 0x0C 从未发出（启动被挂起）→ 立即补发")
                launchEntryCommands()
            }
            return
        }
        let elapsed = Date().timeIntervalSince(last)
        // ★ 用 `effectiveRetryInterval` 而不是写死的 29 秒（2026-10-30 审查）。
        //   广播驱动补发和 `didComplete` 的定时器必须用**同一个**判据：
        //   点火窗口把间隔压到 10 秒，若这里还按 29 秒判，
        //   窗口内一旦定时器没推进（后台），补发就会迟到 19 秒 ——
        //   用户按启动按钮时车端早已忘了钥匙。
        guard elapsed >= effectiveRetryInterval else { return }
        onLog?(String(format: "广播唤醒：距上次 0x0C 已 %.0f 秒（定时器未推进）→ 提前补发", elapsed))
        launchEntryCommands()
    }

    /// App 被系统挂起/终止后重新活跃时调用：把中断的预认证**立刻续上**。
    ///
    /// ## 为什么必须有这个
    ///
    /// 预认证是「车端认为钥匙在场」的唯一来源，而它的节奏靠 29 秒的
    /// `Task.sleep`。iOS 在后台会把进程挂起（日志实证：心跳间隔 3 分 46 秒、
    /// 进程被系统终止 13 分钟），**挂起期间这个定时器不推进**。
    ///
    /// 更麻烦的是 v5.4 之后：断连不再清 `isInArea`，所以从后台回来时
    /// `isInArea` 仍是 `true` → `updateArea(true)` 会因 `inArea == isInArea`
    /// 直接 return → **再也不会重新启动**，用户看到的就是「无感进入不可用」。
    ///
    /// 这里做一次显式补偿：只要有「已启用 + 在区域内 + 没在跑」这三个条件，
    /// 就立刻启动一轮，不等下一个区域边沿。
    public func resumeAfterSuspendIfNeeded() {
        guard isEnabled else { return }
        guard isInArea else { return }
        guard !didStart else { return }
        onLog?("恢复到前台：预认证曾因挂起中断 → 立即续上")
        launchPreAuthentication()
    }

    // MARK: - ⑤ didPassiveStartCompletedWithError:

    /// 覆盖间隔上限 —— 用于「点火窗口」（窗口内强制更快）。
    ///
    /// 只作为**上限**参与 `min`：`didComplete` 算出的原厂间隔如果本来就更快，
    /// 不会被它拖慢。窗口结束置回 `nil`。
    public var retryIntervalOverride: TimeInterval?

    /// 实际生效的重试间隔（窗口内取更快的那个）
    public var effectiveRetryInterval: TimeInterval {
        let base = Self.retryInterval
        guard let o = retryIntervalOverride else { return base }
        return min(base, o)
    }

    /// **失败**后的快速重试间隔 —— 反汇编 `0xb7d8: fmov d0, #6.50000000`
    ///
    /// 抓包实证（`btsnoop_ign`）：20:49:47 那轮虽然收到 `04 00`，但车端随即断开，
    /// App 侧按「有 error」处理 → **6.2 秒后就发了下一轮**。
    public static let failureRetryInterval: TimeInterval = 6.5

    /// 一次预认证往返结束后的重试间隔。
    ///
    /// ## 反汇编：成功慢、失败快（2026-10-31 纠正，之前的注释读反了）
    ///
    /// `-[IBVehicle didPassiveStartCompletedWithError:]` @`0xb6cc`：
    ///
    /// ```asm
    /// 0xb6e8: mov  x23, x2        ; x23 = 第 3 参数
    /// 0xb708: mov  x0, x2
    /// 0xb70c: bl   _objc_retain
    /// 0xb710: mov  x20, x0        ; ★ x20 = retain(第3参数) = error
    /// ...
    /// 0xb7d0: ldr  x1, @selector(setTimeBetweenPassiveStart:)
    /// 0xb7d4: cbz  x20, #0xb7e0   ; ★ error == nil → 跳 0xb7e0
    /// 0xb7d8: fmov d0, #6.5       ; error != nil（失败）→ 6.5
    /// 0xb7dc: b    #0xb7e4
    /// 0xb7e0: fmov d0, #29.0      ; error == nil（成功）→ 29
    /// ```
    ///
    /// **`x20` 是 `error` 而不是 `self`** —— `didPassiveStartCompletedWithError:`
    /// 只有一个显式参数，按 arm64 调用约定就在 `x2`。旧注释误判成 weak-self 判空，
    /// 于是得出「6.5 是固定值、29 走不到」，把语义**整个读反了**。
    ///
    /// 正确语义：**成功 → 29 秒（省电）；失败 → 6.5 秒（快速重试抢回来）**。
    ///
    /// 这也解释了「7 秒内不接受第二次加密重连」那条约束是**失败重连**的产物：
    /// 原厂失败后用 6.5 秒重试，本身就在这条边界上跳舞，但它是**授权**的路径。
    /// ```
    ///
    /// `cbz x20` 判的是 **self 是否为 nil**（编译器为 weak self 生成的判空），
    /// **不是 error**。也就是说 `6.5` 是固定值，`29.0` 走不到。
    ///
    /// （此前把它读成「成功 6.5 / 失败 29.0」是误读，已纠正。）
    ///
    /// ## 但日志实测的节奏是 **30 秒**
    ///
    /// 339 次 `0x01` 的间隔分布（`Docs/evidence/xiaoka_vcc.log`）：
    ///
    /// ```text
    /// 29.9s ×110   30.0s ×99   30.1s ×36   30.2s ×17   30.3s ×6 …
    /// 6.4–7.1s 合计只有 ~6 次
    /// ```
    ///
    /// 说明 6.5 秒之后还有别的门槛（RSSI 滑窗满 10 个值 / 区域判定）
    /// 把实际节奏拉到了 30 秒。我们没实现那套前置条件，
    /// **若按 6.5 秒重试会比原 App 快 4.5 倍** —— 而车端在 7 秒内
    /// 不接受第二次加密重连（2026-10-29 06:14:38 成功、06:14:45 加密超时）。
    ///
    /// 所以这里统一用 **29 秒**：29 秒等待 + 约 1 秒连接/鉴权执行 ≈ 实测的 30 秒。
    public func didComplete(success: Bool = true) {
        guard isEnabled, didStart else { return }
        // ★ 反汇编 0xb7d4 的真实语义：error == nil（成功）→ 29 秒；
        //   error != nil（失败）→ 6.5 秒。**成功慢、失败快**。
        let base = success ? Self.retryInterval : Self.failureRetryInterval
        // 点火窗口只作为「上限」参与 min —— 窗口内即使成功也压到 6.5，
        // 但不允许把原厂更快的失败重试（6.5）拖慢。
        timeBetweenPassiveStart = retryIntervalOverride.map { min(base, $0) } ?? base
        cancelPending()
        onLog?(String(format: "预认证往返结束（%@），%.1f 秒后重试",
                      success ? "成功" : "失败", timeBetweenPassiveStart))
        schedule(after: timeBetweenPassiveStart) { [weak self] in
            self?.launchEntryCommands()
        }
    }

    // MARK: - ⑥ stopPreAuthentication

    public func stop() {
        guard didStart else { return }
        didStart = false
        didStartAt = nil
        cancelPending()
        onLog?("stop sending passive start commands")
    }

    /// 断连/重连后复位。
    ///
    /// 链路断了以后 `isInArea` 必须清掉：否则重连时若仍处于"区域内"，
    /// `updateArea(true)` 会因为 `inArea == isInArea` 直接 return，
    /// 预认证就再也不启动了。
    public func resetEdge() {
        isInArea = false
        if didStart { stop() }
        didStart = false
        didStartAt = nil
        cancelPending()
    }

    // MARK: - 定时器

    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        cancelPending()
        let plannedAt = Date()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // ★ 后台保活的关键证据：**计划延迟 vs 实际延迟**。
            //
            // `Task.sleep` 在 App 被挂起时不会按时唤醒，进程恢复后才补执行。
            // 所以只要这里出现「计划 29s / 实际 300s」的偏差，就证明
            // 那段时间进程是被挂起的 —— 这是无法从其它 API 直接读到的信息。
            let actual = Date().timeIntervalSince(plannedAt)
            let drift = actual - delay
            if drift > 2 {
                FileLogger.shared.warning(
                    "[保活] 预认证定时器被延迟：计划 \(String(format: "%.0f", delay))s，"
                    + "实际 \(String(format: "%.1f", actual))s（偏差 \(String(format: "%+.1f", drift))s）"
                    + "—— 进程在这段时间被挂起过",
                    module: "保活")
            } else {
                FileLogger.shared.info(
                    "[保活] 预认证定时器准时：计划 \(String(format: "%.0f", delay))s，"
                    + "实际 \(String(format: "%.1f", actual))s",
                    module: "保活")
            }
            body()
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}
