# 变更日志（CHANGELOG）

> 版本号采用 **0.1 步进**：每次对外发布 `CFBundleShortVersionString` +0.1，
> `CFBundleVersion`（构建号）每次构建 +1。

---

## v5.7（2026-10-29）—— 澄清：原 App 也不保持连接（附日志证据）

用户问：「车端不受理空闲连接，那原 App 是怎么保持连接的？」

**答案：它根本不保持。** `Docs/evidence/xiaoka_vcc.log` @06:25–06:30 连续 5 轮，
周期精确到 30 秒：

```text
06:25:14:339  Notification updated（订阅成功）
06:25:14:341  Data to send（33B = 01 帧）
06:25:14:540  Data received（17B = 02 挑战）
06:25:14:543  Data to send（18B = 03 帧）
06:25:14:626  Data received {0x0400}（04 成功）
06:25:14:631  Start scan          ← ★ 发完立刻恢复扫描
06:25:14:725  Data received {0x05…}（状态包）
06:25:14:828  device is disconnected   ← 连上到断开 0.7 秒
06:25:43:742  Stopping scan        ← 29 秒后
06:25:43:745  Request for connection
```

**原 App 的连接寿命也只有 0.5–0.7 秒。** 它靠三件事维持「钥匙在场」：

1. **扫描常开**
2. **每 30 秒连一次**，连上就发 `0x0C`，发完就任它断
3. 「钥匙在场」在车端有**足够长的有效期**（≥30 秒），所以不需要长连接

所以「车端不受理空闲连接」和「维持无感进入」并不矛盾 —— 原 App 从来没试图
保持空闲连接，它只是**每 30 秒准时打一次招呼**。

### 唯一找出的时序差异（已对齐）

原 App 在**收到 `04` 后就恢复扫描**（`06:25:14:631 Start scan`），
不等车端 0.2 秒后断开；我们原来要等 `didDisconnectPeripheral` 才恢复。

前台看不出区别，但 iOS 判定「后台是否仍在工作」时，**持续的 BLE 扫描是
最强的信号** —— 原 App 后台 30 秒节奏能稳定，和这个行为可能有关。

新增 `BLECentral.resumeScanIfNeeded()`（直接调底层扫描，**不碰 `linkState`**，
避免 `.ready` 被改成 `.scanning` 导致 `connectRemembered()` 误判重复 discoverServices），
在 `handleIncomingFrame` 收到 `04` 后调用。

### 这个改动不能解决什么

它**不能**让 App 免于被 iOS 挂起。后台挂起期间 29 秒的 `Task.sleep` 不推进，
这是平台行为。对齐它只是减少"被判定为不活跃"的概率，不是保证。

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- 待实测：日志里 `← 04 结果：成功` 之后应紧跟扫描恢复，且断开前仍有广播进来

---

## v5.6（2026-10-29）—— 「无感进入不可用」：开关是好的，断在「钥匙在场」没维持

用户报「无感进入不可用」。

### 先分清两件事

| | 由什么控制 | 现状 |
|---|---|---|
| **无感进入开关**（`0x11`/`0x12`） | 一次性命令，写进车端 | **正常**：17:30:52 下发成功，车端回 `04 00` |
| **「钥匙在场」的持续声明**（`0x0C`） | 预认证，每 29 秒一次 | **断了** —— 见下 |

拉门把手解锁要两者同时成立：功能开着 **且** 车端此刻认为钥匙在附近。
开关没问题，断的是后半段。

### 日志证据

```text
21:14:14.416  第 4 轮 0x0C 成功（04 00）
21:14:20.557  ⬇️ 进入后台
21:17:09.790  心跳#2：距上次 3 分 46 秒「中间被挂起过」
21:17:14.606  ⬇️ 又进后台
21:30:27.957  进程启动 #9：距上次存活 13 分 18 秒「中间被系统终止过」
21:30:33.295  用户点「准备点火」→ 预认证挂起（链路未就绪）
21:30:36.725  再点一次 → 又挂起
21:30:43.474  ⬇️ 进后台（此后再无预认证日志）
```

两个事实：
1. **后台 13 分钟被 iOS 终止进程**，期间预认证完全停摆 → 车端不再认为钥匙在场
2. **21:30 两次手动补发都挂在「链路未就绪」**，且之后没有任何「链路就绪」
   —— 连接根本没建立起来（当时手机大概率不在车旁）

### 修掉的漏洞：从后台回来不会自动续上

这是 v5.4 的副作用：断连不再清 `isInArea` 之后，从后台恢复时
`isInArea` 仍是 `true` → `updateArea(true)` 因 `inArea == isInArea`
直接 return → **预认证再也不会重新启动**。

新增 `PreAuthenticationController.resumeAfterSuspendIfNeeded()`，
在 `didBecomeActive` 时调用：只要「已启用 + 在区域内 + 没在跑」，立刻启动一轮。

### 必须说清的边界

iOS 后台挂起期间，29 秒的 `Task.sleep` **不推进**；进程被终止后更要从头冷启动。
所以「无感进入」不可能像原厂那样 7×24 可靠 —— 这是平台限制，不是代码问题。

现实可用条件是：**App 最近被打开过、且没被系统回收**。
真要做到「拉门把手就开」，得保持 BLE 长连接（车端又不接受空闲连接），
这条路在 iOS 上走不通。

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- 待实测：App 从后台回前台后，日志应出现
  `恢复到前台：预认证曾因挂起中断 → 立即续上` 紧跟一轮 `0x0C`

---

## v5.5（2026-10-29）—— 控制按钮不再变灰

用户报「控制按钮也会变灰」。

三处 `.opacity(isWriteReady ? 1 : …)` 全部移除：

| 位置 | 原来 | 观感 |
|---|---|---|
| 主控车按钮（解锁/锁车） | `1 : 0.7` | 轻微发灰 |
| 次要按钮（后备箱/车窗/寻车） | `1 : 0.55` | **接近禁用** |
| 「开始标定」 | `1 : 0.55` | 同上 |

### 为什么这是错的

灰掉的本意是「提示需要先连接」。但 v5.0 之后点它**真的有效**：
`perform` 会挂起动作 → 自动连接 → 就绪后执行。

**能点的按钮画成不能点，等于把功能藏起来。** 而且用户会得出「App 坏了」的结论，
而不是「需要先连一下」—— 这正是本次反馈。

现在：
- 按钮始终正常显示，点击一定有反馈（`statusLine` 已上主界面，见 v4.7）
- 连接状态只出现在**顶部胶囊**（未连接 / 连接中 / 已连接）—— 那才是它该在的地方
- 「开始标定」未连接时点它会弹明确原因（`calibHint`），比变灰更有用

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- 待实测：断开状态下所有控制按钮外观与连接时**完全一致**

---

## v5.4（2026-10-29）—— 「蓝牙不稳定」的真相：不是蓝牙，是我们自己每 5 秒重连一次

用户报「蓝牙连接还是不稳定」。

### 日志先给出一个好消息

21:14 的实测：**预认证已经完全跑通了**（v5.0 的修复生效）：

```text
21:14:03.796  send prehauthentication command（0x0C，#2）
21:14:03.809  准备预认证（控制码 0x0C）
21:14:03.811  → 01 CA E8 …（TX）
21:14:03.947  ← 02 挑战
21:14:03.948  → 03 … 0C（TX）
21:14:04.037  ← 04 结果：成功（00）「周期校准」   ← 车端认可了
21:14:04.037  预认证往返结束，29.0 秒后重试
```

对比 12:39 那次（`准备预认证` 0 次、`04` 0 次），这条链现在完整走通了。

### 但同一段日志里藏着「不稳定」的真因

```text
21:14:03.466  链路就绪
21:14:04.200  已断开（车端踢）
21:14:07.188  进入区域 → start        ← 3 秒后又来
21:14:09.297  已断开
21:14:12.408  进入区域 → start        ← 又是 3 秒
21:14:14.575  连续 5 次 3 秒内断开 → 暂停重扫 30 秒
```

**每 5 秒重连一轮**，而设计是 29 秒一轮。

根因：断连时调了 `preAuth.resetEdge()`，它把 `isInArea` 一起清零：

```text
0x0C 完成 → didComplete() 排 29s 后重试
  → 车端断开（它每条命令后都断）→ resetEdge() → isInArea=false
  → 下一帧广播仍判「在区域内」→ true != false → 立刻再 launch
```

**29 秒的节奏被压成 3–5 秒**。用户看到的就是「一直在连、一直在断」。

> 这个 `resetEdge` 当初是为了修「断开后再也不触发」才加的，属于**用状态污染
> 换可用性**。正确语义是：**断连只说明链路没了，不说明人离开了区域。**

### 改动

**① 断连不再复位预认证边沿**

```swift
ble.$linkState.filter { $0 == .disconnected || $0 == .failed }
    .sink {
        // 只复位无感开关状态；不动 isInArea / didStart
        self.passiveEntrySwitching = false
        self.pendingPassiveEntryValue = nil
    }
```

区域状态只由 RSSI 判定（`preAuth.updateArea`）驱动 —— 那才是和「人」有关的量。

**② `onWentOutOfRange` 也不再复位**

预认证是 29 秒一轮，车端每轮发完就断，所以「9 秒没有数据」在正常节奏下
**必然成立**。拿它当「人走远了」会每轮清零一次，效果和 ① 一样。

**③ `setEnabled(true)` 时若已在区域内，立刻启动一轮**

否则 `updateArea(true)` 会因 `inArea == isInArea` 直接 return，用户必须
「走出去再走回来」才会触发。之前靠 ① 里那个 resetEdge 歪打正着掩盖了这点。

**④ 「快速断开」只统计**空连接

原来 `lived < 3.0` 就算一次快速断开。但车端**每条命令后都主动断开**，
正常命令往返也就 0.5–1.5 秒 —— 于是每 5 轮预认证（约 2.5 分钟）必然触发
「暂停重扫 30 秒」，表现为**扫描莫名停半分钟**。

新增 `sentFramesThisConnection`：只有「连上却一帧没发就被踢」才计数，
发过帧的正常往返直接清零。

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- **待实测**：站车旁不再频繁重连；日志里两轮 `0x0C` 间隔应接近 **29 秒**，
  而不是 3–5 秒；`连续 5 次…暂停重扫` 不应再出现

---

## v5.3（2026-10-29）—— 「准备点火」入口 + 状态日志去重

用户反馈：**发动机状态还是不对；尝试了好多次才能启动车辆**。

先说清一件事：用户贴的那段会话时间戳是 **12:39**（`⚠️ RSSI 未标定`、
全程没有任何 `0x0C`），属于 **v4.4 之前**的数据，不能用来判断当前版本。
其中「未上电 · 发动机停」对应的是「车熄火、只做了锁/解锁」，本身是**正确**的。

不过这段日志暴露了两个真问题，本轮都处理了。

### ① 状态日志重复刷屏，把协议帧冲走

一次 58 条的会话里，**24 条是同一份状态的重复**（`未锁/未上电/发动机停/ACC关`
每 0.5–1 秒一条）。真正的 01/02/03/04 全被淹了。

`updateVehicleStatus` 改为**只在字段真的变化时**记一条，并带前后差异：

```text
车辆状态变化：未锁 · 未上电 · 发动机停(eng=0) · ACC关 → 已锁 · …
```

`statusUpdatedAt` 仍然每帧刷新（UI 的「X 秒前更新」靠它），只省日志。

### ② 「试很多次才打着火」的数学原因 → 加手动补发入口

预认证 `0x0C` 的自动节奏是 **29 秒一次**（对齐原 App 实测 30 秒周期），
而用户上车、踩刹车、按启动按钮是**随机时刻**。如果车端只认「最近 N 秒内
收到过 0x0C」，命中率就只有 **N / 30** —— 这就是要试很多次的直接原因。

新增 `AppModel.sendPreAuthNow()` + 主界面「**准备点火**」按钮：

- 只做一件事：把定时器该发的那一帧 `0x0C` **提前发出去**，不引入任何新协议动作
- 复用当前链路；链路未就绪时走 `pendingPreAuth` 挂起并在 `.ready` 补发，不会丢
- 前置条件：已配对 + 预认证保活已开 + 非只读模式 + 未锁定，四条任一不满足都有明确提示
- 仅在「已配对且预认证已开启」时显示，避免干扰未配对用户

**用法**：走到车旁 → 点「准备点火」→ 上车踩刹车按启动按钮。

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- `xcodebuild build`（generic/platform=iOS）：BUILD SUCCEEDED
- **待实测**（需手机解锁后安装）：点「准备点火」→ 日志出现
  `手动补发预认证` → `send prehauthentication command（0x0C，#n）` → `← 04 结果：成功（00）`

### 关于「发动机状态还是不对」

当前版本判断发动机的依据是 `status[4]` 的 **bit6:bit5 两位编码**，
`== 2`（即 `10b`）才算运行。要验证只有一条路：**发动机真启动时**看诊断页的
`status[4]=0x?? bin=???????? eng=N`。

| `eng` 值 | 含义 | 处置 |
|---|---|---|
| 2 且显示「运行中」 | 正确 | — |
| 2 但显示「停止」 | 还有 bug | 报我，查解析链 |
| 0 / 1 / 3 | 这台车的编码不是 2 | 报我具体值 + 启动后的 raw hex，按实际编码改判定 |

旧日志（12:39）没有 `eng=` 和 `plain=`，无法反推，只能重测。

### ③ 诊断页新增「预认证 / 点火」区块

之前这些状态**界面上一处都没有**，用户只能问「是不是预认证的问题」而无法自查。
现在摊开显示：保活开关 / 已发次数 / 是否在区域 / 续发状态 / 标定值 / 区域阈值 /
当前 RSSI，以及一句判定式说明，外加「立即发送预认证（0x0C）」按钮。

### 日志实证：预认证「有意图、零发出」

统计 17:28–17:36 那段（用户说"试很多次才能启动"的时段）：

| 事件 | 次数 | 含义 |
|---|---|---|
| `进入被动启动区域 → launch` | 18 | 每次都触发了 |
| `send prehauthentication command（0x0C，#N）` | **12** | `onSend` 确实被调用 |
| `准备预认证（控制码 0x0C` | **0** | ★ 真正构造帧的次数 = 0 |
| `链路已就绪，补发预认证` | **0** | ★ 挂起后从未补发 |
| `预认证往返结束` | **0** | ★ 从未收到 04，也就从未排下一次 |
| `stop sending passive start` | 16 | 被反复重置 |

典型一轮：

```text
17:28:22.059  进入区域 → start
17:28:23.088  send prehauthentication #1     ← 有意图
17:28:30.894  stop                           ← 7.8 秒后，车端零回应
17:28:35.219  又进入区域 → start             ← 4 秒后重来
```

**闭环**：`beginMeasuredAuth` 在链路未就绪时把预认证挂起
（`pendingPreAuth = true`），指望 `.ready` 回调补发 —— 但那个回调当时
`pairingArmed` 判断排在前面，直接把流程截断（**v5.0 已修顺序**）。
而 `stop` 来自 `onWentOutOfRange`（9 秒无车端数据）：0x0C 都没发出去，
车端当然不会回任何数据，9 秒后判出范围 → 重置 → 再进区域 → 再挂起。

**所以「试很多次才打得着火」不是玄学，是预认证一帧都没真正发出过。**
v5.0 修了顺序问题，v5.3 的手动入口 + 诊断区块用于实测确认。

---

## v5.2（2026-10-29）—— 「发现服务」卡死：给 GATT 服务发现加看门狗

用户问主界面左上角的「发现服务」是什么意思。查完发现这个词背后藏着一个
**能永久卡死链路**的漏洞。

### 它是什么

`.discovering` = BLE 连上之后、读对端 GATT 表（找 `F000FF10` 服务和
`F000FF11/F000FF12` 两个特征）的阶段。完整链路：

```
扫描 → 连接(.connecting) → 发现服务(.discovering) → 发现特征 → 订阅(触发 bonding) → .ready
```

**正常只存在 0.04–0.17 秒**（日志实证 30 次，中位 0.09s）；配对弹 PASSKEY 框时
会拉到 5–15 秒。所以它一闪而过是正常的。

### 问题是它会永久停在那里

v4.7 加的连接看门狗只覆盖 `.connecting`：

```swift
guard self.linkState == .connecting else { return }   // ← discovering 不管
```

于是 `didDiscoverServices` 回调不来时（车端忙 / 上一次会话没释放 /
信号弱到 GATT 请求无响应），链路**永久停在「发现服务」**：
`connectRemembered()` 对 `.discovering` 返回 true 却不做事、`autoConnect()` 早退，
用户点任何按钮都变成「连接后自动执行」然后石沉大海。

实测 2026-10-29 19:05–19:06 就是这个状态（日志里连续 5 次
「未连接（discovering）→ 连接后自动执行」）。

### 改动

- 新增 `armDiscoverTimeout()`：`didConnect` 里起表，`.ready` / 失败 / 断连时撤销。
  **15 秒**；配对模式（`pairingMode`）放宽到 **30 秒**（PASSKEY 框）。
- 主界面文案 `发现服务` → **`正在握手…`**（诊断页仍显示原始 `linkState.rawValue`，
  专业信息不丢）。

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- **待实测**：信号弱的地方连车，「正在握手…」最多停 15 秒，
  之后应自动变成「连接失败」并重新扫描，不再永久卡住。

---

## v5.1（2026-10-29）—— 配对/解绑状态机：已配的不再重复展示，解绑能真正回到未配对

用户要求：① 已配对的对象不再保留或重复展示配对关系；② 解绑后恢复为未配对；
③ 只有未配对才允许发起新配对；④ 解绑后能正确重新配对。

### 核心缺陷：解绑只清了 Keychain，没清内存副本

`deleteVehicle()` 调的是 `measured.reset()`，而 `reset()` **不清 `keys`** ——
它是给「用户主动断开」用的（那时 Keychain 里还有密钥，必须保留）。

于是解绑后出现**两个方向都错**的状态：

| 位置 | 实际 | 后果 |
|---|---|---|
| Keychain | 已空 | — |
| `measured.keys`（内存） | **仍是旧值** | 主界面继续显示「数字钥匙已就绪」 |
| `startFullPairing` | 读 `measured.keys != nil` | **被「本地已有密钥」拦住 → 解绑后再也配对不了** |

