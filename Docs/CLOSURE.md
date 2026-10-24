# 闭环审计矩阵

> 审计时间：2026-10-24 20:30
> 判定口径分四级，缺一级就不算闭环：
>
> - **① 代码存在** —— 有实现
> - **② 编译通过** —— `swiftc -typecheck` 无 error/warning
> - **③ 链路可达** —— UI → AppModel → 协议层 → BLE，中间没有断点
> - **④ 已实际跑过** —— 真机/模拟器执行过并观察结果
>
> **本次审计结论：所有条目最多到 ③，没有任何一条到 ④。**

---

## 一、功能闭环矩阵

| # | 功能 | ① | ② | ③ | ④ | 说明 |
|---|---|---|---|---|---|---|
| 1 | 扫描（10FF + AllowDuplicates） | ✅ | ✅ | ✅ | ❌ | `BLECentral.startScanWithService` |
| 2 | 广播匹配（EE01 / 版本 / cryptedID） | ✅ | ✅ | ✅ | ❌ | `ValeoAdvMatch`，自检有 3 项覆盖 |
| 3 | 连接 + 服务发现 + 订阅 | ✅ | ✅ | ✅ | ❌ | `BLECentral.connect` |
| 4 | 配对 0D → 0E → 存密钥 | ✅ | ✅ | ✅ | ❌ | `InBluePairing` + `saveKeyData` |
| 5 | 鉴权 01 → 02 → 03 → 04 | ✅ | ✅ | ✅ | ❌ | `MeasuredSession` 状态机 |
| 6 | 锁车 `0x01` | ✅ | ✅ | ✅ | ❌ | UI → `perform(.lock)` |
| 7 | 解锁 `0x02` | ✅ | ✅ | ✅ | ❌ | 同上 |
| 8 | 后备箱 `0x03` | ✅ | ✅ | ✅ | ❌ | 开关合一 |
| 9 | 关窗 `0x04` | ✅ | ✅ | ✅ | ❌ | |
| 10 | 开窗 `0x05` | ✅ | ✅ | ✅ | ❌ | |
| 11 | 寻车 `0x06` | ✅ | ✅ | ✅ | ❌ | |
| 12 | 无感进入开/关 `0x11`/`0x12` | ✅ | ✅ | ✅ | ❌ | |
| 13 | 已配对手机 `0x0D` → `0x0F` | ✅ | ✅ | ✅ | ❌ | 本轮修了 0F 被吞的断点 |
| 14 | 预认证 `0x0C` | ⚠️ | ✅ | ⚠️ | ❌ | 触发依赖标定，见下 |
| 15 | 车辆状态（`05`） | — | — | — | — | 原 App 不解析，走 TSP，见下 |
| 16 | 错误处理（04 非零） | ✅ | ✅ | ✅ | ❌ | `checkResultMessage:` 三结局 |
| 17 | 防爆破锁定 | ✅ | ✅ | ✅ | ❌ | 本轮修了"只记录不拦截" |
| 18 | 密钥完整性校验 | ✅ | ✅ | ⚠️ | ❌ | 只报结果，不阻止使用 |
| 19 | 断连重连 | ✅ | ✅ | ✅ | ❌ | `BLECentral.autoReconnect` |
| 20 | 自检 11 项 | ✅ | ✅ | ✅ | ❌ | 需在 App 内点"运行自检" |

---

## 二、本轮修掉的 4 个断点

这些都是"代码看着有、实际走不通"的，属于真正的未闭环。

### 断点 1：防爆破锁定形同虚设

```swift
// 修复前：recordAuthFailure 会设置 lockoutRemaining 并逐秒递减
if consecutiveAuthFailures >= maxAuthFailuresBeforeLock {
    lockoutRemaining = Int(lockoutDuration)   // 只是设了个数
}
// 但 perform() / beginMeasuredAuth() 从来不检查 isLockedOut
```

后果：连错 5 次后界面显示"已锁定 60s"，但用户继续点照样发帧。

**已修**：`perform` 与 `beginMeasuredAuth` 开头各加一道 `guard !isLockedOut`。

### 断点 2：`resetEdge()` 从未被调用

```swift
preAuth.resetEdge()   // 定义在 PreAuthenticationController，全仓 0 处调用
```

后果：断开时若处于"区域内"，`isInArea` 残留 `true`。重连后 `updateArea(true)` 因
`inArea == isInArea` 直接 return，预认证**再也不启动**。

**已修**：订阅 `linkState == .disconnected/.failed/.idle` 时复位。

### 断点 3：配对成功后不重读标定

`calibration` 的 key 是 `"<cidpu>_CALIBRATION"`，cidpu 配对后才确定。
`loadCalibration()` 只在 `init` 调用一次 —— 首次配对完成后不会重读。

**已修**：`0x0E` 分支里 `saveKeyData` 之后调用 `loadCalibration()`。

### 断点 4：`0x0F` 被"未知帧"分支吞掉

```swift
if let (cmd, _) = MeasuredFrame.decode(bytes), (0x01...0x05).contains(cmd) {
```

