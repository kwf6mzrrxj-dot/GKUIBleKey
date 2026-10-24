# 按原 App 闭环的最终核对

> 核对时间：2026-10-24 22:44
> 判定基准：原 App（GKUI/小卡）iOS 版反汇编为唯一权威，抓包仅作参考

---

## 一、核心链路闭环核对

### 1. 配对 ✅ 闭环

```
startFullPairing → reconnectForPairing/startScan → linkState ready
  → sendPairingRequest（0x0D 37B 登记帧）→ 车端回 0x0E（62B 密钥）
  → saveKeyData（saveKeysData: @0x12660 切 7 字段）→ loadCalibration
```

- `0x0D` 登记帧：`pairingMessage` @0x13afc，37B ✅
- `0x0E` 密钥帧：`saveKeysData:` @0x12660，62B 切分 ✅
- 配对后重读标定（cidpu 配对后才确定）✅

### 2. 鉴权 + 控车 ✅ 闭环

```
perform(action) → beginMeasuredAuth → buildAuth1（01，AES(明文,CkTRxSP)）
  → 车端回 02 → handle 自动 buildAuth3（03，末字节=控制码）
  → 车端回 04 → checkResultMessage: 三结局分流
```

- 01 帧 33B：`requestParametersforCidpu:` @0x11bec ✅
- 03 帧 18B：`calculateResponseforCidpu:...` @0x12050 ✅
- 04 结果：`checkResultMessage:` @0x107d4（data[1] 非0→失败/0x0D特判/成功）✅
- 8 个动作控制码全部来自 `-[IBVehicle xxx]` 的 `mov w2,#N` ✅

### 3. 查询已配对手机 ✅ 闭环

```
requestPairedDeviceNames → perform(.requestPairedDevices, 0x0D控制码)
  → 03 末字节 0x0D → 车端回 04（受理）+ 0x0F（设备名）
```

- `requestPairedDevicesNames` @0xa30c → `openConnexionForCommand:0x0D` ✅
- 0x0F 单独处理，不被"未知帧"吞掉 ✅

### 4. 广播匹配 ✅ 闭环

- 魔数 EE01、Gen02/03 门槛、cryptedID AES 归属校验，逐字节一致 ✅

### 5. 安全机制 ✅ 闭环

- 防爆破：`perform` + `beginMeasuredAuth` 双入口 `guard !isLockedOut` ✅
- 密钥完整性：`beginMeasuredAuth` 发帧前 `guard keyIntegrityOK != false` ✅
- 断连重连：`resetEdge()` 复位预认证边沿 ✅

---

## 二、已知偏差（有据可依，非缺陷）

### 偏差 1：`0x55` 配对命令未实现

- **原 App**：`startPairing` @0xa350 → `openConnexionForCommand:0x55`（进入配对模式）
- **当前**：未实现 `0x55`，配对走 `0x0D` 登记帧直发
- **依据**：所有抓包里配对写帧**只有 0x0D，没有 0x55**，且车端直接回 0x0E 配对成功
- **结论**：本车 `0D→0E` 即可完成配对，`0x55` 是「进入配对模式」的命令，本车用不到。**保留 `IBCommandType.pairing = 0x55` 枚举作为记录，不实现发帧。**

### 偏差 2：预认证触发依赖标定

- 链路本身通：`RSSI → check → updateArea → launchPreAuthentication → 0x0C`
- 但 `isInPassiveStartArea` 需要 `calibration`，而标定写入端跨 GLBLE 协议（本车抓包无）
- **结论**：未标定时基准 -32，几乎不触发。这与原 App `[nil intValue]=0` 行为一致，**是原 App 设计，非缺陷**。

### 偏差 3：车辆状态走 TSP（非 BLE）

- 原 App 的 `05` 帧只 NSLog，锁状态来自云端 TSP（`CarStatusModel`）
- 本项目只做 BLE，不显示锁状态，显示「最近成功动作」。**通道不存在，非遗漏**。

---

## 三、历史断点全部确认已修复

| 断点 | 修复位置 | 状态 |
|---|---|---|
| 防爆破只记录不拦截 | `perform`/`beginMeasuredAuth` 加 guard | ✅ |
| `resetEdge` 从未调用 | linkState 订阅 | ✅ |
| 配对后不重读标定 | 0x0E 分支加 loadCalibration | ✅ |
| 0x0F 被未知帧吞 | 过滤条件加 `cmd==0x0F` | ✅ |
| 密钥完整性只报警不拦截 | beginMeasuredAuth 加 guard | ✅ |
| UI 未编译 | -plugin-path 修复 | ✅ |

---

## 四、最终结论

**核心功能全部按原 App 闭环**：配对、鉴权、控车、查询已配对手机、广播匹配、安全机制，每一条都能追到反汇编地址，且编译通过、已部署到手机。

**两个已知偏差**（`0x55` 配对命令、预认证标定）都有抓包/反汇编依据证明「本车用不到」或「原 App 本就如此」，不是缺陷，而是对原 App 行为的忠实还原。

**唯一未闭环的是「真机连车跑一遍」**：代码层面已 100% 就绪，需要你在真车上：
1. 点「绑定车辆」→ 看是否拿到密钥（0x0E）
2. 点「解锁」→ 看日志 `01→02→03…02→04 00`
3. 点「查询已配对手机」→ 看 0x0F 设备名