这正是「解绑后无法重新配对」的直接原因。

### 改动

**1. 引入单一判定口 `AppModel.hasLocalKey`**

```swift
public var hasLocalKey: Bool {
    if measured.keys != nil { return true }              // 内存有 → 已配对
    return KeyStore.shared.communicationKey?.isEmpty == false   // 双查 Keychain
}
```

为什么必须双查（两个方向的误判危害相反）：

| 场景 | 内存 | Keychain | 只看内存的后果 |
|---|---|---|---|
| 重启后尚未首次解锁，init 读失败 | nil | 有 | 误判「未配对」→ 允许重复配对 → 车端零响应 |
| 刚解绑（Keychain 已清、内存未刷） | 有 | 无 | 误判「已配对」→ **无法重新配对** |

所有「要不要允许配对 / UI 显示什么」统一用它：`startFullPairing` 的阻止条件、
`autoConnect` 的未配对判断、主界面 `statusRow`、`PairingView.hasVehicle`。

**2. `MeasuredSession.forgetKeys()`** —— 解绑专用，抹掉内存副本。
不塞进 `reset()`，因为 `reset()` 服务于「主动断开」，那里必须保留。

**3. `deleteVehicle()` 重写为「三步都做 + 清派生状态」**

- 清偏好项：`<cidpu>_CALIBRATION`、`<cidpu>_PASSIVE_ENTRY`（原来漏了这个）、
  `calibration.default`、`passiveEntry.default`
- 清密钥：`KeyStore.clearAll()` + `measured.forgetKeys()`
- 清链路：`disconnect` + `forgetRememberedPeripheral`
- 清会话：`measured.reset()` + `pendingPreAuth` / `pendingActionAfterConnect` /
  `pendingPassiveEntryValue` / `passiveEntrySwitching` / `rssiAntenna*` / 锁定计数
- 清配对：`pairingArmed = false`、`pairingBlockedReason = nil`、
  `pairing.resetForNewAttempt()`
- 最后才设 `statusLine`（避免被 `verifyKeyIntegrity()` 的「缺少 communicationKey」覆盖）

**4. UI 不再重复展示配对关系**

| 位置 | 原来 | 现在 |
|---|---|---|
| 右上菜单 | 恒显示「绑定车辆」，点进去只弹「本地已有密钥」 | 已配对时改为「车辆已绑定 · 管理与解绑」，不再给配对入口 |
| `PairingView.onAppear` | 无条件 `startFullPairing()`（已配对时走一遍注定失败的流程） | `hasLocalKey` 为真直接提示，不发任何帧 |
| `PairingView.hasVehicle` | 用 `receivedKeyData`（会话级，重启后为空）→ 已配对用户看到「暂无车辆」 | 用 `hasLocalKey`（持久判定） |
| 主界面 `statusRow` | `measured.keys` | `hasLocalKey` |

**5. 解绑加二次确认**（原来一点就执行，不可逆）

### 状态判断与边界（这一版明确化的规则）

| 状态 | `hasLocalKey` | 允许配对 | UI |
|---|---|---|---|
| 正常已配对 | true | ✗（`startFullPairing` 直接阻止并说明原因） | 「数字钥匙已就绪」 |
| 内存 nil / Keychain 有 | true | ✗ | 「数字钥匙已就绪」（并自动 `reloadKeys()`） |
| 解绑后 | false | ✓ | 「尚未绑定车辆 / 去绑定」 |
| 配对中 | false | ✗（`pairingArmed` 提示"进行中"） | 「配对中」 |

边界处理：
- **内置钥匙用户解绑后**：`builtInKeys.applied.*` 标记**不清**，所以重启不会自动把
  内置钥匙塞回去 —— 保持「未配对」符合预期；想恢复需点「重新应用内置钥匙」
- **解绑后重新配同一辆车**：cidpu 会重新下发，标定值需重做（解绑已清），
  无感进入开关回到关闭
- **解绑时链路正连着**：先 `disconnect` 再清状态，避免清理过程中收到迟到帧
- **解绑后 `keyIntegrityOK` 变 false**：这是「无密钥」的正常态，不算错误；
  重新配对成功后 `handlePairingFrame` 会重新校验并恢复 true

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- **待实测**：解绑 → 主界面应立刻变「尚未绑定车辆」→ 菜单变「绑定车辆」→
  点进去能正常发起配对（不再弹「本地已有密钥」）

---

## v5.0（2026-10-29）—— 「指令没用」的真因：挂起动作从未被执行

用户反馈「开窗/关窗指令好像没用」。拉日志一查，**不是车窗命令的问题，
是命令根本没发出去**。

### 日志实证

```text
链路就绪 .......................... 30 次
已连接，发现服务 .................. 30 次
「未连接（connecting）→ 连接后自动执行「开窗」」... 9 次
「链路已就绪，自动执行」........... 0 次   ← 关键
「准备执行：开窗」................. 1 次（17:30:17，且没有 04 回执）
```

即：**只有「点击时链路恰好就绪」的那 12 次真正执行了**（其中锁车/解锁/无感
共 5 次拿到 `04 00`），凡是「点击时未就绪」的几十次挂起，**一次都没被执行**。

### 根因一：`pairingArmed` 挡在用户动作前面

`.ready` 回调里的顺序原来是：

```swift
if pairingArmed { 发 0x0D 配对帧; return }   // ← 先判断
if let action = pendingActionAfterConnect { 执行 }  // ← 永远轮不到
```

而 `autoConnect()` 在 `measured.keys == nil` 时会反复把 `pairingArmed` 置真。

### 根因二：`measured.keys` 是内存缓存，误判「未配对」

`MeasuredSession.init` 只读一次 Keychain。Keychain 在「重启后尚未首次解锁」
等场景读不到 → `keys == nil` → 被当成「未配对」→ 进配对流程。
但实际鉴权时 `beginMeasuredAuth` 会 `reloadKeys()`，所以密钥是好的 ——
于是出现「能解锁（12 次直接执行成功 5 次），但挂起的动作全部消失」。

### 根因三：配对日志不落盘，问题不可见

`appendPairingLog` 只写 `pairing.log`（@Published 数组，内存），
`FileLogger` 里一条都没有 —— 「链路已就绪，自动发配对登记帧」这类关键分支
在日志文件里完全查不到，排查时只能靠猜。

### 改动

1. **`.ready` 回调改为「用户动作优先」**：`pendingActionAfterConnect` >
   `pairingArmed` > `pendingPreAuth`。用户明确点了按钮，不该被自动配对吞掉。
2. **`autoConnect()` 判断未配对时，二次确认 Keychain**：
   `measured.keys == nil && KeyStore.communicationKey == nil` 才算真的未配对；
   只有内存没加载出来就 `reloadKeys()`，不进配对。
3. **`appendPairingLog` 同时写 FileLogger**（module = "配对"）。
4. **`.ready` 回调入口加诊断日志**：
   `链路就绪 → 挂起项：action=… / pairing=… / preAuth=…`，
   下次同类问题一眼定位。

### 验证

- `swiftc -typecheck`：0 error / 0 warning
- `xcodebuild build`：BUILD SUCCEEDED
- **待实测**：车旁点开窗 → 日志应出现
  「链路就绪 → 挂起项：action=开窗 …」紧跟「链路已就绪，自动执行「开窗」」。

### 遗留疑问（需要实测确认）

17:30:17 那次开窗**确实执行了**（`准备执行：开窗（控制码 0x05）`），
但**没有 04 回执** → 超时。可能是车端要求「上电/IG ON」才受理升窗命令。
这个只能真车在不同电源状态下对比才能定论。

---

## v4.9（2026-10-29）—— 端到端流程审查：8 处缺陷全部修复

按 8 个阶段（启动/扫描/连接/配对/控车/无感/状态/后台）过了一遍数据流，
发现 8 处流程级缺陷，本轮全部修完，并为最严重的两处加了回归护栏。

### ① 0x0E 密钥帧解析失败仍报「配对成功」★假成功

`saveKeyData` 在 `parseKeyFrame` 返回 nil 时只留存 `core`、一个字段都不写，
但调用方 `case .keyData` **无条件**设 `lastResult = .paired` 并打印
「✅ 配对成功」；`AppModel.handlePairingFrame` 也跟着报「已保存，配对完成」。

用户会看到「配对成功」，主界面却仍是「尚未绑定车辆」（`keys == nil`）。

- `saveKeyData` 改返回 `Bool`；
- `case .keyData` 里 `guard saveKeyData(payload) else { phase = .failed;
  lastResult = .refused(0x2BB) }`；
- `handlePairingFrame` 校验 `measured.lastResult == .paired` 才报成功，
  否则 `pairing.fail(...)`；
- 成功路径补 `verifyKeyIntegrity()`，新密钥立刻重算指纹（不再等下次启动）；
- 新增 `SelfTest.testKeyFrameLengthGuard()`：40B 短帧必须 `nil`、
  62B 标准帧必须切出 dk1/ckTRxSP/tail 各 16B。

**验证**：诊断页跑自检，应看到「0x0E 密钥帧长度守卫」通过。

### ② 命令超时不收口「等待中」状态 ★开关永久转圈

`startCommandTimeout` 原来只改 `statusLine`。而 `passiveEntrySwitching`
只在**断连**时复位 —— 车端收下命令但不回 04、也不断开时，无感开关永久转圈，
只能重启 App。同一处还漏了 Siri 和配对状态。

现在超时统一收口：

```swift
if pendingPassiveEntryValue != nil { settlePassiveEntryToggle(.timedOut) }
resolveIntent(false)                       // Siri 立刻拿到失败，不等 12s 兜底
pairingArmed = false
if pairing.state == .requestingPairing { pairing.fail("命令超时…") }
measured.recordNote("超时：…")              // 不再写进「配对日志」
```

**验证**：车端不回 04 时点无感开关 → 4 秒后开关恢复可点并提示超时；
Siri 解锁 → 4 秒内报失败（原来要 12 秒）；配对超时后绑定页显示「配对失败」。

### ③ `listenOnly` 漏拦两条发送路径 ★安全承诺没兑现

只读监听原来只在 `perform` / `setPassiveEntry` 里守卫，但**预认证 `0x0C`**
（`preAuth.onSend → beginMeasuredAuth`）和**配对 `0x0D`**
（`beginMeasuredAuthPairing`）不走 `perform` —— 用户勾了「只读」，
实际仍在发加密命令。

改为下沉到唯一写入口 `BLECentral.send()`，任何上层路径都绕不过；
`AppModel.listenOnly` 用 `didSet` 同步给 BLE 层，并在拦截时写日志。

**验证**：开只读 → 走到车旁 → 日志里 `send prehauthentication` 应为 0 条，
且出现「只读监听拦截发送」。

### ④⑤⑥ 超时引发的三个连带问题

已在 ② 一起修掉：Siri 白等 12 秒 / 配对状态卡「发送配对请求」/
控车超时写进配对日志（语义错位）。

### ⑦ 区域判定退化成单天线

`rssisOneAndTwo` @`0x8954` 是**两路**天线 dB 合成
（`10×log10(√(10^(r1/10)²+10^(r2/10)²)×pondOutToIn)`），
但区域判定一直用同一个 RSSI 填两路 —— 而广播里 antenna 高 4 位（0x80/0x40）
早就把两路分开了，`handleDualRSSI` 也一直在存，只是没用于判定。

现在两路都齐就用真值，缺一路才退化单路。

**验证**：站在车左前 / 右后各测一次，`passiveStart.summary` 的合成值应不同
（原来两种情况完全相同）。改完建议重做一次标定。

### ⑧ 无感开关「未连接就拒绝」与控车「挂起自动执行」两套行为

`setPassiveEntry` 提前 `guard isWriteReady` 直接拒绝，而 `perform` 支持
「挂起 → 连接 → 就绪后执行」。用户刚控完车（车端已断开）马上切开关会被拒。

现在统一交给 `perform` 排队；同时给 `perform` 加防覆盖：
`pendingActionAfterConnect` 只能存一个动作，若被别的动作顶掉，
显式复位 `passiveEntrySwitching`，避免开关永久转圈。

**验证**：未连接时点开关 → 应提示「正在连接，就绪后切换」而非「需先连接车辆」。

### ⑨ 安全：导出备份不再进通用剪贴板

`UIPasteboard.general.string = text` 会把明文车钥匙写进全局剪贴板，
并通过「通用剪贴板」同步到同账号的其他设备。改为
`setItems([...], options: [.localOnly: true, .expirationDate: +60s])`，
按钮文案改为「导出并复制（仅本机）」。

### 验证

- `swiftc -typecheck`（32 文件）：**0 error / 0 warning**
- `xcodebuild build`：BUILD SUCCEEDED
- 自检新增用例：`0x0E 密钥帧长度守卫`

---


## v4.8（2026-10-29）—— 系统性审查 + 死代码清理

按「覆盖主要模块、检查逻辑/边界/错误处理/安全/可维护性」的要求全量过了一遍，
并在不破坏功能的前提下移除无用代码。
**`Sources/`：33 文件 10089 行 → 32 文件 9799 行（净减 290 行）。**

### 一、审查范围

| 层 | 文件 | 关注点 |
|---|---|---|
| BLE 传输 | `BLECentral`(1447) | 扫描/连接/断开状态机、分包、MTU、广播解析 |
| 应用编排 | `AppModel`(1319) | 鉴权流程、超时、锁屏守卫、Intent、密钥完整性 |
| 协议 | `MeasuredSession`(667)、`InBlueAuth`(375)、`InBluePairing`(168)、`ValeoAdvMatch`(263)、`VehicleStatus`(322)、`PassiveStart`(265)、`PreAuthenticationController`(283)、`ProtocolConstants`、`ErrorCodeTable`、`BroadcastParser`、`FrameCodec` | 帧构造/解析、位映射、区域判定、状态机 |
| 密钥 | `KeyStore`(306)、`BuiltInKeys`(247) | Keychain 属性、指纹、内置钥匙自愈 |
| UI | `RootView`(1046)、`PairingView`、`KeyInspectorView`、`DiagnosticsView`、`LogView`、`CarModelView`、`LiveLogFloatingView`、`FloatingWindowController` | 状态一致性、反馈闭环 |
| 支撑 | `FileLogger`(442)、`BackgroundMonitor`(186)、`SelfTest`(407)、`CryptoBox`(143)、`RemoteGuard`、`VehicleProfile`、`AppInfo` | 日志、密码学、自检 |

方法：静态扫描（零引用符号、只写不读字段、永不成立的分支、注释掉的代码、
TODO 残留、重复表达式）+ 逐条回源码核对。**没有直接采信扫描结果** ——
例如 `fullDescription` / `carArt` / `bits` 这类被点号访问或 SwiftUI 直接引用的，
扫描会误报，都已人工确认。

### 二、本轮修掉的问题

| # | 位置 | 问题 |
|---|---|---|
| 1 | `BLECentral.didDiscover` | `if hit && !weak && forceConnectOnce { if !forceConnectOnce, … }` —— 嵌套条件自相矛盾，冷却分支**永不成立**，`lastDisconnectAt` / `autoConnectCooldownSeconds` 全是死变量。删除死分支与两个字段。 |
| 2 | `AppModel` RSSI 订阅 | `relayGuard.record()` 只喂不读：`alarm` / `samples` 从无消费者，每次 RSSI 回调都在做无用计算。**改为接入**（告警变化时写进会话日志并去重），保留中继检测能力。 |
| 3 | `DiagnosticsView` | `discoverCount` / `lastDiscoveredName` 只写不读，但它们的语义（0 = 系统没回调；>0 但列表空 = 被过滤）正是「扫不到车」时最该看的判据。**改为接入**诊断页。 |
| 4 | `ProtocolConstants` | `controlCode` 的文档注释重复了一遍（复制粘贴残留），已去重。 |
| 5 | `BLECentral` 字段区 | 删 `lastDisconnectAt` 时留下半截注释块（`// ── 自动连接冷却` + 残缺段落），已重写为完整的「为什么不是扫到就立刻连」。 |

### 三、删除清单（均可逆，Git 历史可恢复）

**整文件**
- `Sources/UI/AboutView.swift`（153 行）—— 文件自己的注释就写着「当前没有任何入口
  打开它（v2.9 起）……此文件保留备用」。版本号已并入开发者菜单底部，全项目零引用。

**未引用成员**（零成员访问、零构造）

| 位置 | 成员 | 判断依据 |
|---|---|---|
| `AppModel` | `isBusy` | 全项目无 `model.isBusy` |
| `AppModel` | `currentDeviceNameForPairing` | 无引用；`InBluePairing.currentDeviceName()` 本身仍在用 |
| `BLECentral` | `showAllDevices` | 无引用（`didDiscover` 的过滤不读它） |
| `BLECentral` | `clearCandidates()` | 无调用方（`candidates` 本身被诊断页读取，保留） |
| `BLECentral` | `isNotifyReady` | 无引用；链路就绪统一用 `isWriteReady` + `linkState` |
| `BLECentral` | `lastDisconnectAt`、`autoConnectCooldownSeconds` | 仅被上面那个永不成立的分支读取 |
| `BuiltInKeys` | `resetAppliedFlag()` | 无调用（注释本就写明解绑时不调用） |
| `KeyStore` | `getIBSavedKeysArchive()` | 无调用（写入侧 `saveIBSavedKeys` 仍保留） |
| `InBluePairing.State` | `case awaitingConfirmation` | 从未被赋值（配对只有 requesting → succeeded/failed） |
| `ProtocolConstants` | `isPassiveEntryToggle` | 无引用（界面用 `passiveEntryEnabled` 布尔量） |
| `VehicleStatus` | `isValid` | 无引用 |
| `VehicleStatus` | `bits`、`toBits(_:)` | 原本只服务 `bitString`/`bitStringGrouped`，两者删除后成死链 |
| `VehicleStatus` | `bitString`、`bitStringGrouped` | 无引用（诊断改用 `fullDescription` 的 `decodeStatusBin`） |
| `VehicleStatus` | `lockMask` | 无引用（位映射已在 `decodeStatusByte` 内联表达） |
| `ProtocolErrorCode` | `isRetryable` | 无引用（重试策略未按错误码分派） |
| `ProtocolErrorCode` | `describeResultCode(_:)` | 无调用方的纯转发（`ErrorCodeTable` 本身仍被自检与 UI 使用） |
| `RelayGuard` | `average`、`isSuspicious`、`bars`、`latest` | 无读取方；保留 `record`/`alarm`（已接入）与三个阈值 |

