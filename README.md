# 蓝牙钥匙 (GKUIBleKey)

用 iPhone 直接和车辆 PEPS 模块通信，完成数字钥匙的配对、鉴权与控车 —— **纯软件方案，不需要额外硬件**。

> 这是一个个人项目的技术记录：我自己那台车的官方 App 只能用它自己，我想在不依赖它的情况下把车钥匙留在自己手里，于是把协议摸清楚、重写了一遍。

---

## 功能

| 类别 | 内容 |
|---|---|
| **控车** | 解锁 / 闭锁 / 后备箱 / 升降窗 / 微开 / 寻车 / 空调 / 启动·熄火 |
| **点火** | 提前发一次 `0x0C` 预授权，解决「上车按了没反应、试几次才打着」 |
| **靠近解锁** | 双天线 RSSI 判定，进入车边 2 秒自动解锁、走远自动闭锁（双阈值 + 迟滞带） |
| **防误触** | 后备箱 / 开窗 / 微开 / 寻车需长按 0.6 秒，可在设置关闭 |
| **无感进入** | 靠近车辆拉门把手解锁（车端 PEPS 负责，App 只负责使能） |
| **点火位置验证** | 双天线 RSSI 标定 90 次采样，判断手机是否在车内 |
| **状态显示** | 车辆锁止 / 车门 / 后备箱 / 电源状态（广播解密，无需连接） |
| **车辆位置** | 云端车况带的 GPS 坐标，WGS-84 → GCJ-02 后画在地图上，标出「X 分钟前」与可信度 |
| **主动提醒** | 蓝牙断开（= 人离开车）时若未锁或门窗未关，发本地通知，每天上限 3 条 |
| **操作历史** | 本地保留最近 100 条动作，按天分组，可复制导出 |
| **系统集成** | Siri / 快捷指令 / 控制中心 / 操作按钮 / **桌面小组件**（App Intents，后台执行不打开 App） |
| **实时活动** | 锁屏 / 灵动岛 / CarPlay 显示锁态与门·窗·后箱·引擎，兼作后台 BLE 权限凭据 |
| **诊断** | 实时日志浮窗、帧日志、密钥检查器、链路诊断、错误码表 |

## 技术要点

### 协议栈

```
InBlue（应用层）          ValeoCoreCommunication（BLE 传输层）
├─ 0x0D / 0x0E 配对      ├─ 广播解析（Gen02 / Gen03）
├─ 0x01→02→03→04 鉴权    ├─ 服务 F000FF10
├─ 0x05 状态推送         ├─ 特征 FF11（写）/ FF12（读+订阅）
└─ 0x0F 已配对设备列表    └─ 分包：MTU−4，首包 4 字节头
```

### 鉴权链路

```
App                                   车端
 │  0x01  sd|ed|RndTRx|RND1|rights  →   │   33B，AES-128-CBC(CkTRxSP)
 │  ←  0x02  challenge（16B）           │
 │      enc1 = AES-CBC(reverse(RND1) 扩展, Dk1)
 │  0x03  AES-CBC(challenge[0:9]|NOT|cmd, enc1)  →  │   18B
 │  ←  0x04  结果（00 = 成功）           │
 │  ←  0x05  状态包                      │
```

关键点：`0x03` 的载荷用**上一轮的 `enc1` 当密钥**做二次加密，并自带一段可本地校验的
冗余（`computed == expected`），所以自校验能当场判断算法是否对齐 —— 这一条在调试时非常有用。

### 连接行为

- 车端**每条命令执行完就主动断开**，所以 App 稳态是「扫描中」而不是「保持连接」
- 写入类型为 Write Command（`withoutResponse`）
- `CBCentralManager` 带 `RestoreIdentifier` + `willRestoreState`，系统终止进程后能靠 BLE 事件恢复现场
- `UIBackgroundModes: bluetooth-central` + `location`

### 后台能力（实测口径）

| 能力 | 后台可用 |
|---|---|
| Siri / 快捷指令 / 控制中心控车 | ✅ `supportedModes = .background` |
| 无感进入 | ✅ 车端 PEPS 功能 |
| 预认证保活 | ⚠️ 依赖进程存活，挂起后会停 |
| 点火位置标定 | ❌ 需前台 |

`BackgroundMonitor` 会记录 30 秒心跳、前后台切换、预认证定时器的「计划 vs 实际」偏差，
用来量化到底有没有被系统挂起。

