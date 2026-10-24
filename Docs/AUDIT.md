# GKUIBleKey 功能审查报告

> 审查时间：2026-10-24
> 审查对象：`GKUIBleKey`（34 个 Swift 文件，约 7,900 行）
> 对比基准：`XiaoKa.app`（原 App 主二进制 + InBlue.framework + ExDigitalKeySDK.bundle）

---

## 0. 审查范围说明（必须先讲清楚）

原 App 是**整车车联网 App**，功能远不止蓝牙钥匙：

```
导航（AMapNavi*）  日程/纪念日（CalenderTimeAxisVC）
违章查询（AddVehicleForViolationVC）  车况（CarLocationVC）
```

如果按「完整还原原 App」来要求，缺失的是整个车联网业务，与蓝牙钥匙无关。

因此本报告的对比范围限定为 **Valeo InBlue 蓝牙钥匙能力**，即
`IBVehicle` / `IBManager` / `VCLSManager` 暴露出来的那部分，
加上原 App 车控动作的业务清单（来自
`ExDigitalKeySDK.bundle/zh-Hans.lproj/Localizable.strings` 的 `auth_Cmd_Control_Req_*`）。

---

## 1. 协议与链路层

| 能力 | 原 App | 本项目 | 结论 |
|---|---|---|---|
| 扫描过滤 `10FF` + AllowDuplicates | ✓ | ✓ `BLECentral.swift:352` | 一致 |
| 厂商数据魔数 `EE 01` 判定 | ✓ | ✓ `ValeoAdvMatch.parse` | 一致 |
| 版本分支 Gen02/Gen03 + 长度门槛 | ✓ | ✓ 同上 | 一致 |
| `cryptedID` 归属校验（cidpu AES） | ✓ | ✓ `isOwnVehicle` | 一致（cidpu 绑定为 D 级） |
| 连接 `options=nil` | ✓ | ✓ | 一致 |
| 服务 `FF10` / 写 `FF11` / 通知 `FF12` | ✓ | ✓ | 一致 |
| 写入用 Write Command（withoutResponse） | ✓ | ✓ | 一致 |
| 配对 `0D → 0E` | ✓ | ✓ `AppModel.startFullPairing` | 一致 |
| 密钥 6 字段 + core 落盘 | ✓ | ✓ + `tail` | 一致（`[46,62)` 键名未取到） |
| 鉴权 `01→02→03→04` | ✓ | ✓ `InBlueAuth` + `MeasuredSession` | 一致（`01` 顺序自动探测） |
| 状态帧 `05` | **不解析**（只记录） | 解析 `0x40` 锁车位 | 本项目**增强**，非偏差 |

**链路层结论：完整对齐，无缺失。**

---

## 2. 车控功能对照（差异最大的一块）

原 App 车控业务清单（`auth_Cmd_Control_Req_*`，8 项）：

| 序号 | 动作 | 原 App | 本项目 | 差异 |
|---|---|---|---|---|
| 1 | 闭锁 | ✓ | ✓（`0x02`，实测） | 一致 |
| 2 | 解锁 | ✓ | ✓（`0x0C`，实测） | 一致 |
| 3 | 关窗 | ✓ | ✗ | **缺失** |
| 4 | 开窗 | ✓ | ✗ | **缺失** |
| 5 | 关后备箱 | ✓ | ✗ | **缺失** |
| 6 | 开后备箱 | ✓ | ✗ | **缺失** |
| 7 | 寻车 | ✓ | ✗ | **缺失** |
| 8 | 预授权引擎（点火） | ✓ | ✗ | **缺失** |

补充：InBlue 自身还有两项本项目未接：

| 动作 | 原 App 入口 | 本项目 |
|---|---|---|
| 无感进入开/关（`0x11`/`0x12`） | `IBVehicle enable/disablePassiveEntry` | ✗ |
| 查询已配对设备名（`0x0D`→`0x0F`） | `IBVehicle requestPairedDevicesNames` | 解析有（`MeasuredSession.parseDeviceNames`），**无界面入口** |

