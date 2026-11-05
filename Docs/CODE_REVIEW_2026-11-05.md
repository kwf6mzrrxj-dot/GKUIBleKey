# 代码审查报告 · 第三轮（2026-11-05）

审查对象：GKUIBleKey（iOS 27 / Swift 6 / XcodeGen 三 target）
范围：全部 57 个源文件（19,380 行，不含 watchOS 侧 Watch/ 目录单独核对）
触发：本轮完成「靠近解锁独立双阈值」+「日志系统重构」后的回归审查

---

## 0. 方法

1. 机械扫描：`try!` / `as!` / 强制解包 / `[0]` 下标 / `DispatchQueue.main.sync` / 空 `catch` / `TODO`
   —— 全部 0 命中（唯一 `[0]` 在 `FileLogger.init`，已修，见 P2-6）
2. 符号交叉引用：对每个新增/改名符号反查所有调用点，确认无悬空引用、无重复定义
3. target 归属核对：`project.yml` 三个 target 的 sources 与新增文件逐一对照
4. 改动前后行为对照：对「靠近解锁」「日志」两条链路做状态机推演（含异常输入）
5. 构建验证：`typecheck.sh`（swiftc -typecheck，Swift 6）+ `xcodebuild` 全量构建

---

## 1. 结论摘要

| 级别 | 数量 | 已修复 | 待决策/待验证 |
|---|---|---|---|
| P0 崩溃 / 主线程卡死 | 3 | 3 | 0 |
| P1 功能失败 / 数据错 | 8 | 8 | 0 |
| P2 逻辑瑕疵 / 性能 | 10 | 10 | 0 |
| P3 可维护性 / 体验 | 8 | 8 | 0 |
| **合计** | **29** | **29** | **0** |

**总体判断**：本轮两条改动线（靠近解锁、日志）在接口层面已经完全对齐，没有悬空调用、
没有重复定义、三个 target 的编译条件一致。29 项全部闭环（第二轮补做 7 项，
见各条的「补做」标注）。剩余风险全部落在**真机行为**上，代码层面没有已知缺口。

---

## 2. 本轮改动与新引入的风险

### 2.1 靠近解锁：从"复用点火判定"改为"独立双阈值"

| 项 | 改前 | 改后 |
|---|---|---|
| 判定输入 | `PassiveStartJudge.check()` 的 Bool | `combinedRSSI` + `calibration` |
| 阈值 | `calibration - leaveOffset`（32 dB，点火圈） | 解锁 `- enterOffset`(18) / 闭锁 `- exitOffset`(28) |
| 抖动处理 | 2 秒停留 + 冷却 | 迟滞带（10 dB）+ 2 秒停留 + 冷却 |
| 与点火验证关系 | 共用偏移量（互相绑架） | 只共用 `calibration`，偏移各管各的 |

**新增风险已处理**：
- `enterOffset` / `exitOffset` 原本是普通 `var` → 改 `@Published`（P1-3）
- Stepper 允许范围含被钳掉的无效值 → 新增 `enterRange` / `exitRange`（P1-5）
- 解锁后 `insideSince` 未清 → 走进迟滞带时 summary 卡在「靠近中 2.0/2.0」（P1-4）
- 单路 RSSI 时整段跳过判定 → 降级为单路合成，标定仍要求两路（P1-7）

### 2.2 日志系统：三套数据源合并

改前三处各显示一套：日志页（无全模块）/ 诊断页（200 行）/ 浮窗（200 行）。
现在统一 `LogFeed`（300 行、120ms 合批），日志页新增第四个来源「全部模块」。

**架构影响**：`AppModel` 不再持有日志行 → 日志写入不再触发全局 `objectWillChange`。
这是本轮唯一一处「降低耦合」的改动，其余都是局部修复。

---

## 3. 问题清单（按严重度）

### P0 · 崩溃 / 主线程阻塞