### 四、**保留**的无引用项（附理由）

| 项 | 为什么留 |
|---|---|
| `PassiveStartJudge.pondInToOut` | 反汇编 `IBVehicle` 的 ivar，与 `pondOutToIn` 成对；删掉会让「合成 RSSI 的加权系数」无处对应 |
| `PreAuthenticationController.disassemblyInterval` | 反汇编立即数（`6.5s`），是节奏依据的锚点 |
| `BLECentral.readChar` | 对应原 App `setReadCharacteristic:`；虽然当前不读，但它是 GATT 三个特征之一的镜像，删掉会让「为什么只处理 write/notify」失去解释 |
| `VehicleStatus.randomNumber` / `oemID` / `additionalData` | `parseBroadcastData:` 的切分结果，被 `fullDescription` 读取；也是 `Broadcast` 结构的一一对应 |
| `VehicleIntents.typeDisplayRepresentation` / `caseDisplayRepresentations` / `appShortcuts` | `AppIntents` 协议要求的静态属性，由系统在元数据期调用 |
| 3 处 `// if (dev == nil) return;` 之类 | 反汇编伪代码引用，属证据链，不是调试残留 |
| `commandTimeoutSeconds` / `pairingTimeoutSeconds` 等 | 有引用（默认参数 / 超时表） |

### 五、删除后的调整与验证

- **`GKUIBleKey.xcodeproj` 必须重新生成**：删文件后 `pbxproj` 仍指向
  `Sources/UI/AboutView.swift`，`xcodebuild` 直接报
  `Build input file cannot be found`。已执行 `xcodegen generate` 修复。
  **以后删/加源文件都要跟一句 `xcodegen generate`。**
- `swiftc -typecheck`（33→32 文件）：**0 error / 0 warning**
- `xcodebuild build`：**BUILD SUCCEEDED**
- 运行时影响面：只删「无消费者」的成员，唯一的行为变化是
  ① 中继告警开始写入会话日志；② 诊断页多两行（扫描回调数 / 最近广播名）。
  两者都不改协议收发，不影响配对与控车。

---

## v4.7（2026-10-29）—— 全量代码审查：10 处 bug，其中 3 处会让功能彻底失效

用户要求「审查一下有没有 bug」。按「会导致功能失败的真实缺陷」标准过了一遍
9800 行源码（重点：BLE 连接生命周期、鉴权状态机、密钥存取、UI 反馈），
确认并修复 10 处。**其中前三条都能单独造成「看起来完全不能用」。**

### ① 密钥完整性指纹把控车永久拦死 ★最严重

`verifyKeyIntegrity()` 把「`communicationKey` 指纹变化」直接判为
`keyIntegrityOK = false`，而 `perform`/`beginMeasuredAuth` 里 `guard keyIntegrityOK != false`
是硬拦截。但指纹变化的**正常原因**恰恰是合法写入：

| 场景 | 旧行为 |
|---|---|
| 自己配对成功（`saveKeys` 写入新 `communicationKey`） | 下次启动判「被篡改」→ **所有按钮失效** |
| 点「重新应用内置钥匙」 | 同上 |
| 从备份恢复 | 同上 |

而 `verifyKeyIntegrity()` 只在 `AppModel.init` 里调一次 → **重启也救不回来**，
唯一出路是解绑车辆。用户会看到「配对成功但什么都点不动」。

→ 改为**自愈**：指纹不一致就重算写回，只在详情里留一句说明；
硬失败只剩「密钥缺失 / 长度异常」。

### ② `.idle` 被当成断连，把预认证链自己掐断 ★正是 3.4「点火不了」的真凶

`connect(_:)` → `stopScan()` 会把 `.scanning` 改成 `.idle`，而 `AppModel` 的
断连订阅 filter 里**包含 `.idle`** → `preAuth.resetEdge()`。于是：

```
进入区域 → launch → 1s 后 onSend → 链路未就绪 → connectRemembered
→ connect → stopScan → .idle → resetEdge（didStart=false + cancelPending）
→ .ready 补发 0x0C → 车端回 04 → didComplete() 里 guard didStart 直接 return
→ 29s 续发链断掉 → 车只收到一次 0x0C → 点火不了
```

**实测日志里「start sending passive start commands」与
「stop sending passive start commands」出现在同一毫秒**，就是这个（不可能是
RSSI 离开区域）。v4.4 只修了「预认证被丢弃」，没修到这条。

→ 两处同时改：`connect()` 先置 `.connecting` 再 `stopScan()`；filter 去掉 `.idle`。

### ③ 订阅失败只记日志就 return → 链路假死

`didUpdateNotificationStateFor` 的 error 分支原来只 `note(...); return`：
`linkState` 停在 `.discovering`，`writeChar` 仍非 nil（`isWriteReady == true`）。
后果：`autoConnect()` 因 `.discovering` 早退、`connectRemembered()` 返回 true
却不做事；用户点按钮直接往**未加密链路**发 01 → 每次 4 秒超时 690。
车端不踢的话永久卡死，只能杀 App。

→ 改为清特征 + 置 `.failed` + 主动断开，让 `didDisconnect` 正常收尾（重扫/冷却）。

### ④ 回完 03 不再计时 → 04 不来就永久悬挂

`handleIncomingFrame` 第一行**无条件** `cancelCommandTimeout()`，而 02 到达后
发 03 也没有重新起表。于是车端收下 03 却不回 04 时（挑战不匹配/丢包/忙），
`statusLine` 永久停在「已自动回复鉴权3，等待结果」，`preAuth.didComplete()`
永不触发 → 预认证链死掉。顺带：车端周期推送的 `0x05` 状态帧也能把超时撤掉。

→ 只在 `cmd != 0x05` 时撤超时；发完 03 立刻 `startCommandTimeout("鉴权3")`。

### ⑤ 主界面完全不显示 `statusLine` → 按钮点了没反应

`perform` 的所有反馈（未连接/锁定/完整性失败/构造失败/写入失败/超时）
都只写 `model.statusLine`，而主界面**一处都没渲染**，只有「开发者 → 诊断」能看到。

→ `statusSection` 加一行状态卡（按内容着色 + 图标），`animation` 跟随变化。

### ⑥ `forceConnectOnce` 走直连路径时不清 → 操作成功后多一次空连接

标志只在 `didDiscover` 命中分支清零，`connectRemembered()` 直连时不消费。
操作完成后车端断链 → 重扫 → 扫到本车 → 又满足 `forceConnectOnce` →
**再连一次什么帧都不发的空连接**（车端 2 秒踢），表现为「操作成功后信号又闪断」。

→ `didConnect` 里清零。

### ⑦ 连接阶段没有看门狗 → 永久「正在连接车辆…」

`didConnect` / `didFailToConnect` 一个都不来（连到已被系统淘汰的
`CBPeripheral`）时，`linkState` 永远 `.connecting`：`autoConnect()` 早退、
`connectRemembered()` 返回 true 不做事 → 只能杀 App。

→ `connect()` 起 10 秒看门狗，`didConnect`/`didFailToConnect`/`didDisconnect` 撤销。

### ⑧ 重装/换机后内置钥匙会覆盖用户自己配对的钥匙

「只写一次」的依据在 `UserDefaults`，而 Keychain 会跟 iCloud 回来、
UserDefaults 不会 → 重装后判定「从未应用过」→ `apply()` 覆盖成内置这把，
车端槽位对不上 → 鉴权被拒、连上秒断。

→ `applyIfNeeded()` 先检查「Keychain 是否已有完整且非内置的钥匙」，有则跳过。

### ⑨ 从备份恢复后不重载密钥

`KeyInspectorView` 的恢复分支只 `refreshTick += 1`（只重画列表），
没有 `measured.reloadKeys()`、也没有重算完整性 → 主界面仍显示「尚未绑定车辆」，
且若之前是拦截态，恢复一把正确钥匙后依然发不出帧。

→ 恢复成功后 `reloadKeys()` + `verifyKeyIntegrity()`。

### ⑩ 预认证的 `04 00` 会让 Siri 谎报「已解锁」

`resolveIntent(true)` 不看这个 `04` 属于哪一轮。预认证保活开着且在区域内时，
一轮 `0x0C` 的成功回执就能让 Siri 说「已解锁」，而门没开。
同一处已经算出 `isPreAuth` 却没用。

→ `if !isPreAuth` 才 `resolveIntent`。

### 顺带的健壮性修正

- **分包包数公式**：注释写 `ceil((len+4)/mtu)`，代码写成 `ceil(len/mtu)`
  → 179B@mtu182 会算成 1 包（实际 2 包），车端按头只收首包 → 帧被截断。
  当前 MTU 182 不触发，属潜伏 bug，已按反汇编改正。
- **MTU 按实际写入类型取**：原来固定 `for: .withoutResponse`，特征只有 `.write`
  时会拿到 23，整条协议被塞进多包路径。改为 `for: type`。
- **`didFailToConnect` 无条件 arm「配对自动连」**：任何一次普通连接失败都会让
  下次扫描无条件连第一个 Valeo 设备（不校验是否本车）。改为只在
  `pairingMode`（由 `pairingArmed` 同步）时置位。
- **`disconnect()`/`cancelConnection()` 的抑制标志残留**：对已断开的外设置位后
  没有 `didDisconnect` 来消费 → 之后所有断连都不重扫。改为仅在实际连接时置位。
- **`startScan()` 覆盖 `.ready`**：配对成功后链路还连着，却被改成「扫描中」，
  UI 显示错且会触发重复 `discoverServices`。改为 `.ready` 时不动。
- **`AppModel` 不转发 `ble.objectWillChange`**：连接状态/RSSI/报文流靠「日志行」
  被动刷新，日志级别调到 warning 以上就完全不刷新。已补转发。
- **`carStage` 先判 `.ready`**：配对中车图不闪灯（顶部胶囊却写「配对中」）。已调整顺序。
- **Intent 12 秒兜底定时器不取消、无代号**：连说两条指令时第一条的定时器会
  把第二条判失败；超时后挂起动作仍会补发（toggle 命令被翻两次）。
  改为 generation token + 超时清挂起动作。
- **`commandTimeoutSeconds` 加 `nonisolated`**：消除 Swift 6 警告（原为 2 条 warning）。

### 验证

- `swiftc -typecheck`（iOS 27 SDK，33 文件 9800 行）：**0 error / 0 warning**
- `xcodebuild build`：BUILD SUCCEEDED

---

## v4.6（2026-10-29）—— 把「能不能点火」变成界面上看得见的结论

用户问「现在能启动车了吗」。查手机上的实际状态
（`devicectl device copy from … Library/Preferences`）确认三个前提都已满足：

```plist
"01918d…_CALIBRATION"        => -45      ← 已标定
"01918d…_PASSIVE_ENTRY"      => true     ← 无感进入（0x11）已下发成功
"gkuiblekey.preAuth.enabled" => true     ← 预认证保活已开
```

但界面上看不出来，只能自己拼。改两处：

- **预认证成功的状态行**由「预认证成功（6.5s 后继续）」
  改为「✅ 钥匙已被车内认可，可踩刹车按启动按钮（6.5s 后自动续发）」——
  这是 0x0C 的真正语义，原来的文案没告诉用户该干什么。
- **开发者菜单的「预认证保活」**文案由静态的「默认关闭」改为实时状态：
  未标定 / 已关闭 / 保活中（在区域内、已发 N 次 0x0C）/ 已开启待触发；
  关闭时文字标橙，避免误以为能点火。

### 说明：本 App 仍**不能远程启动发动机**

`IBCommandType` 11 个命令里没有「启动发动机」（锁/解/后备箱/关窗/开窗/
寻车/名册/无感开/无感关/配对 + 预认证 0x0C），原 App 同样没有。
「启动车」在本产品里只有一条路径：**上台车踩刹车按车上的启动按钮**，
App 的作用是发 `0x0C` 让车端认可钥匙在场。

### 验证

- `swiftc -typecheck`：0 error

---

## v4.5（2026-10-29）—— 修「发动机启动后只显示上电、发动机恒显示未启动」

用户实测：**发动机启动后 UI 显示「已上电」，但「发动机」一直「未启动」**。

### 根因：`_isEnginRunning` 是 **2 位编码**，被误实现成单 bit

`parseStatus:` @`0x4de4` 的三次复核发现，前两次只看 `mov w2, #N`（location），
漏了紧跟着的 `mov w3, #N`（length）：

```asm
0x502c: mov w2, #3
0x5030: mov w3, #1        ; {3,1} → bit4  → _isIgnitionOn
0x5094: mov w2, #1
0x5098: mov w3, #2        ; {1,2} → bit6:bit5 两位！→ _isEnginRunning
0x50c8: mov x1, #0
0x50c4: mov w2, #2        ; strtol(_, NULL, 2)
0x50dc: cmp x26, #2
0x50e0: cset w8, eq       ; 只有 10b 算运行
0x50f4: mov x2, #0 / w3=#1 ; {0,1} → bit7 → _isHoodClosed
```

| 编码 | bit6:bit5 | 判定 |
|---|---|---|
| 0 | `00` | 未运行 |
| 1 | `01` | 未运行 |
| **2** | **`10`** | **运行中** |
| 3 | `11` | 未运行 |

真车发动机启动时状态字节是 `bit4=1`（上电）+ `bit6=1/bit5=0`（eng=2）。
旧代码取 `bit5` → 恒 false，于是「上电了但发动机未启动」。**完全对得上现象。**

顺带修正 **`isHoodClosed` = bit7**（原来错取 bit6），并删掉并不存在的
`reservedBit7` —— 8 位实际全部用满（7,6,5,4,3,[1..2],0）。

### 改动

- `VehicleStatus`：新增 `engineStateCode`（`(statusByte>>5)&0x03`），
  `isEngineRunning = engineStateCode == 2`；`isHoodClosed` 改 bit7；删 `reservedBit7`。
- `summary` 日志带 `eng=N`；`fullDescription` 增加 `status[4]` 的 8 位二进制串，
  便于实测一眼区分「车端没报」还是「位映射错」。
- `SelfTest.testVehicleStatusBits` 扩成回归用例：
  0x50→运行、0x10→仅上电、0x20→编码1、0x60→编码3、0x80→引擎盖关、四门 + ACC。
- `Docs/VEHICLE_STATUS.md` 表格按 `substringWithRange:` 真实 range 重写。

### 验证

- `swiftc -typecheck`（iOS 27 SDK，全 33 文件）：0 error。

---

## v4.4（2026-10-29）—— 修「总是断联 / 点火不了 / 无感进入无效」：同一个根因

用户在 3.4 上反馈三件事，拉日志后确认**是同一个 bug 的三张面孔**。

### 日志证据（3.4 实测，2026-10-29 17:33）

```log
17:32:26.526  start sending passive start commands
17:32:26.526  stop sending passive start commands     ← 立刻停
17:33:02.512  正在连接 InBlue3f26c66ac89ad4…
17:33:03.252  链路就绪：订阅成功，耗时 0.06s
17:33:05.151  已断开：The specified device has disconnected from us.   ← 2 秒后
17:33:20.351  正在连接 …                              ← 15 秒冷却后又连
17:33:23.002  已断开 …                                ← 又断
```

两次连接之间**一帧都没有发**。车端等约 2 秒就把链路踢掉。

### 根因一：扫描命中就无条件连接 → 空连接循环

v3.1 引入「扫描常开」时，`didDiscover` 里写的是「命中本车 + 不在 15 秒冷却期」就 `connect`。

但车端**不接受空闲连接**：连上不给业务帧，约 2 秒主动断开。于是形成
「连 → 断 → 冷却 15 秒 → 又连 → 又断」的循环，用户看到的就是「总是断联」。

原 App 从不这样 —— 它的每次连接都对应一条要发的命令
（日志里 `Request for connection` 与 `Data to send` 总是成对出现）。

**修法**：`didDiscover` 里加 `&& forceConnectOnce`，改成**按需连接**。
谁要发帧谁先置位；普通扫描只更新状态和 RSSI，不主动连。

### 根因二：预认证在链路就绪前被静默丢弃 → 点火不了

```swift
public func beginMeasuredAuth(..., asPreAuthentication: Bool = false) {
    guard ble.isWriteReady else {
        statusLine = "写特征未就绪，无法发起鉴权"
        return          // ← 预认证在这里被扔掉，之后没人重试
    }
```

预认证的触发时机是「刚进入被动启动区域」，那一刻链路**几乎必然还没连上**。
于是这一轮预认证被丢弃，`.ready` 回调只处理 `pairingArmed` 和
`pendingActionAfterConnect`，**没有任何分支会重试预认证**。

结果：`0x0C` 一次都没发出去 → 车端始终不认为「钥匙在场」→
**点火不了**，拉门把手也不解锁（无感进入看起来「没用」）。

**修法**：

```swift
guard ble.isWriteReady else {
    if asPreAuthentication {
        pendingPreAuth = true
        ble.forceConnectOnce = true
        ble.connectRemembered()      // 不等扫描，直接连已知设备
    }
    return
}
```

`.ready` 回调里补一个分支（优先级：配对 > 用户动作 > 预认证），并记录
`链路已就绪，补发预认证（0x0C）`。

### 根因三：配对路径同样依赖「扫到就连」

`autoConnect()` 里 `keys == nil` 会置 `pairingArmed`，但 v4.4 之后
扫到不再自动连，所以必须同时置 `forceConnectOnce = true`，否则配对也会卡住。

### 所以三个现象的关系

```
按需连接（修一）  → 不再空连、不再无谓断链
     ↓
预认证能发出（修二）→ 车端认为钥匙在场
     ↓
点火 / 无感进入才有基础（修三补配对）
```

### 版本

