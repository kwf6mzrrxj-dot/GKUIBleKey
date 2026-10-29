# 逻辑一致性审查：GKUIBleKey vs 原 App（XiaoKa / InBlue）

- 审查日期：2026-10-25（对应当前 v1.9）
- 对照基线：`InBlue.framework` / `ValeoCoreCommunication.framework` 反汇编
  （见 `Docs/INBLUE_PROTOCOL_SPEC.md`）
- 审查范围：业务规则、数据处理流程、状态管理、异常处理
- 结论：**14 处不一致**（高影响 3 / 中影响 4 / 低影响 7），另有 11 项确认一致

> 排序依据：**是否会导致车端判失败、是否会导致状态错乱、是否会卡死无反馈**，
> 其次才是日志/文案类差异。

---

## 修复状态（v2.0 已全部处理）

| 编号 | 问题 | 修复方式 | 状态 |
|---|---|---|---|
| H1 | 缺 30s 命令超时 | `AppModel.startCommandTimeout()`；超时只报 690，不断连 | ✅ |
| H2 | 缺 `lastPacket` 单调 + 白名单 | `MeasuredSession.lastPacket` / `resetPacketCounter()` | ✅ |
| H3 | `02` 无长度校验 | `payload.count ≤ 16` → `Wrong challenge`（0x278） | ✅ |
| M1 | `0x0E` 无配对成功语义 | 新增 `ActionResult.paired` + `phase = .verified` | ✅ |
| M2 | `reset()` 过度清理 | 拆出 `resetCommandOnly()`，配对收尾用它 | ✅ |
| M3 | 断连有退避重连 | 删除重连循环（VCB 只回调，不重连） | ✅ |
| M4 | `0x0F` 不标成功 | `lastResult = .success` + `lastSucceededAction` | ✅ |
| L1 | `04` 失败码 | 统一 `0x2BB`，`refused` 改 `UInt16` | ✅ |
| L2 | 未知命令不报失败 | `default` → `refused(0x2BB)` + 日志 | ✅ |
| L3 | `connect` 无前置检查 | `state != .disconnected` 时跳过/直接发现服务 | ✅ |
| L4 | `didDiscoverServices` 兜底 | 严格匹配 `F000FF10` | ✅ |
| L5 | `didDiscoverCharacteristics` 不查 error | 补 error 分支 | ✅ |
| L6 | 订阅成功语义 | 保留 Combine，语义对齐回调 | ✅（等价） |
| L7 | `IBCommand` 缺 `0x00` | 补 `case unknown = 0x00` | ✅ |

**残留说明**：L6 仍是「`didUpdateNotificationState` 置 `linkState = .ready` → Combine 触发发 0x0D」，
与原 App「回调带 `success` 参数」路径不同但语义等价；若日后出现
「订阅成功但 `success=false`」的车端行为，需再补 `success` 位。

---

## 高影响（可能直接影响配对成败或导致卡死）

### H1. 缺少 30 秒命令超时定时器

| | 内容 |
|---|---|
| **原 App** | `-[IBDevice openConnexionForCommand:]` @`0x4988`：`cmd == 0x55` 时 `scheduledTimerWithTimeInterval:30.0 → closeConnexionForCommand`；超时后 `didNeedReconnect` + `NSLog "Reconnect with cidpu: %@"` + 断开重连 |
| **当前实现** | **完全没有超时定时器**（`Sources/` 全库 grep `Timer|asyncAfter|30.0` 为空） |
| **位置** | 应在 `BLECentral`/`AppModel` 的连接发起处，但缺失 |
| **差异** | 车端不回 0x0E 时，原 App 30s 后主动断开重连并给出错误；本 App 永远停在「等待 0x0E」 |
| **影响** | ① 用户侧表现为「一直转圈、无任何反馈」，不知失败；② 不会自动恢复，只能手动重试；③ 反之，因为不主动断开，避开了原 App 的「30s 断开重连」失败路径——**这一条是双刃剑**，需明确取舍 |
| **建议** | 补超时，但**只做 UI 提示 + 允许重试，不主动断开**（保留当前「不主动断连」的优点） |

### H2. 缺少 `lastPacket` 单调状态机与命令白名单

