# 手表端重构：纯云端方案

> 2026-11-04 · 手表从「独立钥匙」改为「云端遥控器」，账号与手机共用

---

## 1. 为什么推倒重来

旧方案让手表自己当一把钥匙：在表上跑完整 BLE 协议栈（扫描 → `01/02/03/04` 会话 →
`0x0D` 配对 → `0x0C` 预认证保活 → 广播解密），共 959 行。

放弃它不是因为代码写错了，而是三条硬事实：

| 事实 | 后果 |
|---|---|
| watchOS **没有** `bluetooth-central` 后台模式 | 熄屏即挂起，「靠近解锁」在表上不可能成立 |
| 手表要**单独配一次对**（诊断仪开窗口 + 6 位码） | 实际几乎配不成功，用户根本走不完 |
| 协议栈一大半代码只为了证明「钥匙在场」 | 这个语义对一块表没有价值 —— 抬腕是要「锁一下车」，不是「无感进入」 |

云端方案下，手表的职责收缩成一件事：**抬手看状态，抬腕按一下**。
「人不在车边也能用」本来就是云端的长处。

---

## 2. 涉及的模块与文件

### 2.1 手表 target（重写）

| 文件 | 作用 | 变化 |
|---|---|---|
| `Sources/Watch/WatchCloudController.swift` | 云端控制器：拉状态、发命令、接同步 | **新增**（替代 959 行的 BLE 控制器） |
| `Sources/Watch/WatchRootView.swift` | 主界面 | **重写** |
| `Sources/Watch/GKUIBleKeyWatchApp.swift` | 入口 | 改为注入 `WatchCloudController` |
| ~~`WatchVehicleController.swift`~~ | 旧 BLE 控制器 | **删除** |
| ~~`WatchPairingView.swift`~~ | 旧配对界面 | **删除** |

### 2.2 新增：跨端同步层

| 文件 | 归属 | 作用 |
|---|---|---|
| `Sources/Sync/SyncPayload.swift` | 手机 + 手表 | 两个 `Codable` 载荷（账号 / 车况）+ 约定的 key |
| `Sources/Sync/PhoneWatchSync.swift` | 仅手机 | `WCSession` 代理，推送账号与快照 |

### 2.3 手机端改动（小）

| 位置 | 改动 |
|---|---|
| `AppModel.init` | 启动 `PhoneWatchSync` |
| `AppModel+Cloud.refreshCloudStatus` | 每次云端刷新成功后推快照 |
| `AppModel+Cloud.configureCloud(KeepingPassword)` | 登录成功后推账号 |
| `AppModel+Cloud.clearCloudConfig` | 清除时推空载荷（手表跟着退出） |

### 2.4 Net 层解耦（为让手表能编译）

原来 `ControlChannel.swift` 里带了一段 `extension IBCommandType`，而 `IBCommandType`
是 BLE 协议层的类型。手表一旦引用这个文件，就不得不把整个协议栈编进去。

| 处理 | 说明 |
|---|---|
| 拆出 `Sources/Net/ControlChannel+IBCommand.swift` | 协议层映射，**仅 iOS** |
| `ControlChannel.swift` 保留通道无关类型 | `VehicleCommand` / `VehicleSnapshot` / `StatusSource` / `StatusFreshness` |
| `StatusTimeFormat` 下沉到共享层 | 原来调 `AppModel.hhmm`，手表没有 `AppModel` |

### 2.5 工程配置（`project.yml`）

```yaml
GKUIBleKeyWatch:
  sources:
    - Sources/Watch
    - Sources/Net            # 排除 AppModel+Cloud / ControlChannel+IBCommand / StatusFieldCatalog
    - Sources/Sync           # 排除 PhoneWatchSync（手机专用）
    - Sources/Support/FileLogger.swift
```

**移除**：`Sources/Protocol`、`Sources/BLE`、`Sources/Crypto`、`Sources/Keychain`、
`Sources/Support/BackgroundMonitor.swift`。
**Info.plist** 同步删掉 `NSBluetoothAlwaysUsageDescription`（不再申请用不到的权限）。

---

## 3. 云端接口调用方式

手表与手机走**同一套**代码（`GKCloudClient`，actor），只是入口不同。

### 3.1 认证

| 步骤 | 接口 |
|---|---|
| 登录 | `POST https://user-api.xchanger.cn/auth/account/session/secure`（username + 密码 MD5） |
| 续期 | `GET /auth/account/session/refresh?refreshToken=…` |
| 签名 | `x-signature = Base64(HMAC-SHA1(appSecret, 9 段拼接))`，`GKCloudSignature` |

手表通常**不自己登录**：手机把 access/refresh token 一起同步过来，
`GKCloudClient.importToken(_:)` 直接装上。token 过期后手表先用 refreshToken 续，
续不上再用同步来的 MD5 重登 —— 用户无感。

### 3.2 查车况

```
GET https://device-api.xchanger.cn/remote-control/vehicle/status/{VIN}
    ?latest=Local&target=all&userId={userId}
Authorization: {accessToken}
```

返回的 `vehicleStatus` 摊平成 `[StatusField]`，再映射为 `VehicleSnapshot`。
空调状态单独取 `additionalVehicleStatus.climateStatus.preClimateActive`
（`GKCloudClient.airConditionerOn()`）。

### 3.3 控车

```
PUT https://device-api.xchanger.cn/remote-control/vehicle/telematics/{VIN}
{
  "latest": false, "userId": "...", "command": "start|stop",
  "serviceParameters": [...], "serviceId": "RDL|RDU|RWS|RHL|RES|RCE",
  "operationScheduling": {...}, "timestamp": "...", "pin": null, "creator": "tc"
}
```

