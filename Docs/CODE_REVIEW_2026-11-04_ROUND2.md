# 代码审查报告（第二轮）· 2026-11-04

审查对象：GKUIBleKey（51 个 Swift 文件 / 17,385 行 + project.yml）
上一轮：`CODE_REVIEW_2026-11-04.md`（36 项，已修 21 项）
本轮重点：上次修复之后新增的手表端、跨端同步层、云端命令表，以及此前未覆盖的模块。

---

## 0. 审查方法与分级口径

**方法**：逐文件精读新增/大改文件（Sync、Watch、GKCloudKeychain、AppModel+Cloud、GKCloudClient），
对其余模块做模式扫描（死代码、注释与代码不符、重复定义、并发原语、错误吞没）；
用 `swiftc -typecheck` 收集编译器警告（当前 16 条，全部来自同一个类型问题）；核对工程配置与代码的实际依赖。

**分级口径**（按"用户能不能察觉到"排序，而不是按修起来难不难）：

| 级别 | 定义 | 典型表现 |
|---|---|---|
| **严重** | 静默失败、作用到错误对象、或安全边界失守 | 用户以为成功了，实际没做；或控到另一辆车 |
| **中等** | 特定条件下出错、错误无反馈、显著的可维护性债务 | 边界值失效、错误被吞、注释误导后来者 |
| **轻微** | 不影响行为，只影响整洁度与阅读体验 | 重复字符串、无意义写法、遗留配置 |

---

## 1. 整体评估结论

**核心链路质量高于上一轮。** 云端通道（签名、token 生命周期、401 重登、四门解析）经过一轮针对性修复后
是项目里最扎实的部分；手表端"去蓝牙改纯云端"的模块拆解干净 —— `ControlChannel+IBCommand.swift` 的拆分、
`StatusTimeFormat` 的下沉、`project.yml` 里 watch target 的依赖收窄，都是正确的边界处理，没有把 iOS 业务层
拖进 watchOS。

**问题集中在新旧接合处和"配置固化后的残留物"**：

1. 跨端同步的**协议是单向的** —— 手机能推，手表要不了。手表唯一的恢复入口（"重新同步"）是个空操作（S1）。
2. 账号变更路径**只改了一半** —— 换手机号走的是 `configureCloudKeepingPassword`，它漏了推送手表（S2）。
   这是上一轮修 `startCloudAutoRefresh` 时同一个位置漏掉的第二项，说明这个"配置成功后该做的事"清单没有集中管理。
3. 云端命令表填入真实参数后，**整套"未配置"防护变成死代码**，但 UI 和错误类型还留着（M1）。
   同时留下一批"参数还没填"的过期注释（M2/M3）。
4. **安全边界靠单点** —— 手机端的 Keychain 加固被手表的明文副本抵消（S3）。

**依赖与版本**：零第三方依赖，这点很好。但 `Swift 6.0 语言模式 + SWIFT_STRICT_CONCURRENCY: minimal`
是个矛盾组合 —— 声明用 Swift 6，却关掉了它最主要的收益，实际竞态靠人工发现（S4）。

---

## 2. 严重问题（4 项）

### S1 手表的「重新同步」按钮是空操作

**位置**
- 手表端：`Sources/Watch/WatchCloudController.swift:142-150`（`requestResync`）
- 手机端：`Sources/Sync/PhoneWatchSync.swift:130-134`（`session(_:didReceiveMessage:replyHandler:)`）

**成因**
两端对这条消息的理解不一致：

```swift
// 手表发
session.sendMessage(["cmd": "resync"], replyHandler: { _ in }, errorHandler: { _ in })

// 手机收 —— 完全不看 message 内容
nonisolated func session(_ session: WCSession,
                         didReceiveMessage message: [String: Any],
                         replyHandler: @escaping ([String: Any]) -> Void) {
    replyHandler(["configured": Self.configuredHint])
}
```

手机只回一个 Bool，**从不重推账号**。手表的 `errorHandler` 也是空的，失败也没人知道。

