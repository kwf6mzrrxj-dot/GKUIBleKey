# 业务实现差异审查 v2（2026-10-29）

> 审查方式：从 `InBlue.framework` / `ValeoCoreCommunication.framework` 的符号表取出
> **全部业务方法**（IBVehicle 103 / IBDevice 74 / IBManager 22 / IBVehicleManager 18 /
> IBMessageManager 23 / VCLSManager 19 / IBKey 14 / VCB 各层），按功能域分组，
> 逐组对照本 App 的实现位置。
>
> 与 `Docs/LOGIC_DIFF_AUDIT.md`（v2.0 版，14 项）的区别：那一版只覆盖业务逻辑；
> 本版**把连接层纳入**，并补上 `-[IBVehicle isValid]` 这一道前置闸。

---

## 一、结论速览

| 域 | 对齐度 | 说明 |
|---|---|---|
| 连接与链路 | ✅ 基本对齐 | 本次补齐 `setReadCharacteristic`、提前置 ready；写入 type 无证据 |
| 配对（0x0D/0x0E） | ✅ 完全对齐 | 帧结构、密钥切片、收尾动作全部一致 |
| 鉴权（01→02→03→04） | ✅ 完全对齐 | 五段明文、AES 链、结果判定、序号单调 |
| 车辆状态解析 | ⚠️ 部分缺失 | 缺 4 个分门「锁」状态 |
| 被动进入 | ⚠️ 部分缺失 | 核心判定有，缺「出范围」状态机 |
| 标定 | ✅ 对齐 | 90 次采样、双天线、UserDefaults 存储 |
| 密钥存储 | ✅ 对齐 | 7 字段 hex + NSKeyedArchiver + `IBSavedKeys` |
| 日志 | ✅ 对齐 | 分级 + 轮转 + 脱敏，覆盖连接全链路 |
| 错误处理/超时 | ⚠️ 部分缺失 | 有 30s 命令超时，缺「接收超时」 |

---

## 二、连接与链路（ValeoCoreCommunication）

| 原 App | 地址 | 我们的实现 | 状态 |
|---|---|---|---|
| `centralManager:didConnectPeripheral:` | `0x640c` | `didConnect` | ✅ |
| `connectPeripheral:options: nil` | `0x5de0` | `central.connect(p, options: nil)` | ✅ |
| `peripheral:didDiscoverServices:`（只查 FF10） | `0xa070` | `didDiscoverServices` | ✅ |
| FF12 → `setReadCharacteristic:` + `setNotifyValue:` | `0xa8d4` / `0xa950` | 本次补齐 `readChar` | ✅ |
| FF11 → `setWriteCharacteristic:` | `0xa9fc` / `0xa904` | `writeChar` | ✅ |
| 特征发现末尾 `setState:` + `deviceDidReadyToExchangeData:` | `0xaa88` / `0xaac0` | `characteristicsReady` | ✅ 本次补 |
| `device:didSubcriptionFailedWithError:` | `0xab1c` | `note("订阅失败（bonding 未建立）")` | ✅ |
| `splitData:withMTU:`（包数 ceil((len+4)/mtu)，每包 MTU−4） | `0xdcac` | `send()` 分包 | ✅ |
| `didDisconnectPeripheral`：只 `setState:0` + 回调，不重连 | `0x69fc` | 同 | ✅ |
| `writeValue:forCharacteristic:type:` 的 type | `0x9c14` | `.withoutResponse` | ⚠️ 未定 |
| peripheral → device 映射表（找不到报 `didNotReadyToExchangeDataWithError:`） | `0xa5c8` | 无 | ⚠️ 语义差异 |

**关于写入 type**：`x23`（type 参数）来自 `[sp,#0x40]` 的一次方法调用返回值，
逐寄存器追到 `0x9c00` 之后断链，**目前没有确定值**。
代码注释声称「HCI 抓包看到 opcode 0x52 = Write Command」，但仓库里没有抓包文件、
也无当日记录，无法核实。**这一项属于「无证据」，不能算已对齐。**

---

## 三、配对（IBDevice / IBVehicle / IBMessageFactory）

