# GKUIBleKey 代码审查报告

- 审查日期：2026-11-04
- 代码版本：`工作区当前 HEAD + 未提交改动`（含 2026-11-04 云端通道、状态来源、UI 重排）
- 规模：51 个 Swift 文件 / 17,055 行；4 个 target（主 App / Widget / Watch / Live Activity）
- 构建状态：`xcodebuild` Debug **BUILD SUCCEEDED**，0 error

---

## 0. 审查范围与方法

| 手段 | 覆盖 |
|---|---|
| 全仓静态扫描 | 强解包、`try?`、并发隔离、切片越界、重复定义、废弃 API、权限声明 |
| 逐行精读 | `AppModel`、`AppModel+Cloud`、`ControlChannel`、`GKCloudClient`、`BLECentral.send`/连接回调、`VehicleStatus`、`VehicleTopView`、`RootView`、`CloudSettingsView`、`VehicleIntents`、`FileLogger` |
| 结构核对 | `project.yml`（target / Info.plist / 编译条件）、`Info.plist` 权限与后台模式 |
| 运行时验证 | iPhone 17 模拟器截图核对车控页 / 状态页；真机构建、安装、启动 |

**结论先说**：协议层与密码学层质量明显高于平均水平（长度守卫、字节级注释、自检用例齐全），真正的问题集中在**新加的云端通道与旧模块的接合处**——那里有 3 个会直接影响用户判断的错误，以及 1 个物理安全风险。

---

## 1. 问题分类汇总

| 类别 | 数量 | 最高级别 |
|---|---|---|
| 逻辑错误 / 状态不一致 | 6 | **P1** |
| 异常处理与边界情况 | 8 | **P2** |
| 模块间冲突 / 重复定义 | 7 | P2 |
| 安全与隐私 | 4 | **P1** |
| UI 与交互 | 6 | P2 |
| 可维护性 / 规范 | 5 | P3 |
| **合计** | **36** | |

严重级别定义：

- **P1 严重**：给出错误信息、功能失效或安全风险，必须在下个版本前修
- **P2 中等**：边界条件、异常路径、一致性缺陷，会造成偶发或误导
- **P3 轻微**：可维护性、规范、死代码，不影响当前行为

---

## 2. P1 严重问题

### P1-1 冷启动后云端自动刷新根本不会启动

**位置**：`Sources/App/AppModel.swift:296`、`Sources/Net/AppModel+Cloud.swift:295`

**成因**：`init()` 只调了 `reloadCloudConfig()`（异步读凭据、置 `cloudConfigured`），没有调 `startCloudAutoRefresh()`。全仓只有两处启动它：

- `willEnterForegroundNotification`（`AppModel.swift:332`）——**冷启动不会发这个通知**
- `configureCloud()` 成功后（`AppModel+Cloud.swift:231`）——只有"刚配好账号"那一次

**影响**：用户上次配好云端、这次直接打开 App，状态页和主页的云端数据**永远是上一次进程留下的**，直到他切一次后台再回来，或手动进设置点"刷新一次车况"。这正好打在"状态页与云端保持一致"这条需求上。

**修复建议**：

```swift
// reloadCloudConfig 完成后判断并启动
func reloadCloudConfig() {
    Task { [weak self] in
        guard let self else { return }
        let c = await self.cloud.snapshotOfCredentials()
        self.cloudConfigured = c.isComplete
        if c.isComplete { self.startCloudAutoRefresh() }   // ← 补这一行
    }
}
```
同时把 `configureCloudKeepingPassword()`（`AppModel+Cloud.swift:241`）也补上 `startCloudAutoRefresh()`——它现在同样漏了。

---

### P1-2 云端车门数组用 `compactMap`，缺一个字段整排门就错位

**位置**：`Sources/Net/GKCloudClient.swift:269-272`、`:293-295`

```swift
let doorOpenStates = [
    safety?["doorOpenStatusDriver"], safety?["doorOpenStatusPassenger"],
    safety?["doorOpenStatusDriverRear"], safety?["doorOpenStatusPassengerRear"]
].compactMap { on($0) }        // ← 任何一个为 nil，后面的元素整体前移
```