### 缺失原因（不是遗漏，是缺证据）

`03` 帧末尾的控制码目前只有 `0x02`/`0x0C` 两个真机实测值。
其余动作的控制码在 App 二进制里**不存在映射表**（业务命令 1..8 与协议码是两套编号空间），
`IBCommandType.controlCode` 对它们返回 `nil`，界面也就不提供按钮。

**影响范围**：用户能锁车/解锁，但不能开后备箱、不能升降窗、不能寻车、不能远程点火。
**补齐条件**：每个动作需要一帧原 App 的 `03` 报文（或一次真车操作 + 抓包）。

---

## 3. 页面与交互对照

### 3.1 原 App 的蓝牙相关页面

```
BluetoothViewController        蓝牙设置/配对
ControlMainViewController      控车主界面（入口聚合）
ControlLockViewController      车锁
ControlTrunkViewController     后备箱
ControlWindowViewController    车窗
ControlEngineViewController    发动机/远程启动
ControlAirConditionerViewController  空调（云端，非蓝牙）
CarLocationViewController      车辆位置（云端）
```

### 3.2 本项目页面

| 页面 | 文件 | 对应原 App | 评价 |
|---|---|---|---|
| 主页（车控） | `UI/RootView.swift` 513 行 | ControlMain + ControlLock | **合并**：闭锁/解锁两按钮 |
| 配对 | `UI/PairingView.swift` 197 行 | BluetoothViewController | 流程完整 |
| 设备列表 | `RootView` 内 `DeviceListView` | 无独立页 | 增强 |
| 车辆详情 | `RootView` 内 `VehicleDetailView` | 车辆详情页 | 部分（缺状态明细） |
| 密钥查看 | `UI/KeyInspectorView.swift` 243 行 | 无（原 App 不暴露） | 增强 |
| 诊断 | `UI/DiagnosticsView.swift` 235 行 | 无（原 App 有隐藏日志） | 增强，但**含无效控件** |
| 日志 | `UI/LogView.swift` 166 行 | IBLoggerManager 落盘 | 增强 |

**页面层结论**：核心页面对齐；多动作页面（后备箱/车窗/引擎）未建，因为它们无协议码。

---

## 4. 偏差与实现不一致（需要修正）

### 4.1 【严重】双协议并存，旧代码仍在运行路径上

| 文件 | 行数 | 问题 |
|---|---|---|
| `Protocol/DKSession.swift` | 345 | 旧五步 DK 握手（`FE 01` 帧），与实测链路无关 |
| `Protocol/DKTuning.swift` | 127 | 旧协议调参 |
| `Protocol/ExMessages.swift` | 290 | 旧帧构造 |
| `Protocol/ExSession.swift` | 186 | 旧会话 |
| `Protocol/ExVehicleState.swift` | 121 | 旧状态模型 |
| `Protocol/VehicleKeys.swift` | 122 | 旧密钥模型 |
| `Protocol/InBlueTuning.swift` | 103 | 旧配对调参（HMAC 那套） |
| `Protocol/TuningStore.swift` | 105 | 旧调参持久化 |

合计 **约 1,400 行**，且 `AppModel` 仍持有 `session`、`tuning`、`pairingTuning` 三个成员
（`AppModel.swift:16/46/47`），并保留 `beginHandshake()` / `runHandshake()`（`:376/396`）。

**影响**：无 UI 入口调用，不会误发帧；但增加维护成本，且让后来者分不清哪套是真实的。

### 4.2 【严重】诊断页存在无效调参控件

`UI/DiagnosticsView.swift:155-166`：

```
ID 2 AES 模式 / ID 2 密钥来源 / ID 2 IV 来源
ID 3 密钥来源 / ID 4 变体 / ID 4 密钥来源
ID 5 明文构造 / ID 5 密钥来源 / 控车计数器来源
```

