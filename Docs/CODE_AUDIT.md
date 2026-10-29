# 全源码审查报告

> 审查时间：2026-10-25（v0.9）
> 审查范围：全部 30 个 Swift 文件（7637 行），分协议层 / BLE+App 层 / UI+支持层三路并行审查
> 结论：修复 6 处实质 bug，记录死代码与注释问题清单

---

## 一、已修复的实质 bug（v0.9）

| # | 问题 | 位置 | 影响 |
|---|------|------|------|
| 1 | 点火验证误用 29s 门控采样 | `PassiveStart.check` | 区域判定最多 29s 才刷新，密集求均值分支不可达 |
| 2 | 手动断开仍自动重连 | `BLECentral.disconnect/cancelConnection` | 点「断开/解绑」被立即重连 |
| 3 | Keychain 覆盖写入失败 | `KeyStore.set` | 重新配对/恢复备份时旧密钥删不掉、新密钥写不进 |
| 4 | 无感进入切换被拒卡死 | `AppModel.settlePassiveEntryToggle` | 车端拒绝时开关一直转圈 |
| 5 | 配对日志不刷新 | `AppModel.init` | `pairing.log` 变化不驱动 UI |
| 6 | 浮窗内存泄漏 | `FloatingWindowController.hide` | 反复开关累积隐藏窗口 |

---

## 二、死代码清单（未清理，供后续处理）

> 项目约定：只删「本项目自造 + 从未调用」的纯死代码，原 App 反汇编逻辑一律保留。
> 以下按此约定分类。

### A. 可安全清理（本项目自造，无原 App 依据）

| 文件 | 死代码 | 说明 |
|------|--------|------|
| AppModel.swift | `settle(_:)` | 遗留异步延时辅助，已被 Task.sleep 内联取代 |
| AppInfo.swift | `fullVersion` | 无调用 |
| CryptoBox.swift | `sha256(Data)`/`hmacSHA256(Data:)` 重载 | 只用 [UInt8] 重载 |
| CryptoBox.swift | `AESMode.ecbPKCS7` | 无调用 |
| CryptoBox.swift | `CryptoError.badKeyLength/notImplemented` | 从未 throw |
| KeyStore.swift | `mobileID()`/`isPaired`/`setUInt32`/`getUInt32` | 无调用（getUInt32 还有未对齐 load 隐患） |
| FileLogger.swift | `path`/`readAll()`/`clear()` | 无 UI 接入 |
| RelayGuard.swift | `alarm/latest/average/isSuspicious/bars/reset` | 只写不读，中继告警未展示 |
| MeasuredSession.swift | `IBVehicleState.byteCount`、`MeasuredFrame.encode` | 无调用 |
| InBlueAuth.swift | `firstFrameLength`/`responseFrameLength` | 无调用 |
| ProtocolConstants.swift | `isUserAction`/`symbolName` | UI 图标硬编码，未用 |
| LiveLogFloatingView.swift | `autoScroll` | 恒 true，无 UI 控制 |
| TboxBroadcastCode.swift | `describeCandidates` | 零调用 |

### B. 保留（原 App 反汇编逻辑，按约定不删）

| 文件 | 代码 | 保留理由 |
|------|------|---------|
| InBluePairing.swift | `buildPairingMessage`(0x0D 登记帧) + frameLength/nonceLength/command | 原 App `generatePairingMessage` @0xfecc 的还原，备用路径 |
| InBlueAuth.swift | `PlainOrder` 枚举 | 反汇编字段顺序的记录 |
| MeasuredSession.swift | `IBCommand.authStart/.command/.pairingReq` | 协议枚举完整性 |

### C. 诊断用（写后未读，但属调试指标）

- `BLECentral.discoverCount`/`stateUpdateCount`/`lastDiscoveredName`/`lastManufacturerData`/`currentCidpu`/`broadcastCode`/`broadcastCodeRandom`
- `MeasuredSession.broadcastRandom`

---

## 三、已知但未修复的逻辑隐患（低优先级）

| 问题 | 位置 | 说明 |
|------|------|------|
| `discoverCount` 重复自增 | BLECentral 679/701 | 命中节流 +1、未命中 +2，诊断指标虚高 |
| `ValeoAdvMatch.antennaNumber` 对 Gen02 恒 nil | ValeoAdvMatch 96-103 | Gen02 天线号解析失败（Gen02 实测未出现） |
| `PreAuthenticationController` 未实现「断开立即发」分支 | 162-163 | 无条件走 1s 延迟 |
| `AppModel.deleteVehicle` 复位不完整 | 506-525 | 未清 rememberedPeripheralID、锁定态等 |
| `beginMeasuredAuth` action==nil 且非预认证时误发 | 734-767 | 潜在误发上一动作控制码（当前无调用者） |
| KeyInspectorView 用 `.id(refreshTick)` 整页重建 | 47 | 丢失输入焦点 |
| LiveLogFloatingView 拖动无边界 clamp | 113-123 | 可拖出屏幕 |
| PairingView 进度圈与「可点击重试」矛盾 | 205-214 | isWorking 恒 = !hasVehicle |

---

## 四、遗留的注释问题（已修复主要矛盾，其余低优先级）

- 已修复：`handlePairingFrame` 双段矛盾、`didConnect` quietMode 矛盾
- 待清理：`MeasuredSession.ActionResult.refused` 注释(699 vs 实际原始字节)、
  `IBVehicleState`「19 字节」vs「18 字节」、`CryptoBox.randomBytes`(arc4random vs 实际)、
  `KeyStore.mobileID` 整段逆向注释与实现脱节

---

## 五、审查结论

- 核心协议（配对/鉴权/控车/广播/标定）**逻辑正确**，帧构造与反汇编一致
- 本次修复的 6 处 bug 均为「体验/健壮性」层面，不影响协议正确性
- 仍有一批死代码和低优先级隐患，建议后续分批清理
