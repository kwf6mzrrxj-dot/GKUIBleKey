# 当前缺失清单（含代码位置、预期/实际对比、原因与修复方向）

> 生成时间：2026-10-24 20:15
> 基准：`Sources/` 24 文件 / 6,298 行；`swiftc -typecheck`（非 UI 层）**0 error 0 warning**；
> UI 5 文件 `-parse` 0 error。
>
> 本文只列**确实缺的东西**。凡是能在二进制里找到的，都不在此表。

---

## 缺失 1（严重）：RSSI 标定链整条缺失，导致预认证永不启动

### 现象

`PassiveStartJudge.check` 返回的 `isInPassiveStartArea` **恒为 `false`**，
于是 `PreAuthenticationController.updateArea(false)` 永远不会走到
`launchPreAuthentication()`，被动进入/预认证在实机上不会发生。

### 预期 vs 实际

| | 预期（原 App） | 实际（当前） |
|---|---|---|
| 判定基准 | `calibration - leaveOffset` | `nil` |
| `calibration` 来源 | `NSUserDefaults["<cidpu>_CALIBRATION"]` | 未读取 |
| `leaveOffset` 来源 | `_OBJC_IVAR_$_IBVehicle._leaveOffset` | 未设置 |
| 结果 | 按标定值判定远近 | 恒 `false` |

数值验证（`distance = √(10^(r/10)² + 10^(r/10)²)`）：

```
rssi= -40  distance=1.414e-04   <= 0 ? False
rssi= -60  distance=1.414e-06   <= 0 ? False
rssi= -80  distance=1.414e-08   <= 0 ? False
rssi= -91  distance=1.123e-09   <= 0 ? False
```

`distance` 是正的小量，与 `0` 比较永远为假 —— 这就是"看起来有功能、实际不触发"。

### 相关代码

修复前（`Protocol/PassiveStart.swift`）：

```swift
public var areaThreshold: Double = 0          // ← 用 0 冒充"未标定"
...
isInPassiveStartArea = (dist <= areaThreshold) // ← 恒 false
```

修复后（当前）：

```swift
public var areaThreshold: Double?             // nil = 未标定
...
guard let threshold = areaThreshold else {
    isInPassiveStartArea = false
    return false                              // 显式不判定，而不是假装判定
}
isInPassiveStartArea = (dist <= threshold)
```

并在 `AppModel` 的 RSSI 回调里提示一次：

```swift
if self.passiveStart.areaThreshold == nil, !self.didWarnUncalibrated {
    self.didWarnUncalibrated = true
    self.measured.recordNote("⚠️ RSSI 未标定（calibration/leaveOffset 缺失）：被动进入不会自动启动")
}
```

### 出现原因

原 App 的标定是一条独立链路，**我一条都没实现**：

| 原 App 方法 | 地址 | 作用 | 本项目 |
|---|---|---|---|
| `-[IBVehicle startCalibration]` | `0xa28c` | 发起标定（转发给 device） | 未实现 |
| `-[IBDevice startCalibration]` | `0x4880` | 同上 | 未实现 |
| `-[IBVehicle didCalibrationCompleted:error:]` | `0xa41c` | 写 `UserDefaults["<cidpu>_CALIBRATION"]` | 未实现 |
| `-[IBVehicle getCalibrationSavedValues]` | `0xb83c` | 读回并 `setCalibration:` | 未实现 |
| `-[IBVehicle clearCalibrationData]` | `0xb978` | 清除标定 | 未实现 |
| `-[IBVehicle isCalibrationDone]` | `0xbaf4` | 是否已标定 | 未实现 |

我上一轮甚至把 `startCalibration` 误当成 `0x0C` 的来源 —— 那只是把"转发调用"
当成了"底层会发 0x0C"，属于没有证据的假设，已作废。

### 修复方向（三步，按可行性排序）