| 原 App | 地址 | 我们 | 状态 |
|---|---|---|---|
| `startPairing` → `openConnexionForCommand:0x55` | `0xa350` / `0x4988` | `beginMeasuredAuthPairing` | ✅ |
| 配对**跳过** cidpu 检查（`cmp w21,#0x55 → b.eq`） | `0xfb48` | 同 | ✅ |
| `+[IBMessageFactory pairingMessage]`：`0D + sidpu(16) + 名称(20)` = 37B | `0x13afc` | `InBluePairing.buildPairingMessage` | ✅ |
| sidpu 硬编码 `628f073114ec49c78097e189ce8d2f92` | `0x11a28` | `sidpuHex` | ✅ |
| 名称 >20 截断、不足补零 | `0x13c0c` | 同 | ✅ |
| `saveKeysData:`：7 字段 → hex → 字典 | `0x12660` | `parseKeyFrame` + `saveKeyData` | ✅ |
| `storeDictionary:toKeychainWithKey:`（NSKeyedArchiver → `IBSavedKeys`） | `0x131b4` | `setIBSavedKeysArchive` | ✅ |
| `callDidPairingSuccess` → `disconnect`（= resetCommandTimeout + startScan，不断连） | `0x6d6c` / `0x6588` | `finishPairingWithReconnect` | ✅ |
| 主 App `newVehicleDidPairingSucceed:` 只拼 UI 文案 | `0x1008decc4` | 无协议动作 | ✅ 一致 |

---

## 四、鉴权（VCLSManager / IBDevice）

| 原 App | 地址 | 我们 | 状态 |
|---|---|---|---|
| `[device isValid]` 前置闸（key 非空 + cidpu 非空 + 长度 0x20） | `0x9cb4` | `MeasuredSession.isVehicleValid` | ✅ 本次补 |
| 30s 命令超时 → `callDidSendCommandFailed...code:690`，**不断连** | `0x62dc` | `startCommandTimeout` | ✅ |
| `formatCommand:toDevice:` 起 30s 定时器 | `0xfb48` | 同 | ✅ |
| `0x01` = `sd + ed + RndTRx + RND1(4) + rights` → AES(`CkTRxSP`) | `0x11bec` | `buildFirstMessage` | ✅ |
| `0x03` = `03 + AES128(buf3, enc1) + command` = 18B | `0x12050` | `buildResponse` | ✅ |
| `checkResultMessage:`：`data[1] != 0` → `0x2BB` | `0x107d4` | `handle(.result)` | ✅ |
| `lastPacket` 单调 + 白名单 `{0,1,2,14}` | `0x10004` / `0x101a0` | `handle()` 前置校验 | ✅ |
| `0x05` 只记录不解析 | `0x101a0` | 同 | ✅ |
| `0x0F` → `parseDeviceNames:` | — | `parseDeviceNames` | ✅ |

---

## 五、车辆状态（IBVehicle / IBDevice 的 isXxx 系列）

原 App 提供的状态位：`isLocked` / `isDoorClosed` / `isTrunkLocked` / `isTrunkClosed` /
`isHoodClosed` / `isIgnitionOn` / `isEngineRunning` / `isAccOn` /
`isFLDoorClosed` / `isFRDoorClosed` / `isRLDoorClosed` / `isRRDoorClosed` /
**`isFLDoorLocked` / `isFRDoorLocked` / `isRLDoorLocked` / `isRRDoorLocked`**

| 差异 | 影响 |
|---|---|
| **缺 4 个分门「锁」状态**（`isXxxDoorLocked`） | 只影响展示粒度（原 App 能显示"左前门已锁、右前门未锁"）。不影响控车与配对。 |
| 有 `isHoodClosed` | ✅ 已实现 |

---

## 六、被动进入（IBVehicle）