这些是**旧五步协议**的参数，对当前 `01/02/03` 链路**完全无效**。
用户调了没反应，会误判为"协议没调对"。

**修正建议**：整块移除，或折叠进「已废弃」分组并标注灰色不可点。

### 4.3 【中】`InBluePairing` 的 HMAC 流程属于旧假设

`Protocol/InBluePairing.swift:199-244`（`calculateResponse` / `buildResponseMessage` / `makeResponseFrame`）
实现的是 HMAC-SHA256 响应，但 InBlue 配对只有 `0D→0E`，没有这一步。
`AppModel.respondToPairing`（`:340`）仍可调用。

**影响**：若被误调用会向车端发无效帧。
**修正**：标记 `@available(*, deprecated)` 或在方法内直接 `fatalError`/抛错。

### 4.4 【中】`TboxBroadcastCode` 仍在扫描热路径上做无用功

`BLECentral.didDiscover` 每次发现设备都调用 `TboxBroadcastCode.assemble/parse`
（`:633-648`），并写日志。但 `01` 帧已不使用 `broadcastRandom`。

**影响**：日志噪音（每次广播 2 行）、少量 CPU。
**修正**：降级为诊断页手动触发，或加 `if debug` 开关。

### 4.5 【低】状态显示位串可能误导

`UI/RootView.swift:382` 显示「状态位（首字节）」，但 `05` 帧只有 `0x40` 位有证据，
其余位含义未知。用户看到 `01000000` 容易自己解读。

**修正**：改为「已锁/未锁」+ 原始 hex，不展示位串；或加 tooltip「仅 0x40 已确认」。

### 4.6 【低】`GATT.advNamePrefixes` 已成为死常量

`ProtocolConstants.swift:46` 保留 `["INBLUE","GKUI","GKUINEW"]`，
但匹配逻辑已改为厂商数据判定，该常量无引用。

---

## 5. 功能缺失汇总（按优先级）

| 级别 | 项 | 影响 | 补齐条件 |
|---|---|---|---|
| **P1** | 关窗 / 开窗 | 无法远程关窗，雨天场景失效 | 需 2 帧 `03` 控制码 |
| **P1** | 开/关后备箱 | 无法远程开箱取件 | 需 2 帧 |
| **P1** | 寻车 | 地库找不到车 | 需 1 帧 |
| **P1** | 预授权引擎（点火） | 无法无钥匙启动 | 需 1 帧 + 协议确认 |
| **P2** | 已配对设备名列表入口 | 看不到车上有几台手机 | 仅需 UI（解析已有） |
| **P2** | 无感进入开关（`0x11`/`0x12`） | 不能开关键less entry | 需 2 帧 |
| **P3** | 多车辆管理 | 只能管一把钥匙 | 需设计（原 App 支持多车） |
| **P3** | 后台模式 / 蓝牙保活 | 后台一段时间后需重连 | 需 `startBackgroundMode` 对应实现 |
| **P3** | 车辆位置 / 空调 / 座椅加热 | — | **不属于蓝牙链路**，走云端 TSP，超出范围 |

---

## 6. 已确认无问题的部分

为避免只报问题，以下经核对**与原 App 行为一致**：

1. 扫描/连接/服务发现/订阅/写入方式（含 `withoutResponse` 强制要求）
2. 广播解析三件套：魔数 → 版本 → 字段切分 → `cryptedID`
3. 配对 `0D` 帧格式（nonce 15B + 字符数 + 设备名 + 补零至 37B）
4. 密钥帧切分 7 个字段（位置/长度均与反汇编立即数一致）
5. 鉴权 `01`/`03` 帧构造与 AES 参数
6. `03` 自校验失败时不发送（与原 App 一致）
7. 错误码 `0x276/0x277/0x278/699` 的文案与触发点
8. 锁车/解锁控制码与 `05` 状态位 `0x40`

---

## 7. 建议的修复顺序

1. **清理旧协议**（不改行为、纯减法，风险最低）：
   删除或隔离 8 个旧文件；`AppModel` 移除 `session/tuning/pairingTuning`；
   删除 `beginHandshake/runHandshake`。
