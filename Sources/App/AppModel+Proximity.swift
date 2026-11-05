import Foundation

/// **靠近解锁 / 点火位置验证**的阈值与标定
/// （2026-11-05 第三轮审查从 `AppModel` 拆出）。
///
/// 为什么单独一个文件：这 200 行只服务两个功能（阈值可调 + 90 帧标定），
/// 混在 3000 行的 `AppModel` 里既难找，改动时也很难判断影响面。
///
/// 注意：`lastAreaCheckAt` / `rssiAntennaOne` / `rssiAntennaTwo` /
/// `lastSingleAntennaWarnAt` 是**存储属性**，不能写在扩展里，
/// 仍留在 `AppModel` 定义中（已改为 internal，供本文件使用）。
extension AppModel {

    // MARK: - 阈值（可调）

    /// 把存下来的阈值应用到两个判定器上。
    ///
    /// ## 为什么要拆成两套（2026-11-05 第二轮）
    ///
    /// 第一轮图省事，靠近解锁直接复用了「点火位置验证」的 `isInPassiveStartArea`。
    /// 但那两个功能要的位置**不是同一个**：
    ///
    /// | | 判定式 | 想要的边界 |
    /// |---|---|---|
    /// | 点火位置验证 | `combined > calibration - leaveOffset` | 车内 / 车外（宽的圈） |
    /// | 靠近解锁 | `combined > calibration - enterOffset` | 车边 1–2 米（窄的圈） |
    ///
    /// 共用一个 `leaveOffset` 时，调宽了自动解锁会在车外几米就开门，
    /// 调窄了又会让点火验证判不到「车内」—— 两个功能互相绑架。
    /// 现在标定值（calibration）仍然共用（它就是车内的基准），
    /// 但**偏移量各管各的**。
    ///
    /// 范围：点火验证 15…50（原厂值 32 在中间）；
    /// 靠近解锁 5…60，且要求 `exitOffset ≥ enterOffset + 3` 才有迟滞。
    public func applyProximityThresholds() {
        let d = UserDefaults.standard

        // 点火位置验证（PassiveStartJudge，照反汇编参数）
        let leave = (d.object(forKey: Self.leaveOffsetKey) as? Int) ?? 32
        passiveStart.leaveOffset = min(max(leave, 15), 50)

        // 靠近解锁（ProximityUnlockController，独立双阈值）
        let enter = (d.object(forKey: Self.enterOffsetKey) as? Int) ?? 18
        let exit = (d.object(forKey: Self.exitOffsetKey) as? Int) ?? 28
        let range = ProximityUnlockController.offsetRange
        let e = min(max(enter, range.lowerBound), range.upperBound)
        let x = min(max(exit, range.lowerBound), range.upperBound)
        // 顺序很重要：先进后出，didSet 里的 clamp 会把非法组合拉回来
        proximityUnlock.enterOffset = e
        proximityUnlock.exitOffset = x
    }

    /// 调整**点火位置验证**的离开偏移（改完立刻生效，并写盘）
    public func setProximityLeaveOffset(_ value: Int) {
        let v = min(max(value, 15), 50)
        UserDefaults.standard.set(v, forKey: Self.leaveOffsetKey)
        applyProximityThresholds()
        measured.recordNote("点火位置验证：判定阈值改为 \(passiveStart.threshold) dBm（offset=\(v)）")
    }

    /// 调整**靠近解锁**的解锁偏移（越小 → 阈值越高 → 要求越近）
    public func setProximityEnterOffset(_ value: Int) {
        let v = min(max(value, ProximityUnlockController.offsetRange.lowerBound),
                    ProximityUnlockController.offsetRange.upperBound)
        UserDefaults.standard.set(v, forKey: Self.enterOffsetKey)
        applyProximityThresholds()
        if let t = proximityUnlock.unlockThreshold {
            measured.recordNote("靠近解锁：解锁阈值改为 \(t) dBm（offset=\(v)，迟滞 \(proximityUnlock.hysteresis) dB）")
        }
    }