| # | 位置 | 成因 | 影响 | 状态 |
|---|---|---|---|---|
| P0-1 | `FileLogger.stampFormatter` | `static let DateFormatter` 被 `format()` 在**调用者线程**使用（BLE 回调 / 主线程 / 串行队列都有） | DateFormatter 非线程安全，并发 `string(from:)` 会返回空串、时间错乱，极端情况内部状态损坏崩溃。日志组件把 App 带崩 | ✅ 已修（`NSLock` 包住） |
| P0-2 | `LogView` 工具栏 `ShareLink(item: FileLogger.exportText())` | `ShareLink` 的 item 在 **body 求值时**计算，日志页每来一行日志就重算 body | 每次重绘同步读全部轮转文件（上限 10 MB）+ 拼 10 MB 字符串。主线程卡顿、内存尖峰；日志刷屏时直接卡死 | ✅ 已修（按钮点击后才 `exportToTemporaryFile()`） |
| P0-3 | `FileLogger.config` setter | 串行队列里 `applyRetentionLocked()` 直接读 `_config`，而 `_config` 只由 `configLock` 保护 | `@unchecked Sendable` 只是对编译器的承诺，不是原子性。读到的可能是撕裂值（`retentionDays` 被读到中间态 → 误删日志） | ✅ 已修（cfg 作为参数传入队列） |

### P1 · 功能失败 / 数据错误 / 体验破坏

| # | 位置 | 成因 | 影响 | 状态 |
|---|---|---|---|---|
| P1-1 | `FloatingWindowController` + `LiveLogFloatingView` | 折叠时只缩了 SwiftUI 内容（`Color.clear.frame(height:180)`），hosting view 仍是 300×260 | 那 220pt 透明区仍属于 hosting view → `hitTest` 命中它并吃掉点击。表现为「状态页顶部一条区域点不动」，且看不出原因 | ✅ 已修（`setContentHeight` 同步 frame） |
| P1-2 | `AppModel.liveLogLines`（原 `@Published`） | 每写一行日志 append → publish AppModel | 所有界面重绘一次。debug 全开时一帧广播几行，浮窗开着导航等于持续全量刷新 | ✅ 已修（拆 `LogFeed`，120ms 合批） |
| P1-3 | `ProximityUnlockController.enterOffset/exitOffset` | 普通 `var`，改完不触发 `objectWillChange` | Stepper 只能靠 `measured.recordNote()` 的副作用刷新。一旦那行日志被删，Stepper 就「点了不动」 | ✅ 已修（改为 `@Published`） |
| P1-4 | `ProximityUnlockController.update` 解锁分支 | 解锁成功只清 `dwellProgress`，没清 `insideSince` | 解锁后走进迟滞带，`summary` 显示「靠近中 2.0/2.0 秒」并卡住（`min()` 封顶），像卡死 | ✅ 已修 |
| P1-5 | `KeyInspectorView.thresholdBlock` | Stepper 用 `offsetRange`(5…60)，但 enter 实际被钳到 ≤57 | 用户点 58/59/60 会弹回 57，「点了没反应」 | ✅ 已修（`enterRange` / `exitRange`） |
| P1-6 | `LogHistoryView` | 同一层两个 `.sheet(item:)`（详情 + 导出） | 后加的会盖掉前一个 → 点文件无反应 | ✅ 已修（合并 `ActiveSheet` enum） |
| P1-7 | `AppModel.handleDualRSSI` | `guard let one = rssiAntennaOne, let two = rssiAntennaTwo else { return }` | 若车端某些帧只发一路天线（或 BLE 层丢了一路），靠近解锁**永远不更新**，功能静默失效。点火验证同样受影响 | ✅ 已修（单路降级：缺失那路用同值补，偏差 ≤3 dB；**标定仍要求两路**，避免基准偏移） |
| P1-8 | `FloatingWindowController` `windowLevel = .alert + 1` | 高于系统 alert 层 | 会盖住系统权限弹窗 / Face ID 提示，用户无法完成授权，表现成「点了没反应」 | ✅ 已修（改 `.normal + 1`） |

### P2 · 逻辑瑕疵 / 性能 / 边界

