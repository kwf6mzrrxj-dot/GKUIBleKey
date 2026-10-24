# 部署到 iPhone —— 操作说明

App 已构建、签名并安装到你的 iPhone 17 Pro。**最后两步必须你在手机上手动完成**
（这是 iOS 的安全设计，命令行无法绕过）。

---

## 已完成

| 步骤 | 状态 |
|---|---|
| 编译（Xcode 27 / iOS 27 SDK / Liquid Glass） | ✅ BUILD SUCCEEDED |
| 代码签名 | ✅ `Apple Development: mmxisme@icloud.com (6M4TW7STL3)` |
| Provisioning Profile | ✅ `iOS Team Provisioning Profile: com.mmxisme.gkuiblekey` |
| 安装到设备 | ✅ 已安装（bundle id `com.mmxisme.gkuiblekey`） |

## 你需要做的两步

### 第一步：信任开发者证书

> 不做这步会报：*"its profile has not been explicitly trusted by the user"*

1. iPhone 打开「**设置**」
2. 进入「**通用**」→「**VPN 与设备管理**」
3. 在「**开发者 App**」一栏下，点 **MINGXING MU**（或显示为 `mmxisme@icloud.com`）
4. 点「**信任 "MINGXING MU"**」→ 弹窗再点一次「**信任**」

### 第二步：开启开发者模式

> 不做这步 App 图标会点不开（iOS 16+ 的要求）

1. 「**设置**」→「**隐私与安全性**」
2. 滑到最底部，点「**开发者模式**」
3. 打开开关 → 系统提示需要重启 → **重启 iPhone**
4. 重启后会再弹一次确认，点「**打开**」并输入锁屏密码

### 第三步：启动

回到桌面点「**蓝牙钥匙**」图标即可。

**如果仍打不开**：把 iPhone 用数据线连到 Mac，在 Xcode 里
`Window → Devices and Simulators` 选中你的 iPhone，等它显示 "Ready" 后再试。

---

## ⚠️ 重要：IDFV 与重新配对

`mobileId`（车端用来校验"钥匙属于本机"的字段）= **IDFV**，而 IDFV 取决于
**bundle id + 签名 Team**。

- 原 GKUI 的 bundle id 是 `com.ecarx.xiaoka.voice_assistant`；
- 本 App 用的是 `com.mmxisme.gkuiblekey`（个人账号签名必须用自己唯一的 id）；
- **因此 IDFV 会不同** → 车端会回 `error_sdk_50003 数字钥匙校验mobileId错误`。

**解决办法**（就是之前确认过的那条路）：

> **用诊断仪重新匹配一次**，把本 App 作为一台新手机登记进蓝牙钥匙模块
> （一车可挂 5 台，不用解绑原有的）。

匹配完成后，本 App 就能正常走 DK 五步握手 → 控车 / 点火授权。

---

## 首次使用建议的操作顺序

1. **先跑自检**：首页底部「诊断」→「运行自检」，应显示 **8/8 通过**。
   这能确认密码学与帧编解码实现无误。
2. **看密钥状态**：底部「密钥」→ 查看 `communicationKey` 等是否已存在。
   全新安装时应该都是空的 —— 这是正常的，需要先配对。
3. **扫描连接**：首页「扫描」→ 应能发现广播名为 `GKUI` / `GKUINEW` 的设备。
   - 首次连接时 **iOS 会弹出系统配对框要求输入 6 位配对码**，这是正常的 BLE 绑定流程。
4. **观察握手**：连上后点「握手」，首页会实时显示：
   - **链路就绪**耗时（红线 2000ms）
   - **自适应超时**（随实测 RTT 变化）
   - 每条指令的确认情况
5. **抓包**：诊断页有完整 hex 收发流，可对照分析文档里的帧格式。

---

## 排查"多次才能打着火"

启动后如果仍然需要多次尝试，首页的三个数字能直接定位原因：

| 现象 | 含义 | 对策 |
|---|---|---|
| **每次连接都弹配对框** | bonding 没保住 | iOS 侧 BLE 问题；尝试在系统蓝牙里删除重复条目 |
| **链路就绪 > 1500ms** | 2 秒窗口被挤压 | 本 App 已只发现目标 Service；若仍慢属系统层 |
| **握手某步反复超时** | 协议参数与车端不符 | 到诊断页切换 ID 2/3/4/5 与 CRC 变体，找到能通过组合 |
| **自适应超时一直 800ms（样本 0）** | 从未收到过应答 | 说明车端根本没回帧 → 帧格式或配对状态有问题 |

**最快定参办法**：用诊断仪重新匹配时抓一次 HCI 日志
（Android 开发者选项 → 启用蓝牙 HCI 信息收集日志），
拿到 `btsnoop_hci.log` 后即可把 `DKTuning` 里的待定值全部定死。
