# UI 视觉规范（v9.7 / 2026-11-05）

> 这份文档是**唯一来源**。新增界面先对照这张表，不要在文件里另发明一套数值。
> 代码里的对应实现在 `Sources/UI/DesignSystem.swift`。

---

## 一、本轮修掉的 12 类不一致

| # | 问题 | 具体表现 | 处理 |
|---|---|---|---|
| 1 | **两套玻璃并存** | 系统 `glassEffect`（少数页）与自绘 `.ultraThinMaterial` + 手补描边（多数页）。自绘要"像玻璃"就得自己补光影，每处参数都不同 | 全部改用 `glassEffect`，统一入口 `glassCard/glassPill/glassChip/glassBadge` |
| 2 | **全项目零阴影** | 只有浮窗一处 `.shadow`，且写在 `.clipShape` **之前** → 被裁掉，等于没有。所有面与背景只靠材质差别分隔 | 建立两级投影 `.card` / `.floating`，浮窗修正修饰符顺序 |
| 3 | **6 处 iOS 7 时代按钮** | `.buttonStyle(.bordered)` / `.borderedProminent`：半透明灰底 + 纯蓝实心，与玻璃体系完全无关 | 改为 `.glass` / `.glassProminent` |
| 4 | **两个通栏按钮** | 「准备点火」是整行卡片（88pt 高、15pt 标题、带 chevron）；「启动引擎」整行 48pt | 并入 3 列网格，与其余 8 个按钮同构 |
| 5 | **按钮无形状** | 引擎按钮 `.fill(.quaternary.opacity(0.35))`：`.quaternary` 本身约 8%，再 ×0.35 → **2.8%**，肉眼等于透明。俯视图瓦片同样 | 改玻璃材质 / `Color.secondary.opacity(0.12)` |
| 6 | **文字对比度不足** | 状态条整条用 `green`/`orange`（对浅底约 2:1，低于可读下限）；而它正是"失败/超时/锁定"的唯一反馈 | 图标保留色相，文字回 `primary`，底色 13% |
| 7 | **标注完全不可见** | 刻度带两端 8pt + `.quaternary`（8%）；`需网络` 角标 8pt | 字号下限提到 9pt，`.quaternary` → `.tertiary` |
| 8 | **斑马纹两个浓度** | `glassFill.opacity(0.5)` 与 `0.4` → 3% / 2.4%，肉眼无差但每次要算两层 alpha | 统一 `Glass.zebra()`：4.5% / 5.5% |
| 9 | **色带戳出胶囊** | 刻度带绿/橙段是裸 `Rectangle`，压在圆头底上，两端直角溢出 | 色带整体 `.clipShape(Capsule())`，圆点留在裁剪外 |
| 10 | **分隔线强度不一** | `Divider().overlay(Color.secondary)` 把系统线整条盖成实色，比其它页重一档 | 去掉 overlay |
| 11 | **背景三份定义** | 主界面渐变、配对页手抄渐变（深色第二档差 0.01）、日志/诊断/密钥三页纯 `systemBackground` | 统一 `GlassScreenBackground` |
| 12 | **页边距 18 / 20 / 16 三档** | 主界面 20、三个二级页 18、日志页 16 | 全部 `Glass.pageMargin` |

---

## 二、令牌

### 圆角（四档）

| 令牌 | 值 | 用途 |
|---|---|---|
| `Glass.cardRadius` | 20 | 大卡片：状态、设置、密钥、日志 |
| `Glass.controlRadius` | 14 | 内嵌小卡、刻度带、行按钮 |
| `Glass.pillRadius` | 12 | 胶囊、小标签 |
| `Glass.chipRadius` | 6 | 极小角标 |

> 禁用第三、第四档之外的新圆角。删掉之前项目里出现过 4 / 6 / 10 / 12 / 14 / 16 / 20 / 22 八种。

### 间距（五档）

| 令牌 | 值 | 用途 |
|---|---|---|
| `Glass.pageMargin` | 20 | 页面左右边距 |
| `Glass.cardPadding` | 16 | 卡片内边距 |
| `Glass.sectionSpacing` | 14 | 卡片之间 |
| `Glass.innerSpacing` | 10 | 卡片内元素之间 |
| `Glass.tabBarInset` | 96 | 滚动内容底部留白（悬浮标签栏 80 + 16） |

