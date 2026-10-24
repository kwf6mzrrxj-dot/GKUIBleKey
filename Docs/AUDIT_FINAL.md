# 全量闭环审计（最终版）

> 审计时间：2026-10-24 21:58
> 口径：① 代码存在 → ② 编译通过 → ③ 链路可达 → ④ 真机跑过
> 本次已完成 ②③ 的编译器级验证；④ 需实机（App 已装到 iPhone，待信任签名后连车）。

---

## 一、编译验证（②）

| 验证 | 结果 |
|---|---|
| `swiftc -typecheck`（25 文件含 UI，`-plugin-path` + target 27.0） | ✅ 0 error 0 warning |
| `xcodebuild build`（命令行，已固化 `OTHER_SWIFT_FLAGS`） | ✅ BUILD SUCCEEDED |
| 安装到 iPhone 17 Pro（iOS 27.0） | ✅ 已安装，bundleID `com.mmxisme.gkuiblekey` |

---

## 二、模块接口匹配核对（③）

逐模块核对了 UI → AppModel → Protocol/BLE → Keychain 的每个调用点，
全部能对上（编译器也保证）。**发现 2 处无害死代码 + 1 处注释矛盾**：

### 死代码 1：`AppModel.startPairing()`（第 360 行）

```swift
public func startPairing() { startPairingAuto() }   // 全仓 0 调用
```

UI 已改用 `startFullPairing()`，这个历史别名是残留。**无害，建议删除。**

### 死代码 2：`AppModel.connectFirstCandidate()`（第 371 行）

```swift
public func connectFirstCandidate() { ... }         // 全仓 0 调用
```

UI 已改用 `autoConnect()`。**无害，建议删除。**

### 注释矛盾：`0x0C` 的两种叫法

| 位置 | 说法 |
|---|---|
| `ProtocolConstants.swift:68-70` | `0x0C` 是「RSSI 校准（startCalibration）」 |
| `MeasuredSession.swift:143-144` | `0x0C` 默认是「RSSI 校准码」 |
| `PreAuthenticationController` / `MeasuredSession.preparePreAuthentication()` | `0x0C` 是「预认证（prehautentification）」 |

代码行为一致（都发 `0x0C`），但注释历史残留矛盾。**建议统一为「预认证」**，
因为 `openConnectionWithPassiveStart` 的日志字面量是
`"send prehauthentification command"`，这是更晚、更直接的证据。

---

## 三、缺失清单最终核对（GAPS.md 的每一项）

| # | 项 | 当前真实状态 |
|---|---|---|
| 1 | RSSI 标定链 | ⚠️ 读已实现（`loadCalibration`），**写仍缺**（`startCalibration` 未实现，跨 GLBLE 协议） |
| 2 | `leaveOffset` | ✅ 已关闭（=32，`0x7900`） |
| 3 | 判定式 `w25` | ✅ 已关闭（`rssisOneAndTwo.intValue`） |
| 3b | `rssisOneAndTwo` 加权 | ✅ **已精确还原**（自适应取值 + 合成 dB，不再是近似） |
| 4 | `05` 帧字段 | — 不适用（原 App 走 TSP，不解析 05） |
| 5 | 车端被动启动动作 | — 原 App 也没有 |
| 6 | `0x55` 配对命令 | ❌ 未实现（抓包证明 `0D→0E` 即可，非必需） |
| 7 | UI 类型检查 | ✅ **已解决**（`-plugin-path` 修复，全量编译通过） |
| 8 | 错误码文案 | ✅ 已补（`ErrorCodeTable.swift` 24+30 条） |
| 9 | `.conf.ibcx` | ❌ 未解码（48 字节，单字节 XOR 全试无解，相关性未知） |

---

## 四、核心链路闭环确认

以下链路逐条核对，全部可达、无断点：

1. **扫描**：UI「扫描」→ `startScan` → `ble.startScan()`（用 `10FF` 广播 UUID）✅
2. **连接**：`autoConnect` → `adoptConnectedPeripheral` / `startScan` ✅
3. **配对**：`startFullPairing` → `ble.reconnectForPairing`/`startScan` → linkState ready → `sendPairingRequest`（0x0D）→ `handlePairingFrame`（0x0E）→ `saveKeyData` → `loadCalibration` ✅
4. **控车**：`perform(action)` → 防爆破闸 → 密钥完整性闸 → `beginMeasuredAuth` → `buildAuth1`（01）→ 收 02 → `handleIncomingFrame` 自动回 03 → 收 04 分流 ✅
5. **查询已配对手机**：`requestPairedDeviceNames` → `perform(.requestPairedDevices)`（0x0D 控制码）→ 0x0F 回执单独处理 ✅
6. **预认证**：`ble.$rssi` → `passiveStart.check` → `preAuth.updateArea` → `launchPreAuthentication` → `onSend` → `beginMeasuredAuth(asPreAuthentication:true)` ✅
7. **防爆破**：失败计数 → 达阈值 `startLockout` → 每秒递减 → 归零解锁 ✅（此前"只记录不拦截"已修）
8. **密钥完整性**：`verifyKeyIntegrity` → `keyIntegrityOK` → 发帧前拦截 ✅（此前"只报警不拦截"已修）
9. **断连重连**：`linkState` 订阅 → `preAuth.resetEdge()` 复位边沿 ✅（此前 resetEdge 0 调用已修）
10. **自检**：13 项全部注册到 `runAll()`，诊断页「运行自检」触发 ✅

---

## 五、结论

**代码层面已闭环：25 文件 / 6588 行，全量编译 0 error 0 warning，**
**所有模块接口匹配、调用链无断点。**

**唯一未完成的实质功能**（不影响"能用"，只影响"被动进入自动预认证"）：

- **RSSI 标定写入端**（缺失 1）：`calibration` 的读路径已通，但写入端
  `startCalibration` 走的是底层 GLBLE 协议，本车抓包从未出现该协议，
  无法在不臆测的前提下补全。未标定时基准 = -32，被动进入几乎不触发
  （这与原 App 的 `[nil intValue]=0` 行为一致，**不是本项目的退化**）。

**建议的收尾动作（非必须）**：
1. 删除两处死代码 `startPairing()` / `connectFirstCandidate()`
2. 统一 `0x0C` 注释为「预认证」，清理"校准码"的过时说法
3. 真机连车跑一次端到端（点「解锁」应见 `01→02→03…02→04 00`），
   这是唯一还缺的 ④ 级验证。