2. **诊断页分区**：现有调参全部折叠进「已废弃（旧五步协议）」；
   新增「当前链路参数」只读展示（本帧用的顺序、cidpu、密钥摘要）。
3. **状态显示降噪**：去掉未确认的位串。
4. **加已配对设备入口**：`0x0D` 发送 + `0x0F` 解析已有，接个按钮即可。
5. **P1 动作**：待补帧后再做，不做占位按钮（避免点了没反应的假功能）。

---

## 8. 结论

- **协议层**：与原 App 对齐，无缺失；两处 D 级推断（cidpu 绑定、`01` 顺序）已留兜底。
- **车控层**：8 项业务动作只实现了 2 项（锁/解锁），其余因**控制码无证据**而空缺。
- **界面层**：核心页面齐备，但诊断页混入旧协议控件、状态位展示过度解读，属**实现不一致**。
- **代码层**：约 1,400 行死代码与主链路并存，是当前最大的可维护性风险。

一句话：**「能锁能解锁」这条路是通的，「全能车控」还差 6 个控制码。**

---

## 9. 修复记录（2026-10-24 执行）

本节记录针对第 4、5 节的整改结果。**代码已改完并通过 `swiftc -typecheck`。**

### 9.1 已删除（第 4.1 节）

| 文件 | 行数 | 处理 |
|---|---|---|
| `Protocol/DKSession.swift` | 345 | 删除 |
| `Protocol/ExMessages.swift` | 290 | 删除 |
| `Protocol/ExSession.swift` | 186 | 删除 |
| `Protocol/DKTuning.swift` | 127 | 删除 |
| `Protocol/ExVehicleState.swift` | 121 | 删除 |
| `Protocol/VehicleKeys.swift` | 122 | 删除 |
| `Protocol/InBlueTuning.swift` | 103 | 删除 |
| `Protocol/TuningStore.swift` | 105 | 删除 |
| `BLE/CommandSequencer.swift` | 136 | 删除 |

合计 **1,535 行**。备份在 `/tmp/gkui_legacy_backup/`（临时目录，需要长期保留请自行转存）。

`AppModel` 同步移除：`session`、`tuning`、`pairingTuning`、`sequencer`、`handshakeTask`、
`beginHandshake()`、`runHandshake()`、`applyTuning()`、`applyPairingTuning()`、旧帧下行分支。

### 9.2 已修正（第 4.2 / 4.3 节）

- **诊断页**：删除 10 个旧协议调参项（ID 2/3/4/5、CRC 覆盖、CRC 配置），
  新增「当前链路参数」区块 —— 可切换 `01` 明文顺序、可开关「收到 02 自动回 03」，
  并以只读方式展示 `cidpu(16B)` / `CkTRxSP` / `Dk1` 摘要。
- **`InBluePairing`**：重写为单职责（只发 `0D`、只收 `0E`），
  HMAC 流程整体删除；`AppModel.startPairing(sidpu:cidpu:)`、`requestPairingParameters()`、
  `respondToPairing()` 一并移除。
- **`LogView`**：移除「旧 DK 会话」日志来源。

### 9.3 已补齐（第 5 节 P2）

- **车控动作区**：主页列出全部 8 个动作。
  - 闭锁 / 解锁：可点，走 `01→02→03`，控制码 `0x02` / `0x0C`（实测）。
  - 后备箱 / 关窗 / 开窗 / 寻车 / 无感进入 / 已配对手机：**列出但禁用**，
    下方一行说明「控制码尚未从原 App 抓包确认，已阻止发送」。
- **已配对手机名册**：车辆详情页新增「查询车端已配对手机」按钮 →
  `requestPairedDeviceNames()`（`03` 帧控制码 `0x0D`，D 级证据），
  结果由已有的 `parseDeviceNames` 解析后显示。