**成因**：`on()` 返回 `Bool?`，`compactMap` 把 `nil` 丢掉，数组长度从 4 变成 3 或更少。而下游（`VehicleTopView.doorClosed`、`CarModelView.doorChip(index:)`）是**按下标取**的：

```swift
snapshot.doorClosed[2]   // 本意是左后，实际取到右后的值
```

**影响**：服务端少给一个门字段时，四门显示会**整体错位**——「左后门开着」被显示成「右前门开着」。同时 `isDoorsClosed = !doorOpenStates.contains(true)` 也是用这个残缺数组算的，会误报「全关」。这是会让人跑到车边白跑一趟的那类错误。

**修复建议**：保留 4 元素，缺失置 `nil`：

```swift
let keys = ["doorOpenStatusDriver", "doorOpenStatusPassenger",
            "doorOpenStatusDriverRear", "doorOpenStatusPassengerRear"]
let raw: [Bool?] = keys.map { on(safety?[$0]) }
let doorClosed: [Bool]? = raw.count == 4 && raw.allSatisfy({ $0 != nil })
    ? raw.map { !($0 ?? false) }   // 全部非 nil 才采信，避免用强解包
    : nil
```
`isDoorsClosed` 也改为从 `doorClosed` 推导，不要各自算一遍。

---

### P1-3 锁屏卡片与主页状态自相矛盾

**位置**：`Sources/App/AppModel.swift:1384-1423`

```swift
guard cloudConfigured else { liveActivity.end(); return }
...
let snap = cloudSnapshot
let online = snap?.isFresh ?? false
```

**成因**：2026-11-04 把 Live Activity 的数据源从蓝牙换成了**只读云端**，但主页已经改成了「蓝牙优先、云端兜底」的 `activeStatus`。两者用了不同的判据。

**影响**：车就在旁边时，主页显示「蓝牙 · 已连接 / 已锁」，锁屏卡片显示「暂无数据」或「离线 · 09:12」；没配云端的用户则**完全没有锁屏卡片**。同一时刻、同一台车，两处给出相反结论。

**附带的隐性回归**：注释里写着"Live Activity 提升后台 BLE 权限这层用途也不再需要它承载了"。反过来说——**没有 Live Activity，后台扫描的 duplicates 合并会恢复**，靠近解锁的实时性会下降。这个取舍需要真机验证过再落定。

**修复建议**：改为读 `activeStatus`，并把 `guard cloudConfigured` 放宽为"有任一状态源"：

```swift
let active = activeStatus
guard active.snapshot != nil || cloudConfigured else { ... }
let online = active.source != StatusSource.none  // 蓝牙实时也算在线
```

> **状态：已修复（2026-11-04 19:55）。** 实现时进一步做成了**字段级合并**：
> 蓝牙实时 → 车锁/四门/后备箱/引擎用蓝牙，车窗/天窗用云端补（云端须在 180 秒新鲜期内）；
> 无蓝牙 → 整份云端；都没有 → 「暂无数据」。同时补上「广播到达即刷新卡片」的触发，
> 并让纯蓝牙用户（未配云端）也能有卡片。Widget 端顺带修了 `isLocked == nil`
> 被渲染成「未锁」的问题（改为「—」）。

---

### P1-4 自定义 URL 无二次确认即可开后备箱 / 鸣笛

**位置**：`Sources/App/AppModel.swift:1449-1483`，入口 `Sources/App/AppDelegate.swift:35`

```swift
case "trunk":   action = .openCloseTrunk
case "find":    action = .panic
...
perform(action)
```

**成因**：`gkuiblekey://trunk` 这类链接，**任何** App、网页、备忘录、二维码都能触发。系统只校验 scheme 归属，不校验来源。

**影响**：
- 恶意网页 / 聊天里的链接：点一下就把车后备箱打开（且 App 会被拉到前台，看起来像正常操作）
- 用户自己误触：URL 无法区分"控制中心控件"和"外部链接"

对一辆可以远程开后备箱的车，这属于**物理安全风险**，不只是体验问题。

**修复建议**（三选一，按改动量排序）：