**4.4 / build 44**，`xcodebuild` **0 error 0 warning**，已装 iPhone 17 Pro。

---

## v4.3（2026-10-29）—— 密钥外置（安全）+ 代码上 GitHub

### 一、内置钥匙凭据移出源码

原来 `Sources/Keychain/BuiltInKeys.swift` 里硬编码着真实车钥匙
（`Dk1` / `CkTRxSP` / `cidpu` 等 8 个字段）。准备推到 GitHub 时发现这是
**必须先解决的硬问题**：

> 一旦提交，密钥会永久留在 Git 历史里 —— 即使之后删掉文件，
> 仍然能从历史提交里翻出来。而它是车端认可的真实凭据（能解锁、能点火）。

改法：

```
Resources/builtin-keys.txt          ← 真实值（.gitignore 排除，只在本机）
Resources/builtin-keys.example.txt  ← 模板（入库，值为空）
Sources/Keychain/BuiltInKeys.swift  ← 运行时从 Bundle 读 key=value
```

- `BuiltInKeys.seed` 在类型初始化时读一次 Bundle 里的 `builtin-keys.txt`
- `isConfigured == false` 时 `apply()` **直接返回**，不会写 Keychain
  （否则会把空值写进去、生成 1 字节垃圾 `core` 帧，破坏已有有效密钥）
- 读不到不影响正常路径：自己配对 / 从备份恢复照常可用

顺带把文档里两处完整密钥表脱敏（`Dk1` / `CkTRxSP` → `3c71e819…c1b077` 形式），
以及 `ErrorCodeTable.swift` 注释里的完整 cidpu。

### 二、GitHub 私有仓库

```
https://github.com/kwf6mzrrxj-dot/GKUIBleKey   (PRIVATE)
```

已确认：

- 远程 70 个文件里**没有** `builtin-keys.txt`，只有 `example` 模板
- 提交前对暂存区做过全文搜索（`3c71e819…` / `7156d3cd…` 均 0 命中）

### 三、`tools/sync.sh` —— 一键同步（带密钥防护）

```bash
./tools/sync.sh              # 自动提交信息
./tools/sync.sh "修复 xxx"    # 自定义
```

两道安全检查：

1. `git check-ignore` 确认 `.gitignore` 仍排除密钥文件（防止有人改坏）
2. 暂存区一旦出现 `Resources/builtin-keys.txt` 就**中止**

任一不通过都拒绝提交，避免 `git add -A` 把车钥匙推上去。

### 版本

**4.3 / build 43**，`xcodebuild` **0 error 0 warning**。
安装包已更新：`DerivedData/Install/GKUIBleKey.app`（含 `builtin-keys.txt`，647 B）。

---

## v4.2（2026-10-29）—— 后台保活「可验证」：心跳 + 定时器偏差 + 进程重启间隔

上一版只能从代码推断后台能力，这一版把**证据做进日志**，让实测能给出确定答案。

### 一、新增 `Sources/Support/BackgroundMonitor.swift`

iOS 没有 API 能直接查「我还有没有后台执行权」，所以靠三类证据反推：

**① 前后台切换 + 后台停留时长**

```
[保活] ⬇️ 进入后台（前台停留 3 分 20 秒）
[保活] ⬆️ 即将回前台（后台停留 35 分 10 秒，期间心跳 12 次，理论应有 70 次）
```

「理论应有 70 次、实际 12 次」直接量化了被挂起的比例。

**② 30 秒心跳**

```
[保活] 心跳 #7 状态=后台 广播累计=412 连接=3 断开=3 后台剩余=无限
```

- 心跳**连续** = 进程活着
- 心跳**断档** = 被挂起（日志时间戳自己就是证据）

`后台剩余` 读的是 `UIApplication.shared.backgroundTimeRemaining`：
有 `bluetooth-central` 且保持会话时是「无限」，被降级成几十秒就说明后台权要没了。

**③ 进程重启间隔**

每次心跳把当前时间写进 `UserDefaults["bgmon.lastSeen"]`；
冷启动时先读旧值再覆盖（顺序错了差值恒为 0，已修正）：

```
[保活] 进程启动 #5，距上次存活 2.3 小时（说明中间被系统终止过）
```

配合 `willRestoreState` 的日志，就能回答「被杀之后有没有被 BLE 唤醒」。

### 二、预认证定时器记录「计划 vs 实际」

```swift
let plannedAt = Date()
try await Task.sleep(29s)
let actual = Date().timeIntervalSince(plannedAt)
if actual - 29 > 2 { 警告：进程在这段时间被挂起过 }
```

`Task.sleep` 在挂起时不会按时唤醒，恢复后才补执行。所以：

```
[保活] 预认证定时器被延迟：计划 29s，实际 302.4s（偏差 +273.4s）—— 进程在这段时间被挂起过
```

这是**最直接的挂起证据**，比任何推断都硬。

### 三、接入点

| 位置 | 动作 |
|---|---|
| `AppModel.init` | `BackgroundMonitor.shared.start()` + 三个 `UIApplication` 通知订阅 |
| `BLECentral.didDiscover` | `noteBroadcast()`（在 MainActor 块内） |
| `BLECentral.didConnect` | `noteConnect()` |
| `BLECentral.didDisconnect` | `noteDisconnect()` |
| `PreAuthenticationController.schedule` | 计划/实际偏差 |

### 四、日志判读表（实测用）

| 现象 | 结论 |
|---|---|
| 心跳连续 30s 一条，`状态=后台` | 后台**活着** ✅ |
| 心跳出现 >60s 断档 | 进程被**挂起** |
| `广播累计` 持续增长 | 后台仍在收广播（扫描有效） |
| 心跳在跑但 `广播累计` 不动 | 进程活着，但**扫描停了** |
| 冷启动显示「距上次存活 2 小时」 | 被系统**终止**过 |
| 终止后出现 `willRestoreState` | 被 BLE 事件**唤醒**（恢复机制生效） |
| 预认证定时器偏差 +270s | 那段时间**被挂起** |

### 五、实测步骤（需真机）

**测试 A：短时后台（5 分钟）**

1. 打开 App，走到车边让它开始扫描（或已连接）
2. 上滑回桌面（**不要**划掉 App）
3. 等 5 分钟
4. 回到 App
5. 拉日志筛 `保活`

**测试 B：隔夜（验证系统回收 + 唤醒）**

1. 睡前把 App 切后台（不划掉），手机放车上附近
2. 第二天早上回 App
3. 看日志里有没有「进程启动 #N，距上次存活 X 小时」

**测试 C：强制退出（对照组）**

1. 上滑**划掉** App
2. 走近车、拉门把手
3. 预期：**不响应**（iOS 不会为 BLE 事件重启被用户强制退出的 App）

### 版本

**4.2 / build 42**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 仍无法安装：`CoreDeviceError 4016`。
> 诊断结果：`CurrentlyAssertableStates: []`，缺
> `remoteServiceDiscoveryTrustedConnectivityAvailable` + `powerAssertionTaken`，
> 即**设备必须解锁且屏幕亮着、并已信任此电脑**。
>
> 待装：3.6 / 3.7 / 3.8 / 3.9 / 4.0 / 4.1 / 4.2。

---

## v4.1（2026-10-29）—— 修 `resetCentral()` 丢恢复标识 + 后台能力盘点

### 一、修了一个真 bug：重建 manager 时丢了 RestoreIdentifier

```swift
// 旧
central = CBCentralManager(delegate: self, queue: .main)
```

`resetCentral()`（状态卡在 `.unknown` 时的自救路径）重建出来的 manager
**没有带** `CBCentralManagerOptionRestoreIdentifierKey` —— 也就是说一旦用过这个
自救，App 就永久失去「系统会在 BLE 事件时唤醒它」的能力，直到下次冷启动。

改为统一引用常量：

```swift
private static let restoreIdentifier = "com.mmxisme.gkuiblekey.central"
```

### 二、后台能力盘点（回答「不打开 App 能用吗」）

| 能力 | 后台可用 | 说明 |
|---|---|---|
| Siri / 快捷指令 / 控制中心控车 | ✅ | `supportedModes = .background`，元数据 `supportedModes = 1` |
| 解锁 / 闭锁 / 后备箱 / 寻车 | ✅ | 后台启动进程执行，无界面，约 1–2 秒 |
| 查车辆状态 | ✅ | 只读广播缓存，不连车 |
| 无感进入（拉门把手解锁） | ✅ | **车端 PEPS 功能**，开过一次 `0x11` 后车端自己工作 |
| 预认证保活（29s 循环） | ⚠️ | 见下面三个缺口 |
| 点火位置标定 | ❌ | 必须前台（要连续 90 次 RSSI 采样） |

### 三、三个真实缺口

**① 后台扫描收不到重复广播**

`scanForPeripherals(..., options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])`
在后台会被系统忽略：`didDiscover` 只在该设备**第一次**出现时回调一次。

影响：RSSI 滑窗 / 距离判定在后台断流 —— 只影响「App 自己判断远近」，
不影响控车命令（那条路径是连接后直接发包）。

**② `Task.sleep` 定时器在 App 挂起后停摆**

`PreAuthenticationController.schedule(after:)` 用的是 `Task.sleep`。
App 进入挂起状态后这个 Task 不会按时醒，29 秒循环实际会停。

**③ `location` 后台模式是空壳**

```swift
locationManager.allowsBackgroundLocationUpdates = true
locationManager.pausesLocationUpdatesAutomatically = false
```

两行都设了，但**从来没有 `startUpdatingLocation()`**，
也没有 `CLCircularRegion` / `CLLocationManagerDelegate`。
也就是说声明了后台定位，却没有用它做任何唤醒。

### 四、要补的话，标准做法是地理围栏

```
记录车辆位置（首次连接时取 GPS）
  → CLCircularRegion(center: 车, radius: 300~500m) + startMonitoring(for:)
    → 进入区域：系统唤醒 App（即使已被系统终止）→ 启动扫描 + 预认证
    → 离开区域：停止，省电
```

这正是原 App 声明 `location` 后台模式的用途。需要补 `CLLocationManagerDelegate`。

### 五、诚实的边界

- **「不打开 App 控车」**：100% 可靠 ✅
- **「不打开 App 靠近自动解锁」**：车端负责，可靠 ✅
- **「不打开 App 也能点火」**：依赖预认证在后台存活，**尽力而为**，无法保证。
  另外 iOS 一旦用户从多任务里**强制划掉 App**，系统不会因 BLE/定位事件重启它，
  这条对所有第三方 App 都成立。

### 版本

**4.1 / build 41**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 仍未安装（`CoreDeviceError 4016` 锁屏）。
> 待装：3.6 / 3.7 / 3.8 / 3.9 / 4.0 / 4.1。
> 🔴 签名 profile 2026-10-31 过期。

---

## v4.0（2026-10-29）—— 用 `supportedModes = .background` 硬保证「不跳 App」

### 问题

v3.8/v3.9 用的是 `static var openAppWhenRun: Bool { false }`。

**iOS 26 起这个属性已被废弃**，SDK 里明确标注：

```
@available(iOS, deprecated: 26.0, message: "Please provide 'supportedModes' instead")
static var openAppWhenRun: Bool { get }
```

虽然它仍会通过兼容层推导出后台模式，但既然部署目标是 iOS 27，
继续依赖一个废弃属性来保证「不跳 App」是不该的 —— 一旦兼容层行为变化，
控制中心点一下就会把 App 拉到前台。

### 改法

6 个 Intent 全部改为：

```swift
static var supportedModes: IntentModes { .background }
```

`IntentModes` 是 iOS 26 新增的 OptionSet：

```swift
public static var background: IntentModes
public static var foreground: IntentModes
public static func foreground(_ mode: ForegroundMode) -> IntentModes  // .immediate/.deferred/.dynamic
```

`.background` = **只允许后台执行**，系统不会把 App 切到前台。

### 已用构建产物验证

`Metadata.appintents/extract.actionsdata` 里 6 个 Intent 全部是：

```json
"openAppWhenRun": false,
"supportedModes": 1          // 1 = 仅 .background
```

（若包含前台模式，这个值会带上 foreground 的位。）

### 澄清一个容易误解的点

`.background` 说的是「**不显示界面**」，不是「不启动进程」。

App 被系统回收后，点控制中心里的快捷指令，系统会：
1. 静默启动 App 进程（无 UI，不停留在桌面）
2. 在进程里跑 `perform()` → BLE 连接 + 鉴权
3. 结束后进程继续按系统策略存活或回收

所以看不到 App 界面，但蓝牙命令是真的执行了。

### 仍然会有的一点点视觉反馈（系统行为，非 App 控制）

- **Siri**：会念一句「已解锁」
- **控制中心**：可能有一个系统的运行提示浮层，可在
  「快捷指令 → 该快捷指令 → 详情」里关掉「运行时显示」

### 顺带确认：锁屏也能用

`KeyStore` 写 Keychain 用的是 `kSecAttrAccessibleAfterFirstUnlock`
（不是 `WhenUnlocked`），所以设备**开机后解锁过一次**之后，
即使锁屏状态下从控制中心触发也能读到密钥、完成鉴权。

### 版本

**4.0 / build 40**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 仍未安装（`CoreDeviceError 4016` 锁屏）。3.6 / 3.7 / 3.8 / 3.9 / 4.0 待一并安装。
> 🔴 签名 profile 2026-10-31 过期。

---

## v3.9（2026-10-29）—— 拆出 4 个无参动作，适配「控制中心 / 快捷指令」

### 问题

v3.8 只有一个带参数的 `VehicleControlIntent(action:)`。这在本 App 内部没问题，
但**快捷指令 App 的动作列表是按 Intent 类型列的**：

- 只会显示一条「控制车辆」
- 用户每建一个快捷指令，都要再进二级菜单配一次参数
- 加到控制中心后想换动作，得回快捷指令里重新配

### 改法：每个动作一个无参 Intent

新增 4 个独立动作（`Sources/Intents/VehicleIntents.swift`）：

| Intent | 动作名 | 控制码 |
|---|---|---|
| `UnlockVehicleIntent` | 解锁车辆 | `0x02` |
| `LockVehicleIntent` | 闭锁车辆 | `0x01` |
| `TrunkVehicleIntent` | 开/关后备箱 | `0x03` |
| `FindVehicleIntent` | 寻车 | `0x06` |

加上原有的 `VehicleStatusIntent`（车辆状态），快捷指令 App 里会看到 5 条独立动作，
建快捷指令只要「搜到 → 保存」两步。

`AppShortcutsProvider` 的短语也改为绑到这些无参 Intent 上 ——
Siri 命中后直接执行，不会在带参 Intent 里追问「哪个动作」。

带参的 `VehicleControlIntent` 保留作为「通用」入口（想用一个动作覆盖全部时用）。

### 注册已验证

构建产物 `Metadata.appintents/extract.actionsdata` 中：

```
UnlockVehicleIntent ✓  LockVehicleIntent ✓  TrunkVehicleIntent ✓
FindVehicleIntent ✓    VehicleStatusIntent ✓  VehicleControlIntent ✓
```

### 怎么加到控制中心（用户操作，App 无法代劳）

1. 「快捷指令」App → 新建 → 搜索 **蓝牙钥匙** → 选「解锁车辆」→ 命名保存
2. 下拉打开控制中心 → 左上角 **+** → **添加控制**
3. 搜「快捷指令」→ 添加该控件 → 点它 → 选刚建的那个

> 控制中心里能加的是**快捷指令**（系统自带控件），不是 App 自己的按钮。
> App 自己的按钮要放控制中心，得做 **Control Widget**（iOS 18+ 的
> `ControlWidget`），那必须放在 Widget Extension 里 —— 见 v3.8 的评估：
> 免费个人团队无 App Groups、Xcode 未登录账号生成不了扩展 profile，
> **当前做不了**。

### 版本

**3.9 / build 39**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 仍未安装（`CoreDeviceError 4016` 锁屏）。3.6 / 3.7 / 3.8 / 3.9 四版待一并安装。
> 🔴 签名 profile 2026-10-31 过期。

---

## v3.8（2026-10-29）—— 爱称可改 + Siri / 快捷指令 / 操作按钮

### 一、车辆爱称可改

原来两处硬编码（`RootView.swift:27` 与详情页那一行），现在改为
`@AppStorage("vehicle.nickname")`：

- 主界面车图下方的名字、详情页「车辆爱称」共用同一个键，改完立刻同步
- 详情页那一行改成可点，弹输入框（保存 / 恢复默认 / 取消）
- `VehicleProfile.sanitize()` 去首尾空白、按 Character 截断到 12 字、空串回退默认「爱车」
- **不做多车抽象**：本 App 只服务这一台车，按 cidpu 分键没有意义

### 二、App Intents（Siri / 快捷指令 / 操作按钮）

新增 `Sources/Intents/VehicleIntents.swift`，**不需要新 target、不需要额外 entitlement**。

| Intent | 动作 | 控制码 |
|---|---|---|
| `VehicleControlIntent(action:.unlock)` | 解锁 | `0x02` |
| `VehicleControlIntent(action:.lock)` | 闭锁 | `0x01` |
| `VehicleControlIntent(action:.trunk)` | 开/关后备箱 | `0x03` |
| `VehicleControlIntent(action:.find)` | 寻车 | `0x06` |
| `VehicleStatusIntent` | 查状态（**不连车**，读广播缓存） | — |

`openAppWhenRun = false`：Siri 触发时在**后台**完成
「扫描 → 连接 → 订阅 → `01/02/03` → 等 `04`」，
依赖 Info.plist 已有的 `UIBackgroundModes: bluetooth-central`。

### 三、关键前提：AppModel 必须单例

```swift
public static let shared = AppModel()
@StateObject private var model = AppModel.shared   // App 入口
```

**不单例化就会出现两个 `CBCentralManager`**：Intent 在后台 new 一个，
和 UI 那个同时扫同一台车、抢同一个写特征 → 连接互相打断（表现为「秒断」）。

### 四、Intent 等待结果的机制

`perform()` 是同步触发 + 异步回调，不能直接 `await`。新增：

```swift
public func runIntentCommand(_ action:, timeout: TimeInterval = 12) async -> Bool
```

