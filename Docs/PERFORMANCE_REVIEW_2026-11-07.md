# 性能与调度审查

日期：2026-11-07　范围：GKUIBleKey v9.11
触发：用户提问「有性能调度方面的问题吗」

---

## 摘要

找到 **3 个真实问题**，全部已修。前两个的根因相同：
**一个 2 Hz 的数据流被接到了 0.5 Hz 的界面上，中间靠"全量重绘"当桥。**

| # | 问题 | 量级 | 状态 |
|---|---|---|---|
| P1 | `lastBluetoothStatusAt` 每帧 `@Published` → 全界面每秒重建 2 次 | 每天 17 万次全量重绘 | 已修 |
| P1 | RSSI 看门狗每帧创建/销毁一个 Task | 每天 17 万次 Task 创建 | 已修 |
| P2 | 匹配日志每帧写盘 | 每天 17 万行、约每 4 小时轮转一次 | 已修 |

---

## 一、数据流的上游：2 Hz

整条链的源头是车端广播：**0.5 秒一帧**（`AllowDuplicates` 生效时）。

```
车端广播 0.5s/帧
  ├─ BLECentral.didDiscover        → ValeoAdv 解析
  │    ├─ rssi (@Published)        → 只在订阅了 ble 的视图重绘
  │    ├─ 匹配日志 (写盘)           ← 问题 3
  │    └─ onDualRSSI               → 靠近解锁判定（0.4 秒节流，正常）
  ├─ onBroadcastStatus             → MeasuredSession.updateVehicleStatus
  │    └─ status (@Published)      → AppModel 的 sink
  │         ├─ lastBluetoothStatusAt = Date()   ← 问题 1
  │         └─ refreshLiveActivity()            (2 秒节流，正常)
  └─ rssi 看门狗                    ← 问题 2
```

---

## 二、问题详情

### P1-1 `lastBluetoothStatusAt` 每帧发布 → 全界面重建

**位置**：`AppModel.swift:412`（赋值）、`:167`（声明）

```swift
measured.$status
    .sink { [weak self] status in
        guard let self, status != nil else { return }
        self.lastBluetoothStatusAt = Date()   // ← 每帧
        self.refreshLiveActivity()            // ← 内部有 2 秒节流，这个没问题
    }
```

`lastBluetoothStatusAt` 是 `@Published`。每次赋值 → `AppModel.objectWillChange`
→ 所有 `@EnvironmentObject var model: AppModel` 的视图重建。

**RootView 的重建成本**：车图（`CarModelView`，含状态动画）+ 10 个控制按钮 +
能源条 + 顶栏 + 卡片。每秒 **2 次**。开着 sheet 时密钥页/日志页/诊断页也一起重建。

**真正糟糕的地方**：界面**从来不直接读它**。

| 读取方 | 用途 |
|---|---|
| `AppModel:238` | `bluetoothLinkAliveRaw` 的内部判断 |
| `AppModel+Cloud:58` | `bluetoothStatusTime` 的兜底值 |

界面显示时间走的是 `activeStatus.source.at`，而顶栏那行只精确到**分钟**（`hh:mm`）。

也就是说：**为了一个分钟精度的文字，每 0.5 秒重建一次整个界面。**

**修复**：
1. 去掉 `@Published`（保留精确值供内部判断）
2. 顶栏 RSSI 抽成独立的 `RSSIPill`，自己订阅 `BLECentral` —— 它的 2 Hz 只重绘一个胶囊
3. 顶栏那行「钥匙就绪 · HH:MM」由已有的 0.5 秒循环按**分钟变化**推 `onlineTick`

**效果**：全量重绘从每秒 2 次降到每分钟最多 1 次（约 120 倍）。

> **一个隐藏依赖**：RSSI 原来能刷新，靠的正是这个"每帧全量重绘"——
> RootView 只订阅了 `AppModel`，**收不到 `BLECentral` 的 `objectWillChange`**。
> 所以不能单独去掉 `@Published`，必须先让 RSSI 独立订阅。
> 这是典型的「搭便车」：一个高频副作用在无意为另一个高频需求供电。

### P1-2 RSSI 看门狗每帧创建 Task

**位置**：`BLECentral.swift:515`（原 `armRSSIWatchdog`）

```swift
if hit {
    rssi = rssiValue
    armRSSIWatchdog()      // ← 每帧
}

private func armRSSIWatchdog() {
    rssiWatchdog?.cancel()                    // 取消旧 Task
    rssiWatchdog = Task { @MainActor ... }    // 新建一个睡 120 秒的 Task
}
```

每帧：cancel 一个挂起的 Task + 新建一个。**每秒 2 次、每天 17 万次**，
为的只是一次「现在 - 上次更新 > 120 秒？」。

**修复**：删掉 Task，改成 `purgeStaleRSSI()` —— 由 `AppModel` 那个本来就在跑的
0.5 秒循环调用。零额外调度开销。

