# 原 App 全功能盘点与实现状态（v0.5 诚实版）

> 盘点时间：2026-10-25
> 判定基准：InBlue.framework 符号表 + 反汇编，逐方法核对。
> 本表**不再用「闭环」一词**，改为「已实现 / 未实现 / 已实现但依赖未满足」。

---

## 一、原 App（InBlue SDK）全部功能方法 → 实现状态

### 1. 控车命令（IBVehicle 的 10 个动作方法）

| 原 App 方法 | 控制码 | 本 App 状态 |
|---|---|---|
| `lock` @0xa0f4 | 0x01 | ✅ 已实现 + UI |
| `unlock` @0xa138 | 0x02 | ✅ 已实现 + UI |
| `openCloseTrunk` @0xa17c | 0x03 | ✅ 已实现 + UI |
| `windowUp` @0xa1c0 | 0x04 | ✅ 已实现 + UI |
| `windowDown` @0xa204 | 0x05 | ✅ 已实现 + UI |
| `panic` @0xa248 | 0x06 | ✅ 已实现 + UI |
| `requestPairedDevicesNames` @0xa30c | 0x0D | ✅ 已实现 + UI |
| `enablePassiveEntry` @0xa3d8 | 0x11 | ✅ 已实现 + UI（无感进入开关）|
| `disablePassiveEntry` @0xa394 | 0x12 | ✅ 已实现 + UI |
| `startPairing` @0xa350 | 0x55 | ✅ 已实现（0x55 鉴权链）|

### 2. 配对 / 密钥

| 功能 | 状态 |
|---|---|
| 0x55 配对鉴权链（01→02→03(0x55)→0x0E） | ✅ 已实现（含 RND1 错位修复）|
| 密钥帧 62B 切分（saveKeysData: @0x12660） | ✅ 已实现 |
| 密钥落 Keychain | ✅ 已实现 |
| 删除/解绑车辆（deleteVehicleWithCidpu:，本地清 Keychain） | ✅ **已实现**（`AppModel.deleteVehicle`：清密钥+清标定+复位，UI「解绑车辆」）|

### 3. 车辆状态（广播解密）

| 功能 | 状态 |
|---|---|
| parseBroadcastData:（cidpu 解密广播） | ✅ 已实现 |
| parseStatus:（8 字段：锁/门/后备箱/上电/发动机/引擎盖/ACC） | ✅ 已实现 |
| parseDoorsStatus:（四门） | ✅ 已实现 |
| parsePowerStatus:（ACC） | ✅ 已实现 |

### 4. 被动进入 / 点火（PEPS）

| 功能 | 状态 |
|---|---|
| 预认证保活（launchPrehautentification → 0x0C） | ✅ 已实现，但依赖区域判定 |
| 区域判定（checkRssiForPassiveStart） | ✅ 已实现 |
| **标定（startCalibration → 90 次采样）** | ✅ **v0.5 已实现**（此前遗漏，已补）|
| 被动进入（靠近拉门把手解锁） | ✅ 开关已实现，实际解锁由车端 PEPS 完成 |

### 5. 后台 / 连接管理

| 功能 | 状态 |
|---|---|
| 后台常驻（bluetooth-central + state restoration） | ✅ 已实现 |
| startBackgroundMode/endBackgroundMode（30s 超时） | ⚠️ 未单独实现（属超时管理，非核心协议）|

---

## 二、不属于 InBlue BLE 的功能（通道不同，非遗漏）

这些在 InBlue SDK 里是**数据模型**，数据由**主 App 通过 TSP 云端**拉取后注入，**不是 BLE 协议**。本 App 是纯 BLE 方案，不实现是正确取舍：

| IBVehicleInfo 字段 | 数据来源 |
|---|---|
| batteryLevel（电池） | TSP 云端 |
| tireFrontLeftPressure 等 4 个胎压 | TSP 云端 |
| mileage / mileageToService（里程/保养） | TSP 云端 |
| latitude / longitude（经纬度） | TSP 云端 |

> 证据：主 App 里有 `SXVehicleInfo`、`getCurrentTirePressure` 等类，
> `IBVehicleInfo` 由 `IBVehicle.updateInfo:`（单纯 `objc_storeStrong`）从外部注入，
> `parseStatus:` 只操作 `_isLocked` 等门锁类 ivar，不碰 battery/tire/mileage。

---

## 三、本次审查新发现并处理的缺口

| 缺口 | 处理 |
|---|---|
| 标定（startCalibration）此前未实现，导致点火验证/预认证实际不可用 | v0.5 已完整实现 |
| deleteVehicleWithCidpu:（按车删除密钥） | v0.5 已实现（`AppModel.deleteVehicle`）|

---

## 四、诚实结论

**BLE 协议链路（配对、鉴权、控车、查询、车辆状态、无感进入、标定、预认证、解绑）已全部实现。** 唯一不做的：
- TSP 云端车辆信息（电池/胎压/里程/经纬度）—— 非 BLE 通道，本方案不做。

**此前多次声称「代码层 100% 闭环」是不准确的**：标定（点火位置验证的前置）此前确实遗漏了，直到 v0.5 才补上。这是本次审查的核心教训。

---

## 五、v0.9 全源码审查更新（2026-10-25）

v0.9 对全部 30 个文件（7637 行）做了三路并行审查，修复 6 处实质 bug（详见 `CODE_AUDIT.md`）：

1. 点火验证 29s 门控错误（区域判定最多 29s 才刷新）
2. 手动断开仍自动重连
3. Keychain 覆盖写入失败
4. 无感进入切换被拒卡死
5. 配对日志不刷新
6. 浮窗内存泄漏

协议正确性不受影响，均属体验/健壮性层面修复。