- 内部用 `withCheckedContinuation` 挂起，`resolveIntent(_:)` 在收到 `04`
  的分支里 resume（`.success/.paired/.acceptedAwaitingNames` → true，其余 false）
- 12 秒兜底，防止蓝牙不可用时 Siri 无限挂住
- `intentContinuation != nil` 时直接返回 false —— 不允许两条命令同时在飞

### 五、Siri 短语（免配置，不需要手动建快捷指令）

```
"用蓝牙钥匙解锁车" / "蓝牙钥匙解锁" / "蓝牙钥匙帮我解锁"
"用蓝牙钥匙锁车"   / "蓝牙钥匙锁车" / "蓝牙钥匙帮我锁车"
"用蓝牙钥匙打开后备箱" / "蓝牙钥匙后备箱"
"用蓝牙钥匙寻车"   / "蓝牙钥匙找车"
"用蓝牙钥匙查车状态" / "蓝牙钥匙车锁了吗"
```

`\(.applicationName)` 取 `CFBundleDisplayName` = **蓝牙钥匙**。

⚠️ 每个短语**必须**含 `\(.applicationName)`，否则整组会被系统静默丢弃。

**注册已验证**：构建产物里 `Metadata.appintents/extract.actionsdata`
含 5 组 `phraseTemplates`，全部带 `${applicationName}`。

### 六、待验证（真机）

- Siri 首次使用会请求授权
- 系统索引短语需要几分钟（或重启 Siri 触发）
- 车不在范围时，Siri 会回「操作失败」（4 秒命令超时或 12 秒兜底）

### 版本

**3.8 / build 38**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 仍未安装：`CoreDeviceError 4016`（设备锁屏）。
> 3.6 / 3.7 / 3.8 三版待一并安装。
>
> 🔴 **另外：签名 profile 2026-10-31 过期**（免费个人团队 7 天有效期），
> 过期后 App 无法启动，必须重新签名安装。

---

## v3.7（2026-10-29）—— 「查询车端名册」不再被禁用 + CIDPU 标注

### 一、「已登记手机」为什么必须手动查询

这一项**不是懒加载，是协议决定的**：它没有任何广播或连接时的自动下发。

依据（反汇编 + 日志双证）：

```
-[IBVehicle requestPairedDevicesNames] @0xa30c
  → openConnexionForCommand:0x0D
    → 走完整鉴权 01 → 02 → 03
      03 帧末尾 command = 0x0D
    → 车端回 0x04（受理）+ 0x0F（名册）
```

`0x0F` 的负载是 **101 字节**：

```
0F | 5 个 20 字节槽位 = 100 字节
     非空槽 = 名字 UTF-8 + 0x00 补齐（实测 "iPhone"）
     空槽   = 全部 0xFF
```

原 App 25 天日志里 `0x0d` 只出现 **1 次**、`0x0F` 也只出现 **1 次** ——
说明原 App 同样只在用户主动点「查询」时才发。

**所以「未知（点下方「查询」）」是正确状态**，不是 bug。

### 二、修掉「未连接时按钮变灰点不了」

```swift
// 旧
.disabled(!model.ble.isWriteReady)
```

查询命令要走完整鉴权链，未连接时自然发不出去 —— 但这个 `disabled`
让用户必须先随便控一次车把链路拉起来才能查询，属于「点了没反应」的同类问题。

改为：只判蓝牙是否可用，其余交给 `AppModel.perform` 自动连接后补发
（与主界面控车按钮同一套逻辑，v3.4/v3.5 已实现）。

同时：
- 新增 `MeasuredSession.isQueryingDeviceNames`（`pendingAction == .requestPairedDevices`），
  查询期间按钮文案显示「正在查询…」
- **不加 `.disabled`**：`pendingAction` 在「未收到 0x0F 就断开」的路径下可能残留，
  一旦用它做 disabled 会让按钮永久变灰。重复点只是重发幂等查询，无副作用

### 三、CIDPU 标注改为「后 8 位」

详情页原来写「车辆 ID (CIDPU)」但只显示 `suffix(8)`，容易被当成完整 ID。
改为「CIDPU（后 8 位）」，与 `KeyStore.cidpuDisplayHex` 的实际行为一致。

### 版本

**3.7 / build 37**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 安装仍被锁屏挡住（`CoreDeviceError 4016`），解锁后补装。

---

## v3.6（2026-10-29）—— 修按钮高亮描边与玻璃边缘错位

### 现象

主按钮（解锁 / 闭锁）的绿色高亮描边与按钮玻璃边缘对不上，
四个角错位最明显。

### 根因（两个叠加）

**① 圆角风格不同**

```swift
// 旧代码
.buttonStyle(.glass)
.overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(...))
```

`RoundedRectangle(cornerRadius:)` **默认是 `.circular`（正圆弧）**，
而 iOS 26+ 的玻璃按钮用的是 **continuous（超椭圆）** 圆角。
同样 22pt 半径下，两者只在直边中点重合，往四个角走曲率差异越来越大 ——
这正是「四个角最歪」的原因。

**② `.glass` buttonStyle 在 label frame 内还有一圈 rim**

系统玻璃背景不是严格贴在 label 的 frame 上，而是有内缩。
描边贴着 frame 画，就浮在玻璃外面，形成一圈「双线」。

### 解法：玻璃和描边共用同一个 shape

不再用 `.buttonStyle(.glass)` 让系统去定形状，改为自绘：

```swift
let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

Button { ... } label: {
    VStack { ... }
        .frame(maxWidth: .infinity, minHeight: 76)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(tint.opacity(0.16)).interactive(), in: shape)
        .overlay {
            shape.strokeBorder(isCurrentState ? tint : .clear, lineWidth: 2)
        }
}
.buttonStyle(.plain)
```

- `glassEffect(_:in:)` 的 shape 参数与 `strokeBorder` 的 shape 是**同一个变量**，
  即同一个 path，物理上不可能错开
- `strokeBorder` 是**向内**描边，不会把描边画到玻璃外面
- `.interactive()` 保留按压缩放反馈，`.plain` 保留按钮语义

### 附带

- 主按钮的 `minHeight: 76` + `padding(.vertical, 8)` 让玻璃留出呼吸区，
  高度与原 `.glass` 观感接近
- 次按钮（关窗 / 开窗 / 寻车）圆角仍由系统 `.glass` 决定；
  它们没有描边，不存在对齐问题

### 版本

**3.6 / build 36**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 安装仍被锁屏挡住（`CoreDeviceError 4016`），解锁后补装。

---

## v3.5（2026-10-29）—— 控车链路首次跑通 + 缩短「点按钮后的等待」

### 🎉 首次真机成功

2026-10-29 12:39 / 12:40 实机验证：

```
12:39:47.307  → 01（明文 sd|ed|RndTRx|RND1|rights，RND1=F1 47 5E 28）
12:39:47.480  ← 02（16B 挑战）
12:39:47.480  ✅ 挑战自校验通过（D9 79 AB 6C 8A 5A 14 == 同值）
12:39:47.481  → 03（控制码 0x02 解锁）
12:39:47.569  ← 04 结果：成功（00）
12:39:54     车辆状态更新：未锁
12:40:04     锁车 → 04 00 → 状态更新：已锁
```

**这意味着整条链路（连接 → 订阅 → 鉴权 → 控车）全部正确。**
内置钥匙方案成立，`0x01`/`0x03` 算法与车端完全一致。

### 「点指令后断联几秒」的原因

三层原因叠加，**都不是 bug**：

**① 车端主动断开**（主因）

车端在每条命令执行完就释放链路。原 App 日志同样如此：

```text
17:46:07.107  Data received 22B (0x05)
17:46:07.208  device is disconnected     ← 0.1 秒后
```

这是车端设计，我们无法保持长连接。

**② v3.4 加的 15 秒连接冷却**

为防止「连→断→扫→连」死循环，断开后 15 秒内不自动重连。

**③ 点按钮时要等下一次扫描广播**

`AllowDuplicates = YES` 下广播间隔 1–2 秒，拿到 `didDiscover` 才能 `connect`，
再加连接握手 0.5 秒 + 订阅 0.05 秒。

### 本版优化：直接连已知设备，不等广播

新增 `BLECentral.connectRemembered()`：

```swift
let p = peripheralCache[id]
    ?? central.retrievePeripherals(withIdentifiers: [id]).first
connect(p)      // 不需要扫描
```

`retrievePeripherals(withIdentifiers:)` **不扫描**就能拿到已绑定外设的
`CBPeripheral`，拿到即可 `connect`。

`AppModel.perform` 在未连接时优先走这条路径：

```
点按钮 → connectRemembered() 立即发起连接（~0.5s）
       → 链路 ready → 自动执行（v3.4 的 pendingActionAfterConnect）
```

**省掉 1–2 秒的广播等待**，总延迟从 1.5–2.5 秒降到约 0.7 秒。

没有已知设备时（首次使用 / 系统缓存被 LRU 淘汰）自动回退到扫描。

### 顺带

- `RSSI 未标定（calibration/leaveOffset 缺失）` 的警告是准确的：
  被动进入 / 无感进入依赖标定值，**未标定时不会自动启动**。
  需要走「开发者 → 点火位置验证 → 开始标定」（手机平放扶手箱，90 次采样）。

### 版本

**3.5 / build 35**，`xcodebuild` **0 error 0 warning**。

> ⚠️ 安装时设备锁屏，`devicectl` 报 `error 4016`，待解锁后补装。

---

## v3.4（2026-10-29）—— 补一个致命 bug + 用真实日志验证算法

本版是第一次**用原 App 的真机报文离线验证鉴权算法**，结论：算法全对，
但发现一处会让鉴权「必然失败」的长度判断错误。

### 一、致命 bug：`0x02` 挑战长度判断差一个字节

```swift
// v3.3 及之前（错）
guard payload.count > 16 else { /* Wrong challenge */ }
```

`MeasuredFrame.decode` 返回的 `payload` 是 `bytes.dropFirst()`，所以
17 字节的 `0x02` 帧解出来 `payload.count == 16` → `16 > 16` 为 **false**
→ 每一帧挑战都被判成 `Wrong challenge（0x278）`，鉴权链直接断在第一步。

反汇编 `responseMessageWithData:` @`0x104b4` 判断的是**整帧**长度
（`if ([data length] <= 0x10)`，随后取 `[1,16]`），整帧是 17 字节 → 通过。

```swift
// v3.4（对）
guard bytes.count > 16 else { /* Wrong challenge */ }
```

**为什么一直没被发现**：配对走的是 `0x0D → 0x0E`，完全不经过 `0x02`。
只有真正发 `0x01` 鉴权才会踩到。

### 二、用真实报文验证算法（4/4 通过）

方法：从 `xiaoka_vcc.log` 里取 `01 → 02 → 03` 三元组，反推出当时的 `RND1`，
再用 `Dk1` 重建 `enc1`，然后做两件事验证：

1. **用 `enc1` 解密真实的 `0x03` 帧**，看明文结构是否成立
2. **自校验**：`computed == expected`

`0x01` 帧在日志里被截断（声明 33B，NSData 描述只打 16B），
但段 1 只缺最后 1 字节，用已知的 `sd = 9742355f` 暴力补全 256 种即可复原。

**关键坑**：`Dk1` 在 10-25、10-28 都被重新配对覆盖过，所以必须拿
**10-28 21:12:48 之后**的会话才有意义。我第一次用了 10-04 的会话配
10-28 的 `Dk1`，全部失败，差点误判成「算法错了」。

结果：

| 时间（UTC） | 自校验 | 03 明文结构 |
|---|---|---|
| 2026-10-28 21:13:02 | ✅ | part9 ✓ / 末字节=cmd ✓ / not(part9[0:6]) ✓ |
| 2026-10-28 21:13:32 | ✅ | 同上 |
| 2026-10-28 21:14:02 | ✅ | 同上 |
| 2026-10-29 06:14:38 | ✅ | 同上（末字节 = 0x02 = 解锁） |

**4/4 全过**。同时证实：

- `RndTRx` 在 `0x01` 明文里位于 `[8:11]`，10-28 之后恒为 `0dc312`
  **与 Keychain 里存的值一致** → 我们的「从密钥读 RndTRx」是对的
- `RND1` 在 `[11:15]`，每次随机
- `buf1` 的切片排列（`rev + rev[1:4] + rev[0:1] + rev[2:4] + rev[0:2] + rev[3:4] + rev[0:3]`）正确
- `enc1 = AES-CBC(零IV, key=Dk1)` 正确
- `buf2 = part9 || NOT(part9[0:7])`、`computed = enc2[2:9]` 正确
- `buf3 = part9 || NOT(part9[0:6]) || command` 正确

### 三、连接冷却（防「连→断→扫→连」死循环）

v3.1 加了扫描常开，而 `didDiscover` 里是「命中本车就无条件 connect」。
两者叠加：车端执行完命令主动断开 → 重扫 → 扫到立刻又连 → 又断……

原 App 不是这样：日志里「断开 → Stopping scan → Request for connection」
之间隔 6 秒，且由用户操作触发，**不会扫到就连**。

- 新增 `lastDisconnectAt` + `autoConnectCooldownSeconds = 15`
- 冷却期内只扫描、不自动重连
- `forceConnectOnce` 可无视冷却（用户操作时置位）
- 原有的「3 秒内断开 5 次暂停重扫 30 秒」保留作兜底

### 四、点按钮时未连接 → 自动连接并执行

原来 `perform()` 在 `!ble.isWriteReady` 时只弹提示。现在：

```
记住动作 → forceConnectOnce（无视冷却）→ 链路 ready 后自动执行
```

配合「扫描常开」，点一下按钮就能完成「扫到 → 连接 → 订阅 → 鉴权 → 执行」。

### 版本

**3.4 / build 34**，`xcodebuild` **0 error 0 warning**，已安装到 iPhone 17 Pro。

---

## v3.3（2026-10-29）—— 修 v3.2 两个 bug：「显示非内置」与「少三项」

用户反馈：点了「重新应用内置钥匙」，按钮提示成功，但仍显示
**「当前生效：非内置钥匙」**，且密钥列表**少了三项**。

两个都是 v3.2 的实现错误。

### Bug ① `isActive` 用错了读取方法

```swift
// v3.2（错）
KeyStore.shared.getString(.dk1)?.lowercased() == expectedDk1Hex
```

`getString` 的实现是 `String(data: $0, encoding: .utf8)` —— 拿 **16 字节
二进制密钥**去做 UTF-8 解码，几乎必然返回 `nil`。所以 `isActive`
**永远是 false**，无论密钥写没写进去。

```swift
// v3.3（对）
guard let d = KeyStore.shared.get(.dk1), !d.isEmpty else { return false }
return d.map { String(format: "%02x", $0) }.joined() == dk1Hex
```

### Bug ② 少写了 2 个字段，但界面上表现为「少三项」

v3.2 用 `importBackup(backupString)` 写入，那个 base64 串里只有 9 项。
而 `KeyStore.Key.allCases` 有 13 项，`KeyInspectorView` 是**全量列出**的，
所以缺的显示成 `—`。

| 缺的字段 | 是否必需 | 说明 |
|---|---|---|
| `communicationKey` | **必需** | `saveKeys` 里它是 `ckTRxSP` 的兼容别名（双写）；缺了 `verifyKeyIntegrity` 直接报「缺少 communicationKey」 |
| `core` | 否（无代码读） | 原 App 的遗留键，存完整 `0x0E` 帧 62B |
| `idfv` | 否 | 之前 App 已写过，通常不会缺 |

v3.3 改成**结构化逐项写入**（不再依赖 base64 串），共 11 项：

```swift
(.dk1, dk1Hex), (.sd, sdHex), (.ed, edHex), (.rndTRx, rndTRxHex),
(.rights1, rightsHex), (.keyType, keyTypeHex), (.ckTRxSP, ckTRxSPHex),
(.communicationKey, ckTRxSPHex),      // ← v3.2 漏的
(.keyTail, cidpuHex),
// 另加 string 型 pairedCIDPU、二进制 core（合成 62B 0x0E 帧）
```

`core` 用 `composeKeyFrame()` 合成：
`0E | Dk1(16) | sd(4) | ed(4) | RndTRx(3) | rights(1) | keyType(1) | CkTRxSP(16) | tail(16)` = **62B**，
与 `0x0E` 帧布局完全一致。

### 附带修掉的两个隐患

**① 标记改成版本串，让 v3.2 的残留能自愈**

v3.2 写完就把 `UserDefaults` 标记置成 `true`。如果只判 Bool，
升级到修复版后 `applyIfNeeded()` 会继续跳过 → **缺的字段永远补不上**。

改成存版本串 `"v2"`：
- v3.2 留下的 `true` → `string(forKey:)` 读成 nil ≠ `"v2"` → 自动重写一次
- 之后写入 `"v2"` → 不再重复
- **解绑车辆不会清标记**，解绑后是自己配对，不会被内置钥匙干扰

**② `apply()` 的成功判定改成「读回比对」**

v3.2 是 `n > 0` 就算成功（`importBackup` 的写入条数）。
现在改成写完 `guard isActive` —— 按钮提示不会再说「成功了」但其实没写进去。

### 界面

「内置钥匙」卡片增加 `字段不全` 橙色标记（`BuiltInKeys.isComplete`），
一眼能看出 Keychain 里是不是 11 项齐全。

### 版本

**3.3 / build 33**，`xcodebuild` **0 error 0 warning**，已安装到 iPhone 17 Pro。

---

## v3.2（2026-10-29）—— 内置原 App 的有效钥匙

> 前置：加密备份里的 `IBSavedKeys` 已成功解出（方法见
> `tools/decrypt_keychain.py` 与桌面记录 14.3）。

### 一、内置钥匙 `Sources/Keychain/BuiltInKeys.swift`

把原 App 最后一次配对成功（`cdat = 2026-10-28 13:12:48Z` = 北京 21:12:48）
拿到的 7 字段 + cidpu + keyTail 内置进 App：

| 字段 | 值（已脱敏） |
|---|---|
| `cidpu` | `01918d11…6ac89ad4` |
| `Dk1` | `3c71e819…c1b077` |
| `sd` / `ed` | `9742355f`（车端级常量） |
| `RndTRx` | `0dc312` |
| `rights` | `f0` |
| `keyType` | `00` |
| `CkTRxSP` | `7156d3cd…17466e` |