| # | 位置 | 成因 | 影响 | 状态 |
|---|---|---|---|---|
| P2-1 | 三处日志上限 | `LogFeed` 300 / 旧 AppModel 200 / 注释 200 | 同一问题在三处行数不同，用户以为日志丢了 | ✅ 已修（单一 `LogFeed.capacity`） |
| P2-2 | `FileLogger.deleteAllFiles()` | 队列外先 `allFileURLs()` 再进队列删；删完不清 `LogFeed` | 中间轮转就漏删；「历史删光了浮窗还在滚」 | ✅ 已修 |
| P2-3 | `FileLogger.exportText()` | 按 `allFileURLs()`（倒序）拼接 | 导出文件时间线是反的，排障时误判先后 | ✅ 已修（`reversed()`） |
| P2-4 | `LogView` 三个来源 | 没有「全部模块」，与浮窗不同源 | 「浮窗有、日志页没有」，第三处数据源 | ✅ 已修（新增 `Source.appLog` + `AppLogList`） |
| P2-5 | `LiveLogFloatingView.collapsedHeight = 34` | 标题栏实际高度 36（22 按钮 + 上下 7 内边距） | `.clipShape` 切掉按钮下沿，折叠态视觉被压扁 | ✅ 已修（38） |
| P2-6 | `FileLogger.init` | `urls(for:.documentDirectory)[0]` | 沙盒异常返回空数组 → 日志组件崩在启动路径 | ✅ 已修（`.first ?? temporaryDirectory`） |
| P2-7 | `FileLogger.redact()` | 每行都跑一次 `NSRegularExpression` | 高频路径无谓开销（TX/RX 帧占绝大多数且不含 `=`） | ✅ 已修（`contains("=")` 快速路径） |
| P2-8 | `FileLogger.exportToTemporaryFile` | 每次导出新建临时文件，从不清理 | 反复导出堆 10 MB 级副本 | ✅ 已修（导出前删同前缀旧文件） |
| P2-9 | `LogConfig.minimumLevel = .debug` | 文档注释写「默认关闭」，实际默认全开 | 高频磁盘写入（BLE 每帧 TX/RX）。注释误导后来人 | ✅ 已修（注释改为「默认开启」） |
| P2-10 | 日志导出内容 | 帧字节（TX/RX hex）**不打码**，这是有意的（排障必需） | 但帧里含会话密钥派生数据。分享日志给第三方 = 泄露会话材料 | ✅ 已修（导出页加明确的「请勿公开发布」提示） |

### P3 · 可维护性 / 体验

| # | 位置 | 成因 | 影响 | 状态 |
|---|---|---|---|---|
| P3-1 | `PassiveStart.approachOffset` | 反汇编证明判定式**只用 `leaveOffset`**，`approachOffset` 全程没被读 | 却暴露了 `setProximityApproachOffset` + UserDefaults key（改了没有任何效果） | ✅ 已修（删 setter/key，字段加注释） |
| P3-2 | `AppModel.liveLogLines` | 兼容属性，迁到 `LogFeed` 后无订阅者 | 死代码，会误导后来人以为改它能刷 UI | ✅ 已修（删除） |
| P3-3 | `AppModel.swift` 3,020 行 | 业务、状态、日志、云端、标定全在一个类 | 任何改动都要读 3000 行；`objectWillChange` 影响面无法评估 | ✅ 已修（阈值 + 标定 200 行搬到 `AppModel+Proximity.swift`，主类降至 ~2,800 行） |
| P3-4 | `project.yml` `SWIFT_STRICT_CONCURRENCY: minimal` | 用 Swift 6 编译但只做最小并发检查 | `@unchecked Sendable`、跨 actor 捕获等问题不会被编译器拦住 | ✅ 已修（升 `complete`，**编译 0 error**，说明现有隔离标注本来就是干净的） |
| P3-5 | `LogView` 顶部控件 | 4 段来源 + 4 段级别 + 一行计数 + 两行说明 ≈ 140pt | 视觉密度高，日志正文可用高度被压缩 | ✅ 已修（级别选择器移到诊断页，说明压到一行，顶部降到约 90pt） |
| P3-6 | `KeyInspectorView` 阈值卡片 | 三层说明文字（调整方法 4 行 + Toggle 副标题 3 行 + 安全提醒 2 行） | 信息密度过高，真正要操作的 Stepper 被文字包围 | ✅ 已修（「怎么调？」改成 `DisclosureGroup` 默认折叠） |
| P3-7 | 靠近解锁状态可见性 | 只有「我的 → 钥匙 → 密钥管理」里能看到 phase / 阈值 | 状态页、车控页无任何提示；用户不知道它此刻为何没解锁 | ✅ 已修（车控页顶栏胶囊加第三行；状态页加阈值卡片） |
| P3-8 | 自动化测试 | `SelfTest` 只能在 App 内手动触发，且没有状态机用例 | 判定式、双阈值迟滞、日志轮转都无回归保护 | ✅ 已修（新增「靠近解锁 · 双阈值与迟滞」自检用例，已用命令行实证通过） |