> 1–5pt 的微调（图标与文字对齐）允许直接写数字，那不属于布局节奏。

### 字体（五档）

| 令牌 | 值 | 用途 |
|---|---|---|
| `Glass.Typo.page` | 22 bold | 页标题（Tab 页与二级页） |
| `Glass.Typo.cardTitle` | 15 semibold | 卡片标题、弹窗标题 |
| `Glass.Typo.body` | 13 | 正文、列表主行 |
| `Glass.Typo.caption` | 11 | 次要说明、按钮标签 |
| `Glass.Typo.micro` | 9 | 状态第三行、等宽数据（**下限**，不再有 8pt） |

**为什么合并**：改前有 8 / 9 / 9.5 / 10 / 11 / 12 / 13 / 14 / 15 / 16 / 18 十一种字号。
**1pt 的差异不产生层级，只产生噪声**；层级必须靠跨档拉开（9 → 13 → 22）。

### 语义色

| 令牌 | 色 | 含义 |
|---|---|---|
| `Glass.Tone.success` | green | 成功 / 在线 / 已连接 |
| `Glass.Tone.warning` | orange | 警告 / 过期 / 需注意 |
| `Glass.Tone.danger` | red | 失败 / 危险 |
| `Glass.Tone.bluetooth` | blue | 蓝牙通道 |
| `Glass.Tone.network` | green | 网络通道 |
| `Glass.Tone.outgoing` | cyan | 发送 / 主动 |