1. 不可逆动作（`trunk` / `find`）加确认弹窗——最简单，立刻有效
2. URL 携带一次性 token：控件生成时由 App 写入 `UserDefaults`，App 校验后消费，外部链接拿不到
3. 长期方案：控件全部改用 `AppIntent`（系统会带上调用来源），彻底不依赖 URL 分发

---

## 3. P2 中等问题

| # | 问题 | 位置 | 成因 / 影响 | 建议 |
|---|---|---|---|---|
| P2-1 | 车锁字段语义未验证 | `GKCloudClient.swift:291` | `doorLockStatusDriver` 用 `on()`（`"1"` = true）判为「已锁」。若服务端 `1` 表示"未锁"，**整页锁状态是反的** | 车已锁时抓一次响应对照；同一响应里若 `trunkOpenStatus` 的 1=开已被注释确认，锁字段需单独验证 |
| P2-2 | 改手机号后不启动自动刷新 | `AppModel+Cloud.swift:241-265` | 与 P1-1 同源：`configureCloudKeepingPassword` 没有 `startCloudAutoRefresh()` | 补一行 |
| P2-3 | token 未持久化，注释与实现冲突 | `GKCloudClient.swift:402`、`:398` | `tokenKey` 声明了但**从未使用**；注释写"token 放 Keychain"，实际只存在 actor 内存里 | 每次冷启动都重新登录（多一次往返 + 风控计入）。要么真存 Keychain，要么改注释 |
| P2-4 | 密码 MD5 与凭据存 UserDefaults | `GKCloudClient.swift:404-416` | 注释说放 Keychain，实际全在 `UserDefaults` | MD5 可离线撞库，且随 iCloud 备份外流。建议改 Keychain（`AfterFirstUnlock`） |
| P2-5 | 401 无自动重登 | `GKCloudClient.perform` | 只按本地 `tokenExpiry` 判断，服务端提前失效时直接抛 `HTTP 401` | 捕获 401 → `invalidateToken()` → 重试一次 |
| P2-6 | `comps.url!` 强解包 | `GKCloudClient.swift:111` | VIN 含非法字符时 `URLComponents.url` 为 nil → 崩溃 | 改 `guard let`，抛 `badResponse` |
| P2-7 | `cloudState = .failed` 不自动恢复 | `AppModel+Cloud.swift:196-199` | `performOnCloud` 4 秒后复位，`runNetworkCommand` 没有 | 设置页"当前"一栏会永久停在上次失败原因 |
| P2-8 | `location` 后台模式 + Always 定位权限声明了但从不使用 | `Info.plist`、`BLECentral.swift:184/231-235/335` | `allowsBackgroundLocationUpdates = true` 设了，但**全仓没有 `startUpdatingLocation()`** | 审核风险 + 权限文案对不上。要么真用起来，要么删掉 `UIBackgroundModes: location` 与两个定位描述 |
| P2-9 | 分包发送无流控 | `BLECentral.swift:1068-1085` | 多包路径连续 `writeValue(.withoutResponse)`，无节流、无完成回调 | 当前 MTU 182 / 帧 62B 不会触发；一旦 MTU 变小会丢包。建议 `withResponse` 或分批 + 间隔 |
| P2-10 | "过期"阈值有四套 | `60`（`AppModel+Cloud:51`）/`120`（`RootView:571`）/`180`（`ControlChannel:127`、`:282`） | 同一概念（状态还新不新鲜）出现 4 个常量，行为互不一致 | 收成一个 `StatusFreshness`，UI 按场景取倍数 |
| P2-11 | 没有"退出 / 清除云端凭据"入口 | `CloudSettingsView.swift` | 换账号只能覆盖，无法清除 | 加"清除配置"（带二次确认） |
| P2-12 | 保存后的成功文案不准确 | `CloudSettingsView.swift:147` | 只要 `login()` 成功就报"已连接，车况读取成功"，即使随后 `fetchStatus` 失败 | 按 `cloudSnapshot != nil` 判断 |

---

## 4. 模块间冲突与重复定义（P2/P3）