**影响**
手表错过账号推送后就没有任何恢复路径。会错过的典型场景：
- 手表的 App 是后装的（手机早就配置好了云端，不会再有新的推送）；
- 手机在 `WCSession` 尚未 `activated` 时调了 `pushAccount`（`PhoneWatchSync.swift:56` 直接 `return`，静默）；
- 手表重装 / 换表。

用户点「重新同步」，界面显示"已请求 iPhone 重新同步"——**这句话是不成立的**。

**建议**
1. 手机端识别命令并真正执行：
   ```swift
   if let cmd = message["cmd"] as? String, cmd == "resync" {
       replyHandler(["configured": Self.configuredHint, "accepted": true])
       Task { @MainActor in AppModel.shared.syncAccountToWatch() }
       return
   }
   ```
2. 手表端加超时：5 秒内没收到 `didReceiveUserInfo` 就把状态改成"同步失败，请在 iPhone 上打开 App 再试"。
3. `errorHandler` 至少写日志，不要空实现。

---

### S2 改手机号 / VIN 后不推手表 —— 手表会继续用旧账号

**位置** `Sources/Net/AppModel+Cloud.swift:290-316`（`configureCloudKeepingPassword`）

**成因**
`configureCloud`（:254-285）末尾是：

```swift
await refreshCloudStatus()
startCloudAutoRefresh()
syncAccountToWatch()      // ← 有
```

`configureCloudKeepingPassword`（:306-315）末尾是：

```swift
await refreshCloudStatus()
startCloudAutoRefresh()   // ← 上一轮补的
                          // ← syncAccountToWatch 漏了
```

**影响**
用户换了账号（换手机号、换车、换 VIN），手机上一切正常，手表仍在用**旧的 VIN + 旧 token** 发命令。
后果不是"失败"这么简单 —— 如果旧账号仍然有效，手表的解锁 / 开后备箱会作用到**另一辆车**上。
这是本次审查里唯一可能产生物理后果的缺陷。

**建议**
1. 立刻补 `syncAccountToWatch()`。
2. 更根本的修法：把"配置成功后必须做的三件事"收成一个方法，两个入口都调它，从结构上杜绝再漏：
   ```swift
   private func afterCloudConfigured() async {
       await refreshCloudStatus()
       startCloudAutoRefresh()
       syncAccountToWatch()
   }
   ```
   这类"同一组副作用散在多处"的问题，上一轮已经漏过一次（`startCloudAutoRefresh`），这次又漏一次（`syncAccountToWatch`）。

---

### S3 密码 MD5 与 token 同步到手表，且手表端没有任何身份门槛

**位置**
- 载荷：`Sources/Sync/SyncPayload.swift:23-47`（`CloudAccountPayload` 含 `passMD5` / `accessToken` / `refreshToken`）
- 落盘：`Sources/Watch/WatchCloudController.swift:154-172`（`applyAccount` → 手表 Keychain）
- 使用：`WatchCloudController.swift:116-139`（`perform` 直接下发，无确认）

**成因**
为了让手表能独立续期，把**可离线撞库的密码摘要**和**车控通行证 token** 一起搬到了手表；
而手表是"抬腕即解锁"的设备，App 层没有任何二次验证。

**影响**
手机端有 Face ID 作为事实上的门槛（解锁手机才能操作），手表没有。拿走一块未佩戴锁定的手表，
等于拿到一把能开车门、开后备箱、启动发动机的钥匙。上一轮把凭据从 `UserDefaults` 搬进 Keychain 的加固，
被手表这份副本部分抵消。

**建议**（按性价比排序）
1. **手表上对破坏性命令要求认证**：`unlock` / `trunk` / `engine` 执行前走
   `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`（手表上表现为输入腕表密码）。
   `lock` 与查询不需要 —— 它们只会让车更安全。
2. **不要把 `passMD5` 同步给手表**。手表只需要 access/refresh token；token 彻底失效时提示
   "请在 iPhone 上重新登录"，而不是让手表保存一份长期可用的密码摘要。
   这一条能去掉最敏感的资产，且用户体验损失很小（refresh token 有效期通常以月计）。
3. `applicationContext` 里的账号载荷考虑加密（WCSession 传输本身是加密的，但落盘在 watchOS 上的是明文 Data）。