    /// 调整**靠近解锁**的闭锁偏移（越大 → 阈值越低 → 走更远才闭锁）
    public func setProximityExitOffset(_ value: Int) {
        let v = min(max(value, ProximityUnlockController.offsetRange.lowerBound),
                    ProximityUnlockController.offsetRange.upperBound)
        UserDefaults.standard.set(v, forKey: Self.exitOffsetKey)
        applyProximityThresholds()
        if let t = proximityUnlock.lockThreshold {
            measured.recordNote("靠近解锁：闭锁阈值改为 \(t) dBm（offset=\(v)，迟滞 \(proximityUnlock.hysteresis) dB）")
        }
    }

    /// 读取车端标定值 —— 照 `-[IBVehicle getCalibrationSavedValues]` @`0xb83c`。
    ///
    /// ```asm
    /// 0xb864: [NSUserDefaults standardUserDefaults]
    /// 0xb8c0: adr x2, #0x20a48 ; CFSTR "%@_CALIBRATION"
    /// 0xb8ec: objectForKey:
    /// 0xb90c: setCalibration:
    /// ```
    /// 写入点在 `-[IBVehicle didCalibrationCompleted:error:]` @`0xa41c`。
    ///
    /// 未标定时 `calibration = nil`，判定时按 `0` 处理
    /// （与原 App 的 `[nil intValue]` 等价）。
    public func loadCalibration() {
        guard let cidpu = KeyStore.shared.cidpuFullHex, !cidpu.isEmpty else {
            passiveStart.calibration = nil
            return
        }
        let key = "\(cidpu)_CALIBRATION"
        if let n = UserDefaults.standard.object(forKey: key) as? NSNumber {
            passiveStart.calibration = n.intValue
            measured.recordNote("已读取标定值 calibration=\(n.intValue)（key=\(key)）")
        } else {
            passiveStart.calibration = nil
        }
    }

    // MARK: - ★ 标定流程（照 VCBDevice startCalibration / calibrationWithRSSIOne:RSSITwo:）

    /// 分路 RSSI 处理 —— 对应 `addRSSI:` @`0x801c`。
    ///
    /// 广播回调时，按 antenna 高 4 位（0x80=天线1/0x40=天线2）把本次 RSSI
    /// 分路存进 `rssiAntennaOne` / `rssiAntennaTwo`；标定进行中时，两路都齐
    /// 就合成一次采样喂给 `passiveStart.addCalibrationSample`。
    ///
    /// ## 单路降级（2026-11-05 第三轮审查）
    ///
    /// 原来这里 `guard let one = ..., let two = ... else { return }` —— 只要有一路
    /// 没收到，判定就整段跳过。但"没收到"的现实原因很多：手机方向导致某一天线
    /// 低于灵敏度、车端某帧只带一路、BLE 丢包。结果是**靠近解锁静默失效**，
    /// 用户只会觉得"这功能不好使"，日志里一条线索都没有。
    ///
    /// 现在：只要有一路就判定，缺失的那路用同一值补（等价于单路 +3 dB 的合成，
    /// 与原厂两路合成的偏差 ≤3 dB）。**标定仍然要求两路** —— 标定值要当基准，
    /// 不能用降级数据，否则阈值会系统性偏移。
    ///
    /// `internal` 而非 `private`：`AppModel.init` 里把它挂到 `ble.onDualRSSI` 回调上，
    /// 跨文件访问。
    func handleDualRSSI(antenna: Int, rssi: Int) {
        let v = Double(rssi)
        switch antenna {
        case 1: rssiAntennaOne = v
        case 2: rssiAntennaTwo = v
        default: return
        }
        guard let anyOne = rssiAntennaOne ?? rssiAntennaTwo else { return }

        let one = rssiAntennaOne ?? anyOne
        let two = rssiAntennaTwo ?? anyOne
        let dualAvailable = (rssiAntennaOne != nil && rssiAntennaTwo != nil)

        // 标定进行中 → 按帧采样（这一支优先级最高，标定期间不做区域判定）
        if passiveStart.isCalibrating {
            // 标定必须双路：单路数据会把基准拉低 3 dB，之后双路判定就系统性偏严。
            guard dualAvailable else {
                // 每帧都提示会刷屏，10 秒一次足够说明问题
                let now = Date()
                if lastSingleAntennaWarnAt.map({ now.timeIntervalSince($0) > 10 }) ?? true {
                    lastSingleAntennaWarnAt = now
                    measured.recordNote("标定采样跳过：当前只有一路天线数据（需要两路都收到）")
                }
                return
            }
            if let avg = passiveStart.addCalibrationSample(rssiOne: one, rssiTwo: two) {
                finishCalibration(value: avg)
            }
            return
        }

        // ★ 正常运行时也判定（2026-11-05）。
        //
        // 原来这里 `guard passiveStart.isCalibrating` 直接 return —— 也就是
        // `check()` 从来没被调用过，判定逻辑是死的。
        //
        // 节流 0.4 秒：一帧广播会分别回调 antenna 1 / 2 各一次，
        // 不节流的话样本会翻倍，`combinedRSSI` 的「平均间隔」也会算错
        // （它靠间隔决定"取最新"还是"取均值"）。
        let now = Date()
        if let last = lastAreaCheckAt, now.timeIntervalSince(last) < 0.4 { return }
        lastAreaCheckAt = now

        // ① 点火位置验证：照反汇编，只更新 `isInPassiveStartArea`（预认证要靠它）。
        //    它的阈值是 `calibration - leaveOffset`，与自动解锁**无关**。
        _ = passiveStart.check(rssiOne: one, rssiTwo: two, at: now)

        // ② 靠近解锁：吃**同一个合成 RSSI**，但用自己的双阈值（enter/exit）。
        //    两者共用 calibration（车内基准），不共用 offset —— 见
        //    `applyProximityThresholds()` 的注释。
        if let action = proximityUnlock.update(combinedRSSI: passiveStart.combinedRSSI,
                                               calibration: passiveStart.calibration,
                                               now: now) {
            executeProximityUnlock(action)
        }
    }

