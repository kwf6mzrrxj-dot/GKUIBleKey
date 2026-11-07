# 全项目审查（第五轮）

日期：2026-11-07　范围：GKUIBleKey v9.10 → v9.11
审查对象：本轮改动的三块（实时活动内容重构、材质三分层、全按钮触感）+ 存量代码

---

## 一、问题分类汇总

| 级别 | 数量 | 已修 | 需真机验证 |
|---|---|---|---|
| P1 功能失效 | 1 | 1 | 0 |
| P2 行为错误 / 误导 | 2 | 2 | 0 |
| P3 死代码 / 文档不一致 | 6 | 6 | 0 |
| **合计** | **9** | **9** | **2 项观感** |

**总体判断**：三块改动在接口层面全部对齐 —— 无重复定义、无悬空符号、
三个 target 编译一致、`SWIFT_STRICT_CONCURRENCY = complete` 下 0 error。
但**本轮最有价值的两条都是「做了却没生效」**，属于同一个失败模式。

---

## 二、按严重程度排序

### P1-1（已修）`staleDate` 设了，但没有任何地方读 `isStale`

| 项 | 内容 |
|---|---|
| 位置 | `LiveActivity/LiveActivityController.swift` + `Widget/VehicleLiveActivityWidget.swift` |
| 成因 | 上一轮给 `ActivityContent` 传了 `staleDate: Date()+300`，本意是「App 被杀后卡片别假装实时」。但 `staleDate` 只是**给开发者的标记**，系统不会自动改变外观 —— 需要在 Widget 里读 `context.isStale` 自己处理。整个 Widget 里一处都没有。 |
| 影响 | **等于没设**。App 被系统杀掉后，锁屏上仍然挂着一份看起来完全实时的旧状态。而这条正是上一轮专门想解决的问题 —— 改完以为解决了，实际没解决。 |
| 修复 | 锁屏卡与灵动岛展开态都读 `context.isStale`：过期时时间文字转橙 + `exclamationmark.triangle.fill`。克制但明确，不整卡变灰。 |

> **这是本项目第二次踩同一个坑**。第一次是阴影：把 `.shadow` 从 `.clipShape`
> 前面挪到后面，顺序对了但宿主 frame 仍等于内容尺寸，投影只画出两条边。
> 模式相同 —— **用了一个 API，却没验证它的效果是否真的落地**。

### P2-1（已修）三处 `.tactile()` 排在 `.disabled()` 之后，禁用按钮仍会震

| 项 | 内容 |
|---|---|
| 位置 | `ActionHistoryView`（清空历史）、`CloudSettingsView`（清除配置）、`LogHistoryView`（删除日志） |
| 成因 | 批量给按钮加触感时只匹配 `.buttonStyle(...)`，没考虑链式修饰符顺序。`.disabled()` 靠环境值向下传递，`.tactile()` 挂在它**外层**时不受约束。 |
| 影响 | 列表为空时点「清空」按钮，按钮已置灰、点了没反应，但**手机会震一下** —— 那是在告诉用户"操作被接受了"。比没有反馈更糟。 |
| 修复 | 三处都改成 `tactile` 在内、`disabled` 在外，并在代码里留注释说明顺序不可换。 |

### P2-2（已修）`staleAfter = 300s` 阈值过短，正常离车 5 分钟就误报过期

| 项 | 内容 |
|---|---|
| 位置 | `LiveActivityController.staleAfter` |
| 成因 | 取 300 秒时的理由是「比 `VehicleSnapshot.staleSeconds`（180 s）宽一档」。**错误类比** —— 两个阈值量的问题不同：前者是「这份数据能不能用来做决策」，后者是「这张卡片还可能代表现状吗」。 |
| 影响 | 锁车走开、蓝牙断开是最高频场景。5 分钟后卡片标成"过期"，而车其实还锁着 —— 误报会让用户以为出了问题。 |
| 修复 | 改 1200 秒（20 分钟）。依据写进代码注释：超过这个时长，人大概率已离开车的视野，且期间车辆被他人操作的可能性开始不可忽略。 |

> **关键前提**：`measured.$status` 每帧广播都会调 `refreshLiveActivity()`
> （内部 2 秒节流），所以只要 App 活着且收得到广播，staleDate 一直被推后。
> 真正触发只有「App 被杀」或「长时间收不到任何车辆数据」。