**① 静态补齐（可做，需继续反汇编）**
- 反汇编 `0x4880` 的下游：`[self.device startCalibration]` 究竟走哪条命令
  （`IBDevice` 的 delegate 是 `IBMessageManager`，可从 `didMessageToSend:toDevice:` @`0x7108` 反推）
- 反汇编 `0xa41c` 的 `x19` 参数结构，确认写进 UserDefaults 的是什么类型
  （`intValue` 说明它至少可转 Int）

**② 半自动标定（不依赖反汇编，可立即做）**
用户拿着手机在车旁走一圈，App 记录 `distance` 的最大/最小值，
取中位数作为 `areaThreshold` 写入 `UserDefaults["<cidpu>_CALIBRATION"]`（自定格式）。
**这不是原 App 行为，属于补充方案，必须在 UI 上标明。**

**③ 手动触发（当前的安全降级）**
不自动判定，改为用户点「启动预认证」按钮直接发 `0x0C`。
默认保持关闭，避免后台误发帧。

### 验证步骤

1. 未标定时启动 App → 日志应出现一次
   `⚠️ RSSI 未标定（calibration/leaveOffset 缺失）：被动进入不会自动启动`
2. 界面「点火位置验证」应显示 **未标定**，而不是"未验证"
3. 打开「预认证保活」开关 → 日志应出现
   `进入被动启动区域 → launchPrehautentification` **不应出现**（因为未标定）
4. 若手动设 `areaThreshold = 1e-5` 再走同一流程 → 第 3 步的日志应出现，
   且随后发出 `03 …0C`

---

## 缺失 2：`leaveOffset` 的写入点未定位

### 现状

- getter `-[IBVehicle leaveOffset]` @`0xbcec`、setter @`0xbcfc` 都存在
- ivar：`_OBJC_IVAR_$_IBVehicle._leaveOffset` @`0x28014`
- 但**找不到谁调用 `setLeaveOffset:`** —— 用 capstone 扫描全部 `ldr` 引用
  `#0x276a8`（leaveOffset 的 selref）返回空列表

### 影响

判定式 `cmp w25, (calibration - leaveOffset)` 的第二个操作数缺失，
`PassiveStartJudge` 无法照抄原式。

### 原因

`setLeaveOffset:` 很可能是通过 **`setValue:forKey:`（KVC）** 或
**`objc_msgSend` 的动态 selector** 调用的，静态 `ldr` 扫描抓不到。

### 修复方向

1. 扫 `__objc_methname` 里是否有 `setLeaveOffset:`，再反查 `__objc_selrefs` 的引用计数
2. 或者：在 `didCalibrationCompleted:` @`0xa41c` 里找 `x19` 的字段拆解，
   `leaveOffset` 可能就是标定结果对象的一个 key
3. 兜底：若两者都取不到，就按缺失 1 的方案 ②/③ 处理

### 验证

反汇编 `0xa41c` 中 `x19` 到 `setLeaveOffset:` 之间是否存在 `objc_msgSend` 且
selector 来自变量（而非 `ldr #imm`）。若有，则确认是动态派发。

---

## 缺失 3：判定式中 `w25` 的来源

### 现状

`0xb030: cmp w25, w8`，`w8 = calibration - leaveOffset`。
`w25` 在 `0xafc0` 之前的整数运算链里产生，只追到 `0xafc8 @selector(intValue)` 附近。

### 影响

即使拿到 `calibration`/`leaveOffset`，比较的左操作数仍不确定，
无法判断是"当前距离"还是"某次采样"还是"RSSI 原值"。

### 修复方向

从 `0xac04` 入口按寄存器数据流逐条走 `w25` 的 def-use 链，
重点看 `0xaf00`–`0xafc0` 之间是否出现 `sub`/`mov` 自某个 `intValue`。

### 验证

若 `w25` 最终来自 `[self RSSI1].intValue`，则可写成一个完整可复现的判定式；
若是某个中间量，则仍按缺失处理。

---

## 缺失 4：`05` 帧 19 字节的字段含义

### 现状