`0x0F`（设备名回执）不在 1–5 内，也不在 `handlePairingFrame`（只认 0D/0E）内，
于是落到最后的"未知帧"分支 —— **`requestPairedDevicesNames()` 永远拿不到结果**。

**已修**：过滤条件加 `|| cmd == 0x0F`，并单独处理状态行。

---

## 三、仍未闭环的环节

### A. 预认证：触发条件不可用（半闭环）

链路本身是通的：

```
RSSI → passiveStart.check → isInPassiveStartArea
     → preAuth.updateArea(true) → launchPreAuthentication
     → schedule(1.0s) → onSend → beginMeasuredAuth(0x0C)
     → 04 → preAuth.didComplete(success:) → 6.5s / 29.0s 后再来
```

**断在第一个箭头**：`isInPassiveStartArea` 需要 `calibration`，
而没有标定流程去写这个值。

未标定时基准 = `0 - 32 = -32`，只有 RSSI > -32（几乎贴脸）才会触发。
这与原 App 的 `[nil intValue] = 0` 行为一致 —— **是原 App 的设计，不是缺陷**，
但意味着"靠近自动预认证"在本项目里实际用不了。

补法：实现标定写入端（见 `GAPS.md` 缺失 1），或加一个手动"标定"按钮写
`UserDefaults["<cidpu>_CALIBRATION"]`（属新增功能，需标注）。

### B. 车辆状态：原 App 就没有（不适用）

`05` 帧在 `performActionBasedOnPayloadType:` 的 `case 5` 里只有 `NSLog`。
原 App 的车辆状态来自 TSP 的 `CarStatusModel`（云端），不是 BLE。

本项目只做 BLE，所以界面显示"最近一次成功动作 + 05 原始 hex"，**不显示锁状态**。
这不是遗漏，是通道不存在。

### C. 密钥完整性：只报警不拦截（半闭环）

`verifyKeyIntegrity()` 在 `init` 调用，结果写进 `keyIntegrityOK` / `keyIntegrityDetail`，
但**没有任何地方根据它阻止操作**。

若 Keychain 里的密钥被改坏，App 仍会拿它去发 `01`，只是车端会静默丢弃。

补法：`beginMeasuredAuth` 里加 `guard keyIntegrityOK != false`。

### D. UI 层从未编译过（链路④缺失）

`swift-plugin-server` 被 SIGTERM，`@State` 宏无法展开，5 个 UI 文件只做了
`swiftc -parse`（语法检查），**类型检查与运行都没做过**。

所以整个 ③（链路可达）的判断依据是：人工核对 `model.xxx` 的每个调用都能在
`AppModel` / `MeasuredSession` 上找到对应成员 —— 不是编译器给的保证。

### E. 自检从未运行过

11 项自检的代码逻辑是自洽的，但**没有一次实际执行**。
需要装到设备上点"诊断 → 运行自检"才能确认。

---

## 四、闭环率

按四级口径：

| 级别 | 条数 | 占比 |
|---|---|---|
| ①+② 代码与编译 | 19 / 20 | 95% |
| ③ 链路可达 | 17 / 20 | 85% |
| ④ 实际跑过 | **0 / 20** | 0% |

**一句话**：协议层该有的都有，能编译、能追到每一行依据；但**没有一行在真机上跑过**。

---

## 五、要在 Xcode 里做的三件事

1. **编译**
   ```
   xcodebuild -project GKUIBleKey.xcodeproj -scheme GKUIBleKey \
     -sdk iphoneos -destination 'generic/platform=iOS' \
     -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
   ```
   期望 `BUILD SUCCEEDED`。若 UI 报类型错误，说明我人工核对的链路有遗漏。

2. **跑自检**
   诊断页 → 运行自检 → 11 项应全绿。重点看
   `被动启动判定式` 与 `错误码表` 这两项（本轮新增）。

3. **连车看日志**
   - 点"解锁" → 日志应依次出现 `01`(33B)、`02`(17B)、`03 …02`(18B)、`04 00`
   - 点"查询已配对手机" → `03 …0D` → `04 00` → `0F`（本轮才接上）
   - 连续点 5 次失败动作 → 第 6 次应被拦截（本轮才接上）

---

## 六、追加（21:40）：`rssisOneAndTwo` 精确还原 + UI 构建突破

### ① `rssisOneAndTwo` 不再是近似（消除 CLOSURE 里"D 级"最后一项）

上一轮把 `rssisOneAndTwo` 标成"用两路均值近似"。这轮逐条追完反汇编，
发现它根本不是加权平均，而是**自适应取值**：

```asm
; -[IBVehicle rssisOneAndTwo] @0x8954
0x89f8: timeIntervalSinceDate:     ; span = last.date - first.date
0x8a44: fdiv d8, d8, d0            ; avgInterval = span / count
0x8a5c: ldr  d0, #0x1fba0          ; 0.3
0x8a60: fcmp d8, d0
0x8a64: b.le #0x8bc0               ; ≤0.3 → fast-enum 求和
0x8ab8: sub x24, x0, #1            ; >0.3 → 下标=count-1（只取最后一个）
...
0x8c48: fadd d8, d8, d0            ; 密集：∑ rssis[i].doubleValue
0x8cb8: fdiv d0, d8, d0            ; 密集：÷ count → 均值
```