### P3-1（已修）`ContentState` 三个字段零消费

| 字段 | 状态 |
|---|---|
| `fuelLevel` | v9.9 新加，但 Widget 从未显示 → 删 |
| `isAccOn` / `isIgnitionOn` | v9.2 曾用于「电源」格，v9.9 换成「窗」后零引用 → 删 |

上一轮我给它们写的注释是「留给将来 CarPlay 单独排版」。**那不是保留死代码的理由** ——
真要做横向布局时重新接一遍数据，比现在维护三个假接口便宜。
删完 `AppModel.refreshLiveActivity` 还少了一个 `bt` 变量和一次判断。

### P3-2（已修）UI_STYLE_GUIDE 写「按钮三种」，实际四种

文档列的三种：主操作（自绘玻璃）、次要（`.glass`）、破坏性（`.glassProminent`）。
实际还有 8 处 `.buttonStyle(.plain)`（设置行、工具栏图标、列表行）。

它们不是「忘了统一」，是**有意**的：可点区域是整个子视图，套 `.glass`
会在行内再长出一个胶囊、把列表撑变形。文档已改为四种并写明理由与对应触感档位。

### P3-3（已修）三处列表行材质与卡片不一致

`listRowBackground` 用 `.ultraThinMaterial`（模糊），而内容卡片已改成
`Glass.surface`（半透明实心面）。两种材质语言并存时，从主界面点进设置页，质感会跳。

新增 `GlassListRowBackground`（内部读 `colorScheme`），三处统一。
**副作用**：顺带修掉了「`.listRowBackground` 收 View 不收 ShapeStyle」那个坑的重复踩踏
（之前用过 `AnyShapeStyle` 包装，类型推断报错过一次）。

### P3-4（已修）`Haptics` 注释笔误

`weight: .light / .medium / .heavy —— 力量（没 有 rigid）`：多余空格，且容易让人
以为 rigid 也是 weight 的一种。已改为明确的两个维度对照。

### P3-5（已修）`statusText` 默认值与语义不符

默认值 `"待机"` 是 v9.2 的遗留（当时 statusText 是自由文本）。现在它只承载
数据来源标签（`StatusSource.label`）："蓝牙实时" / "云端" / "暂无数据"。
已改默认值为 `"暂无数据"` 并加注释。

### P3-6（已修）LIVE_ACTIVITY.md 缺两条边界

- **纯蓝牙用户看不到窗位**：蓝牙 16 字节广播里没有窗位，只有云端有。
  没配云端的用户，「窗」这一格永远是「—」。这是诚实的（不知道 ≠ 关着），
  但对这类用户这一格没有信息量 —— 必须写明，否则会被当成 bug 反复查。
- 过期标记的呈现方式、以及 `staleDate` 与 `staleSeconds` 的区别。

---

## 三、冲突与适配检查

| 检查项 | 结果 |
|---|---|
| 重复定义 | ✅ 无。`contentCard` / `surfaceBadge` / `surfaceChip` / `GlassListRowBackground` 各一处定义 |
| 悬空符号 | ✅ 无。删除 `glassCard` / `glassBadge` / `glassChip` 后全部调用点已替换（0 残留） |
| 死字段 | ✅ 已清（见 P3-1） |
| 三 target 编译 | ✅ 主 App / Widget / Watch 一致。`Haptics.swift` 只在主 App 与 Widget 编入（Watch 不用触感） |
| 严格并发 | ✅ `SWIFT_STRICT_CONCURRENCY = complete` 下 0 error |
| 实时活动跨版本解码 | ✅ 新增字段全 optional + 默认值；删除字段对 `Codable` 解码安全（未知键忽略） |
| 触感与既有交互 | ✅ `HoldToConfirmButton` 单独处理（`.tactile()` 会让长按完成时双震）；alert 内按钮未加（系统管理） |
| 材质替换与布局 | ✅ `contentCard` 与 `glassCard` 签名一致（`radius` / `elevated`），16 处调用无需改参数 |

**适配结论**：预认证保活、点火验证、标定、云端路由、防爆破锁定、
位置解析、操作历史、未锁提醒、桌面小组件——均未被本轮改动破坏。
`refreshLiveActivity` 是新旧交接点，删除 `bt` 变量后逻辑更短，行为不变。