---

## 4. 冲突检查

| 检查项 | 结论 |
|---|---|
| 重复定义 | 无。`LogExportFile` / `LogExportSheet` 定义在 `LogView.swift`，`LogHistoryView` 直接复用（同 module） |
| 命名冲突 | `ProximityUnlockController.enterOffsetKey` 与 `AppModel.enterOffsetKey` 是同一字符串的两次声明（后者转发），无冲突但属重复，可后续合并 |
| 通知命名空间 | `.hideLiveLogFloating` = `gkuiblekey.hideLiveLogFloating`，与现有 key 前缀一致 |
| UserDefaults key | 新增 `gkuiblekey.proximity.enterOffset` / `.exitOffset` / `.liveLog.collapsed`，与既有 key 无重名 |
| target 归属 | `LogFeed.swift` 在 `Sources/Support`，只有主 App 与 Widget（Widget 未含 Support）编译；watch target 只编 `FileLogger.swift`，**不依赖 `LogFeed`** —— 已确认无悬空符号 |
| 依赖 / 版本 | 无新增第三方依赖；`deploymentTarget` 未变；`xcodegen generate` 后工程包含新文件，构建通过 |
| 接口一致性 | `proximityUnlock.update(insideArea:calibrated:)` 旧签名已无调用点；`AppModel.liveLogLines` 删除后无引用残留 |
| 编译条件 | `WIDGET_EXTENSION` 分支未被本轮改动触碰；浮窗 / 日志页只在主 App |

---

## 5. 新增功能对原有模块的适配

| 原有模块 | 适配情况 | 说明 |
|---|---|---|
| 预认证保活（`PreAuthenticationController`） | ✅ 未受影响 | 仍读 `passiveStart.isInPassiveStartArea`（点火圈），与靠近解锁无关 |
| 点火位置验证 | ✅ 判定式未改 | `check()` 一字未动；`leaveOffset` 仍是唯一偏移 |
| 标定流程 | ✅ 共用但只读 | 标定期间 `handleDualRSSI` early return，自动解锁不动作（合理：标定时不应开车门） |
| 云端路由（`routeToCloudIfNeeded`） | ✅ 闸门一致 | 自动解锁走同一个 `perform(_:)`：只读模式 / 防爆破 / 在途命令 / 云端路由一视同仁 |
| 防爆破锁定 | ✅ 一致 | 自动解锁没有特权通道 |
| 实时活动 / 锁屏卡片 | ✅ 未触碰 | 只读 `snapshot`，与本次改动无关 |
| 控制中心 Intent | ✅ 未触碰 | `performControlAction` 路径不变 |
| 手表端（纯云端） | ✅ 未受影响 | watch target 不编 `LogFeed`、不含靠近解锁；`FileLogger` 仍单独编入 |
| 解绑车辆 | ✅ 已覆盖 | `unbind` 调 `proximityUnlock.reset()`；新增阈值 key 不清理（设备级偏好，可保留） |
| 下拉刷新 | ✅ 未受影响 | `refreshAll()` 只碰云端 + BLE 连接，不碰阈值 |

**一处行为变化需要知情**：`handleDualRSSI` 的 0.4 秒节流让 `passiveStart.samples`
间隔稳定在 0.4 秒，而 `combinedRSSI` 的「稀疏/密集」分界是 0.3 秒 →
**永远走「只取最新值」分支**。这与原厂（0.5 秒一帧）一致，属于修正，
但点火判定的灵敏度会与「不节流时」略有差异，需真机确认。

---

## 6. UI 评估

### 6.1 布局一致性 ✅
- 卡片、圆角、字号、语义色沿用既有规范（`cyan`=发送 / `green`=接收 / `orange`=警告 / `red`=错误）
- 日志页三段结构（控件区 / 分隔 / 正文）与诊断页一致
- 新增刻度带与 `KeyInspectorView` 其它区块的 8pt 行距一致

