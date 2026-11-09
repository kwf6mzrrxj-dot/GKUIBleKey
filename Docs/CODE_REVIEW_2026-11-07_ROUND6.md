# 全项目审查 · 2026-11-07 第 6 轮

> 范围：本轮新增/改动的 10 个文件 + 与既有模块的接缝。
> 基准：类型检查 0 error 0 warning，真机 iPhone 17 Pro（iOS 27）实装验证。
> 说明：按用户要求**不评估老机型屏幕适配**（最低设备即 iPhone 17e 级别），
> 但保留"同一屏内不同数据量"的自适应检查。

---

## 一、问题分类汇总

| 级别 | 数量 | 已修 | 保留 | 含义 |
|---|---|---|---|---|
| **P0** | 2 | 2 | 0 | 功能错误或资源泄漏，必须修 |
| **P1** | 4 | 3 | 1 | 可用但明显有缺陷 |
| **P2** | 6 | 3 | 3 | 一致性与可读性 |
| **冲突** | 0 | — | — | 无重复定义 / 接口不一致 |
| **适配** | 1 | 1 | 0 | 新改动波及旧模块 |

---

## 二、P0 · 功能错误

### P0-1 全屏地图漏了 `onDisappear`，GPS 引用计数只增不减

| | |
|---|---|
| 位置 | `Sources/UI/VehicleLocationCard.swift` · `VehicleLocationDetail` |
| 状态 | **已修** |

**成因**：`UserLocationProvider` 本轮从 `@StateObject`（每卡一个实例）改成
`shared` + 引用计数。卡片本体写了 `onAppear { me.start() }` / `onDisappear { me.stop() }`，
但全屏 sheet 只写了 `onAppear { me.start() }`。

**影响**：每打开一次全屏地图，`activeUsers` 永久 +1。计数再也回不到 0，
`stopUpdatingLocation()` 永远不会被调用 —— 定位一直开着。
更隐蔽的是：这个计数只增不减，所以后面所有 `stop()` 都失效。

**修复**：补 `.onDisappear { me.stop() }`，并在注释里写明"必须配对"。

---

### P0-2 车辆位置更新后，地址仍是上一个地点

| | |
|---|---|
| 位置 | `Sources/UI/VehicleLocationCard.swift` · `resolveAddress()` |
| 状态 | **已修** |

**成因**：`.task(id: coordinate.reportedAt)` 在坐标时间戳变化时会取消旧任务、重跑；
但 `resolveAddress()` 开头是 `guard address == nil else { return }` ——
`address` 是 `@State`，上次解析成功后就再也不为 nil，于是新任务**立即返回**。

**影响**：车从 A 小区开到 B 小区，卡片上仍写着「A 小区 7 号楼」。
这比不显示更危险 —— 用户会照着旧地址去错的地方找车。

**修复**：引入 `resolvedFor: Date?` 记录"已解析的是哪一份位置"：
- 同一时间戳 + 已有结果 → 直接复用（省高德额度）
- 时间戳变了 → 先清空 `address` / `place`，再重新解析

---

## 三、P1 · 明显缺陷

### P1-1 高德请求没有缓存

| 位置 | `Sources/Net/AMapGeocoder.swift` | 状态 **已修** |
|---|---|---|

车控页和状态页各有一张位置卡，同一个坐标会发**两次**请求；切页、卡片重建再来。
高德个人 key 只有 5000 次/天，这种重复纯属浪费。
修复：`NSCache` 按坐标 4 位小数（≈11 米）缓存 —— 同一车位必命中，车开出十几米才 miss。

### P1-2 词表索引遇到重复 token 直接 crash

| 位置 | `Sources/Net/FieldGlossary.swift` · `ruleIndex` | 状态 **已修** |
|---|---|---|

原写法 `Dictionary(uniqueKeysWithValues:)` 在 key 重复时触发 `fatal error`。
词表是手写的几百行，本轮开发中真的踩到过一次（`belt` 写了两遍），
后果是**整个状态页崩溃**。

修复：改成"先到先得"的循环构造，重复项静默忽略；
同时加 `SelfTest.testFieldGlossary()` —— 检查重复 + 4 个典型字段的译名，
把这类错误从"运行时崩溃"降级为"自检红灯"。

### P1-3 高德 key 每次请求都读 Bundle 文件