> ⚠️ **真实值不写进仓库**：从 v4.3 起凭据移到
> `Resources/builtin-keys.txt`（被 `.gitignore` 排除），
> 仓库里只保留 `builtin-keys.example.txt` 模板。
> 原因：`Dk1` / `CkTRxSP` 是车端认可的真实凭据，
> 一旦提交会永久留在 Git 历史里。

### 二、写入时机

`AppModel.init()` 开头调 `BuiltInKeys.applyIfNeeded()`，成功后
`measured.reloadKeys()`。

**为什么必须显式 reload**：`measured` 是属性初始化器，
`MeasuredSession.init()` 里已经读过一次 Keychain
（`loadKeysFromStore()`）。不 reload 的话 `measured.keys` 还是旧值，
主界面会继续显示「尚未绑定车辆」。

### 三、只写一次（不会覆盖你以后自己配的钥匙）

`UserDefaults` 标记 `builtInKeys.applied.20261029`。首次启动写入后置位，
之后不再自动覆盖。

需要重新应用时：**开发者 → 密钥管理 → 内置钥匙 → 重新应用内置钥匙**
（该按钮不受标记限制，随时可强制覆盖）。

**解绑车辆不清除这个标记** —— 解绑后是干净的无密钥状态，可以直接自己配对；
想改回内置钥匙就点上面那个按钮。

### 四、这把钥匙解决了什么

本机 Keychain 里原有的是 **2026-10-04** 那把（`Dk1 = 94a1d624…`），
车端从未真正写入槽位（诊断仪判「配对失败」）。所以：

- `CkTRxSP` 与有效钥匙**相同** → `0x01` 帧能构造、能发出去
- `Dk1` **不同** → 车端验不过 → 拒绝 → 断链（「连上秒断」的物证）

内置的这把 `Dk1 = 3c71e819…` 是车端确认有效的（原 App 现在能正常控车），
用它可以把「协议实现是否正确」和「配对环节」彻底分开验证。

### 安全边界

- 这是本车真实凭据，**不要把 App 分发给任何人**
- **与原 App 是同一把钥匙**，使用时把原 App 彻底划掉，否则两边同时往
  FF11 写帧，车端收到的字节流会混

### 版本

**3.2 / build 32**，`xcodebuild` **0 error 0 warning**，已安装到 iPhone 17 Pro。

---

## v3.1（2026-10-29）—— 补齐三处流程层差异

> v3.0 把协议层对齐完了，但「流程编排」还有三处没对上。本版补完。
> 三项依据都是 `Docs/evidence/xiaoka_vcc.log` 的时间序列 + 反汇编。

### 一、扫描常开（影响最大）

原 App 的扫描是**常开**的，不是"用到才扫"：

```text
17:46:06.988  Start scan
17:46:07.107  Data received 22B (0x05)
17:46:07.208  device is disconnected      ← 断开时扫描已经在跑
17:46:07.311  Stopping scan
17:46:07.313  Request for connection      ← 车端一广播就 2ms 内连上
```

我们原来：连接成功即 `stopScan()`，断开后停着不动，只能等
`autoConnect()`（启动/回前台）或用户手动操作。后果两个：

1. **无感进入的 RSSI 采样断流**（那条链路依赖持续扫描）
2. 点按钮要等 1–2 秒扫描 + 连接，原 App 是 0.1 秒

现在 `didDisconnectPeripheral` 末尾调用 `resumeScanAfterDisconnect()` 自动重扫。

**防抖**（我们自加的，原 App 没有）：3 秒内断开累计 5 次就暂停 30 秒。
正常使用（每条命令一次连接、车端执行完主动断开）永远触发不到；
只有在车端异常疯狂断连时才会生效，避免「连→断→扫→再连」死循环耗电。

手动断开（`disconnect()` / `cancelConnection()`）走 `suppressAutoReconnect`，不受影响。

### 二、配对改成广播驱动

原 App **没有「点绑定」这个动作**：`keys = 0` 时扫到本车广播，
内部判定 `isUnpairedDevice` 后自动停扫描、连接、发 `0x0D`。

我们原来必须用户点「绑定车辆」才动。

现在 `autoConnect()` 里加：本地 `measured.keys == nil` 且尚未 armed 时，
自动置 `pairingArmed = true`。连接仍由扫描回调里的**归属校验通过**触发
（`cryptedID` 用本机 cidpu 验算），不会误连别人的车。

### 三、预认证周期：6.5 秒 → 29 秒（原来快 4.5 倍）

**先纠正一个误读**。`-[IBVehicle didPassiveStartCompletedWithError:]` @`0xb6cc`：

```asm
0xb710: mov  x20, x0                  ; x20 = self
0xb7d0: ldr  x1, @selector(setTimeBetweenPassiveStart:)
0xb7d4: cbz  x20, #0xb7e0             ; self == nil → 29.0
0xb7d8: fmov d0, #6.5                 ; self != nil → 固定 6.5
```

`cbz x20` 判的是 **self 是否为 nil**（编译器为 weak self 生成的判空），
**不是 error**。`6.5` 是固定值，`29.0` 是走不到的占位。
此前把它读成「成功 6.5 / 失败 29」是错的。

**但日志实测的节奏是 30 秒**（339 次 `0x01` 的间隔分布）：

```text
29.9s ×110   30.0s ×99   30.1s ×36   30.2s ×17   30.3s ×6 …
6.4–7.1s 合计只有 ~6 次
```

说明 6.5 秒之后还有别的门槛（RSSI 滑窗满 10 个值 / 区域判定）把节奏拉到了 30 秒。

我们的实现没有那套前置条件，若按 6.5 秒跑会**比原 App 快 4.5 倍** ——
而车端在 7 秒内不接受第二次加密重连（2026-10-29 06:14:38 成功、06:14:45 加密超时）。

所以改成统一 `retryInterval = 29.0`（29 秒等待 + 约 1 秒执行 ≈ 实测 30 秒），
`didComplete()` 去掉 `success` 参数。`disassemblyInterval = 6.5` 保留作记录，不参与调度。

### 版本

**3.1 / build 31**，`xcodebuild` **0 error 0 warning**，已安装到 iPhone 17 Pro。

---

## v3.0（2026-10-29）—— 原 App 日志全量挖掘后的四项落地

> 前置：加密备份解密成功，取出原 App 25 天完整日志
> （`Docs/evidence/xiaoka_gl.log` 420 KB / `xiaoka_vcc.log` 813 KB）。
> 以下改动全部由日志 + 反汇编双证支撑，无一条来自推断。

### 一、命令超时改成两档（原来统一 30 秒，是错的）

反汇编 `-[IBManager init]` @`0xed40`：

```asm
0xed44: mov x9, #0x4010000000000000   ; IEEE-754 double = 4.0
0xed48: str x9, [x19, x8]             ; _OBJC_IVAR_$_IBManager._commandTimeout
```

`openConnexionForCommand:` @`0x4a84` 再按命令号分档：

```asm
0x4a84: cmp  w21, #0x55        ; 配对
0x4a88: b.ne #0x4b0c           ; 否则取 commandTimeout
0x4a9c: fmov d0, #30.0         ; 配对 30 秒
```

日志实证：5 次 `Command failed. Code : 690` 全部约 **4.09 秒**。

- 新增 `AppModel.commandTimeoutSeconds = 4.0` / `pairingTimeoutSeconds = 30.0`
- 鉴权、控车、无感切换走 4 秒；只有配对 `0x0D` 走 30 秒
- 失败更快，用户不必干等半分钟

### 二、订阅耗时监控 —— bonding 状态的量化判据

原 App 日志里 344 次订阅的耗时分布：

| 耗时 | 次数 | 含义 |
|---|---|---|
| **< 0.3s** | **338** | bonding 已建立，iOS 直接复用 LTK（**中位数 0.056s**） |
| 5–15s | 5 | 这 5 次正是配对，在等用户输 PASSKEY |
| 2.95s 后失败 | 1 | `CBATTErrorDomain Code=15 "Encryption is insufficient."` |

`BLECentral` 现在记录「请求订阅 → 订阅回调」的耗时并据此判读：

- `< 0.3s` 成功 → `bonding 已复用，链路已加密`
- `≥ 0.3s` 成功 → 警告（正常应 <0.3s）
- `≥ 5s` 成功 → 说明这次刚弹 PASSKEY 建立了 bonding
- **1–6s 失败** → 直接给出处置建议（车端 LTK 与手机不匹配）

这比 `error.localizedDescription` 可靠：同样的失败，iOS 有时报
`Encryption is insufficient`，有时报 `Failed to encrypt the connection`。

### 三、配对前置检查 —— 修掉「零响应」的真正原因

日志里 `didFoundVehicleRequestPairing` 出现 **9 次，全部 `keys = 0`**；
`keys = 1` 时只有 `didShowVehicle`（解析状态），**绝不触发配对**。

反汇编 `-[IBVehicleManager updateVehicleWithDevice:]` @`0xd220`：

```asm
0xd300: initWithDevice:cidpu:   ; 内部 checkCryptedID: 校验广播归属
0xd318: cbz x0, #0xd3b8         ; 不是本车 → 丢弃
0xd320: isUnpairedDevice
0xd32c: cbz w0, #0xd3b8         ; 已配对 → 丢弃
0xd368: initWithoutKey          ; 仅未配对时创建"无密钥车辆"
```

**结论**：`0x0D` 只在「本地无密钥」时才该发。我们之前本地留着上次失败的旧密钥，
照样发 `0x0D` → 车端不受理 → 零响应 → 30 秒超时。

- `startFullPairing(force:)` 检测到 `measured.keys != nil` 时**主动阻止**并说明原因
- `PairingView` 弹出说明（含「先去解绑」的路径），不再表现为"点了没反应"

### 四、错误码表补传输层

原 App 日志里只有两种失败码，均来自
`callDidSendCommandFailedWithMessage:code:` 的透传：

| code | 次数 | 含义 |
|---|---|---|
| `690` | 5 | 命令超时（4 秒） |
| `310` | 1 | 加密超时（`CBError.code 15` 透传）—— 车端 LTK 不匹配 |

新增 `ErrorCodeTable.transportErrors`，`message(for:)` 优先查它。

### 其它已确认无差异的项

- **MTU**：原 App `The MTU is : 182`，来源是
  `-[VCBTransportProtocolManager sendData:]` @`0xd744` 调用
  `maximumWriteValueLengthForType:` —— 与本 App 的
  `p.maximumWriteValueLength(for: .withoutResponse)` 完全一致
- **命令码表**：`01` lock / `02` unlock / `03` trunk / `04` windowUp /
  `05` windowDown / `06` panic（寻车）/ `0C` passiveStart（`0x03` 帧的
  command）/ `0D` requestPairedDevicesNames / `11` enablePassiveEntry /
  `12` disablePassiveEntry / `55` pairing —— 与本 App 一致
- **`0x0F` 设备列表**：101 字节 = 1 字节命令 + **5 个 20 字节槽位**
  （`69 50 68 6f 6e 65 00…` = "iPhone" 补零，空槽 `ff ff ff`）—— 一致
- **原 App 每条命令都是「连接 → 鉴权 → 执行 → 车端断开」**，单次约 1.2 秒；
  `0x05` 状态帧到达后 0.2 秒车端主动断开 —— 与本 App 行为一致

### 未确认项（不猜）

- **`0x10` 命令**：25 天日志里只出现 1 次
  （`2026-10-04 17:46:06`，`03 …10` 18 字节，车端回 `04 00` 成功）。
  该时段 `gl.log` 已轮转，无法确定用户当时点了什么。语义未知。

### 版本

**3.0 / build 30**，`xcodebuild` **0 error 0 warning**，已安装到 iPhone 17 Pro。

---

## v2.9（2026-10-29）

### 交互审查：修掉「点击无反应」，清理无用入口

#### 1. 8 处静默禁用 → 改为可点击 + 明确提示

原先控车按钮直接 `.disabled(!isWriteReady)`：未连接时按钮变灰、**点了毫无反馈**，
用户分不清是"没连上"还是"App 坏了"。

| 位置 | 改动 |
|---|---|
| 解锁 / 闭锁（主按钮） | 去掉 `.disabled`，未连接时点击弹「车辆尚未连接，指令发不出去…」+「去连接」按钮 |
| 后备箱 / 关窗 / 开窗 / 寻车 | 同上 |
| 「开始标定」 | 同上，弹「标定需要连接车辆后才能开始」 |
| 配对页状态条 | 三种情况分别回应：已绑定 → 提示先解绑；配对中 → 提示确认诊断仪窗口；未绑定 → 重新发起 |

视觉上用 `.opacity(0.55)` 表示「当前不可执行」，但仍可点——**任何一次点击都有回应**。

#### 2. 清理无用入口

| 项 | 处理 | 理由 |
|---|---|---|
| 「关于」页 | 删除入口，版本号并入开发者页底部（`2.9 (29)`） | 只显示版本号，多一次跳转无意义 |
| 「校验密钥完整性」 | 删除入口 | 与诊断页「运行自检」重复；启动时仍会自动校验一次 |
| 「实时日志浮窗」开关 | **保留** | 排障必需（悬浮实时日志），删了会削弱诊断能力 |
| 「运行自检」 | **保留** | 诊断页核心工具，认证/时间量向量都靠它 |

`AboutView.swift` 保留但标注「当前无入口」，避免删掉后将来重写。

#### 3. 修掉一处死描述

「密钥管理」副标题原为「检视 / 备份 / 恢复 / **导入**」——**从原 App 导入密钥的功能
早在 2026-10-25 就移除了**（`KeyInspectorView` 顶部注释明确说明），
留着"导入"会让人去找不存在的能力。已改为「检视 / 备份 / 恢复」。

### 版本
- **2.9 / build 29**，`xcodebuild` **0 error 0 warning**
- 未安装：`devicectl` `error 4016`（设备锁屏）

---

## v2.8（2026-10-29）

### 剩余 6 项缺口全部对齐

| # | 缺口 | 结论 | 动作 |
|---|---|---|---|
| 1 | `writeValue` 的 type | **确认 = `withoutResponse`** | 无需改，本来正确 |
| 2 | 缺 4 个分门「锁」状态 | 确实缺（bit4~bit7） | 补齐 |
| 3 | 缺出范围状态机 | 确实缺（9 秒） | 补齐 |
| 4 | 无 peripheral→device 映射 | 语义差异 | 补齐校验 |
| 5 | 缺 `didRequestWelcome` | **只是 getter（读 ivar），不是功能** | 无需实现 |
| 6 | 缺 `didNotReceiveDataWithError:` | 由 #3 的 9 秒超时覆盖 | 无需单独实现 |

#### 1. `writeValue` type 确定 = `withoutResponse`

之前的困惑源于参数位置数错了。`-[VCBDevice sendData:]` @`0x99c4`：

```asm
0x9bf4: bl  objc_msgSend        ; [self writeCharacteristic] → 返回 CBCharacteristic
0x9c00: mov x23, x0             ; x23 = characteristic（不是 type）
0x9c04: mov w4, #1              ; ★ x4 = 1 → CBCharacteristicWriteWithoutResponse
0x9c08: mov x0, x22             ; receiver = peripheral
0x9c0c: mov x1, x24             ; @selector(writeValue:forCharacteristic:type:)
0x9c10: mov x2, x27             ; data
0x9c14: mov x3, x23             ; characteristic
0x9c18: bl  objc_msgSend
```

`writeValue:forCharacteristic:type:` 的参数是 **x2=data / x3=characteristic / x4=type**。
`mov w4, #1` = Write Command。**结论：本 App 的 `.withoutResponse` 正确，无需改动。**

> 说明：此前代码注释里引用过一条「2026-10-04 HCI 抓包」的说法，**该结论已作废**，
> 现已删除，改以纯反汇编为依据。

#### 2. 分门「锁」状态补齐（`parseDoorsStatus:` 8 位全解析）

反汇编里 `substringWithRange:` 的起始位依次是 `7,6,5,4,3,2,1,0`，
而 `hexToBinary:` 高位在前 → **第 7 个字符 = bit0**。所以：

| 位 | 字段 |
|---|---|
| bit0~bit3 | FL / FR / RL / RR **门关闭**（原有）|
| bit4~bit7 | FL / FR / RL / RR **门已锁**（本次补）|

对应 `-[IBVehicle isFLDoorLocked]` 等 4 个属性。

#### 3. 出范围机制补齐（9 秒）

`-[VCBDevice resetWithTimeout]` @`0x9fb4`：

```objc
[self cancelTimeout];
[self performSelector:@selector(deviceWhentOutOfRange) withObject:nil afterDelay:9.0];  // fmov d0, #9.0
```

即**每收到一帧就重置 9 秒计时，超时判定设备已远离**，进而触发
`-[IBVehicle vehicleWentOutOfRange]` @`0xa800`。

实现：`BLECentral.resetRangeTimeout()`（收到数据即重置）+ `isInRange` +
`onWentOutOfRange` 回调；`AppModel` 收到后调 `preAuth.resetEdge()`。
断连时 `cancelRangeTimeout()`。

**修复的实际问题**：原先只在「断连」时复位被动进入边沿，
**「连着但走远」不会复位**，回来时不再触发一次被动进入。

#### 4. peripheral → device 映射校验

原 App 在 `peripheral:didDiscoverCharacteristics...` 开头用
`sharedManager` + `deviceWithIdentifier:` 找设备，找不到就回调
`device:didNotReadyToExchangeDataWithError:` 并报
`"The device is nil. The SDK don't know this peripheral."`

我们是单设备模型，等价校验：**特征发现回调必须来自当前跟踪的外设**，
否则 `linkState = .failed` 并记日志。

---

## v2.7（2026-10-29）

### 补齐 `[IBVehicle isValid]` 前置校验

**反汇编依据**（`-[IBVehicle isValid]` @`0x9cb4`）：

```objc
- (BOOL)isValid {
    if ([IBNSString isNullOrEmpty:self.key])   return NO;
    if ([IBNSString isNullOrEmpty:self.cidpu]) return NO;
    return [self.cidpu length] == 0x20;   // 32 个 hex 字符 = 16 字节
}
```