## 构建

```bash
# 依赖：Xcode 27 / iOS 27 SDK / xcodegen
brew install xcodegen

git clone https://github.com/kwf6mzrrxj-dot/GKUIBleKey.git
cd GKUIBleKey

# 1. 配置密钥（可选，不配也能跑，走正常配对流程）
cp Resources/builtin-keys.example.txt Resources/builtin-keys.txt
#    填入自己车辆的 8 个字段

# 2. 生成工程并构建
xcodegen generate
xcodebuild -project GKUIBleKey.xcodeproj -scheme GKUIBleKey \
           -destination 'generic/platform=iOS' build
```

> 命令行构建必须带 `-plugin-path`（Xcode 27 的 SwiftUI 宏需要），
> 已写在 `project.yml` 的 `OTHER_SWIFT_FLAGS` 里。

## 目录结构

```
Sources/
├─ App/           AppModel（单例，App Intents 共用）、入口、阈值与标定扩展
├─ BLE/           BLECentral（扫描/连接/订阅/分包）、GATT、广播匹配
├─ Protocol/      InBlue 帧编解码、鉴权、配对、状态解析、被动进入、靠近解锁判定
├─ Net/           云端通道（GKUI 账号、签名、命令下发）
├─ Keychain/      密钥存储、内置凭据加载
├─ Intents/       App Intents（Siri / 快捷指令 / 操作按钮）
├─ Support/       日志、日志流、后台保活、车辆资料、通知、操作历史
├─ Sync/          手机 ⇄ 手表同步
├─ Widget/        桌面小组件、锁屏实时活动、控制中心控件
└─ UI/            SwiftUI 界面 + DesignSystem（视觉规范的唯一来源）

Docs/             协议规范、审计记录、变更日志、UI 规范
tools/            同步脚本、类型检查
```

## 视觉规范

界面样式**只有一个来源**：`Sources/UI/DesignSystem.swift` 的 `Glass` 命名空间。

- 圆角四档（20 / 14 / 12 / 6）、间距五档（20 / 16 / 14 / 10 / 96）、字号五档（22 / 15 / 13 / 11 / 9）
- 材质统一 `glassEffect`，投影两级（`.card` / `.floating`）
- 语义色只用于图标、描边、底色 —— **正文一律 primary**（系统绿/橙对浅底只有 2:1，不能承载文字）

完整规则见 `Docs/UI_STYLE_GUIDE.md`。

## 技术文档

- `Docs/INBLUE_PROTOCOL_SPEC.md` —— 协议规范（帧格式、命令码、状态位定义）
- `Docs/LIVE_ACTIVITY.md` —— 实时活动：三套画布、四格取值、颜色语气规则
- `Docs/UI_STYLE_GUIDE.md` —— **改界面前必看**：令牌表、组件规则、有意保留的差异
- `Docs/CHANGELOG.md` —— 逐版本变更（含踩过的坑）
- `Docs/BIZ_AUDIT_v2.md` —— 与官方 App 的业务实现对照
- `Docs/REVIEW_CHECKLIST.md` —— **改代码前必看**：从 30 个真实 bug 反推的审查清单
- `Docs/CODE_REVIEW_2026-11-05_ROUND4.md` —— 最近一轮全项目审查

## 关于密钥

**仓库里没有任何可用的车辆凭据。**

- 真实密钥存在 `Resources/builtin-keys.txt`，被 `.gitignore` 排除，只在本机
- 仓库里只有 `builtin-keys.example.txt` 模板
- `tools/sync.sh` 在提交前会检查暂存区，一旦出现密钥文件直接中止

想要给自己的车做一个，得先拿到自己车辆的密钥 —— 只能通过**为你的车配对一把新钥匙**获得
（需要诊断仪开配对窗口）。备份提取相关的工具不随仓库提供。

## 免责声明

- 本项目是**个人学习与自用**的产物，仅供技术研究与交流
- 逆向分析的对象是**我自己车辆配套的官方 App**，目的是让自己能在自己的车上使用自己配的钥匙
- 不提供任何车辆凭据、不提供配对协助、不提供绕过厂商授权的服务
- 请勿用于他人车辆。未经授权控制他人车辆在几乎所有司法辖区都是违法行为
- 因使用本项目造成的一切后果（车辆故障、保修失效、法律纠纷）由使用者自行承担

## License

MIT