`-[IBMessageManager performActionBasedOnPayloadType:andData:]` @`0x101a0`：

```objc
case 5:
    NSLog(@"Message 5 received");
    break;              // ← 没有任何解析
```

所以 `IBVehicleState` 现在只是字节容器：

```swift
public struct IBVehicleState: Sendable, Equatable {
    public var raw: [UInt8] = []
    public var hexDescription: String { FrameCodec.hexString(raw) }
}
```

### 预期 vs 实际

| | 预期 | 实际 |
|---|---|---|
| 用户看到 | 车速锁状态 | 「最近一次成功动作」+ 原始 05 帧 hex |
| 数据来源 | 广播解密（`parseStatus:`） | 广播数据不足 36B，走不到 |

### 原因

原 App 的锁状态来自**广播解密**（`parseBroadcastData:`），
要求厂商数据 ≥36 字节；实测只有 19 字节，所以原 App 在你的车上也拿不到。
`05` 帧本身没有解析代码，任何字段映射都只能是编造。

### 修复方向

1. **保持现状**（推荐）：不解析，界面显示「最近动作」，这与原 App 行为一致
2. 若一定要显示锁状态：需要一份 ≥36 字节厂商数据的广播抓包，
   再用 `parseBroadcastData:` 的切分（`[4] status / [5] oemID / [6] doors / [7] power`）验证

### 验证

`VehicleStatus.isLocked` 现在取 `bit0`（`parseStatus:` 的 `bin[7]`），
但**这条路径不会被 `05` 帧调用**。自检 `testVehicleStatusBits` 只验证取位逻辑，
不代表真车可用 —— 这一点已在注释里写明。

---

## 缺失 5：被动启动成功后车端的动作

### 现状

`launchPassiveEntryCommands` @`0xb54c` 只做：

```objc
if (self.isDisconnected) [self openConnectionWithPassiveStart];
else [self performSelector:@selector(openConnectionWithPassiveStart) withObject:self afterDelay:1.0];
```

`openConnectionWithPassiveStart` @`0xb5a8` 只发 `0x0C`。

**原 App 不发 `lock`/`unlock`。** 开锁由车端完成，App 内无对应实现。

### 影响

没有"靠近自动解锁"这个功能 —— 这不是漏做，是原 App 本来就没有。
本项目此前自造的 `PassiveEntryController`（自动 unlock/lock）已删除。

### 修复方向

不需要修。若产品上确实想要"靠近自动解锁"，那属于**新增功能**，
必须明确标注为非原 App 行为，且默认关闭。

### 验证

全仓搜索 `onAutoCommand` 应无结果（已删除）。

---

## 缺失 6：`0x55`（`startPairing`）未实现

### 现状

`-[IBVehicle startPairing]` @`0xa350` → `openConnexionForCommand:0x55`
（`0xa37c: mov w2,#0x55`，且在 `0x4a84` 有 `cmp w21,#0x55` → 30 秒超时特殊处理）。

当前 `InBluePairing` 只发 `0x0D`，未发 `0x55`。

### 为什么暂时不补

抓包 `btsnoop_ctl_20261004_210011.log` 的第一帧就是 `0x0D`（37B），
车端直接回 `0x0E`（20B），**没有 `0x55`**，且配对成功。

说明 `0D → 0E` 是可行的最小路径，`0x55` 可能是"重新进入配对模式"或
"配对模式保活"，不是必需。

### 修复方向

若要 100% 覆盖原 App 行为，应在 `0D` 之前发一次 `0x55`：

```swift
// 依据：-[IBVehicle startPairing] @0xa350 → mov w2,#0x55
// 注意 openConnexionForCommand: 对 0x55 用 30 秒超时（0x4a84 cmp w21,#0x55）
```

但**必须先确认 0x55 不会让车端退出配对模式**，否则会破坏当前可用的流程。

### 验证

在真车抓包中观察：发 `0x55` 后车端是否仍接受 `0x0D`。

---

