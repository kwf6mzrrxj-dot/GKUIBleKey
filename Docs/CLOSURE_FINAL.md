# 按原 App 闭环的最终核对

> 核对时间：2026-10-25 11:30（v0.9）；**2026-10-30 复核（v7.4）修正了配对口径与手表端**
> 判定基准：原 App（GKUI/小卡）iOS 版反汇编为唯一权威，抓包仅作参考

---

## 一、核心链路闭环核对

### 1. 配对 ✅ 闭环（`0x0D` 登记帧）

> ⚠️ **2026-10-30 更正**：本节原来写的是「配对走 0x55 鉴权链」，那是
> 2026-10-25 之前的错误实现。反汇编 `generateFirstMessage:` @0xff98 里
> `cmp #0x55 → generatePairingMessage` 说明：配对发的是 **`0x0D` 登记帧**，
> 不走 `01→02→03` 挑战-响应。真实链路见下。

```
startFullPairing → stopScan/cancel/prepareForPairingScan → startScan
  → didDiscover 兜底自动连接 → connect → didConnect(发现服务→订阅)
  → linkState ready → beginMeasuredAuthPairing
  → buildPairingMessage（0D + sidpu 16B + 设备名 20B = 37B）
  → 车端回 0x0E(62B 密钥) → saveKeyData → loadCalibration
```

- 配对走 **`0x0D` 登记帧**（`+[IBMessageFactory pairingMessage]` @`0x13afc`），
  **没有挑战-响应**，手机上不需要算任何东西
- `sidpu` 是**固定 16 字节常量** `628f07…2f92`（`getSidpu` @`0x11a28`），
  与手机身份无关；只有设备名来自 `UIDevice.name`（截断/补零到 20B）
- `0x0E` 密钥帧：`saveKeysData:` @0x12660，62B 切 7 字段 ✅
- 配对后重读标定（cidpu 配对后才确定）✅
- **配对前提在车外**：诊断仪先登记槽位 + 6 位码 bonding（见 `INBLUE_PROTOCOL_SPEC` 5.10）

### 2. 鉴权 + 控车 ✅ 闭环

```
perform(action) → beginMeasuredAuth → buildAuth1（01，AES(明文,CkTRxSP)）
  → 车端回 02 → handle 自动 buildAuth3（03，末字节=控制码）
  → 车端回 04 → checkResultMessage: 三结局分流
```

- 01 帧 33B：`requestParametersforCidpu:` @0x11bec ✅
- 03 帧 18B：`calculateResponseforCidpu:...` @0x12050 ✅
- 04 结果：`checkResultMessage:` @0x107d4 ✅
- 10 个动作控制码全部来自 `-[IBVehicle xxx]` 的 `mov w2,#N` ✅

### 3. 查询已配对手机 ✅ 闭环

```
requestPairedDeviceNames → perform(.requestPairedDevices, 0x0D控制码)
  → 03 末字节 0x0D → 车端回 04（受理）+ 0x0F（设备名）
```

### 4. 广播匹配 + 车辆状态 ✅ 闭环

- 魔数 EE01、Gen02/03 门槛、cryptedID AES 归属校验，逐字节一致 ✅
- 车辆状态走 **BLE 广播解密**（`parseBroadcastData:` @0x4bc0 → parseStatus/Doors/Power），
  非 TSP（早期误判已纠正）

### 5. 无感进入（PE）✅ 闭环

- `enablePassiveEntry`(0x11) / `disablePassiveEntry`(0x12) 走完整鉴权链
- 语义（Android `settings_pe_tip` 实证）：「靠近车辆拉门把手解锁」**单方向**
- ⚠️ 原 App **无「远离闭锁」**，本 App 不臆造

### 6. 安全机制 ✅ 闭环

- 防爆破：`perform` + `beginMeasuredAuth` 双入口 `guard !isLockedOut` ✅
- 密钥完整性：发帧前 `guard keyIntegrityOK != false` ✅
- 断连重连：`resetEdge()` 复位预认证边沿 ✅

---

## 二、控制码对照表（反汇编权威）

| 动作 | 控制码 | 反汇编 |
|---|---|---|
| lock | 0x01 | `-[IBVehicle lock]` @0xa0f4 `mov w2,#1` |
| unlock | 0x02 | `unlock` @0xa138 `mov w2,#2` |
| openCloseTrunk | 0x03 | `openCloseTrunk` @0xa17c `mov w2,#3` |
| windowUp | 0x04 | `windowUp` @0xa1c0 `mov w2,#4` |
| windowDown | 0x05 | `windowDown` @0xa204 `mov w2,#5` |
| panic | 0x06 | `panic` @0xa248 `mov w2,#6` |
| requestPairedDevices | 0x0D | `requestPairedDevicesNames` @0xa30c |
| enablePassiveEntry | 0x11 | `enablePassiveEntry` @0xa3d8 |
| disablePassiveEntry | 0x12 | `disablePassiveEntry` @0xa394 |
| pairing | 0x55 | `startPairing` @0xa350 |