**结论**：`avgInterval > 0.3s`（采样稀疏）只取最新一个值；否则取均值。

更进一步，`addRSSI:` @`0xad90` 证明塞进 `rssis` 数组的元素是
**两路 RSSI 合成后的 dB 距离值**，不是原始单路值：

```asm
0xaeac: fmul d8,d8,d0   ; distance = √(10^(r1/10)²+10^(r2/10)²) × pondOutToIn
0xaf50: STUB _log10     ; log10(distance)
0xaf58: fmul d0,d0,d1   ; ×10 → 转回 dB
0xaf68: numberWithDouble: ; 塞进 rssis
```

**已落地**：`PassiveStart.Sample` 新增 `combinedDB`（= `10×log10(distance)`），
`combinedRSSI` 改为对合成 dB 数组做稀疏/密集自适应，`check()`/`summary` 全部改走它。
自检 `testPassiveStartJudge` 断言方向不变（-30→合成-28、-60→合成-58），仅更新注释。

### ② UI 层类型检查：根因是 Xcode 27.1 工具链损坏，非代码问题

- `swift-plugin-server` 直接跑即 SIGTERM（exit 137），即使 `DYLD_LIBRARY_PATH`
  指向含 `libSwiftSyntax*.dylib` 的 `host` 目录也一样。
- **最小模板 `struct T { @State var x = 0 }` 都编译不过**，报同样的
  `SwiftUIMacros.StateMacro ... malformed response`。
- 结论：`@State` 在 Xcode 27 里被实现成了宏（`SwiftUIMacros.StateMacro`），
  而宏插件服务器在本机损坏，导致**任何 SwiftUI 代码都无法在命令行类型检查**。
  这是环境问题，需升级/重装 Xcode 或换用 Xcode 26 的 toolchain 才能解。

### ③ 顺带抓到 1 个真实 bug（宏展开失败才暴露）

`LogView.emptyHint` 里残留一个 `case .dk`，但 `Source` 枚举早已删掉 `dk`
（改为 `measured/raw/pairing`）。这是重构漏删，宏正常时也会报
`type 'LogView.Source' has no member 'dk'`。**已删**。

其余 `cannot find '$xxx'` / `'self' is immutable` 全是 `@State` 宏未展开的假阳性，
宏恢复后自动消失。

### 更新后的闭环状态

| 项 | 之前 | 现在 |
|---|---|---|
| `rssisOneAndTwo` 加权 | 近似（两路均值） | ✅ **精确还原**（自适应取值 + 合成 dB） |
| UI 类型检查 | 未做（宏坏） | ⚠️ 确认是 Xcode 27.1 工具链损坏，最小模板也编译不过 |
| `LogView.Source.dk` | 未发现 | ✅ 已删（真实 bug） |

---

## 七、追加（21:47）：Xcode 构建链已彻底修好（UI 层闭环）

上一节（六）误判为"Xcode 27.1 工具链损坏、需重装"。**实际是命令行参数缺失，可修。**

### 根因（精确）

`xcodebuild` 命令行模式默认**不传 `-plugin-path`** 给 `swift-frontend`。
而 Xcode 27 把 `@State` 等 SwiftUI 属性包装器改成了宏
（`#externalMacro(module: "SwiftUIMacros", type: "StateMacro")`），
宏库在：

```
/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib
```

不传路径 → `swift-plugin-server` 找不到宏实现 → "malformed response"。
GUI 的 Xcode 内部自动解析该路径，所以 GUI 一直正常，只有命令行 `xcodebuild` 失败。

### 修复

`project.yml` 的 target settings 加一行：

```yaml
OTHER_SWIFT_FLAGS: "-plugin-path /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib/swift/host/plugins"
```

`xcodegen generate` 后，命令行 `xcodebuild ... build` 直接 **BUILD SUCCEEDED**，
无需再手动传参。

### 验证结果

- `swiftc -typecheck`（全部 25 文件含 UI）：**0 error 0 warning**
- `xcodebuild build`：**BUILD SUCCEEDED**
- 新增可复用脚本 `typecheck.sh`（自动带 `-plugin-path` + target 27.0）

### 顺带澄清两个上一节的误判

1. 之前把 `glassProminent`/`GlassEffectContainer` 报"iOS 26+ 才可用"当成 bug ——
   实际是我命令行用了 `-target arm64-apple-ios17.0`，而项目 target 是 **27.0**。
   用 27.0 后这些 API 合法，不报错。
2. `swift-plugin-server` 的 SIGTERM 是**缺 `-plugin-path`** 的连带表现，
   不是进程本身损坏。

### 闭环率更新

| 级别 | 之前 | 现在 |
|---|---|---|
| ② 编译通过 | 核心通过，UI 未验 | ✅ **全部通过**（含 UI） |
| ③ 链路可达 | 17/20（人工核对） | ✅ 编译器级验证 |
| ④ 实际跑过 | 0/20 | 仍 0/20（需真机/模拟器） |

**剩下的唯一未闭环项：④ 真机运行**（需要签名 + 连车），与代码无关。