| 原 App | 我们 | 状态 |
|---|---|---|
| `calibration` / `setCalibration:` / `getCalibrationSavedValues` | `PassiveStart.calibration` + UserDefaults `<cidpu>_CALIBRATION` | ✅ |
| `leaveOffset = 32` / `approachOffset` | 同（`leaveOffset=32`、`approachOffset=30`） | ✅ |
| `addRSSI:`（10 值滑窗 + 3 时间戳） | `addCalibrationSample` / `samples` | ✅ |
| `checkRssiForPassiveStart`（`rssisOneAndTwo > calibration - leaveOffset`） | `check(rssiOne:rssiTwo:)` | ✅ |
| `isInPassiveStartArea` | `isInPassiveStartArea` | ✅ |
| `pondInToOut = 1.0` / `pondOutToIn = 1.0` / `timeBetweenPassiveStart = 29.0` | 同 | ✅ |
| `startCalibration`（90 次采样） | `startCalibration` + `calibrationSampleTarget = 90` | ✅ |
| `clearCalibrationData` | 解绑时清除 | ✅ |
| `launchPrehautentification` / `stopPreAuthentication` | `PreAuthenticationController.launch / stop` | ✅ |
| `cancelPreviousPassiveStartCommands` | `cancelPending()` | ✅ 等价 |
| **`isInRange` / `resetOutOfRangeTimeout` / `vehicleWentOutOfRange`** | **无** | ❌ 缺 |
| **`didRequestWelcome`（迎宾）** | **无** | ❌ 缺 |

**缺「出范围」状态机的实际影响**：原 App 用 `vehicleWentOutOfRange` +
`resetOutOfRangeTimeout` 维护「车已远离」的状态，用于复位被动进入的边沿判断。
我们靠 `preAuth.resetEdge()`（断连时复位）替代，**在"连着但走远"的场景下可能不触发复位**——
即离开车辆但不断连时，回来可能不会重新触发一次被动进入。

---

## 七、密钥与配置存储

| 项 | 原 App | 我们 | 状态 |
|---|---|---|---|
| 密钥 7 字段 | Keychain `IBSavedKeys`（NSKeyedArchiver） | 双写：主存储 + `IBSavedKeys` 同构 | ✅ |
| cidpu | `lastCarKey`（UserDefaults） | `KeyStore.cidpuFullHex` | ✅ |
| 标定值 | `<cidpu>_CALIBRATION`（Double） | 同 | ✅ |
| IDFV（mobileId） | `VKKeychainIDFV`（Keychain 持久化） | `KeyStore.idfvDisplay`（Keychain 持久化） | ✅ |

---

## 八、错误处理与超时

| 原 App | 我们 | 状态 |
|---|---|---|
| 命令超时 30s → 690 | ✅ | ✅ |
| `device:didSendDataFailedWithError:` | 写失败 → `lastMessage` | ✅ 近似 |
| `device:willNotConnectedWithError:` | `didFailToConnect` → 转扫描 | ✅ |
| **`device:didNotReceiveDataWithError:`** | **无对应** | ❌ 缺 |

`didNotReceiveDataWithError:` 表明原 App 除了「命令超时」外，还有一条**接收侧超时/失败**
的独立路径。我们只有 30s 命令超时一条，如果车端在 30s 内明确拒收，我们无法更早反应。

---

## 九、缺口状态（v2.8 更新：全部已对齐）

| # | 缺口 | 结论 | 状态 |
|---|---|---|---|
| 1 | `writeValue` type 无证据 | **反汇编确认 `mov w4, #1` = `withoutResponse`**（`x2=data/x3=char/x4=type`，此前把 x3 误当 type） | ✅ 本来正确 |
| 2 | 缺 4 个分门「锁」状态 | `parseDoorsStatus:` 实为 8 位，bit4~bit7 就是门锁 | ✅ 已补 |
| 3 | 缺出范围状态机 | `VCBDevice resetWithTimeout` `fmov d0, #9.0` → 9 秒接收超时 | ✅ 已补 |
| 4 | 无 peripheral→device 映射 | 单设备等价校验：回调必须来自当前外设 | ✅ 已补 |
| 5 | 缺 `didRequestWelcome` | 反汇编 `0xbccc` 只是 **getter**（`ldrb w0,[x0,x8]`），非功能 | ✅ 无需实现 |
| 6 | 缺 `device:didNotReceiveDataWithError:` | 由 #3 的 9 秒超时覆盖（原 App 的 VCB 层超时即此机制） | ✅ 无需单独实现 |

**结论：截至 v2.8，业务实现层面已无已知未对齐项。**

---

## 十、这次审查**没能**回答的问题

以下三项必须靠设备数据，静态反汇编给不出结论：

1. **车端为什么在收到 `0x0D` 后零响应**（2026-10-28 21:15 实测）
2. **「连上秒断」是谁断的、什么原因**
3. **写入 type 到底是什么**

需要：链路日志的 `[链路] 已断开：<reason>` + `CBError.Code`，或 HCI 抓包。