| # | 冲突 | 位置 | 说明 |
|---|---|---|---|
| C-1 | 两套"状态来源"枚举 | `ControlChannel.swift:20`（`ControlChannel`）与 `:249`（`StatusSource`） | `VehicleSnapshot.source` 用前者，界面显示用后者。同一个概念两种类型，`VehicleSnapshot.source` 现在只有写入、没有读者 |
| C-2 | `staleSeconds` 重复定义 | `ControlChannel.swift:127`、`:282` | 两个 180 秒常量字面量相同、命名不同，改一处不影响另一处 |
| C-3 | `pendingAction` 同名不同义 | `AppModel.swift:1491` vs `MeasuredSession` | 前者写于 `perform:1638`，**全仓无 UI 读取**，只在解绑时清空——是一个会让人误判"命令在途"的僵尸状态 |
| C-4 | 状态文案两处重复实现 | `RootView.swift:181`（`statusPageSubtitle`）与 `:526`（`keyStatusText`） | 同样的 `switch activeStatus.source` 各写一遍，改一处容易漏 |
| C-5 | 注释与代码相反 | `BLECentral.swift:314` vs `:365` | 314 行启用了 `RestoreIdentifier`，365 行注释写"当前没有启用" |
| C-6 | 新旧 AppIntents API 并存 | `QuickControlIntent.swift:58`（`openAppWhenRun`，已废弃）vs `VehicleIntents.swift:217`（`supportedModes`） | iOS 26 起前者弃用，行为可能与后者不一致 |
| C-7 | 死代码 | `VehicleCommand.openTrunk/.closeTrunk`（`ControlChannel.swift:54-55`） | `asVehicleCommand` 不映射 `openCloseTrunk`，`plan(for:)` 又对它抛"不支持"——两个 case 永远构造不出来 |

---

## 5. 新增功能对既有模块的适配评估

云端通道（2026-11-04）引入了"第二条数据源 + 第二条控制通道"，需要逐个模块确认是否跟上：

| 模块 | 是否适配 | 结论 |
|---|---|---|
| 主页车图 / 状态页 | ✅ 已适配 | 统一走 `activeStatus`，来源标注齐全 |
| 主控按钮高亮推荐 | ⚠️ 部分 | `RootView:593-598` 仍只读 `measured.status` + 120 秒阈值；只有云端数据时不会推荐按钮。**不会显示错误信息，但会漏掉推荐** |
| 锁屏 / 灵动岛卡片 | ✅ 已修复 | 改走 `activeStatus`，与主页同一份数据、同一条优先级 |
| Siri / 快捷指令「查询车辆状态」 | ❌ 未适配 | `VehicleIntents.swift:221` 只读 `measured.status`，后台场景下必然回答"还没收到过车辆状态"，哪怕云端刚拉到 |
| 控制中心控件 | ✅ 正常 | 走 `QuickControlIntent` → `perform()`，由通道选择器统一决策 |
| Apple Watch | ⚠️ 独立实现 | `WatchVehicleController.swift:126` 有自己的过期判定，与手机端 60 秒窗口不一致（手表是独立钥匙，可接受，但阈值应统一并写注释） |
| 按钮角标 / 通道提示 | ✅ 正常 | 与 `preferredChannel` 同源 |

**结论**：新功能的**核心链路是通的**，断在"旁路消费者"——锁屏卡片、Siri、手表各读各的，没有统一到 `activeStatus`。建议把 `activeStatus` 定为唯一入口，其余模块一律不得直接读 `measured.status` / `cloudSnapshot`（可在代码注释或 lint 里约束）。

---

## 6. UI 评估

### 6.1 布局一致性 —— 良好，有 2 处不齐

- ✅ 三页统一 `pageHeader`，标题/副标题样式一致
- ✅ 车控页主次层级清晰：车名 25pt → 车图 → 主按钮 78 → 次按钮 62 → 通栏 48
- ⚠️ **圆角三档混用**：字段卡片 16 / 俯视图卡 20 / 主按钮 20 / 通栏按钮 14。建议收敛为 16（卡片）与 20（可点元素）两档
- ⚠️ **间距不统一**：页面 20、卡片内 16、区块间 12/14/16 都有。建议定 4 的倍数阶梯

### 6.2 交互可用性 —— 基本达标，有 3 处可提升