其中 `key` 是 `createANewKeyWithCidpu:` 由 cidpu 派生的车辆对象，**不是配对密钥**，
所以「还没配过」不影响这项校验通过。

**改动**：

| 位置 | 内容 |
|---|---|
| `MeasuredSession.isVehicleValid` | 新增计算属性，判定 `cidpuFullHex` 非空且长度 == 32 |
| `MeasuredSession.buildAuth1()` | 开头加闸；不通过直接返回，日志写明 `Vehicle is not valid` |
| `AppModel.beginMeasuredAuthPairing()` | 同上（配对走同一条 `openConnexionForCommand:0x55`） |

**为什么要补**：原 App 在 `openConnexionForCommand:` 第一行就查它，不通过则**一帧都不发**。
我们之前没有这道闸，cidpu 缺失/格式错时会照发帧、然后干等 30 秒超时 ——
表现为「一律 code 690」，掩盖了真实原因。

### 连接层两处补齐（严格照 Valeo 反汇编）

| 项 | 原 App | 之前 | 现在 |
|---|---|---|---|
| FF12 特征角色 | `setReadCharacteristic:` + `setNotifyValue:`（@`0xa8d4`） | 只登记 notify | 补 `readChar` |
| 置 ready 时机 | 特征发现末尾 `setState:` + `deviceDidReadyToExchangeData:`（@`0xaa88`/`0xaac0`） | 等订阅回调 | 补 `characteristicsReady` |

注意：`characteristicsReady` 只是「可交换数据」的状态标记，**发送时机仍以订阅成功为准**
（原 App 的 `deviceDidSubscriptionDoneWithSuccess:` → `sendData`），避免打乱已验证的路径。

### 新增 `Docs/BIZ_AUDIT_v2.md`

按 `InBlue` 全部业务方法（IBVehicle 103 / IBDevice 74 / IBManager 22 / IBVehicleManager 18 /
IBMessageManager 23 / VCLSManager 19 / IBKey 14）逐域对照本 App 实现，输出对齐度矩阵与缺口清单。

**确认的缺口**（6 项）：

1. `writeValue` 的 type 无确定证据（现用 `.withoutResponse`，依据是一条无法核实的注释）
2. 缺 `device:didNotReceiveDataWithError:`（接收侧超时/失败）
3. 缺 `isInRange` / `vehicleWentOutOfRange` 出范围状态机
4. 缺 4 个分门「锁」状态（`isFLDoorLocked` 等）
5. 缺 `didRequestWelcome`（迎宾）
6. 无 peripheral → device 映射表（单设备场景无实际差异）

### 版本号修正

v2.5（尝试改 bundle id 为 `cn.com.ecarx.*` 以共享 IDFV）**未产生可用构建**：
本机只有 explicit App ID 的 profile，Xcode 未登录账号，换包名无法签名。已回滚。

---

## v2.4（2026-10-29）

### 车辆状态加时效标记

**问题**：状态芯片（已锁 / 门关 / 后备箱 / 未启动 / ACC）与 RSSI 同源 ——
都来自广播解密，都**没有时效标记**。人离开车辆后界面照样稳稳显示「已锁」，
存在「显示已锁、实际已解锁」的误导风险。

**前提认知修正**：车机广播**不是实时流**。日志实测间隔为
`10s / 22s / 28s / 31s / 77s`，最长到 **17 分钟**（车静止时系统限流）。
所以「实时刷新」在物理上做不到，只能做到「最后快照 + 明确告知新鲜度」。

**改动**：

| 位置 | 内容 |
|---|---|
| `MeasuredSession` | 新增 `statusUpdatedAt`，在 `updateVehicleStatus` 里刷新，`reset()` 时清空 |
| `RootView.statusChips` | 芯片下方加一行「X 秒/分钟/小时前更新」 |
| 过期阈值 | `statusStaleSeconds = 120`；超过则图标换成警告三角、文字变橙「可能已不是当前状态」 |
| 刷新机制 | `TimelineView(.periodic(by: 1))` 每秒重算，不依赖业务事件 |

### RSSI 有效期修正 10s → 120s

v2.3 把 `rssiStaleSeconds` 设为 10 秒，依据是「车机广播间隔 1–2 秒」——
**这个假设是错的**。实测间隔最长 17 分钟，10 秒会造成正常扫描中 RSSI 反复消失。
改为 120 秒：既能清掉「已离开范围」的假值，又不误伤正常的稀疏广播。

---

## v2.3（2026-10-29）

### 修复：RSSI 显示值永久冻结（假信号）

**现象**：人已离开车辆十公里，界面顶部仍稳定显示 `-88 dBm`。

**根因**：`BLECentral` 里只有一处赋值 —— `if hit { rssi = rssiValue }`
（扫描命中本车广播时）。**从来没有清空逻辑**，所以一旦扫到过一次，
这个值就永久留在内存里，与当前是否在覆盖范围内完全脱钩。

`RootView` 的注释还写着「RSSI 信号值（连接后显示）」，但实际判断是
`if let r = model.ble.rssi` —— 只要有值就显示，注释与实现不符。

**物理上不可能**：BLE 普通 1M PHY 空旷约 50–150 米，Coded PHY 也就几百米。
十公里绝不可能是真实信号，纯属缓存出来的假值。

**修复**：

| 改动 | 内容 |
|---|---|
| 新增 `rssiUpdatedAt` | 记录最后一次刷新时刻 |
| 新增 `rssiStaleSeconds = 10` | 有效期；车机广播间隔通常 1–2s，10s 收不到即视为离开 |
| 新增 `armRSSIWatchdog()` | 每次收到新值重置看门狗，超时清空 `rssi` / `rssiUpdatedAt` |
| `stopScan()` 调用 `clearRSSI()` | 停止扫描后立刻清空，不再有来源就不该显示 |
| `RootView` 注释修正 | 说明「扫描中 + 10 秒内收到过广播」才显示 |

**设计取舍**：连接后不做周期 `readRSSI()`（原 App 同样不做，会干扰 bonding 协商），
因此连接状态下没有 RSSI 来源，显示值会在 10 秒后自然消失 —— 这比挂一个
永不更新的假值更诚实。

### 已知同源问题（未修，待确认）

车辆状态（已锁 / 门关 / 后备箱 / 未启动 / ACC）同样来自广播解密，
且没有时效标记，离开覆盖范围后也是「最后一次收到的状态」。
理论上存在「显示已锁、实际已解锁」的误导风险，与 RSSI 假值同性质。
是否加时效标记待定。

---

## v2.2（2026-10-28）

### 补全连接链路日志（关键排障缺口）

真机日志暴露了一个严重盲区：**连接 / 服务发现 / 特征发现 / 订阅这四步
原先只写界面文案（`lastMessage`），完全没有落盘**。导致配对失败后
日志里只有「已发 0x0D」和「30s 超时」，看不到中间发生了什么。

新增 `BLECentral.note(_:level:)`，同时更新 `lastMessage` 与日志文件，
并把下列步骤全部接入（`module = "链路"`）：

| 步骤 | 落盘内容 |
|---|---|
| 发起连接 | `正在连接 <name>` |
| 已连接 | `已连接，发现服务中` |
| 服务发现 | `已找到目标服务 F000FF10` / 失败原因（含现有 UUID 列表） |
| 特征发现 | `特征就绪：write=FF11 / notify=FF12，已请求订阅` / 特征不完整 |
| **订阅回调** | **`链路就绪：订阅成功（Notification updated）= BLE 链路应已加密 / bonding 已建立`** |
| 订阅失败 | `订阅失败（bonding 未建立）：<error>` |
| 断连 | `已断开：<reason>` |

**为什么订阅这一行最关键**：它是 BLE bonding（SMP 加密）是否建立的唯一可见证据，
对应原 App 的 `Notification updated for %@ device.`。原 App 在
`didSubcriptionFailedWithError:` 分支下**根本不会发 0x0D**；车端也只在加密链路上
受理业务帧。所以「有没有这一行」直接决定成败归因。

### 真机验证得到的确切失败点（v2.1 实测）

2026-10-28 21:15 在 iPhone 17 Pro + 该车机实测：

```
21:15:32.238  [配对] 配对请求：sidpu=628f…8d2f92 名=iPhone（6字）→ 共 37 字节
21:15:32.239  [TX]   → 0D 62 8F 07 31 14 EC 49 C7 80 97 E1 89 CE 8D 2F 92 69 50 68 6F 6E 65 00…
21:16:44.558  [ERROR] ❌ 命令超时（30s）：Timeout to send command is reached. code 690
```

**车端零响应**：整段日志里没有任何 `RX` 记录（`← xx`）。
0x0D 帧结构本身已核对无误（命令码 + sidpu 16B + 设备名 20B = 37B），
所以排除「帧构造错误」，指向**链路未加密（bonding 未完成）**或
**车端只在配对模式下受理**。

---

## v2.1（2026-10-25）

### 完整分级日志系统

把原先「单文件 + 单一级别」的 `FileLogger` 重写为分级日志系统（`Docs/LOGGING.md`）：

1. **四级日志**：`debug / info / warning / error`，低于阈值**入队前**丢弃（不拼串、不排队）。
2. **统一格式**：`时间戳 [级别] [模块] 消息 ctx{k=v}`，error 自动附调用栈（最多 10 帧）。
3. **级别过滤**：`config.minimumLevel`；运行时可在「日志」页分段控件切换，写入
   `gkuiblekey.log.level` 持久化。
4. **轮转与持久化**：`Documents/Logs/gkuiblekey.log` → `.1` → `.2`…，最多 `maxFiles` 份；
   超 `maxFileBytes`（默认 2MB）轮转，按 `retentionDays`（默认 7 天）每小时清理。
5. **线程安全**：文件/内存写入单串行队列；`config` 用 `NSLock`；类标 `@unchecked Sendable`，
   可从任意线程/actor 调用。
6. **脱敏**：`Dk1/sd/ed/RndTRx/rights/keyType/CkTRxSP` 字段值与敏感上下文 key 掩码为
   `前4…后4(len=N)`；**裸帧字节不打码**（排障必需且不含长期密钥）。
7. **兼容**：原 `append(_:tag:)` 保留为 `info(module:)` 别名。

### 调用点分级落地
- `BLECentral` 的 TX/RX/广播/匹配/状态 → `debug`
- `CarModelView` 资源加载失败 → `warning`
- `MeasuredSession` / `InBluePairing` 的日志按内容自动分级（`❌`→error、`⚠️`→warning、其余→info）

### UI
- 「日志」页新增 **落盘级别** 分段控件（即时生效 + 持久化）
- 新增 **导出** 按钮（`ShareLink`，拼接全部轮转文件）

### 验证
- `xcodebuild build`：**0 error / 0 warning**
- 版本号 2.0→2.1；构建号 20→21

---

## v2.0（2026-10-25）

### 逻辑一致性全量修复（14 处全部按原 App 对齐）

依据 `Docs/LOGIC_DIFF_AUDIT.md` 发现的 14 处不一致，逐项按反汇编行为修复。

#### 高影响
1. **补 30 秒命令超时**（`startCommandTimeout`）
   反汇编 `openConnexionForCommand:` @`0x4988` 的 `scheduledTimerWithTimeInterval:30.0`；
   超时走 `closeConnexionForCommand` @`0x62dc` 的 `didNeedReconnect == NO` 分支
   （全库无 `setDidNeedReconnect:YES`）——**只回报 `Timeout to send command is reached.`
   （code 690），不断开、不重连**。同时删除此前自创的「鉴权1 2.5s 提示」。
2. **补消息序号单调状态机 + 命令白名单**（`lastPacket` / `resetPacketCounter`）
   照 `analyzeMessage:` @`0xfc64`：非白名单命令或 `cmd ≤ lastPacket` 一律判
   `Protocol failed`（code 0x2BB）；每轮命令前清零。
3. **补 `02` 挑战长度校验**
   照 `responseMessageWithData:` @`0x104b4`：`payload.count ≤ 16` 直接判
   `Wrong challenge`（code 0x278），不再进入响应计算。

#### 中影响
4. **`0x0E` 补配对成功语义**：新增 `ActionResult.paired`，`saveKeysData` 后 `phase = .verified`
   （对应 `callDidPairingSuccess` @`0x6d6c`）。
5. **`reset()` 拆分为 `resetCommandOnly()`**：配对收尾只清命令态，保留刚收到的密钥帧/车辆状态
   （原 App `resetCommandTimeout` @`0x64f4` 只 invalidate 定时器）。
6. **去掉退避自动重连**：VCB `didDisconnectPeripheral` @`0x69fc` 只 `setState:0` + 回调，
   **无任何 connect 重试**；重连交给上层 `autoConnect()`。
7. **`0x0F` 标记动作成功**（对应 `parseDeviceNames:` → `callDidSendCommandSuccess`）。

#### 低影响
8. `04` 失败码统一为原 App 的 `0x2BB`（699），`ActionResult.refused` 改 `UInt16`
9. 未知命令按 `default: callDidSendCommandFailed("Invalid Message type", 699)` 处理
10. `connect` 增加 `state != .disconnected` 前置检查（`VCBDevice connect` @`0x8de4`）
11. `didDiscoverServices` 严格要求 `F000FF10`，去掉「第一个服务」兜底
12. `didDiscoverCharacteristics` 补 `error` 检查
13. 订阅成功沿用 Combine，但语义对齐 `deviceDidSubscriptionDoneWithSuccess:`
14. `IBCommand` 补 `0x00`（白名单 `0x4007` 含 bit0）

#### 顺带清理
- 删除死代码：`reconnectAttempt`、`maxReconnectAttempts`（重连循环移除后无引用）

### 验证
- `xcodebuild build`：**0 error / 0 warning**，BUILD SUCCEEDED
- 版本号 1.9→2.0；构建号 19→20

---

## v1.9（2026-10-25）

### 分包与 Keychain 格式对齐原 App + 全量协议规格文档

对 `InBlue` / `ValeoCoreCommunication` 做了系统反汇编，覆盖 10 类运行时数据的
**格式与实现**（帧/广播/连接时序/Bonding/业务方法/Keychain/UserDefaults/RSSI/日志/网络），
并据此补两处实现：

1. **写入分包（真实缺陷修复）**
   原先 `BLECentral.send()` 整帧直发、不分包。反汇编
   `-[VCBTransportProtocolManager splitData:withMTU:]` @`0xdcac` 显示原 App 必定分包：
   - 包数 = `ceil((len + 4) / mtu)`
   - **每包数据量 = MTU − 4**（`sub x8,x20,#4`）
   - 首包前置 **4 字节头 = 包数（小端 uint32）**
   现改为：`len ≤ MTU−4` 时保持整帧直发（实测 MTU=182，已验证车端可正常回 0x0E，
   不引入额外字节）；`len > MTU−4` 时按上述规则分包并打日志。

2. **Keychain 对齐 `IBSavedKeys`（双写）**
   反汇编 `-[VCLSManager saveKeysData:]` @`0x12660` 末尾调用
   `storeDictionary:toKeychainWithKey:@"IBSavedKeys"`；`+[IBKeyChainManager storeDictionary:toKeychainWithKey:]`
   @`0x131b4` 的实现是 **`NSKeyedArchiver` 归档整个字典 → 先 delete 再 `SecItemAdd`**。
   新增 `KeyStore.setIBSavedKeysArchive(_:)` / `getIBSavedKeysArchive()`，
   在 `saveKeyData` 里**双写**：保留原有「一字段一项」主存储，同时写一份与原 App
   完全同构的 `IBSavedKeys` 归档（结构 `{ <cidpu32hex> : {7 个 hex 字符串字段} }`）。

3. **新增 `Docs/INBLUE_PROTOCOL_SPEC.md`**
   10 类数据的反汇编权威规格（含全部偏移/常量/时序/日志判据），作为后续实现与排障的唯一依据。

### 本轮反汇编的关键纠正
- **配对命令是 `0x55`**，`0x0D` 只是 `pairingMessage` 的 payload 首字节；两者不是一回事。
- **`0x55` 配对明确跳过 cidpu 检查**（`formatCommand:toDevice:` @`0xfb48` 的
  `cmp w21,#0x55 ; b.eq`），只有非 0x55 命令才会报 `CIDPU is nil.`（0x276）。
- **`-[IBDevice disconnect]` @`0x6588` 名不副实**：只做 `resetCommandTimeout + startScan`，
  **不断开 BLE**；配对成功后不回任何帧。
- **`isValidCodeString:` @`0x125cc` 是死代码**（InBlue 内无任何 selref 引用，主 App 也无相关字符串）；
  用户所说的「6 位配对码」= **iOS 系统级 BLE SMP Passkey 弹窗**，App 代码不参与。
- 原 App 日志统计：`didFoundVehicleRequestPairing`=1、`Pairing failed`=1（Code 690 超时）、
  `Pairing success`=0、`Key received`=0 —— **原 App 在该车机上从未配对成功过**，
  因此没有成功样本可参照，排障须以 `vcc.log` 的 bonding/Key received 判据为准。

### 验证
- `xcodebuild build`：**0 error / 0 warning**，BUILD SUCCEEDED
- 版本号 1.8→1.9；构建号 18→19

---

## v1.8（2026-10-25）

### 修复配对连接竞态（深挖原 App 配对流程后的反汇编对齐）

深挖原 App 配对全链路（`startPairing` → `openConnexionForCommand:0x55` → `connect` →
`deviceDidConnectedWithSuccess` → `subscriptionToNotification` → `setNotifyValue` 触发 6 位码
→ `deviceDidSubscriptionDoneWithSuccess` → `sendData` 发 0D → 收 0E），确认**配对帧字节级正确**，
同时发现并修复两处真实的连接竞态：

1. **`didDisconnectPeripheral` 的 linkState 覆盖竞态** —— `startFullPairing` 会
   `cancelConnection` 旧连接后立即 `startScan → connect` 新连接，旧连接的**异步**断开回调
   可能在新连接建立后才触发，把新连接的 `.scanning/.discovering/.ready` 覆盖成 `.disconnected`，
   破坏「首次连接 → 触发 6 位码配对」时序（表现为首次不弹码、要退出重进才弹）。
   修复：`didDisconnectPeripheral` 只处理「当前连接」（`peripheral === self.peripheral`）的断开。
