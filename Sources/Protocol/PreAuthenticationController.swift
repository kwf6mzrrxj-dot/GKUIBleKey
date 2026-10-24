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

    /// 预认证成功后到下一次的间隔 —— `0xb7d8: fmov d0, #6.5`
    public static let successInterval: TimeInterval = 6.5
    /// 预认证失败后到下一次的间隔 —— `0xb7e0: fmov d0, #29.0`
    public static let failureInterval: TimeInterval = 29.0
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

    public func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { onLog?("预认证已开启（进入区域后每隔 6.5s/29s 发 0x0C）") }
        else { stop() }
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
        onLog?("start sending passive start commands")
        launchEntryCommands()
    }

    // MARK: - ③ launchPassiveEntryCommands

    private func launchEntryCommands() {
        guard isEnabled, didStart else { return }
        cancelPending()
        // `0xb584` 断开立即发；`0xb590` 已连接延迟 1 秒
        schedule(after: Self.connectedDelay) { [weak self] in
            guard let self, self.didStart else { return }
            self.sentCount += 1
            self.onLog?("send prehauthentication command（0x0C，#\(self.sentCount)）")
            self.onSend?()
        }
    }

    // MARK: - ⑤ didPassiveStartCompletedWithError:

    /// 一次预认证往返结束时调用。`success == false` 用 29.0 秒，
    /// 成功用 6.5 秒 —— 与 `0xb7d8` / `0xb7e0` 一致。
    public func didComplete(success: Bool) {
        guard isEnabled, didStart else { return }
        timeBetweenPassiveStart = success ? Self.successInterval : Self.failureInterval
        cancelPending()
        onLog?(String(format: "预认证%@，%.1f 秒后重试",
                      success ? "成功" : "失败", timeBetweenPassiveStart))
        schedule(after: timeBetweenPassiveStart) { [weak self] in
            self?.launchEntryCommands()
        }
    }

    // MARK: - ⑥ stopPreAuthentication

    public func stop() {
        guard didStart else { return }
        didStart = false
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
        cancelPending()
    }

    // MARK: - 定时器

    private func schedule(after delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        cancelPending()
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            body()
        }
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
    }
}