- ✅ 按钮全部可点（不做 `.disabled` 灰化），点不到时有明确原因弹窗——这一点做得比多数同类 App 好
- ✅ 点击热区充足（48–78pt），远超 44pt 最低要求
- ⚠️ 状态页**没有下拉刷新**，手动刷新入口埋在「我的 → 网络通道」里
- ⚠️ 「其他原始字段」折叠区字号 10pt（`RootView:945` 附近），低于可读下限（11pt）
- ⚠️ 云端请求进行中只有 `cloudState.text` 一行文字，没有按钮级 loading 态，用户容易连点

### 6.3 响应式适配 —— 主要短板

| 问题 | 位置 | 说明 |
|---|---|---|
| 车图宽度写死 136 | `VehicleTopView.swift:41` | iPhone 17 Pro Max（440pt 宽）上左右留白会变多，与"填满空白"的目标反而背离 |
| 车图高度写死 168 | `RootView.swift:558` | 小屏（375pt）上单屏信息量不足，要靠滚动 |
| 底部留白写死 72 | `RootView.swift`（三页） | 应按标签栏实际安全区计算，而非魔法数字 |
| 三列网格最窄 ~92pt | `RootView.swift:603` | 375pt 设备上「后备箱」+通道角标接近挤压临界 |

**建议**：车图宽度改为 `min(可用宽度 * 0.42, 160)`；底部留白改 `safeAreaInsets.bottom + 56`。

### 6.4 视觉规范 —— 一致性尚可，缺动态字体

- ✅ 颜色全部走语义色（`.primary` / `.secondary` / `.quaternary`），无硬编码黑白，深色模式自适应正常
- ✅ 玻璃材质（`.ultraThinMaterial` / `.glassEffect`）使用克制，层次分明
- ❌ **35 处固定字号**（`font(.system(size:))`）不支持 Dynamic Type。在"大字体"辅助功能下，文字不放大而按钮不缩，层级会崩
- ⚠️ 四门状态点仅 8pt 且**只靠颜色**区分开关（`VehicleTopView.swift:79`），色觉障碍用户无法分辨；已有 `accessibilityLabel`（好），建议再补形状差异（开=实心 + 外环，关=空心）

### 6.5 UI 结论

整体属于**完成度高、细节待收口**的状态：信息架构（控制/状态/我的）合理，主路径无阻塞，视觉语言统一。需要修的是**响应式硬编码**和**动态字体**这两项，其余为打磨。

---

## 7. 优先修复建议

### 第一批（本版本必须，约 0.5 天）

1. **P1-1** 冷启动启动云端自动刷新（2 行）
2. **P1-2** 车门数组保留 4 元素（10 行）
3. **P1-4** 后备箱 / 寻车加二次确认（1 个 alert）
4. **P1-3** 锁屏卡片改读 `activeStatus`

### 第二批（下一版本，约 1 天）

5. **P2-1** 车锁字段语义实测核对（唯一一条"可能是反的"数据）
6. **P2-3/4** token 与凭据迁至 Keychain，或修正注释
7. **P2-5** 401 自动重登
8. **P2-8** 定位权限与后台模式二选一（要么用，要么删）
9. **P2-11/12** 设置页补"清除配置"、修正成功文案
10. **C-1/C-2/C-4** 状态来源与过期阈值归一

### 第三批（技术债，随迭代清理）

11. **C-3/C-7** 删除 `AppModel.pendingAction`、`openTrunk/closeTrunk` 死代码
12. **C-5/C-6** 注释与新 API 对齐
13. **UI** 响应式改比例 + 引入 Dynamic Type
14. **P2-9** 分包流控

---

## 8. 本次审查未覆盖的部分

诚实说明边界：

- **Watch target**（约 1,200 行）只做了接口一致性抽查，未逐行走查协议状态机
- **`MeasuredSession` / `InBlueAuth` / `CryptoBox`** 做了数据结构与边界检查，但**未重新验证密码学正确性**——这部分此前有三方交叉验证（RFC 向量 + Python cryptography + 自检用例），本次不重复
- **真机行为**（后台保活、靠近解锁、点火命中率）无法从静态代码判定，需实测日志
- Widget 扩展的实际渲染未在真机核对

如果需要，我可以把第一批 4 项直接改掉并跑一遍构建 + 模拟器截图验证。

---

## 9. 修复记录（2026-11-04 20:00）