| | 内容 |
|---|---|
| **原 App** | `-[IBMessageManager analyzeMessage:]` @`0xfc64`：① 命令白名单 `{0,1,2,14}`（`0x4007` 位掩码）；② 要求 `cmd > lastPacket`，否则 `"Protocol failed. Message %d received or the last message is %d or vehicle is not valid"`；③ 未通过则走 `isValidVehicle` 分支再判一次 |
| **当前实现** | `MeasuredSession.handle()` @`Sources/Protocol/MeasuredSession.swift:265-333`：`switch IBCommand(rawValue:)` **直接分发**，无白名单、无 `lastPacket` |
| **差异** | 不维护 `lastPacket`；重复/乱序/非法命令一律照常处理 |
| **影响** | ① 重复的 `02` 会触发**多次** `03` 发送（车端可能判协议违规）；② 迟到的旧帧（如上一轮 `04`）会被当成新一轮结果，造成「动作结果错配」；③ 非法命令静默忽略而非报协议错 |
| **建议** | 补 `lastPacket` 单调校验 + 白名单，失败时走与 H3 一致的错误路径 |

### H3. `02` 挑战帧缺少长度校验

| | 内容 |
|---|---|
| **原 App** | `-[IBMessageManager responseMessageWithData:]` @`0x104b4`：`if ([data length] <= 0x10)` → 直接 `callDidSendCommandFailedWithMessage:@"Authentification is insufficient. Wrong challenge" code:0x278` |
| **当前实现** | `MeasuredSession.swift:271-277`：`case .response:` 直接 `buildAuth3(challenge: payload)`，**不校验长度** |
| **差异** | 短帧（≤16B）进入响应计算，而不是判「Wrong challenge」 |
| **影响** | ① 长度异常时产出错误 `03`，车端**秒断**（历史已复现过「车端秒断」）；② 缺少明确错误码，排障时看不到 0x278 这条线索 |
| **建议** | 在 `case .response` 入口加 `guard payload.count > 16 else { 记 wrongChallenge 失败; return nil }` |

---

## 中影响（状态/体验不一致，不必然导致失败）

### M1. `0x0E` 没有「配对成功」的显式状态与回调

| | 内容 |
|---|---|
| **原 App** | `saveKeysData:` → **`callDidPairingSuccess`** @`0x6d6c`：`NSLog "Pairing succeeed"` → `vehicleDidPairingSucceed:` 回调 → `disconnect` |
| **当前实现** | `MeasuredSession.swift:316-321` 的 `case .keyData` 只 `saveKeyData(payload)`，`phase` **保持原值**；配对成功仅靠 `AppModel.handlePairingFrame` 里的 `statusLine` 文本 + `finishPairingWithReconnect()` |
| **影响** | ① UI 无可靠「配对成功」信号（只能嗅文本或看 `keys != nil`）；② `MeasuredSession.phase` 不反映成功态，后续逻辑若依赖 phase 会误判；③ 与 `04` 成功路径的语义不对称 |
| **建议** | 在 `case .keyData` 里补 `phase = .verified` + 新增 `ActionResult.paired`，并让 UI 监听它 |

### M2. `reset()` 清理过度（超出原 App 的 `resetCommandTimeout`）

| | 内容 |
|---|---|
| **原 App** | `-[IBDevice resetCommandTimeout]` @`0x64f4`：**只取消定时器**，不动业务状态 |
| **当前实现** | `MeasuredSession.reset()` @`:466-477` 清 `phase/rnd1/lastStatusCode/lastResult/pendingAction/receivedKeyData/pairedDeviceNames/challengeVerified/status/vehicleState`；`AppModel.finishPairingWithReconnect()` @`:468-474` 直接调它 |
| **影响** | ① 配对成功的瞬间，刚写入的 `receivedKeyData` 与刚解密的 `status` 被清空 → 「收到密钥」「车辆状态」展示会闪一下消失；② 若配对后紧接预认证，`rnd1` 被清，需重新走 `01` |
| **建议** | 配对收尾改用「只清 `rnd1` + 定时器」的轻量方法，不动 `receivedKeyData/status` |

### M3. 断连后有退避自动重连循环（原 App 无此机制）

| | 内容 |
|---|---|
| **原 App** | 断连只在超时场景走一次 `didNeedReconnect` + 重连；无「最多 N 次、指数退避」循环 |
| **当前实现** | `BLECentral.swift:807-835`：`reconnectAttempt` 递增、`delay = min(5.0, 0.4 * 2^n)`、最多 `maxReconnectAttempts` 次 |
| **影响** | ① 配对成功后若车端主动断开，会反复重连，可能干扰车端会话状态；② 与原 App 行为不一致，排障时日志噪音大 |
| **建议** | 配对成功后的断开不触发自动重连（复用 `suppressAutoReconnect`） |

### M4. `0x0F` 设备名回执不标记动作成功

| | 内容 |
|---|---|
| **原 App** | `case 15` → `parseDeviceNames:` → **`callDidSendCommandSuccess`** |
| **当前实现** | `MeasuredSession.swift:323-327` 只解析并赋值 `pairedDeviceNames`，`lastResult` 不更新（`04` 时给的是 `.acceptedAwaitingNames`） |
| **影响** | 「查询已配对设备名」动作永远停在「已受理」，`lastSucceededAction` 不更新，界面/状态机无法闭环 |
| **建议** | `case .deviceNames` 里补 `lastResult = .success` + `lastSucceededAction = .requestPairedDevices` |