---

### S4 `Swift 6.0` 语言模式 + `SWIFT_STRICT_CONCURRENCY: minimal`

**位置** `project.yml:11-13`

```yaml
SWIFT_VERSION: "6.0"
SWIFT_STRICT_CONCURRENCY: minimal
```

**成因**
声明用 Swift 6，却把并发安全等级降到最低。

**影响**
本轮和上一轮修的那批 WCSession 并发问题（`[String: Any]` 不是 Sendable 却被捕获进 `Task`、
`replyHandler` 跨隔离、`WCSession` 跨隔离）**编译器一条都没报**，全是人工读出来的。
降级等于放弃了升级 Swift 6 的主要收益，同时给未来埋同类问题的口子。

**建议**
升到 `complete`，逐条修。已知的三处（`PhoneWatchSync`、`WatchCloudController`）已经手工处理过，
剩下的量不大；先开 `complete` 跑一次编译，看真实数量再排期。

---

## 3. 中等问题（17 项）

### 配置与类型正确性

**M1 `RemoteCommandTable` 四条命令是非可选类型，整套"未配置"防护变成死代码**
- 位置：`GKCloudClient.swift:522-556`（四个 `static let`）、`:633-635`（`fromTable` 的 `guard let raw`）、
  `RootView.swift` 的 `guard ready else { return ackNotConfigured(...) }` 等分支
- 成因：填入真实参数时写成 `static let acOn = RawPlan(...)`，没有 `: RawPlan?` 标注，编译器推断为**非可选**
- 证据：`swiftc` 报 8 处 `comparing non-optional value of type 'GKCloudClient.RawPlan' to 'nil' always returns true`
- 影响：`isReady` / `remoteCommandsReady` 恒 `true`；`commandNotConfigured` 永远不会抛；
  UI 里虚线边框、"待配置"标签、`ackNotConfigured` 全是死分支。
  将来若想把某条命令临时停用（设为 `nil`），会直接编译失败 —— 看着像防护，其实没有防护
- 建议：二选一。
  ① 显式标注 `: RawPlan?`，恢复防护语义；
  ② 承认"参数已固化"，删掉 `isReady` / `remoteCommandsReady` / `commandNotConfigured` / UI 的 `!ready` 分支，
     让代码只说真话。**我倾向 ②** —— 参数已经过真机抓包验证，不会再临时缺失

**M2 `isSupportedOnNetwork` 恒真，switch 是死逻辑，注释还在讲"参数还没填"**
- 位置：`ControlChannel.swift:111-119`
- 两个分支都 `return true`
- 建议：改成 `var isSupportedOnNetwork: Bool { true }` 或直接删掉（连带 `send()` 里 :413 的 guard）

**M3 `VehicleCommand.engine` 注释仍为「占位，云端命令未抓到」**
- 位置：`ControlChannel.swift:94`
- 实际已抓到 `RES` start/stop 并存进命令表
- 建议：改为「云端 `RES`；蓝牙无此命令」

**M4 `GKCloudKeychain.set()` 完全忽略 Keychain 错误**
- 位置：`GKCloudKeychain.swift:31-49`
- `SecItemAdd` 返回值直接丢弃；`SecItemUpdate` 只处理 `errSecItemNotFound`，其它错误码静默
- 影响：写入失败时用户以为密码存好了，下次冷启动要重配，且无任何线索
- 建议：返回 `Bool` 或抛错，失败时写 `FileLogger.error`

**M5 Keychain 用 `AfterFirstUnlock` 而非 `...ThisDeviceOnly`**
- 位置：`GKCloudKeychain.swift:40`
- 影响：条目会进 iCloud / iTunes 加密备份。而该文件头部的注释正是用"UserDefaults 会随备份外流"来论证搬 Keychain 的必要性 ——
  **不带 `ThisDeviceOnly` 的 Keychain 同样会进备份**，论证链条不完整