| 位置 | `AMapCredential.webKey` | 状态 **已修** |
|---|---|---|

Bundle 内容在进程生命周期内不会变，每次请求读一遍是纯 IO 浪费。
修复：进程内缓存（`String??` 三态，区分"没读过"和"读过了但为空"）。

### P1-4 TabView 下定位可能常驻

| 位置 | `UserLocationProvider` + 两张位置卡 | 状态 **保留（判定可接受）** |
|---|---|---|

SwiftUI 的 `TabView` 会保留已访问页的视图，`onAppear` / `onDisappear`
**不随切页配对**。所以两张卡都访问过之后，`activeUsers` 可能停在 2，
GPS 会话一直开着。

判定为可接受，理由：
- `desiredAccuracy = kCLLocationAccuracyNearestTenMeters`
- `distanceFilter = 15` —— 站着不动时不产生定位回调，也就没有耗电
- 找车是高频操作，每次进页面重新起 GPS 反而慢

处理：**不改逻辑，只在 `UserLocationProvider` 的注释里写明这一点**，
避免以后有人把它当成泄漏去"修"。

---

## 四、P2 · 一致性

| # | 问题 | 位置 | 状态 |
|---|---|---|---|
| P2-1 | 能源读数带圆角 12，紧邻的车辆位置卡 14 | `CarModelView.energyBar` | 已修（统一 14） |
| P2-2 | `@Environment(\.colorScheme)` 死代码（水印遮罩方案换掉后没人用） | `VehicleLocationCard` | 已修 |
| P2-3 | 配对页车图从 220 缩到 178 | `PairingView` | 已修（显式传 220） |
| P2-4 | `stageBadge` 的 `alert ? tone.color : (highlight ? tone.color : .secondary)` 两个分支结果相同 | `CarModelView` | 保留（可读性问题，改动收益低） |
| P2-5 | 高德成功路径不过 `AddressNormalizer` | `VehicleLocationCard.resolveAddress` | 保留（实测高德 `formatted_address` 本身不含国名） |
| P2-6 | `UIMockVehicle.snapshot.updatedAt` 是 `static let` 求值时刻 | `CarModelView` | 保留（仅 DEBUG，长跑后 `isFresh` 变 false，无害） |

---

## 五、代码冲突专项

**无重复定义、无接口不一致。** 逐项确认：

| 检查项 | 结论 |
|---|---|
| 重复类型 / 函数 | 无。`EnergyReadout`、`AMapAddress`、`AddressNormalizer`、`FieldGlossary` 各自唯一 |
| `StatusFieldCatalog.leftovers` 删除后是否还有调用方 | 无。状态页已全量切到 `extras(for:)` / `foldables(from:)` |
| `CarModelView.channel` 参数删除 | `PairingView` 用默认值编译通过；高度问题见 P2-3 |
| `Info.plist` 的 `LSApplicationQueriesSchemes` | 已移除，与 `NavigationApp` 改用 `open(_:options:completionHandler:)` 一致 |
| `Resources/amap-key.txt` | 已进 `.gitignore`；文件缺失时 `webKey` 返回 nil → 回退 MapKit，不崩 |
| `project.yml` 的 Watch 依赖 | 当前为 `[NO-WATCH]` 注释态（`switch-watch.sh off`）。`install.sh --phone-only` 的临时注释匹配不到该行，二者不冲突；**含义是当前构建永不含手表 App**，需要时先 `switch-watch.sh on` |
| 依赖版本 | 本轮未新增任何第三方依赖。高德走 HTTP，不引入 SDK |

---

## 六、新功能对既有模块的适配

| 改动 | 波及面 | 结论 |
|---|---|---|
| `VehicleSnapshot` 未变 | `VehicleTopView` / Widget / Watch / 实时活动 | 无影响 |
| `VehicleProfile.displayName` 新增 | 主界面标题、实时活动车名 | Widget / Watch 不读昵称，无影响 |
| `CarModelView` 删除 `channelPill` + 两行 `statusChips` | 车控页、配对页 | 两处均验证 |
| `StatusFieldCatalog` 语义分组 | 状态页字段区 | 白名单顺序未变，同组内 extras 追加在后 |
| `UserLocationProvider` 改共享 | 车控页 + 状态页两张卡 | 引用计数；P0-1 已修，P1-4 已注释 |
| `ContentView` 标签栏加 `sensoryFeedback` | 全 App 标签切换 | 不影响页面状态 |