**为什么原来要写 Task**：这是一个常见的误用 —— 把"到点做某事"直觉地写成定时器，
但这里的语义其实是「**读的时候判断是否过期**」，不是「到期时主动清空」。
后者需要 17 万个定时器，前者只需要一次比较。

### P2 匹配日志每帧写盘

**位置**：`BLECentral.swift:1313`

```swift
if let adv {
    FileLogger.shared.debug("匹配：\(adv.genLabel) ... cryptedID=\(...) ...", module: "匹配")
}
```

每帧执行：字符串插值 + `cryptedID.map { String(format:) }` +
`configLock` 加锁 + 队列投递 + 落盘。

- 每天 **17 万行**
- 单文件上限 2 MB → 约每 4 小时轮转一次
- `LogConfig.minimumLevel` 默认是 `.debug`，所以**默认就全写**

**修复**：10 秒节流，且判断放在字符串拼接**之前**（否则只省 IO，格式化照付）。

> 这行日志的价值是「确认匹配到了本车」，一旦确认，重复记录没有新信息 ——
> 和之前修过的「一次会话 58 条里 24 条是同一份状态」是同类问题。

---

## 三、检查过但没有问题的

| 项 | 结论 |
|---|---|
| 0.5 秒链路存活循环 | 只在翻转时写 `@Published`，设计正确（见下节权衡） |
| 5 秒在线重算 | 有 `guard` 前置，空转时不写状态 |
| `refreshLiveActivity` | 2 秒 / 5 秒双档节流，且节流**在 `activeStatus` 计算之前** |
| 日志级别过滤 | 在入队前（`log()` 开头），不产生字符串也不落盘 |
| `updateVehicleStatus` | 状态未变化时不记日志（早期已修） |
| 靠近解锁判定 | 0.4 秒节流，避开"一帧回调两次天线" |
| FileLogger 写盘 | 单串行队列，`DateFormatter` 已加锁 |
| 并发隔离 | `AppModel` / `MeasuredSession` / `BLECentral` 均 `@MainActor`；CoreBluetooth 默认主队列回调 —— 不存在跨线程改 `@Published` |
| Task 泄漏 | 两个常驻循环都有 `[weak self]` + `Task.isCancelled`，`AppModel` 释放时取消 |

---

## 四、有意识保留的（不是漏了）

### 4.1 0.5 秒循环在离线时仍全速

离线状态下每 0.5 秒唤醒一次主线程，只是比较一个布尔值 —— 但确实可以降到 2–3 秒。

**为什么没改**：`lastLinkAlive` 的更新依赖这个循环自身。放宽周期会让
「车连上了」的界面反馈最多延迟一个周期（3 秒）。用 3 秒延迟换一点电，
对车钥匙这种"每次上车都要看"的应用不划算。

真要优化，正确做法是把"离线→在线"的翻转改成事件驱动（广播触发），
而不是调周期 —— 那是独立一轮的改动。

### 4.2 `activeStatus` 每次调用分配一个结构体 + `[Bool]` 数组

`RootView` 里有 5 处 `model.activeStatus`，每次 body 求值都重新构造快照。

**为什么没改**：修完 P1-1 后，body 的重绘频率从 2 Hz 降到约 1 次/分钟，
每秒 10 次分配变成每分钟 5 次，已经不值得为它加缓存层
（缓存会引入"什么时候失效"的新问题）。

### 4.3 `LogConfig.minimumLevel` 默认 `.debug`

日常使用时 `debug` 会记录大量协议细节。

**为什么没改**：这个 App 的主要用途之一是排障，日志是唯一手段。
把默认降到 `.info` 会让用户遇到问题时第一手资料缺失。
更精准的做法是**逐条判断这条 debug 值不值得每帧记**（就是 P2 做的事），
而不是一刀切抬高级别。

---

## 五、给后续的调度原则

从这轮三个问题里提炼出的三条，值得写进 checklist：

1. **高频数据流不要经过 `@Published` 汇总对象。**
   2 Hz 的数据挂到全局状态上，等于让所有视图按 2 Hz 重建。
   让**需要它的那一个视图**去订阅数据源本身。

2. **"到点做某事"先问是不是"读时判断"。**
   过期清理、超时标记这类逻辑，大部分可以用「读的时候比较时间」实现，
   不需要每来一次数据就重置一个定时器。

3. **高频路径上的日志要同时管住格式化和 IO。**
   节流判断必须放在字符串拼接之前 —— 否则省下的只是写盘。

---

## 六、状态

- `typecheck` 0 error 0 warning（67 文件 / 21,831 行）
- `xcodebuild` BUILD SUCCEEDED
- **未装机**：设备不可达

真机验证时顺带可以看：

- 顶栏 RSSI 是否仍然 2 Hz 刷新（抽成独立视图后不应变慢）
- 顶栏「钥匙就绪 · HH:MM」的分钟是否还会跳
- 用 Instruments 的 SwiftUI 模板看 `View Body` 调用次数，应显著下降