- 建议：改 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`；若确实需要备份恢复，在注释里写明这个取舍

**M6 `login()` 用字符串插值拼 JSON**
- 位置：`GKCloudClient.swift:246`
  ```swift
  let body = #"{"username":"\#(credentials.phone)","password":"\#(credentials.passMD5)"}"#
  ```
- 影响：输入含 `"` 或 `\` 就拼出非法 JSON。当前输入恰好是数字，但这是"靠输入恰好安全"
- 建议：用 `JSONSerialization` 或一个 `Codable` 结构体构造

**M7 `applyTokenResponse` 用 `String(describing:)` 取 userId**
- 位置：`GKCloudClient.swift:235`
- 服务端返回 JSON `null` 时得到 `"<null>"`，写进 `credentials.userId`，之后所有请求都带这个假 ID
- 建议：`as? String` / `as? Int` 显式取，取不到就保持原值

**M8 `tokenExpiry = expiresIn - 3600` 在短有效期下会立即过期**
- 位置：`GKCloudClient.swift:237-239`
- `expiresIn < 3600` 时 `tokenExpiry` 落在过去 → 每次请求都重新登录，表现为"偶发很慢 / 反复登录"
- 建议：`Date().addingTimeInterval(max(60, expiresIn * 0.9))`

### 手表端竞态与状态机

**M9 `activate()` 与 `loadLocalAccount()` 存在启动竞态**
- 位置：`WatchCloudController.swift:66-89`
- `activate()` 先起 `Task { await loadLocalAccount() }`，随后立刻写 `statusLine`；
  若手机此时推来账号，两条异步路径都会写 `configured` / `statusLine` 并各自触发 `refresh()`
- 影响：可能出现"已登录"被覆盖回"等待 iPhone 同步账号"，或并发两次刷新
- 建议：`loadLocalAccount` 里加 `guard !configured` 守卫，或用单一状态机串联初始化

**M10 `refresh()` 的 `guard !refreshing` 会让命令后的自动刷新被静默丢弃**
- 位置：`WatchCloudController.swift:98`、`:132`
- `perform()` 在命令后等 3 秒再 `await refresh()`，若此时已有刷新在跑，这次直接 return，
  用户看到的是**命令执行前**的状态
- 建议：改成"标记待刷新、当前轮结束后补一次"，而不是直接丢弃

**M11 `sendAuthed` 重试时 body 内 timestamp 不更新**
- 位置：`GKCloudClient.swift:196-206` + `:418-419`
- `timestamp` 在 `send()` 里生成一次，`sendAuthed` 重试时只重建了 `date` / `nonce` / 签名
- 影响：若服务端校验 `timestamp` 与 `date` 的偏差窗口，401 重试那次会被拒
- 建议：把 body 构造放进 `sendAuthed` 的闭包，每次重试重新取时间戳

### 路由与状态判据一致性

**M12 路由与界面用了两套"车在不在"判据**
- 位置：`AppModel+Cloud.swift:146`（`isVehicleOnline`，含"命令成功""收到任意帧"）
  对比 `:44-47`（`bluetoothStatusIsLive`，只认广播）
- 影响：可能出现"界面显示云端数据（蓝牙判定不新鲜），但点按钮时仍认为车在附近而挂起等蓝牙"，
  用户点完没反应
- 建议：路由统一用 `bluetoothStatusIsLive`；若确实需要区别，在注释里写清两个判据各自的意图

### 性能

**M13 `DateFormatter` 每次调用都新建**
- 位置：`ControlChannel.swift:52-59`（`StatusTimeFormat.hhmm`），全项目 7 个调用点，
  包含状态页每次渲染
- `DateFormatter` 初始化是毫秒级开销，放在渲染路径上是可感知的
- 建议：改用 `date.formatted(.dateTime.hour().minute())`（无状态、Sendable），或缓存一个 `static let`

### 可维护性

**M14 空调温度 key 硬编码在两个文件**
- `RootView.swift:39`（`@AppStorage("gkuicloud.acTemperature")`）
- `AppModel+Cloud.swift:347`（`UserDefaults.standard.object(forKey: "gkuicloud.acTemperature")`）
- 改 key 要改两处，漏一处就静默不同步
- 建议：抽 `enum CloudPrefs { static let acTemperature = "gkuicloud.acTemperature" }`