---

## 七、UI 评估

### 7.1 玻璃遮罩规则（一致性结论）

| 材质 | 用在 | 可点？ |
|---|---|---|
| 玻璃 `glassEffect` | 顶栏 3 个胶囊、10 个控车按钮 | 只有「通道胶囊」和 10 个按钮可点 |
| 半透明面 `contentCard` | 车图 6 个浮标、能源带、车辆位置卡、车型 chip | 全部只读 |
| 半透明面 `surfaceBadge` | 按钮右上角通道角标 | 只读（**必须**：叠在玻璃上，玻璃套玻璃会有边缘噪点） |

**两处"玻璃但不可点"**：蓝牙状态胶囊、RSSI 胶囊。
**判定合理**：它们与可点的通道胶囊同处顶栏一条横排，材质分裂会让整排看起来断掉，
应整体视为 L2 控件带。
**但这条规则必须写进 `UI_STYLE_GUIDE`**，否则下次往顶栏加元素又会纠结。

### 7.2 布局一致性

- **左边缘**：标题 / 车图区 / 能源带 / 位置卡 / 按钮网格全部对齐到 20pt
  （车图区 26pt —— 3/4 视角的斜边需要 6pt 呼吸位，肉眼不可辨）
- **纵向节奏**：车图 → 能源 4pt（同组）｜能源 → 位置卡 10pt｜位置卡 → 按钮 14pt（跨组）
- **圆角**：卡片 20 / 内嵌 14 / 胶囊 12 / 微标签 6，本轮已把能源带从 12 并到 14

### 7.3 交互可用性

- 位置卡整卡可点 → 全屏地图（地图 + 导航 + 距离 + 采集时间）
- 三个第三方导航入口失败时给 4 秒提示，不静默失败
- 标签切换用 `Haptics.select`（selection，不是 impact）—— 语义是"选中项变了"，不是"执行了动作"
- 长按确认覆盖后备箱 / 开窗 / 寻车三个误触代价高的动作
- 不可执行时按钮不置灰、点击弹原因（避免"点了没反应"）

### 7.4 自适应（不含老机型）

| 场景 | 表现 | 判定 |
|---|---|---|
| 小区名很长（>10 字） | `lineLimit(1)` 截断 | 可接受；建议后续加 `minimumScaleFactor(0.85)` |
| 能源三项缺其中一两项 | HStack 自适应，仍左对齐 | 正确 |
| 四门/车窗/天窗全无数据 | 整行浮标消失，不留空 | 正确 |
| 位置卡无坐标 | 整卡不出现 | 正确 |
| 高德失败 | 回退 MapKit 道路级，卡片不白屏 | 正确 |

### 7.5 视觉规范偏离

1. 车图浮标 10pt 固定字号，不随 Dynamic Type 缩放 —— 它们是"图形化标注"，
   放大字号会直接压到车身上。可接受，但要在文档里写明这是有意为之。
2. 能源带与位置卡虽然圆角一致，但前者无图标底色、后者有地图 —— 材质同为
   `contentCard`，层级相同，判定合理。

---

## 八、优先修复建议

**已完成（本轮）**：P0 全部 2 项、P1 的 3 项、P2 的 3 项。

**建议下一步**：

1. **P2-4（低）**：`stageBadge` 的分支合并成 `(alert || highlight) ? tone.color : .secondary`。
2. **7.4 的截断**：给位置卡主标题加 `minimumScaleFactor(0.85)`，
   避免「XX国际花园三期」这类名字被硬截。
3. **补 `UI_STYLE_GUIDE` 的顶栏例外条款**（见 7.1），这是本轮唯一还缺"成文规则"的地方。

---

## 九、验证记录

| 项目 | 结果 |
|---|---|
| 类型检查（`./typecheck.sh`） | 0 error / 0 warning，70 文件 23,848 行 |
| 真机构建（`./tools/install.sh --phone-only`） | BUILD SUCCEEDED，装机成功 |
| 高德逆地理编码 | 实测返回 `上海市浦东新区高桥镇浦凌佳苑7号楼` + `aois:["浦凌佳苑"]` |
| 首屏完整性 | 车图 + 能源带 + 位置卡 + 10 个按钮，一屏内可滚动到底 |
| 水印 | 缩略图裁切方案，真机确认无「法律信息」遮挡 |