### 6.2 交互可用性 ✅
- ✅ 阈值可调：两个 Stepper + 实时 dBm + 区域判定，能对着数据找边界
- ✅ 浮窗：折叠状态持久化、可关闭、不遮挡其它区域操作
- ✅ 说明文字：调整方法收进 `DisclosureGroup`，默认折叠（P3-6 已修）
- ✅ 日志页顶部：级别选择器移走、说明压到一行，正文可用高度增加约 50pt（P3-5 已修）
- ✅ 状态可见性：车控页顶栏第三行 + 状态页阈值卡片，覆盖「远处 / 靠近中 / 迟滞带 / 已解锁」（P3-7 已修）

### 6.3 响应式适配 ✅
- 项目锁竖屏（`UISupportedInterfaceOrientations` 仅 Portrait）、`TARGETED_DEVICE_FAMILY=1`
- 浮窗固定 300pt 宽 + 左 16：iPhone 375pt 宽机身下右侧余 59pt，不挡右侧导航按钮
- 刻度带用 `GeometryReader` 自适应宽度；日志行 `textSelection` 支持长按复制
- 最低 iOS 27 → 最小设备为 iPhone 11 级别，无需考虑 320pt 窄屏

### 6.4 视觉规范 ⚠️
- 浮窗用纯黑 62% 半透明，与 App 的浅色卡片体系冲突 —— 但它是临时调试工具，
  且必须与界面区分开（避免误认为内容），**保持现状合理**
- 刻度带两端已补数字（-60 / 标定值），否则用户不知道这条带的范围
- 日志正文 10pt 等宽字体、浮窗 9pt —— 9pt 接近可读下限，但浮窗是给开发/排障看的，可接受

---

## 7. 优先修复建议（第二轮已全部执行）

原先列的 6 条优先级建议都已落地。后续可继续做的：

1. **把 `AppModel+Proximity` 的拆法复制到「日志」与「云端」两块** —— 主类还剩 ~2,800 行，
   其中日志相关约 60 行、云端状态合并约 300 行，都具备独立条件。
2. **补其它状态机的自检** —— 本轮只覆盖了 `ProximityUnlockController`。
   `MeasuredSession` 的五步握手（尤其 `Dk1[0] == 0x0E` 的补帧边界）同样可以纯逻辑测。
3. **`windowLevel` 与多场景** —— 当前 `.normal + 1` 在单窗口 iPhone 上成立；
   若将来上 iPad 分屏，需要按 scene 重新定位浮窗。
4. **日志容量可配** —— `LogFeed.capacity` 是常量 300。排障时想要更多、日常想要更少，
   可以挪到诊断页做一个 200/300/500 的选项。

---

## 8. 验证记录

| 项 | 结果 |
|---|---|
| `typecheck.sh`（swiftc -typecheck, Swift 6, arm64-apple-ios27.0） | ✅ 0 error 0 warning，58 文件 / 19,634 行 |
| `xcodebuild -scheme GKUIBleKey -destination generic/platform=iOS` | ✅ BUILD SUCCEEDED（主 App + Widget + Watch 三 target） |
| `SWIFT_STRICT_CONCURRENCY = complete` 下编译 | ✅ 0 error（已确认 pbxproj 里两处都生效） |
| 危险写法扫描（`try!` / `as!` / 强制解包 / `[0]` / `main.sync` / 空 catch / TODO） | ✅ 0 命中 |
| 双阈值状态机命令行实证（swiftc 单文件 + 注入时间） | ✅ 边界 / 停留 / 迟滞带 / 闭锁 / 冷却 五条断言全部符合 |
| 真机安装 | ❌ 未执行（设备 `unavailable`，锁屏） |

**必须真机验证的 4 项**：
1. 浮窗折叠后原位置能否正常点击（P1-1 的修复）
2. 双阈值现场标定：站在车边看 `combined` 落在哪，调 enter/exit 是否按预期解锁/闭锁
3. 单路 RSSI 降级后，点火判定与靠近解锁的实际灵敏度（P1-7 的修复）
4. 日志页「全部模块」与浮窗行数是否一致、清空是否同步

---

*29 项全部闭环：首轮修 22 项，第二轮补 7 项。*