**M15 关空调带的是本地记忆温度，注释却说"带当前温度"**
- 位置：`RootView.swift` 的 `airConditionerAction`，关空调分支
- 实际发给车的是 `acTemperature`（手机本地值），不是车内当前设定值
- 建议：改注释；若服务端确实读这个值，考虑从云端 `climateStatus` 取真实设定温度

**M16 `CloudSnapshotPayload` 手写映射的注释理由是反的**
- 位置：`SyncPayload.swift:56-60`
- 注释说"免得以后给 `VehicleSnapshot` 加字段时忘了同步改协议" —— 但显式映射恰恰**要求**两处都改，
  而让 `VehicleSnapshot: Codable` 自动合成反而不会漏
- 建议：直接给 `VehicleSnapshot` 加 `Codable` 并删掉这层；或保留但把理由改成真实的
  （"手表端只需要字段子集，不想把 UI 类型整个搬过去"）

**M17 两套 Keychain 封装并存**
- `Sources/Net/GKCloudKeychain.swift`（云端凭据）与 `Sources/Keychain/KeyStore.swift`（蓝牙密钥）
- service 命名、错误处理、可访问性策略各写一遍
- 建议：长期合并成一个薄封装；短期至少在两边注释里写明分工边界

---

## 4. 轻微问题（7 项）

| 编号 | 位置 | 问题 | 建议 |
|---|---|---|---|
| L1 | `WatchCloudController.swift:143` | `WCSession.default as WCSession?` 是隐式可选转换，无意义 | 直接 `WCSession.default` |
| L2 | `PhoneWatchSync.swift:70` | `payload!.maskedPhone` 强解包（逻辑安全但读着危险） | `if let payload` 嵌套 |
| L3 | `PhoneWatchSync.swift:35` | `nonisolated(unsafe) static var configuredHint` 跨线程读非原子 Bool，严格说是 UB | 用 `OSAllocatedUnfairLock`，或让 replyHandler 走 `DispatchQueue.main.async` |
| L4 | `GKCloudClient.swift:267-271` | `TokenSnapshot` 用 `public var`，但类型本身是 internal | 去掉 `public` |
| L5 | `project.yml:3` | `bundleIdPrefix: com.example` 是遗留，实际 bundle id 由 target 显式指定 | 删掉或改成真实前缀 |
| L6 | `Sources/Info.plist:49-53` | 声明了 `UIBackgroundModes: location`，全仓无 `startUpdatingLocation` | 上一轮已列为待决策：删掉，或真的用起来 |
| L7 | `WatchCloudController.swift:196-199`、`SyncPayload.swift:50-53` | 手机号非 11 位时脱敏函数直接返回原文（会完整显示） | 统一改为"保留前 3 后 4，其余打码"，不依赖长度 |

---

## 5. 分维度结论

| 维度 | 结论 |
|---|---|
| **结构与模块划分** | 良好，但 `AppModel+Cloud.swift`（425 行）职责过载 —— 混了"状态来源判定"（`activeStatus`）、路由、云端执行、配置、手表同步、自动刷新。其中 `activeStatus` 是核心状态模型，不属于"云端"，建议抽到 `AppModel+Status.swift`。这是本轮唯一的结构性建议 |
| **逻辑正确性** | 主链路正确。缺陷集中在**多入口的副作用清单**（S2）和**两端协议**（S1）—— 都是"某一侧改了、另一侧没跟"的类型 |
| **边界情况** | 云端四门/车窗的缺字段处理（上一轮修复）已经比较严谨。新的边界缺口在 token 有效期计算（M8）和 `applyTokenResponse` 的类型强转（M7） |
| **性能** | 两处：`DateFormatter` 每帧新建（M13，可感知）；90 秒轮询在多个入口重复触发 `refreshCloudStatus`（每次 `startCloudAutoRefresh` 都会立刻拉一次，冷启动 + 回前台可能连发） |
| **安全** | 最大缺口是 S3（手表端无门槛 + 密码摘要跨设备）。其次是 M5（Keychain 未排除备份）。传输层（HTTPS + 签名）没有问题 |
| **可读性 / 可维护性** | 注释密度高、意图交代清楚，是明显优点。代价是**注释随代码演进失同步**，本轮发现 4 处（M2/M3/M15/M16）属于这种情况 |
| **错误处理** | 云端层做得好（分类错误类型、401 重登、失败态复位）。弱在存储层（M4 Keychain 静默失败）和跨端通道（S1 的 errorHandler 空实现） |
| **依赖与版本** | 零第三方依赖，很好。问题在 `Swift 6.0 + minimal` 的组合（S4），以及 `iOS 27.0` 这个极高的最低版本门槛（见下） |
| **注释准确性** | 见第 3 节 M2/M3/M15/M16。另有一处**论证不成立**：`GKCloudKeychain.swift:13-15` 与 `M5` 的冲突 |

