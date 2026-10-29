# 按原 App 闭环的最终核对

> 核对时间：2026-10-25 11:30（v0.9）
> 判定基准：原 App（GKUI/小卡）iOS 版反汇编为唯一权威，抓包仅作参考

---

## 一、核心链路闭环核对

### 1. 配对 ✅ 闭环（0x55 鉴权链）

```
startFullPairing → stopScan/cancel/prepareForPairingScan → startScan
  → didDiscover 兜底自动连接 → connect → didConnect(exitQuietMode→发现服务→订阅)
  → linkState ready → beginMeasuredAuthPairing → preparePairing(0x55)
  → buildAuth1(配对占位) → 车端回 02 → buildAuth3(控制码0x55)
  → 车端回 0x0E(62B 密钥) → saveKeyData → loadCalibration
```

- 配对走 **0x55 鉴权链**（`startPairing` @0xa350 → `openConnexionForCommand:0x55`）
- 配对 01 帧占位：**9 零 + RND1@[9,13) + 3 零**（`stringToData` 每 2 字符 strtoul，
  每个 nil 字段 `"(null)"`(6字符)=3 零，非 4 零）
- `0x0E` 密钥帧：`saveKeysData:` @0x12660，62B 切 7 字段 ✅
- 配对后重读标定（cidpu 配对后才确定）✅

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

### 偏差 2：0x0D 登记帧为备用路径

- 主配对走 0x55 鉴权链；`InBluePairing.buildPairingMessage`（0x0D 37B 登记帧）
  保留为原 App `generatePairingMessage` @0xfecc 的还原，当前未调用

---

## 五、最终结论

**核心功能全部按原 App 闭环**：配对（0x55 链）、鉴权、控车、查询已配对手机、
广播匹配、车辆状态（广播解密）、无感进入、安全机制，每一条都能追到反汇编地址。

**唯一未闭环的是「真机连车跑一遍」**：代码层面已 100% 就绪，需真车验证：
1. 绑定车辆 → 看是否走通 0x55 链拿到 0x0E 密钥
2. 解锁 → 看日志 `01→02→03…02→04 00`
3. 查询已配对手机 → 看 0x0F 设备名