**铁律**：语义色只用于**图标、描边、底色**。正文一律 `primary` ——
系统 `green`(#34C759) 对浅底约 2.1:1、`orange`(#FF9500) 约 2.0:1，
低于可读下限，绝不能承载正文。

### 投影（两级）

> 这一节只说**投影**。哪一层该用玻璃、哪一层该用表面，见下方「材质三分层」。
> （两者曾都用 L0–L3 编号，含义不同，容易看串，已拆开。）

| 级别 | 用在哪 | 浅色 | 深色 |
|---|---|---|---|
| `.card` | 内容卡片 | 7% / r10 / y3 | 18% / r6 / y2 |
| `.floating` | 浮层（操作横幅、日志浮窗） | 18% / r20 / y8 | 45% / r22 / y9 |

**深色下几乎不用投影**：黑压在近黑背景上不产生分离，只会在卡片四周留一圈更黑的边。
深色的层次由材质建立（面比底亮一档 + 边缘描边）。

---

## 三、组件规则

### 按钮（四种）

| 场景 | 写法 | 触感 |
|---|---|---|
| 主操作（解锁 / 闭锁） | 自绘 `glassEffect(.regular.tint(x).interactive(), in: RoundedRectangle(20))` + 同 shape 的 `strokeBorder` 高亮 | `.commit` |
| 次要操作（网格内 8 个） | `.buttonStyle(.glass)`，label = 图标 18 + `caption` 标题 + 可选 9pt 第三行 | `tap` |
| 破坏性 / 确认 | `.buttonStyle(.glassProminent)` | `commit`；入口用 `warn` |
| 整行 / 图标按钮（设置行、工具栏、列表行） | `.buttonStyle(.plain)` + 自绘 label | `tap` |

第四种（`.plain`）此前没写进文档，实际有 8 处 —— 它们不是"忘了统一"，
而是**有意**的：这些按钮的可点区域是整个子视图（设置行是一整行、工具栏是图标本身），
套 `.glass` 会在行内再长出一个胶囊，把列表撑变形。

- **能点的按钮不画成不能点**：不按连接状态调 `.opacity`，状态由顶部胶囊表达。
- 误触代价高的（后备箱 / 开窗 / 微开 / 寻车）走 `HoldToConfirmButton` 长按 0.6 秒。
- **形状差异表达层级**：主操作圆角矩形（20，有分量），次要操作胶囊（轻）。这是唯一允许的形状不统一，不要"统一"掉。

### 卡片

一律 `.contentCard()`。**列表里成批出现的传 `elevated: false`** ——
十几张卡各自投影会在间隙叠成灰带，反而更脏，且每张都要离屏合成。

> ⚠️ **2026-11-07 改名并换了材质**，从 `glassCard()`（真的用 `glassEffect`）
> 改成 `contentCard()`（半透明表面 + 描边 + 投影）。原因见下节 ——
> 这条是本规范里唯一一次「推翻上一版结论」，别照着旧代码改回去。

### 数据格（energyStrip）

车控页的油量 / 续航 / 电瓶是**一排小格**，不是按钮：

- 三格等宽，`HStack(spacing: 8)`，每格 `minHeight: 50` + `.glassCard(radius: controlRadius, elevated: false)`
- 结构固定：`图标 9pt + 标签 9pt`（secondary）→ `数值 15pt semibold`（monospacedDigit）
- 取不到值的格子**不显示**，整条都取不到时整条不出现（不写「—」占位）

**三格都是只读的，没有可点交互。**

油量只显示百分比。曾做过「点按切换升数」，按 58 L 油箱折算并标了「估算」，
后来删掉了：**接口只给百分比、不给油箱容积，58 L 是查来的参数不是实测值**。
一个乘法算出来的数字，哪怕标了"约"，摆在那里也像测量结果。
没有确切数据就不显示 —— 这是数据诚实的一部分，不是功能缺失。

配色只做两处语义提示：油量 < 15% 转 `Tone.warning`，电压 < 12.0 V 转 `Tone.danger`。
其余一律 `primary`（见第二节的铁律）。

### 材质三分层（2026-11-07 修正）

上一版把**所有面板**都改成了 `glassEffect(.regular)`，共 17 处。
那是错的 —— iOS 26/27 的 Liquid Glass 有一条前提：

> **玻璃是「控件层」的材质，不是内容容器的材质。**

| 层 | 用什么 | 例子 |
|---|---|---|
| L0 背景 | 渐变 + 氛围光 | `GlassScreenBackground` |
| L1 内容 | **半透明表面**（`contentCard`），不是玻璃 | 状态卡、设置分组、密钥卡、数据格 |
| L2 控件 | **玻璃**（`.buttonStyle(.glass)`、`glassPill`） | 主/次按钮、顶栏胶囊 |
| L3 浮层 | 玻璃 + `.floating` 投影 | 操作横幅 |

#### 为什么内容卡片不能用玻璃

1. **玻璃失去意义**。玻璃之所以像玻璃，是因为背后有内容可透。
   17 张卡片摞在渐变底上，每张背后都是另一张卡片 —— 全部退化成模糊白板，
   与 `.ultraThinMaterial` 看不出区别，却贵得多（每张都要离屏合成）。
2. **层次反而消失**。所有层同一种材质时，深浅只由模糊决定，
   卡片与卡片、卡片与背景之间没有明确层级。
3. **glass on glass**。卡片里的按钮本身就是 `.buttonStyle(.glass)`，
   两层折射互相干扰，转角处出现噪点。

#### 表面怎么做的

`Glass.surface()` + `Glass.hairline()` + `.card` 投影，三段组成：

- **半透明**（浅 72% 白 / 深 7% 白）：仍透出底下的渐变，不是白纸。
  这两个数不是随手取的：浅色底（0.82~0.94 亮度）上 72% 能把卡片提到约 0.97，
  刚好看得出一档；深色底（0.06~0.11）上 7% 提到 0.13，再高就成"发灰的塑料板"。
- **0.5pt 描边**：浅色用黑、深色用白。
  之前那套 `white.opacity(0.55)` 在浅色底上等于隐形 —— 这是它失效的原因。
- **不做模糊**：模糊是玻璃的职责，内容层只需要"比背景亮一档"。

#### 小尺寸图形也不要玻璃

通道角标（16pt 圆）、车型角标（chip）原来都是 `glassEffect`。
但它们**叠在玻璃按钮上** —— glass on glass。而且 16pt 的圆上看不出折射，
只能看到边缘噪点。改成 `surfaceBadge()` / `surfaceChip()`：
半透明面 + 细描边，要的是**轮廓清晰**，不是折射。

#### 玻璃保留在哪

- 顶栏胶囊、通道胶囊：浮在**滚动内容**上，背后一直有新内容经过 —— 玻璃该用的场景
- 全部按钮：控件层
- 操作横幅：L3 浮层

### 背景

- 玻璃要有东西可透。纯 `systemBackground` 做底会让材质退化成灰板。
- 背景只有 `GlassScreenBackground` 一处定义：纵向渐变 + 右上主色雾光 + 左下冷雾。
  **两盏灯是必需的**：只有一盏时卡片从左上到右下透出的底色一样，玻璃没有"厚度"。

### 触感反馈（2026-11-07 新增）

每个按钮都有触感，按动作轻重分三档 —— 全部一样重等于告诉用户"每件事同等重要"。

| 档位 | 常量 | 用于 | 数量 |
|---|---|---|---|
| 轻 | `Haptics.tap` | 次要动作、设置行、图标按钮、关闭 | 50 |
| 中 | `Haptics.commit` | 主操作（解锁 / 闭锁 / 启动引擎 / 提交） | 10 |
| 重 | `Haptics.warn` | 危险入口（解绑、清空历史、删除日志、断开连接） | 5 |

用法：`.buttonStyle(.glass).tactile()`，主操作传 `Haptics.commit`。

#### 为什么不用自定义 ButtonStyle 包装

系统的 `.glass` / `.glassProminent` 是 **`PrimitiveButtonStyle`** ——
它的 `Configuration` 只暴露 `label` 和 `trigger()`，**没有 `isPressed`**，
写不出「按下时震动」的包装器（`PrimitiveButtonStyleConfiguration` 也没有公开 init）。

所以用 `.simultaneousGesture(TapGesture())` 计一次数 + `.sensoryFeedback(trigger:)`：
并行手势不与 Button 竞争，action 照常触发；触感交给系统管线程与生命周期
（直接调 `UIImpactFeedbackGenerator` 要自己管 prepare 时机和后台重建）。

#### 长按按钮是例外

`HoldToConfirmButton` **不能**加 `.tactile()` —— 它用 `LongPressGesture`，
按住 0.6 秒后松手时 `TapGesture` 同样会识别（它没有时长上限），
会在命令发出那一刻多震一次。它自己用两处 `.sensoryFeedback`：
按下 → `tap`，到位 → `warn`。

到位用 `warn` 而不是 `.success`：这一刻只是"命令发出去了"，
还不知道车端结果，用 success 会在失败时给出相反的当体感结论。

#### 哪些不加

- **alert / confirmationDialog 里的按钮** —— 系统管理，加了会双震
- **系统 `TabView` 的 tab** —— 系统自带触感

---

## 四、有意保留的差异（不要"修"）

1. **主 vs 次按钮形状不同**（圆角矩形 vs 胶囊）—— 层级编码。
2. **日志浮窗用深色半透明而非玻璃** —— 它盖的是内容不是空底，需要与内容强分离；终端语义。
3. **`.disabled` 只在真的不能操作时用**（未标定的开关、空列表的导出）；
   控车按钮一律不 disable，走 `perform` 的挂起重连。
4. **日志页/诊断页信息密度高** —— 那是排障页，密度优先于留白。

---

## 五、验证

- `typecheck` 0 error 0 warning（64 文件 / 20,702 行）
- `xcodebuild` BUILD SUCCEEDED（主 App + Widget + Watch）
- 真机 9.7 (100) 已装机，主界面截图确认：8 个网格按钮同构、无通栏按钮、底部不再被标签栏切字

**尚未验证**：深色模式（模拟器只有 iOS 26.5 运行时，装不了 iOS 27 包；
真机切换外观无法脚本化）。深色参数按渲染原理推算，需人工过一眼。

---

## 六、其他页面的阴影/遮罩问题（第二轮排查）

主界面之外还有六处，分三类。

### A. 页面级遮罩断裂：三个列表页

| 页面 | 入口 | 现象 |
|---|---|---|
| 设置（`DeveloperMenuView`） | 我的 → 设置 | 整页白色不透明分组底 |
| 网络通道（`CloudSettingsView`） | 我的 → 网络通道 | 同上（Form） |
| 历史日志（`LogHistoryView`） | 诊断 → 历史 | 同上 |

**成因**：`List` / `Form` 在 `.insetGrouped` 下自带**不透明的分组底**
（`secondarySystemGroupedBackground`），它盖在页面背景之上。
只给外层加 `GlassScreenBackground()` 是无效的 —— 渐变被 List 自己的底遮住了。
于是从任何一个玻璃页点进这三页，视觉上像切到了另一个 App。

**期望**：底色延续渐变，行是半透明玻璃，分组结构保留。

**修复**（三处同样三行）：
```swift
.listRowBackground(Rectangle().fill(.ultraThinMaterial))
.scrollContentBackground(.hidden)
.background(GlassScreenBackground())
```
- `scrollContentBackground(.hidden)` 去掉 List 的整体底色（不然渐变透不出来）
- `listRowBackground` 必须**同时**改：它控制每一行的底，默认是纯白。
  只做前一步会变成"白行浮在渐变上"，比原来更糟
- 注意 `listRowBackground` 收的是 **View 不是 ShapeStyle**，`.ultraThinMaterial`
  直接传会报 `generic parameter 'V' could not be inferred`，要包成 `Rectangle().fill(...)`

### B. 多包了一层空容器：三个 `card()`

`RootView.card()`（车辆详情/点火验证）、`DiagnosticsView.card()`、
`KeyInspectorView.card()` 都是：

```swift
GlassEffectContainer {       // ← 容器里只有一个元素
    VStack { ... }.glassCard()
}
```

**成因**：`GlassEffectContainer` 的职责是让**多个相邻玻璃融合**
（morphing / 共享形状）。只包一个元素时它不做任何融合，
只多一层离屏渲染 —— 并且容器会把内容合成到自己的 bounds 里，
卡片的 `.shadow` 有被容器边界裁掉的风险。

**修复**：删掉容器外壳，直接返回卡片。融合逻辑真正需要时
（一屏多张相邻玻璃）再用 `GlassSection` 包**整组**。

### C. 浮窗投影只画出两条边

**位置**：`FloatingWindowController` 的宿主视图。

**现象**：日志浮窗的投影只在上沿、左沿可见，右沿和下沿是硬切边。

**成因**：SwiftUI 的 `.shadow` 画在内容边界**之外**，
而宿主 `hosting.view.frame` 原来严格等于 300×260（内容尺寸），
多出来的投影没有地方落，被宿主视图边界裁掉。
上一轮把 `.clipShape` 和 `.shadow` 的顺序调对了，但没解决宿主尺寸问题 ——
**两层裁剪，只修了一层**。

**修复**：
1. 宿主 frame 用 `contentRect.insetBy(dx: -24, dy: -24)`，四周留出投影空间
2. 宿主 `clipsToBounds = false`
3. `FloatingWindow.hitTest` 改为只认 `contentRect`，
   外圈那 24pt 透明区显式放过 —— 否则会变成"浮窗边缘一条点不动"

> 这一条是"修了却没修对"的典型：顺序对了，尺寸没跟上，症状从"全无阴影"
> 变成"两条边有阴影"，更容易被误认为已修好。

---

## 七、令牌落地情况

第四轮审查发现一个**自述与实现不符**的问题：上一轮建立的六个令牌
（`Typo` / `Tone` / `rimStroke` / `GlassSection` / `innerSpacing` / `sectionSpacing`）
**全部零引用** —— 文档写着"唯一来源"，代码里没人用。等于给自己发了张空头支票。

本轮处理：

| 令牌 | 处理 | 现有引用 |
|---|---|---|
| `Typo.cardTitle` | 落地到 4 处卡片标题；改为 `.subheadline`（保留 Dynamic Type） | 4 |
| `Typo.page` | 落地到 3 处页标题 | 2 |
| `Typo.body` | 落地到正文 13pt | 1 |
| `Typo.micro` | 落地到状态胶囊第二/三行（原 9.5pt） | 2 |
| `Typo.caption` | **删除** —— 它就是 `Font.caption`，没有信息量 | — |
| `Tone.*` | 落地到状态条 / 车辆状态 / 通道角标 | 6 |
| `innerSpacing` | 落地到 `VStack(spacing: 10)` | 4 |
| `sectionSpacing` | 落地到卡片间距 | 5 |
| `rimStroke` | **删除** —— 零引用，且系统材质自带高光 | — |
| `GlassSection` | **删除** —— 零引用，"多玻璃融合"的真实场景尚未出现 | — |

## 八、已知残留（诚实记录）

1. **约 34 处 10pt / 12pt 未并入五档**。
   1pt 的改动会改变换行与行高，必须逐屏目视；批量替换会撑破已调好的密集布局。
   新增代码只用五档令牌。

2. **`typecheck` 覆盖不到布局**。0 error 只说明能编译，
   字号/间距的视觉结果必须装机看。

3. **深色模式未经真机确认**。模拟器只有 iOS 26.5 运行时（包是 iOS 27），
   深色参数按渲染原理推算：浅色卡片投影 7%、深色 18%。
   深色我不敢给更高 —— 黑压在近黑背景上不产生分离，只会在四周留一圈更黑的脏边。

## 九、状态

- `typecheck` 0 error 0 warning（64 文件 / 20,725 行）
- `xcodebuild` BUILD SUCCEEDED
- 上一轮（列表页背景、浮窗宿主）**未装机**：设备锁屏
  （`CoreDeviceError 4016`，需要 `powerAssertionTaken`）

## 十、材质分配规则（2026-11-07 定稿）

前九节讲的是"令牌用哪个值"，这一节讲**什么时候用哪种材质**。
起因是这一轮做车控页时，同一屏里出现了玻璃、半透明面、无材质三层，
不写清楚下次加元素一定又会纠结。

### 10.1 一条主规则

> **玻璃 = 可交互的控件；半透明面 = 只读的标签与徽标。**

理由不是审美，是可预期性：一旦"能点的会发光"成立，用户扫一眼就知道哪里能按。
反过来，如果只读的读数带也用玻璃，它看起来就像个按钮。

### 10.2 当前全量清单（车控页）

| 材质 | 用在 | 可点 |
|---|---|---|
| 玻璃 `glassEffect` | 顶栏蓝牙胶囊 / RSSI 胶囊 / 通道胶囊、10 个控车按钮 | 只有通道胶囊和按钮 |
| 半透明面 `contentCard` | 车图 6 个状态浮标、能源读数带、车辆位置卡、车型 chip | 否 |
| 半透明面 `surfaceBadge` | 按钮右上角通道角标 | 否 |

### 10.3 两个例外，都是有意为之

**例外一：顶栏三个胶囊即使不可点也用玻璃。**
它们和可点的通道胶囊在同一条横排上，材质分裂会让整排看起来断掉。
把顶栏视为一个 L2 控件带，材质跟着容器走，不跟着单个元素的交互性走。

**例外二：按钮角标必须用面，不能用玻璃。**
它叠在玻璃按钮之上 —— 玻璃套玻璃会有两层折射，
在 16pt 的小圆上表现为边缘噪点。这不是风格选择，是硬约束。

### 10.4 车图浮标的双态

浮标（已锁 / 天窗关 / 后备箱关 / 引擎熄火 / 四门全关 / 车窗全关）：

- **正常态**：灰字 + 10% 白底（深色）/ 78% 白底（浅色），几乎没有重量
- **异常态**：橙色字 + 橙色 15%~24% 底

目的：正常时整排是安静的灰字，用户扫一眼确认"没有橙色"就够，不必逐字读。
所以**六个浮标全绿是没有意义的** —— 绿色只留给"需要注意的正面状态"。

### 10.5 能源读数带

不可点 → 用面不用玻璃。同时它**不是三格等宽**：
油量 / 续航 15pt semibold（每周看），电瓶 11pt medium（半年看）。
三格等宽会把两个不同频率的信息画成同等重要。

位置在车图下沿、左对齐（与标题、按钮网格同一条竖线），
不居中、不占满宽 —— 它属于"车图这一组"，不是独立的一张卡。

### 10.6 圆角只有四档，且相邻元素必须同档

| 档位 | 值 | 用在 |
|---|---|---|
| `cardRadius` | 20 | 独立卡片 |
| `controlRadius` | 14 | 内嵌块、浮标容器、能源带、位置卡 |
| `pillRadius` | 12 | 胶囊、小标签 |
| `chipRadius` | 6 | 极小角标 |

⚠️ 本轮踩过一次：能源带用 12、紧挨着的车辆位置卡用 14，
单看都没问题，并排就是"没对齐"。**相邻的两块必须同档。**