---

## 四、UI 评估

### 4.1 材质分层 ✅

| 层 | 材质 | 数量 |
|---|---|---|
| L0 背景 | 渐变 + 两盏氛围光 | 1 处定义 |
| L1 内容 | 半透明表面（`contentCard`）+ 列表行（`GlassListRowBackground`） | 16 + 3 |
| L2 控件 | 玻璃（`.glass` 26 / `.glassProminent` 8 / `.glassPill` 11） | 45 |
| L3 浮层 | 玻璃 + `.floating` | 2 |

玻璃不再出现在内容层，`glass on glass` 组合已消除（卡片内按钮现在是玻璃叠在表面上，
这是正确方向 —— 玻璃浮在内容之上）。

### 4.2 触感 ✅（手感未验证）

65 处，三档分布合理：轻 50 / 中 10 / 重 5。
危险入口（解绑、清空、删除、断开）单独用 `warn`，与普通点击区分开。

**风险**：`simultaneousGesture(TapGesture())` 在滚动容器里是否会在
"轻微拖动"时误触发，需要真机确认。理论上 `TapGesture` 有内部移动阈值，
但阈值大小未文档化。

### 4.3 布局一致性 ✅

- 圆角四档（20/14/12/6）、间距五档、字号五档 —— 无新增离群值
- 页边距 `Glass.pageMargin`(20) 全项目统一
- 底部留白 `Glass.tabBarInset`(96) 覆盖三个 Tab 页

### 4.4 响应式 ⚠️

- 锁竖屏 + iPhone only，主界面单列布局
- `energyStrip` / 控制区网格用 `maxWidth: .infinity` 自适应
- **未验证**：iPhone SE 类小屏（4.7"）上 10 个按钮 + 能源条是否溢出。
  项目最低支持版本是 iOS 27，但 SE 尺寸仍可能存在。

### 4.5 视觉规范文档 ✅

`UI_STYLE_GUIDE.md` 已与实现对齐：按钮四种、材质三分层、触感三档、
投影两级（与材质分层拆开编号，避免 L0–L3 撞号看串）。

---

## 五、优先修复建议

### 已完成（本轮）

1. `isStale` 消费 —— 让 `staleDate` 真正生效
2. 三处 `.tactile()` / `.disabled()` 顺序
3. `staleAfter` 300 → 1200 秒
4. 三个死字段
5. 列表行材质统一
6. 文档三处不一致

### 真机验证（优先级最高）

回家装机后按这个顺序看，每项只需一眼：

1. **材质**：主界面卡片是否"半透明但不模糊"，能透出底下渐变的色温
2. **深色模式**：卡片 7% 白是否太亮（我按亮度推算的，未实测）
3. **触感**：普通按钮是否"轻而短"；长按按钮完成时**只震一次**（不能双震）
4. **滚动误触**：在日志页滚动时是否有异常震动
5. **禁用态**：列表为空时点"清空"，**不应有震动**

### 下一批（按价值排序）

1. **`TactileModifier` 加移动阈值保护** —— 如果真机上发现滚动误震，
   给 TapGesture 换成 `DragGesture(minimumDistance: 0).onEnded` + 位移判断。
   先看真机结果，不要预防性复杂化。
2. **小屏适配** —— 若 SE 上控制区溢出，网格改 `LazyVGrid` 自适应列数。
3. **`Glass.surface` 参数化** —— 如果深色 7% 需要调，建议做成
   `Glass.surface(_:elevated:)` 两档，而不是让调用点传数值。

---

## 六、本轮结论

**三块改动本身是对的，但两处「做了没生效」说明验证方式有缺口。**

共同点：改动的是「配置」（staleDate、修饰符顺序），
而验证只做到「编译通过」，没做到「行为可观测」。

能脱离真机验证的部分（判定矩阵、算法）我都跑过了；
但**配置类改动没有等价的自检手段** —— 这类改动只能靠真机，
所以更应该在写的时候就把「谁来消费」写清楚。

具体到 `staleDate`：如果当时在 Widget 里先写 `if context.isStale { ... }`
再去设 staleDate，就不会漏。**从消费端往生产端写**，比反过来可靠。