> ⚠️ 早期文档曾写「锁车=0x02/解锁=0x0C」，那是 Android 抓包旧结论，已被 iOS
> 反汇编推翻，勿采信。

---

## 三、本次会话（v0.2→v0.3）关键修复

| 问题 | 根因 | 修复 |
|---|---|---|
| 配对后秒断、密钥不存 | 配对 01 占位 RND1 错位 2 字节 | 占位改 9零+RND1@[9,13)+3零 |
| 绑定页收不到配对 | 配对兜底连接条件过严 + 分叉漏判 | 无条件连第一个设备 + 确定性扫描 |
| 状态条「点击」无反应 | 死文案没绑动作 | 加 onTapGesture 重试 |
| 主页不显示已绑定 | measured 非 @Published，UI 不刷新 | objectWillChange 转发 |

详见 `CHANGELOG.md`。

---

## 四、已知偏差（有据可依，非缺陷）

### 偏差 1：预认证触发依赖标定

- 链路通：`RSSI → check → updateArea → launchPreAuthentication → 0x0C`
- `isInPassiveStartArea` 需 `calibration`，标定写入端跨 GLBLE 协议（本车无）
- 未标定基准 -32 几乎不触发，与原 App `[nil intValue]=0` 一致，**是原 App 设计**

### 偏差 2：~~0x0D 登记帧为备用路径~~ → **已更正：0x0D 才是主路径**

- 2026-10-25 曾误判「主配对走 0x55 鉴权链，0x0D 是 `generatePairingMessage`
  的备用还原、当前未调用」。
- 实际相反：`startFullPairing` 走的就是 `0x0D` 登记帧（见第一节 1）；
  `0x55` 那条链是早期按 `openConnexionForCommand:0x55` 猜出来的错误实现，
  **代码与文档均已删除**。

---

## 五、Apple Watch 端（v7.4 A 方案，v7.5 加前台保活）

手表是**独立的钥匙**：自己扫描 / 连接 / 鉴权 / 配对，与手机之间没有任何
密钥传输（车端一车可挂 5 台，每台各有自己的槽位密钥）。

| 能力 | 手机 App | 手表 App |
|---|---|---|
| 配对 `0x0D → 0x0E` | ✅ | ✅（v7.4） |
| 控车 `01→02→03→04` | ✅ | ✅ |
| 车辆状态（广播解密） | ✅ | ✅（120 秒过期窗口） |
| 预认证心跳 `0x0C` | ✅ 29 秒一轮，带后台 | ✅ **仅前台**（v7.5）；判据是「收到本车广播」，不用 calibration |
| 无感进入 `0x11/0x12` | ✅ | ❌ 刻意不做 |
| 扫描策略 | 常开（含后台） | 前台常开（心跳要靠广播流）/ 进后台全停 |
| 后台保活 | Live Activity + bluetooth-central | ❌ watchOS 无 `bluetooth-central` |

**手表为什么不做后台心跳**：watchOS 没有 `bluetooth-central` 后台模式，
熄屏即挂起，维持不了「持续在场」。做后台只能靠 `WKExtendedRuntimeSession`
（类型受限，滥用会被审核拒）或在手表上重建标定流程，代价远超收益。

**未闭环项（只能真机验）**：
1. watchOS 的 Passkey Entry 弹窗能否输入 6 位码；
2. 诊断仪登记槽位时是否接受手表；
3. 手表前台心跳是否被车端认账（手机不在时能否无感启动）。

---

## 六、最终结论

**核心功能全部按原 App 闭环**：配对（`0x0D` 登记帧）、鉴权、控车、查询已配对手机、
广播匹配、车辆状态（广播解密）、无感进入、安全机制，每一条都能追到反汇编地址。
**Apple Watch 端**（v7.4 A 方案 + v7.5 前台保活）复用同一套协议栈，代码已就绪。

**唯一未闭环的是「真机跑一遍」**：代码层面已就绪，需真车验证：
1. 绑定车辆 → 看是否发 `0x0D` 并收到 `0x0E`（62B 密钥）
2. 解锁 → 看日志 `01→02→03…02→04 00`
3. 查询已配对手机 → 看 `0x0F` 设备名
4. 手表配对 → 看是否弹 6 位码、诊断仪是否认这台设备