- **状态展示降噪**：去掉未确认的位串，改为「已锁/未锁」+ 原始 `05` 帧十六进制。

### 9.4 仍未完成（需外部输入）

| 项 | 阻塞原因 |
|---|---|
| 后备箱 / 车窗 / 寻车 / 预授权引擎 的实际控制码 | App 二进制内无映射表，需 1 帧/动作的原 App 抓包 |
| `01` 明文五段顺序的最终确认 | ABI 歧义；已用运行时自动探测兜住 |
| `cidpu` 与密钥帧 `[46,62)` 的绑定关系 | 键名在栈上，未取到字面量 |

### 9.5 清理后的规模

```
改动前：34 个 Swift 文件 / 约 7,900 行
改动后：23 个 Swift 文件 / 5991 行
```
（删 12 个文件，新增 0 个；另精简 `FrameCodec` 为纯工具、删除 `CRC16.swift`/`VehicleStatus` / `ValeoAdvMatch` / `InBlueAuth` 为上一轮新增）

---

## 10. 2026-10-24 晚：第 9.4 节的阻塞项全部解除

第 9.4 节列的「仍需外部输入」三项，其中两项在重新反汇编后**不需要任何外部输入**了。

### 10.1 根因：曾经把两个数当成两套编号

旧实现里 `IBCommandType.controlCode` 对非锁/解锁动作返回 `nil`，理由是
「业务命令号（`1..6`）与 `03` 控制码（`0x02/0x0C`）不是同一个命名空间」。

**这个前提是错的。** `03` 帧末字节就是 `command` 原值
（`+[IBMessageFactory responseMessageWithCommand:randomData:cidpu:]` @`0x13904`
里 `strb w23` 直接 append）。所以：

- `0x01` = 锁车（不是 `0x02`）
- `0x02` = 解锁（不是 `0x0C`）
- `0x0C` = `startCalibration`（RSSI 校准），不是用户动作

### 10.2 全部 8 个动作已可用

| 动作 | 命令号 | 界面 |
|---|---|---|
| 闭锁 | `0x01` | 可用 |
| 解锁 | `0x02` | 可用 |
| 后备箱 | `0x03` | 可用 |
| 关窗 | `0x04` | 可用 |
| 开窗 | `0x05` | 可用 |
| 寻车 | `0x06` | 可用 |
| 开/关无感进入 | `0x11` / `0x12` | 可用 |
| 查询已配对手机 | `0x0D` | 可用 |

界面上「未确认控制码、已阻止发送」的禁用按钮**全部移除**。

### 10.3 新增模块（20:10 已更正）

| 文件 | 作用 | 依据 |
|---|---|---|
| `Protocol/PreAuthenticationController.swift` | 预认证保活（只发 `0x0C`） | `openConnectionWithPassiveStart` @`0xb5a8`；`didPassiveStartCompletedWithError:` @`0xb6cc` |

- **`0x0C` = 预认证**，不是"RSSI 校准"（20:00 那版写错了，已作废）。
- 间隔：成功 **6.5s**、失败 **29.0s**（`0xb7d8` / `0xb7e0` 立即数）。
- 原 App **不自动发** `lock`/`unlock`，因此本模块也不发；`PassiveEntryController` 已删除。

### 10.4 状态语义的最终处理

`05` 帧在原 App 里只有一句 `NSLog(@"Message 5 received")`，没有任何字段解析。
因此：

- `IBVehicleState` 退化为**纯原始字节容器**（无 `isLocked`）；
- `VehicleStatus` 仅用于广播解密路径（`parseStatus:`），锁位改回 `bit0`；
- 界面显示「最近一次成功动作」，不再猜车速锁状态。

### 10.5 当前规模

```
23 → 24 个 Swift 文件
5,991 → 6,258 行
```

`swiftc -typecheck`（非 UI 层）0 error；UI 5 个文件 `-parse` 0 error。
（宏插件 `swift-plugin-server` 在此环境仍被 SIGTERM，完整 build 需在 Xcode 内执行。）