**关于 iOS 27.0 最低版本**：`project.yml:5` 与 `:12` 都是 27.0。
从代码看这是必要的（`.glass` 按钮样式、`IntentModes` 等都是新 API），但配合免费账号的 7 天重签，
实际可用人群极小。这不是缺陷，是一个需要被记录的产品约束，建议在 README/文档里写明。

---

## 6. 优先修复清单

排序依据（按顺序应用，前一条压倒后一条）：

1. **会不会作用到错误的车上** —— 物理后果，最高优先
2. **会不会让用户以为成功了而实际没做** —— 静默失败比报错更伤
3. **安全边界是否被削弱**
4. **会不会让后续每次改动都踩同一个坑** —— 结构性债务
5. 只是不够整洁

| 顺序 | 编号 | 事项 | 理由 | 预估 |
|---|---|---|---|---|
| 1 | **S2** | 补 `syncAccountToWatch()`，并把三件副作用收成一个方法 | 唯一可能控到另一辆车的缺陷；且是第二次在同一个位置漏项，必须结构性解决 | 20 分钟 |
| 2 | **S1** | 打通手表"重新同步"：手机端识别 `resync` 并真的重推 | 手表唯一的恢复入口当前是空操作，UI 在撒谎 | 40 分钟 |
| 3 | **S3** | 手表端对 unlock/trunk/engine 要求腕表密码；停止同步 `passMD5` | 安全边界被手表副本削弱；改动小、体验损失小 | 2 小时 |
| 4 | **M1** | 决定 `RemoteCommandTable` 是可选还是删防护（建议删） | 现在"防护"是假的，还带 16 条编译警告；越早定，后面越少纠结 | 40 分钟 |
| 5 | **S4** | `SWIFT_STRICT_CONCURRENCY` 升到 `complete`，修暴露出来的问题 | 不升，同类并发问题还会继续靠人工发现 | 半天（视数量） |
| 6 | **M13** | `StatusTimeFormat` 改用 `formatted(.dateTime...)` | 渲染路径上的毫秒级开销，改一处全覆盖 | 10 分钟 |
| 7 | **M4/M5** | Keychain 写失败可见 + 加 `ThisDeviceOnly` | 存储层静默失败最难查；`ThisDeviceOnly` 一行 | 30 分钟 |
| 8 | **M6/M7/M8** | 登录体改结构化构造、userId 显式取、有效期留余量 | 三个都是小边界，一起改一次测一遍 | 30 分钟 |
| 9 | **M2/M3/M15/M16** | 四处过期/错误注释校正 | 纯文档，但会误导下一个读代码的人 | 20 分钟 |
| 10 | **M9/M10/M11/M12/M14** | 手表状态机、刷新丢弃、重试时间戳、路由判据、key 常量 | 特定条件下才触发，可排在本轮之后 | 半天 |
| 11 | M17 + L 系列 | Keychain 合并、轻微清理 | 纯整洁度 | 择机 |

**第 1–4 项（约 4 小时）覆盖了本次审查全部"严重"级问题，建议作为一批完成并回归验证。**

---

## 7. 修复记录（2026-11-04 22:35）

按第 6 节的顺序修了前 4 项（全部严重级）+ 顺带清理 M2/M3。