    /// 执行自动解锁 / 闭锁。
    ///
    /// 走的是和手动按钮完全相同的 `perform(_:)` —— 只读模式、防爆破锁定、
    /// 云端路由、上一轮命令在途这些闸门一视同仁。自动动作不该有特权通道。
    private func executeProximityUnlock(_ action: ProximityUnlockController.Action) {
        let cmd: IBCommandType = (action == .unlock) ? .unlock : .lock
        let text = action == .unlock ? "靠近解锁" : "远离闭锁"
        let threshold = (action == .unlock
                         ? proximityUnlock.unlockThreshold
                         : proximityUnlock.lockThreshold).map(String.init) ?? "—"
        measured.recordNote("自动\(text)（combined=\(Int(proximityUnlock.lastCombinedRSSI.rounded()))"
                            + " 阈值=\(threshold) 迟滞=\(proximityUnlock.hysteresis)dB）")
        statusLine = "自动\(text)"
        perform(cmd)
    }

    /// 开始标定 —— 对应 `IBVehicle.startCalibration` @`0xa28c` →
    /// `openConnexionForCommand:0x0D`（触发车端进入标定/持续广播）。
    ///
    /// 之后 App 进入标定模式，靠广播回调按 antenna 分路采集 90 次 RSSI，
    /// 算均值写入 `calibration`（见 `handleDualRSSI`）。
    public func startCalibration() {
        guard ble.isWriteReady else {
            statusLine = "写特征未就绪，无法开始标定（需先连接车辆）"
            return
        }
        guard !passiveStart.isCalibrating else {
            statusLine = "标定已在进行中"
            return
        }
        rssiAntennaOne = nil
        rssiAntennaTwo = nil
        passiveStart.startCalibration()
        statusLine = "标定开始：触发 0x0D 后采集 90 次双天线 RSSI…"
        measured.recordNote("标定开始（照 startCalibration → openConnexionForCommand:0x0D）")
        // 触发车端进入标定模式（0x0D 与「查设备名」同码）
        perform(.requestPairedDevices)
    }

    /// 取消标定。
    public func cancelCalibration() {
        passiveStart.cancelCalibration()
        statusLine = "已取消标定"
    }

    /// 标定完成 → 写 `NSUserDefaults["<cidpu>_CALIBRATION"]`（照 didCalibrationCompleted:）。
    private func finishCalibration(value: Int) {
        if let cidpu = KeyStore.shared.cidpuFullHex, !cidpu.isEmpty {
            UserDefaults.standard.set(value, forKey: "\(cidpu)_CALIBRATION")
        } else {
            UserDefaults.standard.set(value, forKey: "gkuiblekey.calibration.default")
        }
        measured.recordNote("✅ 标定完成：calibration=\(value)，已写入 <cidpu>_CALIBRATION")
        statusLine = "标定完成：calibration=\(value)，点火位置验证已可用"
    }
}