## 缺失 7（环境，非代码）：UI 层无法类型检查、无法运行

### 报错原文

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found for macro 'State()';
'/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/bin/swift-plugin-server'
produced malformed response
```

### 影响

- 5 个 UI 文件只做了 `swiftc -parse`（语法检查），**没有类型检查**
- 无法在模拟器/真机运行，因此"点击按钮 → 发帧"这条端到端路径**从未实际执行过**

### 原因

`swift-plugin-server` 一启动就被 SIGTERM（本机 Xcode 工具链问题），
`@State` 等宏无法展开；CoreSimulator 版本也落后于 SDK。

### 修复方向

1. 在 Xcode GUI 里打开工程直接 ⌘B（GUI 使用不同的插件加载路径）
2. 若仍失败：`xcodebuild -runFirstLaunch`，或重装 Command Line Tools
3. 升级 Xcode 到与 SDK 匹配的版本

### 验证

```
xcodebuild -project GKUIBleKey.xcodeproj -scheme GKUIBleKey \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```
出现 `BUILD SUCCEEDED` 即通过。

---

## 汇总

| # | 缺失项 | 严重度 | 能否静态补齐 | 当前处理 |
|---|---|---|---|---|
| 1 | RSSI 标定链 | **高**（被动进入失效） | 部分可以 | 显式标"未标定"，不假装工作 |
| 2 | `leaveOffset` 写入点 | 高 | 可能可以 | 同上 |
| 3 | 判定式 `w25` 来源 | 中 | 可能可以 | 同上 |
| 4 | `05` 帧字段 | 低 | **不能**（原 App 无代码） | 不解析，只显示原文 |
| 5 | 车端被动启动动作 | — | 不需要 | 原 App 也没有，已删除自造实现 |
| 6 | `0x55` 配对命令 | 低 | 可以 | 暂不补（抓包证明非必需） |
| 7 | UI 类型检查/运行 | 中 | 环境问题 | 仅语法检查，需在 Xcode 内 build |

**没有列在这里的，都是在二进制里能找到地址的。**
逐项地址见 `SOURCE_AUDIT.md`。

---

# 追加（20:20）：缺失 1/2/3 的追查结果

这一轮用「按 selref 地址全段扫描 + `ldr` 字面量解析」把前三个缺失追到了底。
结论：**其中两个可以关闭，一个只剩写入端。**

## 缺失 2 —— 已解决：`leaveOffset` 默认就是 32

`setLeaveOffset:` 的 selref 在 `0x27410`，全段扫描命中两处调用：

| 调用点 | 所在方法 |
|---|---|
| `0x791c` | `-[IBVehicle initWithKey:]` @`0x776c` |
| `0x880c` | `-[IBVehicle setModel:]` @`0x876c` |

`initWithKey:` 里的赋值（A 级）：

```asm
0x7898: mov x9, #0x403d000000000000   ; _timeBetweenPassiveStart = 29.0
0x78c8: mov w2, #0x1e                 ; [x0 numberWithInt:30]
0x78e4: bl  setApproachOffset:        ; approachOffset = 30
0x7900: mov w2, #0x20                 ; [x0 numberWithInt:32]
0x791c: bl  setLeaveOffset:           ; leaveOffset = 32
```

`setModel:` 里是 `0x87f0 ldr w2,[x23,#4]` —— 从车型结构体第 2 个 int 取值，
即不同车型可覆盖这两个默认值。

**已写入 `PassiveStartJudge.leaveOffset = 32` / `approachOffset = 30`。**

## 缺失 3 —— 已解决：`w25` 就是 `[[self rssisOneAndTwo] intValue]`

```asm
0xafac: bl   [self rssisOneAndTwo]   ; 0x27698
0xafcc: bl   [x0 intValue]           ; 0x27460
0xafd4: mov  x25, x0                 ; ★ w25 = rssisOneAndTwo.intValue
0xafdc: [self calibration] → intValue
0x00b008: [self leaveOffset] → intValue
0x00b02c: sub  w8, w22, w0           ; calibration - leaveOffset
0x00b030: cmp  w25, w8
0x00b034: b.le 0xb230
```

`0xb230` 分支首条有效指令是 `0xb24c setIsInPassiveStartArea:` + `0xb250 mov w2,#0`，
即 **`≤` → 不在区域**。所以完整判定式是：

```
在区域内  ⟺  rssisOneAndTwo.intValue > (calibration.intValue - leaveOffset.intValue)
```

**已按此重写 `PassiveStartJudge.check`**，删除原来的 `distance <= areaThreshold`。

## 缺失 1 —— 部分解决：读的路径通了，写的路径仍缺

`calibration` 的读取链已实现（`AppModel.loadCalibration()`）：

```swift
// getCalibrationSavedValues @0xb83c：key = "<cidpu>_CALIBRATION"
let key = "\(cidpu)_CALIBRATION"
if let n = UserDefaults.standard.object(forKey: key) as? NSNumber {
    passiveStart.calibration = n.intValue
}
```

**仍然缺的是「写入端」**：谁发起标定、车端怎么回、`didCalibrationCompleted:` 的
`x19` 是什么类型。这三点没解决，用户就无法在本 App 里生成 `calibration`。

## 行为验证（新判定式）

```
  RSSI  calibration     基准     在区域?
   -30         None    -32     True
   -50         None    -32    False
   -30          -20    -52     True
   -50          -20    -52     True
```

未标定时基准是 `-32`，只有贴得非常近才触发 —— **这与原 App 的 `[nil intValue] = 0`
行为完全一致，不是本项目的退化**。之前"永远 false"的说法要修正：
原 App 未标定时同样几乎不触发，区别只在于它有标定流程去写这个值。

## 更新后的缺失清单

| # | 项 | 状态 |
|---|---|---|
| 1 | 标定链 | ⚠️ **读已实现，写仍缺** |
| 2 | `leaveOffset` | ✅ 已解决（=32） |
| 3 | 判定式 `w25` | ✅ 已解决（`rssisOneAndTwo.intValue`） |
| 3b | `rssisOneAndTwo` 内部加权 | ❌ 仍缺（现用两路均值近似） |
| 4 | `05` 帧字段 | ❌ 仍缺（原 App 无代码） |
| 5 | 车端被动启动动作 | — 不需要 |
| 6 | `0x55` | ❌ 未实现（抓包证明非必需） |
| 7 | UI 类型检查 | ❌ 环境问题 |

---

# 追加（20:24）：按目录结构重新检索的结果

上一轮只搜了二进制。这一轮按「目录 → 配置 → 资源 → 代码」的顺序重查，
找到一批此前完全没看到的东西。

## 新找到的位置与内容

### ① `ExDigitalKeySDK.bundle/zh-Hans.lproj/Localizable.strings`

**原 App 唯一成体系的错误码表**，此前完全没利用：

| 前缀 | 数量 | 例子 |
|---|---|---|
| `error_sdk_*` | 24 条 | `40001` 控车指令重发次数已满 / `30002` 通信秘钥错误 |
| `error_20xx`–`22xx` | 100+ 条 | `2007` 请挂到 P/N 档位 / `2015` 钥匙在车内 |
| `error_70xx` | 8 条 | `7017` 预约充电失败 |

同时暴露了两套命令编号：

```
auth_Cmd_Control_Req_1..8  → 闭锁/解锁/关窗/开窗/关后备箱/开后备箱/寻车/预授权引擎
auth_Cmd_Req_1..5          → 连接确认/特征交换/身份认证/DK传输验证/会话密钥协商
auth_Cmd_Req_256           → 控车指令
auth_Cmd_Rsp_256/257/258   → 发送返回 / 执行结果 / 车辆状态
```

**已落地**：`Sources/Protocol/ErrorCodeTable.swift`（SDK 层 24 条 + 业务层 30 条），
并把 `04` 结果码的解释改为「只认 `0x00`，其余不编语义」。

### ② 8 个动作与 InBlue 命令的对应关系

`auth_Cmd_Control_Req` 是**上层抽象**，InBlue 的 `0x03` 是**开关合一**：

| 抽象层 | InBlue 命令 | 说明 |
|---|---|---|
| Req_1 闭锁 | `0x01` | |
| Req_2 解锁 | `0x02` | |
| Req_3 关窗 | `0x04` | |
| Req_4 开窗 | `0x05` | |
| Req_5 关后备箱 / Req_6 开后备箱 | `0x03`（同一个） | `openCloseTrunk` 是切换语义 |
| Req_7 寻车 | `0x06` | |
| Req_8 预授权引擎 | `0x0C`（预认证） | 见下方说明 |

Req_8「预授权引擎」在 InBlue 里没有同名方法，唯一语义相符的是
`launchPrehautentification` → `0x0C`（日志字面量 `"send prehauthentification command"`）。
**这一条属于语义匹配，不是直接证据，仍标为待确认。**

### ③ 标定命令不在 InBlue 的 `01/02/03` 体系里

`-[IBDevice startCalibration]` @`0x4880` 只做两件事：

```asm
0x4938: setDelegate:self
0x4968: ldr x1, #0x27218 ; @selector(startCalibration)
0x496c: bl  _objc_msgSend        ; [self.device startCalibration]
```

`self.device` 是底层 BLE 封装，**不是 IBDevice 自己**。
同理 `device:didCalibrationIsDone:error:` @`0x6208` 只是把结果转发给
`IBVehicle` 的 `didCalibrationCompleted:error:` @`0xa41c`。

全段扫 selref `didCalibrationIsDone:error:` **无命中** —— 说明它由底层用
动态 selector 回调，静态抓不到。

**结论**：标定走的是底层 BLE 协议（GLBLE 那一套），不是 InBlue 的 AES 挑战链。
要完整实现标定，等于要再实现一套 GLBLE 协议；而那套协议在本车的抓包里
**从未出现过**（抓包全是 01/02/03）。

### ④ `.conf.ibcx`（48 字节）

App 根目录下的隐藏文件：

```
3d 2e 31 6a 68 7c 18 6e 18 19 19 18 6f 65 1a 69 ...
```

试过 256 个单字节 XOR，无一个能出可打印文本；也不像 base64/plist。
**暂未解码**，不确定是否与蓝牙相关。

### ⑤ 车辆状态在上层用的是另一套模型

主 App 里有 `CarStatusModel` / `CarStatusDataModel` / `CarStatusClimateModel` /
`CarStatusServiceResultModel` 等类。命名里的 `ServiceResult` 表明这是
**TSP（云端）** 的模型，与 BLE 的 `05` 帧不是同一条通道。

这也解释了为什么 `05` 帧在 InBlue 里只有 `NSLog`：状态本来就不从这里来。

## 更新后的缺失清单

| # | 项 | 状态 | 说明 |
|---|---|---|---|
| 1 | 标定链 | ⚠️ 读已实现 | 写入端跨 GLBLE 协议，本车抓包无该协议 |
| 2 | `leaveOffset` | ✅ 关闭 | = 32（`0x7900`） |
| 3 | 判定式 `w25` | ✅ 关闭 | `rssisOneAndTwo.intValue` |
| 3b | `rssisOneAndTwo` 加权 | ❌ | 现用两路均值近似 |
| 4 | `05` 帧字段 | ⚠️ **不是缺失** | 原 App 就不从 05 取状态，走 TSP |
| 5 | 车端被动启动动作 | — | 原 App 也没有 |
| 6 | `0x55` | ❌ | 抓包证明非必需 |
| 7 | UI 类型检查 | ❌ | 环境 |
| 8 | 错误码文案 | ✅ **已补** | 24 + 30 条，来自 Localizable.strings |
| 9 | `.conf.ibcx` | ❌ | 未解码，相关性未知 |