本轮把「不需要硬件验证 / 不需要产品决策」的问题全部改完，构建三个 target 均通过
（主 App、Widget、Watch）。

### 已修复

| 编号 | 问题 | 改法 |
|---|---|---|
| P1-1 | 冷启动不启动云端自动刷新 | `reloadCloudConfig()` 读到完整凭据后直接 `startCloudAutoRefresh()` |
| P2-2 | 改手机号后不启动自动刷新 | `configureCloudKeepingPassword()` 补 `startCloudAutoRefresh()` |
| P1-2 | 四门 `compactMap` 导致错位 | 保留 4 个位置，缺失即整组判「未知」；`isDoorsClosed` 同源推导 |
| — | 车窗部分字段被当成「全关」 | 任一窗 >0 才算确定；全为 0 且不足 4 项时保持「未知」 |
| P2-5 | 401 无自动重登 | 新增 `sendAuthed`：401 → 丢 token → 重登 → 重试一次 |
| P2-6 | `comps.url!` 强解包 | `makeRequest` 改 `throws`，拼装失败抛 `badResponse` |
| P2-7 | `cloudState` 失败态不复位 | `runNetworkCommand` 4 秒后复位，与 `performOnCloud` 一致 |
| P2-3/P2-4 | 密码 MD5 / token 存在 UserDefaults | 新增 `GKCloudKeychain`，两者进 Keychain（`AfterFirstUnlock`）；UserDefaults 只留非机密；带旧数据自动迁移 |
| P2-11 | 没有「清除云端配置」入口 | 设置页加按钮 + 二次确认；`AppModel.clearCloudConfig()` 清内存/Keychain/快照 |
| P2-12 | 成功文案不准确 | 按 `cloudSnapshot` 是否拿到区分两种文案 |
| P1-4 | URL 可直接开后备箱/解锁 | `unlock`/`openCloseTrunk`/`panic` 走确认弹窗；`lock` 直接执行 |
| P2-10/C-2 | 新鲜度阈值四套 | 统一到 `StatusFreshness`（60/120/180 三语义一处定义） |
| C-1 | `VehicleSnapshot.source` 与 `StatusSource` 重复 | 删除前者（无读者） |
| C-4 | 状态文案两处重复 | 抽 `StatusSource.displayText` |
| — | 主控按钮推荐只读蓝牙 | 改读 `activeStatus`，用 `recommendationWindow` 控制保守度 |
| — | Siri 状态查询只读蓝牙 | 改读 `activeStatus`，并按来源说明「秒级/分钟级」 |
| C-3 | `AppModel.pendingAction` 僵尸状态 | 删除；顺带去掉 `beginMeasuredAuth` 里回落到它的写法 |
| C-7 | `openTrunk`/`closeTrunk` 不可达 | 删除两个 case 及各 switch 分支 |
| C-5 | BLECentral 注释与代码相反 | 校正为「已启用状态恢复」 |
| C-6 | `openAppWhenRun`（已废弃） | 改 `supportedModes: .foreground` |
| — | `try!` 正则 | 改 `try?` + 兜底（不脱敏好过崩溃） |

### 未修复（附理由）

| 编号 | 问题 | 为什么不改 |
|---|---|---|
| P2-1 | 车锁字段语义未验证 | 只能靠真车抓一次响应确认；改代码没有依据 |
| P2-8 | `location` 后台模式声明但未使用 | 删掉可能影响后台保活（真机验证过的东西），加回去又要重新验证。需产品决策 |
| P2-9 | 分包发送无流控 | 改动的是**已验证可用的协议路径**，当前 MTU 182 / 帧 62B 永不触发多包。等真出现小 MTU 设备再改 |
| UI | 响应式硬编码 / 无动态字体 | 属于改造而非修复，影响面大，单独排期 |

### 本轮引入的验证

- 主 App / Widget / Watch 三个 target `BUILD SUCCEEDED`
- 模拟器装机运行，主页布局无回归
- `gkuiblekey://trunk` 触发系统「在蓝牙钥匙中打开？」—— 说明 URL 确实从外部进来；
  点「打开」后才会进入我们自己的确认弹窗（该步需人工点击，未自动化）