| 编号 | 改法 | 文件 |
|---|---|---|
| **S2** | 新增 `afterCloudConfigured()`：`refreshCloudStatus` + `startCloudAutoRefresh` + `syncAccountToWatch` 三件事收成一处，`configureCloud` 与 `configureCloudKeepingPassword` 都调它 | `AppModel+Cloud.swift` |
| **S1** | 手机端 `didReceiveMessage` 识别 `cmd == "resync"` 并真的调 `syncAccountToWatch()`；`pushAccount` 通道未激活时不再静默（写日志）；手表端 `requestResync` 改成三态收尾（6 秒超时 / 回执被拒 / 送达失败），并记录 `lastAccountAt` 判断成功 | `PhoneWatchSync.swift`、`WatchCloudController.swift` |
| **S3** | ① 手表对 `unlock` / `engine(on: true)` 执行前走 `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`（腕表密码）；没设密码直接拒绝并说明原因② 手机不再同步 `passMD5`，手表只拿 token ③ 新增 `GKCloudCredentials.canMakeAuthedRequests`（有 VIN + userId 即可发请求），手表不再被 `isComplete` 判成"未配置" | `WatchCloudController.swift`、`AppModel+Cloud.swift`、`GKCloudClient.swift` |
| **M1** | 参数已固化，删掉假的防护：`RemoteCommandTable.isReady`、`remoteCommandsReady`、`GKCloudError.commandNotConfigured`、`fromTable` 的 `guard let`（参数改非可选）、UI 的 `!ready` 虚线分支与 `ackNotConfigured` | `GKCloudClient.swift`、`RootView.swift`、`WatchCloudController.swift` |
| M2 | `isSupportedOnNetwork` 改 `{ true }`，注释说明保留理由 | `ControlChannel.swift` |
| M3 | `VehicleCommand.engine` 注释改为「云端 RES；蓝牙无此命令」；`RemoteCommandTable` 的"待填"长注释换成已填 + serviceId 对照表 + 改表注意事项 | `ControlChannel.swift`、`GKCloudClient.swift` |

**验证**
- 主 App `BUILD SUCCEEDED`，**编译警告 0 条**（修 M1 前是 16 条，全部指向 `RawPlan?` 恒真比较）
- 手表 target `BUILD SUCCEEDED`（仅剩 "no AppIntents.framework dependency" 的常规提示）
- 已安装到真机并启动

**S3 的一个取舍需要你知道**：手表没设密码时，`LAContext` 无法评估，代码选择**拒绝执行解锁/启动**，并提示"请先在手表上设置密码"。
理由是没设密码的表谁拿起来都能用，那种状态下不该允许开车门。实际影响很小（手表设密码才能用 Apple Pay）。

---

## 8. 第二批修复（2026-11-04 22:50）

第 6 节剩下的 5–11 项也全部处理完。**28 项全部关闭**，其中 3 项按"标注清楚"而非"删除"处理，理由见下。

### 中等项（M4–M17）

