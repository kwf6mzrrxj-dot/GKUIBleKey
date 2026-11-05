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

### 层次与投影（四层）

| 层 | 内容 | 投影 |
|---|---|---|
| L0 | 渐变底 + 两盏氛围光 | 无 |
| L1 | 卡片 | `.card`：浅 7% / 深 18% |
| L2 | 卡内嵌块（斑马纹、状态条、刻度带） | 无，靠底色 |
| L3 | 浮层（日志浮窗、操作横幅） | `.floating`：浅 18% / 深 45% |

**深色下几乎不用投影**：黑压在近黑背景上不产生分离，只会在卡片四周留一圈更黑的边。
深色的层次由材质建立（玻璃比底亮一档 + 边缘高光）。

---

## 三、组件规则

### 按钮（三种，不再有第四种）

| 场景 | 写法 |
|---|---|
| 主操作（解锁 / 闭锁） | 自绘 `glassEffect(.regular.tint(x).interactive(), in: RoundedRectangle(20))` + 同 shape 的 `strokeBorder` 高亮 |
| 次要操作（网格内 8 个） | `.buttonStyle(.glass)`，label = 图标 18 + `caption` 标题 + 可选 9pt 第三行 |
| 破坏性 / 确认 | `.buttonStyle(.glassProminent)` |

- **能点的按钮不画成不能点**：不按连接状态调 `.opacity`，状态由顶部胶囊表达。
- 误触代价高的（后备箱 / 开窗 / 微开 / 寻车）走 `HoldToConfirmButton` 长按 0.6 秒。
- **形状差异表达层级**：主操作圆角矩形（20，有分量），次要操作胶囊（轻）。这是唯一允许的形状不统一，不要"统一"掉。

### 卡片

一律 `.glassCard()`。**列表里成批出现的传 `elevated: false`** ——
十几张卡各自投影会在间隙叠成灰带，反而更脏，且每张都要离屏合成。

### 玻璃与背景

- 玻璃要有东西可透。纯 `systemBackground` 做底会让材质退化成灰板。
- 背景只有 `GlassScreenBackground` 一处定义：纵向渐变 + 右上主色雾光 + 左下冷雾。
  **两盏灯是必需的**：只有一盏时卡片从左上到右下透出的底色一样，玻璃没有"厚度"。

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
