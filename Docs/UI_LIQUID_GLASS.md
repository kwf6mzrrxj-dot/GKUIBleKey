# 液态玻璃视觉规范（Liquid Glass）

2026-11-05 · 适用：GKUIBleKey 全部界面

---

## 一、统一前的不一致清单

| 位置 | 改前 | 问题 |
|---|---|---|
| 主界面卡片（6 处） | `.background(.ultraThinMaterial, in: RoundedRectangle(20/16))` | 只有模糊，没有折射、没有边缘高光；深色模式下几乎退化成灰块 |
| 密钥页卡片 | `glassEffect(.regular, in: .rect(20))` | 系统 Liquid Glass，与主界面**不是同一种材质** |
| 日志 / 诊断 / 密钥页背景 | `Color(uiColor: .systemBackground)` | 纯色底让玻璃无内容可透，看起来廉价 |
| 操作历史 | `List(.insetGrouped)` | 自带不透明分组底，像在玻璃上贴白纸 |
| 车图胶囊（3 处） | `.ultraThinMaterial` | 同上，无描边无高光 |
| 主按钮 | `glassEffect(.regular.tint().interactive())` | 材质正确，但圆角硬编码 20 |
| 圆角 | 20 / 16 / 14 / 12 / 10 / 6 / 4 / 22 混用 | 同一页里三种圆角并存 |
| 长按按钮 | `.buttonStyle(.glass)` + 绿色进度条 | 绿色是"成功"语义，未执行就上绿色会误导 |

**根因**：两套玻璃实现并存 —— 系统 `glassEffect`（少数页面）和自绘 `.ultraThinMaterial`（多数页面）。
自绘要"像玻璃"就得自己补描边、内高光、投影，每处补的参数都不同，于是越补越散。

---

## 二、规范（`Sources/UI/DesignSystem.swift`）

### 材质

**所有面板一律用系统 `glassEffect(.regular, …)`** —— 它和 `.buttonStyle(.glass)`、
控制中心、Dock 是同一套渲染，高光方向与折射强度由系统保证一致。

| 入口 | 形状 | 用途 |
|---|---|---|
| `.glassCard()` | 圆角 20 | 大卡片：车辆状态、设置分组、日志卡、密钥卡 |
| `.glassCard(radius: Glass.controlRadius)` | 圆角 14 | 内嵌小卡、刻度带容器 |
| `.glassPill()` | 胶囊 | 顶栏状态、通道徽标、来源标签 |
| `.glassChip()` | 圆角 6 | 极小角标（"需网络"、车型） |
| `.buttonStyle(.glass)` | 系统 | 所有按钮 |

### 圆角（只有四档）

```
Glass.cardRadius    = 20   大卡片
Glass.controlRadius = 14   控件容器
Glass.pillRadius    = 12   胶囊 / 小瓦片
Glass.chipRadius    = 6    角标
```

### 间距（4 的倍数）

```
Glass.cardPadding    = 16   卡片内边距
Glass.sectionSpacing = 14   卡片之间
Glass.innerSpacing   = 10   卡片内元素
Glass.pageMargin     = 20   页面边距
```

### 背景

`GlassScreenBackground`：纵向渐变 + 右上角氛围光。
**所有页面共用**，二级页不再用 `systemBackground` —— 玻璃要有东西可透。

---

## 三、本次改动

| 文件 | 改动 |
|---|---|
| `DesignSystem.swift`（新增） | 材质入口、圆角/间距常量、`GlassScreenBackground`、`GlassSection` |
| `RootView.swift` | 6 处卡片 → `glassCard`；背景 → `GlassScreenBackground`；顶栏 2 处胶囊 + 光源标签 → `glassPill`；主按钮圆角 → `Glass.cardRadius` |
| `KeyInspectorView.swift` | `card()` 内部改用 `glassCard()`；背景换渐变 |
| `LogView.swift` / `DiagnosticsView.swift` | 背景换渐变 |
| `ActionHistoryView.swift` | `List(.insetGrouped)` → ScrollView + 每天一张玻璃卡 |
| `CarModelView.swift` | 3 处 `ultraThinMaterial` 胶囊 → `glassPill` |
| `VehicleTopView.swift` | 瓦片圆角 4/10 → `Glass.chipRadius` / `Glass.pillRadius` |
| `LiveLogFloatingView.swift` | 浮窗圆角 → `Glass.pillRadius`（仍是深色半透明，与内容区刻意区分） |
| `HoldToConfirmButton.swift` | 进度条绿 → accent（绿色是"成功"语义，未执行不该用）；按下加 3% 亮度，贴近系统按压反馈 |

---

## 四、有意保留的例外

| 位置 | 为什么不用玻璃 |
|---|---|
| 实时日志浮窗 | 它是调试工具，必须与 App 内容**明显区分**，用深色半透明是有意的 |
| 车图上的状态瓦片 | 叠在车图上看，用透明+描边更清楚；已统一圆角 |
| `GlassSection` | 目前没有页面用到（各页卡片间距足够），保留给将来需要玻璃融合的场景 |

---

## 五、待确认

- 真机截图验证未完成：截图时手机锁屏，`devicectl` 只能截到锁屏。
  解锁后应逐页看一遍：主控 / 状态 / 我的 / 密钥 / 诊断 / 日志 / 操作历史。
- 主控页顶栏胶囊、车辆标题、以及「我的」页的账号卡与设置卡，
  在修复一次误删时按原逻辑**重建**过（原实现被脚本误删）。
  功能与文案按记忆还原，若与原设计有出入请指出。