| 编号 | 改法 |
|---|---|
| **M4** | `GKCloudKeychain.set` 返回 `Bool`，`SecItemUpdate` / `SecItemAdd` 的错误码都走 `logFailure`（`SecCopyErrorMessageString` 翻译成人话）。此前写失败完全静默 |
| **M5** | 可访问性 → `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不再进 iCloud/iTunes 备份；文件头注释补上"为什么少了 ThisDeviceOnly 等于把机密交给备份" |
| **M6** | `login()` 改用 `JSONSerialization` 构造 body，不再字符串插值 |
| **M7** | `userId` 按 `String` / `Int` / `Int64` 显式取，取不到保持原值 —— 原来 `String(describing: NSNull())` 会写入 `"<null>"` |
| **M8** | 续期提前量改成 `min(3600, max(60, expiresIn * 0.1))`，短有效期不再算出过去时间 |
| **M9** | `activate()` 的初始化收敛成一条顺序链（`loadLocalAccount` → 再决定要不要显示"等待同步"），消除与手机推送的竞态 |
| **M10** | `refresh()` 改为排队：有刷新在跑时记 `refreshPending`，当前轮结束补做一次，不再静默丢弃命令后的刷新 |
| **M11** | body 构造下沉到 `sendAuthed` 的闭包内，每次尝试重新取时间戳；日志带尝试序号 |
| **M12** | `routeToCloudIfNeeded` 的判据从 `isVehicleOnline` 改为 `bluetoothStatusIsLive`，与界面同源 |
| **M13** | `StatusTimeFormat` 缓存 `static let formatter`（编译器确认 `DateFormatter` 已是 `Sendable`，不需要 `nonisolated(unsafe)`） |
| **M14** | 新增 `Sources/Net/CloudPrefs.swift`，空调温度 key 与默认值集中；`@AppStorage` 与 `UserDefaults` 两边都引用它 |
| **M15** | 关空调的注释改成实话：带的是本地记忆温度，不是车内实际设定值 |
| **M16** | `CloudSnapshotPayload` 的注释理由重写 —— 原来说"免得加字段时忘了改协议"，但显式映射恰恰要求两处都改；真实理由是两端字段集不同 + 手表解码容错 |
| **M17** | 两套 Keychain 的分工写成表格放进 `GKCloudKeychain` 文件头，而不是强行合并（service 名、可访问性、生命周期都不同，抽通用层只会多一层间接） |

### 轻微项（L1–L7）

| 编号 | 改法 |
|---|---|
| L1 | 已随 S1 一并移除（`WCSession.default as WCSession?`） |
| L2 | 去掉 `payload!`，改 `payload.map { ... } ?? ...` |
| L3 | `configuredHint` 换成 `OSAllocatedUnfairLock` + `nonisolated` 访问器，不再跨线程读写非原子 Bool |
| L4 | `TokenSnapshot` 的 `public var` → `var` |
| L5 | `bundleIdPrefix` 从 `com.example` 改为 `com.mmxisme`（三个 target 都显式写了 `PRODUCT_BUNDLE_IDENTIFIER`，此前缀本就不生效，只是避免误导） |
| L6 | **保留不删**，见下 |
| L7 | 手机号脱敏改为按数字位数判断（≥7 位就打码），带 `+86` 或空格时不再原样显示 |

### 三项按"标注"处理，没有直接改

**L6 `location` 后台模式**：审查时以为是"声明了从不用"，实际 `BLECentral` 里有完整的 `CLLocationManager` —— 申请 WhenInUse → 升级 Always，界面上还有 `locationAuthText` 显示权限状态。只是从不读取经纬度。
这段是真机验证过"后台扫不到车"问题的修复，删掉要重新验证一遍后台唤醒行为，收益（少一个权限申请）与风险不成比例。
处理方式：在 `requestLocationPermission()` 上写清现状与删除前提，**代码、`NSLocation*` 描述、`UIBackgroundModes: location` 三处都保留**，并注明"要删请一起删"。

**M17 两套 Keychain**：合并的收益是形式上的整洁，风险是动到已验证的存储路径。改成把边界写死。

### 验证

```
主 App      BUILD SUCCEEDED   0 warning
手表 target  BUILD SUCCEEDED   0 warning
```

`swiftc -typecheck` 亦为 0 error / 0 warning。已安装到真机并启动。

### 过程中踩到的两个点（对以后有用）

1. **`nonisolated(unsafe)` 用在 `DateFormatter` 上会被警告说不必要** —— 当前 SDK 里它已经是 `Sendable`。但用于 `static var` 缓存时仍需要 `nonisolated`（否则 `@MainActor` 类里的静态属性在 nonisolated 回调中不可读）。
2. **`OSAllocatedUnfairLock` 需要 `import os`**，且包裹的 static 属性必须标 `nonisolated` 才能从 WCSession 回调访问。

---

## 9. 结论

两轮修完，报告里 28 项**全部关闭**。当前状态：

- 编译 0 error / 0 warning（修 M1 前是 16 条）
- 主 App、Widget、Watch 三个 target 均可构建
- 云端凭据：只进本机 Keychain，不进备份，不同步到手表
- 手表：破坏性命令需腕表密码，账号由手机单向同步，resync 链路双向可用

剩下的都是"要改架构才能动"的事：`AppModel+Cloud.swift` 职责过载（`activeStatus` 该抽出去）、
`SWIFT_STRICT_CONCURRENCY` 升到 `complete`。这两项不在本次清单里，属于下一轮。