---

## 低影响（日志/错误码/健壮性）

### L1. `04` 失败码语义不同
- 原 App：固定 `code:0x2BB(699)` + `"Send command failed. The vehicle refused the command"`。
- 当前：`MeasuredSession.swift:286-292` 用 `payload.first` 作为 `.refused(code)`。
- 影响：错误码/文案不一致，功能无碍；但与原 App 日志比对时会对不上。

### L2. 未知命令不报失败
- 原 App：`default → callDidSendCommandFailed(@"Invalid Message type", 699)`。
- 当前：`MeasuredSession.swift:329-331` 只 `append` 日志。
- 影响：非法帧被静默吞掉，不报错、不触发失败计数。

### L3. `connect` 不检查 `isConnectable` / `state == 0`
- 原 App：`VCBDevice connect` @`0x8de4` 双重前置检查，否则 `"The device is not disconnected"`。
- 当前：`BLECentral.swift:355-364` 直接 `connect(p, options: nil)`。
- 影响：对不可连接设备也会发起连接；重复连接靠 `prepareForPairingScan()` 缓解。

### L4. `didDiscoverServices` 用「第一个服务」兜底
- 原 App：必须匹配 `F000FF10`，不匹配即失败。
- 当前：`BLECentral.swift:840-846` 的 `?? peripheral.services?.first`。
- 影响：找不到目标服务时会连到错误服务，后续特征发现失败且报错不明确。

### L5. `didDiscoverCharacteristicsFor` 不检查 `error`
- 当前：`BLECentral.swift:850-870`，`error` 参数未使用。
- 影响：发现特征失败被忽略，表现为「特征不完整」而无具体原因。

### L6. 订阅成功判定路径不同（Combine 订阅 vs 回调）
- 原 App：`deviceDidSubscriptionDoneWithSuccess:(BOOL)success` **带回 success 参数**。
- 当前：`BLECentral.swift:876-891` 只判 `isNotifying`，再由 `AppModel.swift:204-210` 订阅 `$linkState` 触发发 0x0D。
- 影响：功能等价（时序也正确），但未使用 success 语义；若将来车端出现「订阅成功但 success=false」的边界情况无法区分。

### L7. `IBCommand` 缺 `0x00`
- 原 App 白名单 `{0,1,2,14}` 含 `0`；当前 `MeasuredSession.swift:21-43` 的 enum 无 `0x00`。
- 影响：`0x00` 走 `default` 分支（同 L2）。

---

## 确认一致的项（无需改动）

| # | 项 | 依据 |
|---|---|---|
| 1 | `0x0D` 帧 37B：`0D + sidpu(16B) + 设备名(20B)` | `pairingMessage` @`0x13afc` |
| 2 | sidpu 常量 `628f...8d2f92` | `getSidpu` @`0x11a28` |
| 3 | 设备名 `UIDevice.current.name`，≤19 补零 / ≥21 截断 | 同上 |
| 4 | `0x0E` 七字段切片（含 RndTRx=3B） | `saveKeysData:` @`0x12660` |
| 5 | Keychain `IBSavedKeys` + NSKeyedArchiver（v1.9 双写） | `storeDictionary:toKeychainWithKey:` @`0x131b4` |
| 6 | 配对收尾 `resetCommandTimeout + startScan`、不回帧、不断 BLE | `callDidPairingSuccess` @`0x6d6c` / `disconnect` @`0x6588`（但见 M2 的清理范围） |
| 7 | `connectPeripheral:options: = nil` | `connectToDevice:` @`0x5dbc` |
| 8 | 广播魔数 `EE 01`、Gen02/Gen03 字段偏移、antenna 位判定、RSSI −91 | `VCBAdvertisingData` 系列 |
| 9 | RSSI 窗口 10 值 + 3 时间戳 | `addRSSI:` @`0x8d38` |
| 10 | 标定 key `<cidpu>_CALIBRATION` | `getCalibrationSavedValues` @`0xb83c` |
| 11 | 预认证间隔 6.5s / 29.0s | `0xb7d8` / `0xb7e0` 的 `fmov` |

---

## 修复优先级建议

1. **H3**（02 长度校验）—— 改动最小、直接避免「车端秒断」
2. **H1**（超时提示）—— 只补提示不主动断开
3. **H2**（lastPacket + 白名单）
4. **M1**（配对成功显式状态）
5. **M2**（reset 收敛）
6. **M3**（配对后不自动重连）
7. **M4 / L1–L7**（随迭代清理）