2. **`suppressAutoReconnect` 残留** —— 旧连接断开回调被忽略后该标志残留，会抑制「配对成功后
   车端断开」的自动重连。修复：`prepareForPairingScan` 里复位该标志。

### 反汇编关键发现（记录备查）

- `VCBDevice.connect` @0x8de4 要求 `state == 0`（断开态）才连接，否则报「The device is not
  disconnected」——印证「配对前必须确保旧连接已断开」。
- `deviceDidSubscriptionDoneWithSuccess` @0x6138 = 取 `messageTosend` → `sendData`，证明
  **发 0D 严格在 6 位码 bonding 完成（订阅成功）之后**。
- 配对成功后 `disconnect` @0x6588 = `resetCommandTimeout + startScan`，**不断开 BLE**；
  `didNeedReconnect` 机制在「配对后第一次控车」时触发断开重连。

---

## v1.7（2026-10-25）

### 冗余代码清理（对齐原 App 核心逻辑）

删除不属于原 App 核心逻辑的遗留/调试/废弃代码，共移除 1 个文件、净减约 224 行：

1. **`TboxBroadcastCode.swift`（整个文件）** —— 废弃的 Tbox 广播码解析模块；其产出的
   `broadcastRandom` 已确认不参与 `01` 帧（`01` 帧是 AES 两段结构，不含该字段）。
2. **`debugTboxBroadcastCode` 调试开关 + `broadcastCode`/`broadcastCodeRandom`/`onBroadcastCode`**
   —— Tbox 解析结果与回调，均已从主链路移除。
3. **`svcDataPairs`（Service 数据解析）+ Service 数据日志** —— 仅用于「Tbox 广播码补齐」的
   遗留假设；Service 数据在 Valeo 数字钥匙里无用（匹配与解密都走厂商数据）。
4. **`MeasuredSession.broadcastRandom` + `updateBroadcastRandom`** —— 广播随机数兼容字段，
   注释已自认「不参与 01 帧」。
5. **`lastManufacturerData`** —— 只写不读的冗余字段（广播解密实际用 `adv.broadcastData`）。
6. **`onRawData` + `handleRawData`** —— 「裸数据」重复回调：`onFrame` 已无条件回调所有接收
   字节、`didUpdateValueFor` 也已记录 RX 日志；其历史用途（喂 01 帧广播随机数）已被推翻。
7. **`mobileID()` / `isPaired` / `authKey` / `idKey` / `identityKey`** —— GLBLEAuthSDK
   国密版遗留（主 App 未调用，InBlue 密钥体系不用这些键）。
8. **`ConnectTiming` 时序埋点**（结构体 + `timing` 属性 + DiagnosticsView 时序 section）——
   为诊断「点很多次才打着火」临时加的调试埋点，不属于原 App 逻辑。
9. **`maxWriteLength`** —— 记录了 MTU 上限但 `send()` 从未用它分包（帧最大 37B，iOS 自动
   协商 MTU 到 185B+），是「预留但没实现」的冗余。

### 结果

typecheck 0 error 0 warning；BUILD SUCCEEDED。

---

## v1.6（2026-10-25）

### ★ 配对根因修复（诊断仪「配对手机蓝牙钥匙失败」+ 手动点才弹 6 位码）

两个根因，都已定位并修复：

**根因 1：扫描竞态 → 不自动连接 → 要手动点才弹 6 位码**

- `startFullPairing` 里 `cancelConnection`（断开旧连接）是**异步**的，它的
  `didDisconnectPeripheral` 回调把 `linkState` 从 `.scanning` 覆盖成 `.disconnected`，
  导致 `didDiscover` 里 `linkState == .scanning` 判断永远失败 → 扫描到了设备却不自动连接。
- 修复：`didDiscover` 去掉 `linkState == .scanning` 条件，配对等待中无条件连第一个发现的设备。

**根因 2：连接后 readRSSI 轮询干扰 6 位码协商 → 诊断仪判失败**

- 反汇编证据：原 App `didConnectPeripheral` @0x640c 连接成功后**直接 `discoverServices`，
  从不 readRSSI**（`nm`/`strings` 证实 InBlue / ValeoCoreCommunication 里完全没有 readRSSI，
  readRSSI 只在主 App 层的 `readRSSITimer`）。6 位码配对（Passkey Entry）期间，周期 readRSSI
  会干扰 iOS 与车端的协商 → 诊断仪「配对失败」。
- 修复：**彻底移除**连接后的 readRSSI 轮询（`startRSSIPolling` / `stopRSSIPolling` /
  `rssiTask` / `didReadRSSI`），`rssi` 改为从广播回调更新；同时删除已无用的
  `quietMode` / `pendingPairingReconnect` / `exitQuietMode` / `scheduleQuietModeExit`。

---

## v1.5（2026-10-25）

### ★ 配对闭环补全：配对成功后断开重连（诊断仪判失败根因）

- 反汇编发现：`callDidPairingSuccess` @0x6d6c 末尾调用 `disconnect` @0x6588
  （`resetCommandTimeout` + 断开 + `startScan` 重扫）。
  **断开是车端判定「配对完成」的关键信号**——之前 App 收到 0x0E 就停住，
  没断开，车端一直等待 → 诊断仪超时判「配对失败」。
- 修复：收到 0x0E 保存密钥后，`finishPairingWithReconnect()` 断开 + 0.5s 后重扫，
  用新密钥重连完成「配对 → 验证新密钥」闭环。

---

## v1.4（2026-10-25）

### ★ 配对根因修复（重大）

- **纠正配对流程**：原 App 配对**不是**「01→02→03 鉴权链」，而是**直发 0x0D 登记帧**
  → 等车端回 0x0E 密钥，**没有挑战-响应**。
- 反汇编 `+[IBMessageFactory pairingMessage]` @0x13afc 还原真实格式：
  `0x0D + sidpu(16B 常量 628f073114ec49c78097e189ce8d2f92) + 设备名(20B UTF8+零填充)` = 37B
- 修正 `InBluePairing.buildPairingMessage`（此前用「15B 随机 nonce + 字符数」，错误）
- 修正 `beginMeasuredAuthPairing`（此前发 01 全零占位鉴权帧 → 03 自校验必失败；
  现改为直发 0x0D 登记帧）
- **清理旧错误路线死代码**：`preparePairing`、`isPairing` 属性、
  `buildAuth1`/`buildAuth3` 的 isPairing 分支、`buildPairingFirstMessage`
- 新增 `Docs/PAIRING_CLOSURE.md`：配对流程权威闭环（反汇编逐行还原）

---

## v1.3（2026-10-25）

### 浮窗触摸穿透修复

- 根因：全屏透明 `Color.clear` 容器导致 `hitTest` 命中 hosting 根视图而非窗口自身，
  透明区无法穿透，除浮窗外所有触摸被拦截
- 修复：去掉全屏透明容器，`hosting.view` 直接定位为顶部 300×260 固定区域，
  窗口其余透明区 `hitTest` 命中窗口自身 → 穿透
- 折叠时浮窗框保持固定高度（日志区隐藏、留半透明占位），避免 hosting 高度变化
  导致的触摸区域错乱

---

## v1.2（2026-10-25）

### 浮窗位置修正

- 去除 `.ignoresSafeArea()`，浮窗自动避开顶部安全区（刘海/灵动岛）
- 改用 `.topLeading` 对齐 + 宽度收窄到 300，靠左放置，避免遮挡右上角菜单按钮

---

## v1.1（2026-10-25）

### 实时日志浮窗：改为固定位置

- **移除拖动**：拖动与折叠手势冲突、且易拖出屏幕，改为固定顶部居中
- **触摸穿透修正**：透明区用 `.allowsHitTesting(false)`，`FloatingWindow.hitTest` 简化为
  「命中窗口自身才穿透」，避免之前 root view 判断失效导致的触摸拦截问题
- 保留折叠功能（点击标题栏折叠/展开）与自动滚动

---

## v1.0（2026-10-25）

### 低优先级问题集中修复 + 死代码清理

**修复：**
- `discoverCount` 重复自增（诊断指标虚高）
- Gen02 `antennaNumber` 恒 nil（`setAntennaGen2WithData` 也是取 `raw[3]`，修正 antenna 解析）
- `deleteVehicle` 复位不完整（补清 rememberedPeripheralID、锁定态、pendingAction 等）
- 浮窗拖动无边界（加 clamp 到屏幕内，用 GeometryReader 避免 UIScreen.main 弃用）
- 配对页进度圈与「可点击重试」矛盾（isWorking 改为 pairingArmed || isWriteReady）
- KeyInspectorView 用 `.id(refreshTick)` 整页重建丢焦点（改为只重建密钥列表）

**死代码清理（本项目自造、零引用）：**
- `AppModel.settle(_:)`、`AppInfo.fullVersion`
- `CryptoBox` 的 `sha256(Data)`/`hmacSHA256(Data:)` 重载、`AESMode.ecbPKCS7`、`CryptoError.badKeyLength/notImplemented`
- `KeyStore.setUInt32/getUInt32`（getUInt32 还有未对齐 load 隐患）
- `FileLogger.path/readAll/clear`
- `InBlueAuth.firstFrameLength/responseFrameLength`、`PlainOrder` 枚举
- `MeasuredSession.byteCount`、`MeasuredFrame.encode`
- `ProtocolConstants.isUserAction/symbolName`
- `TboxBroadcastCode.describeCandidates`

**过时注释修正：**
- `CryptoBox.randomBytes`（arc4random → UInt8.random）
- `MeasuredSession.hexDescription`（19 字节 → 载荷不含命令号）
- `InBlueAuth` 顺序注释（PlainOrder 引用 → 反汇编栈布局）

---

## v0.9（2026-10-25）

### 全面代码审查后修复的实质 bug

- **点火位置验证 29s 门控错误**：`PassiveStart.check` 误用 `timeBetweenPassiveStart`
  （预认证命令重发间隔）当采样节流，导致区域判定最多 29s 才刷新、密集采样求均值
  分支永远不可达。已删除该门控（反汇编 `checkRssiForPassiveStart` 无此层）。
- **手动断开仍自动重连**：`disconnect`/`cancelConnection` 未抑制 `autoReconnect`，
  导致点「断开」/「解绑」/「配对重置」后链路被立即重连回来。新增 `suppressAutoReconnect`
  标志，并在 `didDisconnectPeripheral` 里消费。
- **Keychain 覆盖写入失败**：`KeyStore.set` 的 `SecItemDelete`/`SecItemUpdate` 缺
  `kSecAttrSynchronizableAny`，导致旧的非同步项删不掉/更新不了，覆盖写密钥会失败。
  已补上，并修正重连 Task 用入参而非 `self.peripheral` 的问题。
- **无感进入切换被拒卡死**：`settlePassiveEntryToggle` 依赖 `lastSucceededAction`
  （仅成功时设置），被车端拒绝时 `passiveEntrySwitching` 卡住、开关一直转圈。
  改用 `pendingPassiveEntryValue != nil` 判断。
- **配对日志不刷新**：`objectWillChange` 只转发 `measured`，补转发 `pairing`/`preAuth`。
- **浮窗内存泄漏**：`FloatingWindowController.hide` 置 nil 但 UIWindowScene 强持有窗口，
  反复开关累积隐藏窗口。改为复用单例窗口、仅切换 `isHidden`。

### 清理过时/自相矛盾注释

- `handlePairingFrame` 双段矛盾注释、`didConnect` 的 quietMode 矛盾注释。

### 新增文档

- `Docs/CODE_AUDIT.md`：全源码审查报告（死代码清单 + 逻辑问题 + 注释问题）。

---

## v0.8（2026-10-25）

### 实时日志浮窗：改为全局悬浮 + 真半透明

- **悬浮在所有界面之上**：改用独立 `UIWindow`（`windowLevel = alert + 1`）承载，
  覆盖 sheet/导航等所有界面（此前放 RootView overlay 会被 sheet 盖住）
- **真半透明**：背景改为深色 `black.opacity(0.62)`，非毛玻璃；文字用亮色
- 触摸穿透：浮窗矩形外区域 `hitTest` 返回 nil，不挡下层操作
- 新增 `FloatingWindowController`（@MainActor 单例 + 自定义 FloatingWindow）

---

## v0.7（2026-10-25）

### 新增：实时日志浮窗

- 主页面悬浮显示实时日志（最近 200 行），半透明毛玻璃材质，可拖动、可折叠
- 开发者菜单「调试」区加开关，UserDefaults 持久化
- 日志按类型着色：发送（→）青色 / 接收（←）绿色 / 错误（❌）红色 / 警告（⚠️）橙色
- `FileLogger` 新增内存环形缓冲区 + `onNewLine` 回调，`AppModel.liveLogLines` 驱动浮窗
- 自动滚动到底部，始终显示最新日志

---

## v0.6（2026-10-25）

### 修复：后台蓝牙权限补全（靠近解锁）

- **补 `UIBackgroundModes: location`**：原 App 声明了 `bluetooth-central` + `location` +
  `audio` + `fetch` + `remote-notification`，本 App 此前只有 `bluetooth-central`，
  缺 `location` 后台模式导致 App 退后台后无法扫描发现靠近的车。
- **定位权限升级支持**：`requestLocationPermission` 增加 WhenInUse → Always 升级；
  init 里设置 `allowsBackgroundLocationUpdates = true` + `pausesLocationUpdatesAutomatically = false`。
- 说明：state restoration（`RestoreIdentifier` + `willRestoreState`）此前已实现，
  本次补齐的是「后台主动扫描」所需的后台定位能力。

---

## v0.5（2026-10-25）

### 新增：标定流程（点火位置验证可用化）

- **逆向还原标定链路**（纠正「标定值车端下发」的误判）：
  - 标定值是 App 本地用双天线 RSSI 采样算的，非车端下发
  - `startCalibration` → `openConnexionForCommand:0x0D` 触发
  - `addRSSI:` @0x801c：按广播 antenna 字段高 4 位分路（0x80=天线1/0x40=天线2）
  - `averageForCalibration` = `10×√((rssi1/10)²+(rssi2/10)²)`
  - 采满 90 次 → `averageOfRSSIArray`（∑/count）→ 写 `<cidpu>_CALIBRATION`
- 实现：
  - `ValeoAdvMatch.Advertisement.antennaNumber`（高 4 位解析天线编号）
  - `PassiveStartJudge` 标定状态机（startCalibration/addCalibrationSample/cancelCalibration）
  - `BLECentral.onDualRSSI`（广播回调分路 RSSI）
  - `AppModel.handleDualRSSI` / `startCalibration` / `finishCalibration`
  - 点火位置验证页加「开始标定」按钮 + 进度条

### 说明

- 标定是本地纯算法，无新车端协议；`antenna` 高 4 位语义已反汇编确定
- 需真机验证 antenna 字段随天线切换的实际行为

### 补充

- 新增「解绑车辆」：`AppModel.deleteVehicle`（清密钥 + 清标定 + 复位，对应 `deleteVehicleWithCidpu:`）
- 新增 `Docs/FUNCTION_AUDIT.md`：原 App 全功能盘点与实现状态（诚实版）

---

## v0.4（2026-10-25）

### 移除

- **移除「手动导入（从原 App 导出）」**：iOS 原版 XiaoKa 没有任何导出密钥的界面，
  密钥无法从原 App 迁移，该功能前提不成立（此前误判可以）。同时降低误写入错误
  密钥污染 Keychain 的风险。
- `auth.key` 等原 App 遗留键名仍保留在 Keychain 枚举中（兼容展示），但 InBlue
  链路不使用（GLBLEAuthSDK 的 SM4 五步协议才用，主 App 未调用该 framework）。

### 保留

- 「备份 / 恢复」功能不变：导出/导入的是**本 App 自己的**密钥（升级/换机兜底）。

---

## v0.3（2026-10-25）

### 配对流程关键修复（真车实测发现）

- **修复配对后秒断、密钥不存的根因**：配对 01 帧占位 RND1 错位 2 字节。
  - 原 App `stringToData:` 每 2 字符 `strtoul`，nil 字段 `"(null)"`(6 字符) = 3 个 `0x00`（非 4 个）
  - 真实占位布局：`9 零 + RND1@[9,13) + 3 零`（旧代码错写成 RND1@[11,15)）
  - 导致 enc1 派生错误 → 03 帧自校验失败 → 车端拒绝并断连
- **修复绑定页收不到配对**：配对兜底自动连接条件过严（要求广播名非空且排在 hit 判定后），
  配对模式下车端广播名空/无 EE01 魔数时永远不自动连。改为配对等待中无条件连第一个设备。
- **修复 `startFullPairing` 分叉漏判**：统一走确定性路径
  `stopScan → cancel → prepareForPairingScan → startScan`。
- **修复配对页状态条「点击」无反应**：死文案未绑动作，加 `onTapGesture` 重试。
- **修复主页不显示「已绑定」**：`measured` 非 `@Published`，UI 不刷新。
  改为订阅 `measured.objectWillChange` 转发到 AppModel。

### 功能新增

- 无感进入（Passive Entry）开关：`enablePassiveEntry`(0x11)/`disablePassiveEntry`(0x12)，
  主界面开关卡片，状态持久化按 cidpu 区分。
- 关于页面：版本号、车型、项目说明。
- 版本号展示：开发者菜单「关于」入口。

### 语义纠正

- 无感进入语义纠正为「靠近车辆拉门把手解锁」单方向，删除无证据的「远离闭锁」。

---

## v0.2（2026-10-25）

- 版本号起步 0.1 → 0.2，建立 0.1 步进约定。
- 引入版本号读取工具 `AppInfo`。
- 修正两处过时注释（CIDPU 长度 16B、AES 模式 CBC 无 padding）。

---

## v0.1（2026-10-24 及更早）

- 初始版本：完整还原原 App InBlue 协议栈（配对、鉴权、控车、广播、车辆状态）。
- 见 `Docs/CLOSURE_FINAL.md`、`Docs/PAIRING_REFACTOR.md` 等历史文档。