手表可用的动作与 serviceId：

| 动作 | serviceId | 说明 |
|---|---|---|
| 闭锁 / 解锁 | `RDL` / `RDU` | 带 `time.start` + `time.window=2` |
| 关窗 / 开窗 / 微开 | `RWS` | `rws=all` / `all` / `ventilate` |
| 寻车 | `RHL` | `rhl=horn-light-flash` |
| 空调 开 / 关 | `RCE` | `rce={温度}`，开与关都带 |
| 启动 / 熄火 | `RES` | `time.window` 启动=2、熄火=0；**熄火不带 operationScheduling** |

> 后备箱云端不支持（`isSupportedOnNetwork == false`），手表界面上没有这个按钮。

---

## 4. 账号体系

```
iPhone 是账号的唯一来源
        │
        │  WCSession.transferUserInfo  （必达，手表 App 没跑也补投）
        ▼
   手表 Keychain（GKCloudKeychain）
```

- **手表没有登录界面**。40mm 屏幕上输手机号 + 密码 + 17 位 VIN 不现实，
  而且两处都能改账号必然出现「手机改了、手表还是旧账号」的分裂。
- **同步内容**：手机号、VIN、userId、clientId、密码 MD5、access/refresh token、过期时间。
- **存储**：手表自己的 Keychain（`kSecAttrAccessibleAfterFirstUnlock`），与手机的
  Keychain 相互独立 —— 两端各自持有同一份凭据。
- **退出**：手机点「清除云端配置」→ `pushAccount(nil)` → 手表 `clearAllCredentials()`，
  界面回到「还没有账号」。避免「手机已退出、手表还能开锁」。

### 已知取舍

密码 MD5 会存到第二台设备上。它已是服务端要求的摘要（不是明文），
但仍属可离线撞库的材料。用 `transferUserInfo` 而非 iCloud Keychain，
是为了让「同步」这件事可解释、可控、可撤销。

---

## 5. 数据同步逻辑

| 内容 | 通道 | 时机 | 语义 |
|---|---|---|---|
| 账号 + token | `transferUserInfo` | 登录 / 清除 / App 启动 | 必达、排队 |
| 账号 + 车况 | `applicationContext` | 同上 + 每次刷新 | 覆盖式，只留最新一份 |
| 车况 | 手表自己 `GET status` | 打开 App / 点刷新 / 命令后 3 秒 | 以手表请求为准 |

**为什么两条都要**：

- 只靠推送 → 手机锁屏一整天，推来的快照早就过期，抬腕看到的是昨天的车况
- 只靠自己拉 → 每次抬腕都要等一次网络往返（1–3 秒），表上体验很差

所以：推送负责「一抬腕就有内容」，自己拉负责「内容是当下的」。
冲突时按 `updatedAt` 取新（`applySnapshot` 里比较）。

---

## 6. 验证过什么 / 待验证什么

### 已通过（本次）

- 三个 target 编译：主 App、Widget、Watch（`BUILD SUCCEEDED`）
- 手机端主页、状态页、设置页未回归（本次未改 UI，仅接线）
- 手表 target **不再包含任何** `CoreBluetooth` 引用（源文件层面已移除）

### 需要真机验证的关键场景

| # | 场景 | 期望 |
|---|---|---|
| 1 | 手机上首次登录云端 | 手表 1–3 秒内变成「已锁 / 已登录 138****8000」 |
| 2 | 手机在后台 / 锁屏，手表打开 App | 能拿到车况（自己拉的），不依赖手机是否在前台 |
| 3 | 手表点「解锁」 | 车解锁；手表 3 秒后状态刷新为「未锁」；手机端状态页同步变化 |
| 4 | 手表点「开空调」（默认温度跟随手机） | 空调启动；手表显示「空调 22°」 |
| 5 | 手表点「启动引擎」 | 先弹确认；确认后车启动；按钮变成「熄火」 |
| 6 | 手机上点「清除云端配置」 | 手表回到「还没有账号」，按钮全部不可用 |
| 7 | 手表断网（飞行模式）+ 打开 App | 显示上次快照 + 「网络错误」提示，不崩不白屏 |
| 8 | 手机换了账号后重新登录 | 手表跟着换成新账号（`transferUserInfo` 覆盖） |
| 9 | 手表单独重启（手机不在附近） | 从自己的 Keychain 恢复账号，仍可下发命令 |
| 10 | token 过期（隔天首次使用） | 手表自动用 refreshToken 续期，用户无感 |

### 已知限制

| 限制 | 说明 |
|---|---|
| 手表必须曾经与手机配对过 | `WCSession` 的前提；换表后需重新同步 |
| 后台不能自动刷新 | watchOS 没有后台网络权限，抬腕才拉；显示的是「多久前同步」 |
| 空调温度不可在表上调 | 跟随手机设置（避免两处各设一个） |
| 后备箱不可用 | 云端接口未抓到该命令 |

---

## 7. 部署方式

手表 App 通过**手机**安装（不是 `devicectl` 直连）：

1. 安装主 App 到 iPhone（本次已完成）
2. iPhone 上打开「Watch」App → 找到本 App → 安装
3. 首次打开手表 App，等待 1–3 秒自动同步账号

远端调试：`Xcode → Window → Devices → 选择手表 → Open Console`，
日志里筛 `[手表]` 可看到账号同步与命令下发记录。
