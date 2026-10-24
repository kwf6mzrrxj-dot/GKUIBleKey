# 原 App 来源审计表（SOURCE AUDIT）

> **审计原则**：每一条结论都必须能在 `XiaoKa.app` 二进制内找到对应指令、
> `CFSTR` 字面量或 `subdataWithRange` 立即数。找不到的一律标 **缺失**，
> 不写"推断值"。
>
> 与真机抓包冲突时，**以二进制为准**，冲突点在文末单列。
>
> 审计基准：`ios/Payload/XiaoKa.app/Frameworks/InBlue.framework/InBlue`
> （arm64，`nm -n` 符号表 + capstone 反汇编）。

---

## 一、帧结构

| 结论 | 来源 | 等级 |
|---|---|---|
| `01` 帧 = 33 字节（`0x01` + 32B） | `+[IBMessageFactory derivationParametersMessageWithCidpu:]` @`0x13794`：`0x13810 mov w2,#0x21`（`dataWithCapacity:0x21`）、`0x1385c mov w3,#0x21`（`checkMessageLength:length:0x21`） | A |
| `01` 载荷 = `[VCLSManager requestParametersforCidpu:]` 的返回值直接 append | 同上 `0x13844 [data appendData:x21]`，x21 即该调用结果 | A |
| `03` 帧 = 18 字节（`0x03` + 16B + 1B） | `+[IBMessageFactory responseMessageWithCommand:randomData:cidpu:]` @`0x13904`：`0x139dc mov w2,#0x12`、`0x13a44 mov w3,#0x12` | A |
| `03` 帧末字节 = `command` 原值 | 同函数：`0x13924 mov x23,x2`（x2=command）→ `0x13a24 strb w23,[sp,#0x1d]` → `0x13a34 appendBytes:1` | A |
| `03` 帧首字节固定 `0x03` | 同函数：`0x139f0 mov w8,#3` → `0x139f4 strb w8,[sp,#0x1e]` → `0x13a0c appendBytes:1` | A |
| 接收侧只处理 `2/4/5/0x0E/0x0F` | `-[IBMessageManager performActionBasedOnPayloadType:andData:]` @`0x10004`：`0x10030 cmp w21,#4` / `0x10038 cmp w21,#5` / `0x10040 cmp w21,#0xe` / `0x10048 cmp w21,#0xf` | A |

---

## 二、命令号（`03` 末字节）

每个号都是 `-[IBVehicle xxx]` 内 `openConnexionForCommand:` 的 `w2` 立即数。

| 动作 | 命令号 | 方法地址 | 证据指令 |
|---|---|---|---|
| 锁车 | `0x01` | `-[IBVehicle lock]` `0xa0f4` | `0xa120: e2030032  mov w2,#1` |
| 解锁 | `0x02` | `unlock` `0xa138` | `0xa164: e2031f32  mov w2,#2` |
| 后备箱开/关 | `0x03` | `openCloseTrunk` `0xa17c` | `0xa1a8: e2070032  mov w2,#3` |
| 关窗 | `0x04` | `windowUp` `0xa1c0` | `0xa1ec: e2031e32  mov w2,#4` |
| 开窗 | `0x05` | `windowDown` `0xa204` | `0xa230: a2008052  mov w2,#5` |
| 寻车/鸣笛 | `0x06` | `panic` `0xa248` | `0xa274: e2071f32  mov w2,#6` |
| 查询已配对手机 | `0x0D` | `requestPairedDevicesNames` `0xa30c` | `0xa338: a2018052  mov w2,#0xd` |
| 开启无感进入 | `0x11` | `enablePassiveEntry` `0xa3d8` | `0xa404: 22028052  mov w2,#0x11` |
| 关闭无感进入 | `0x12` | `disablePassiveEntry` `0xa394` | `0xa3c0: 42028052  mov w2,#0x12` |
| 配对 | `0x55` | `startPairing` `0xa350` | `0xa37c: a20a8052  mov w2,#0x55` |
| **预认证** | `0x0C` | `openConnectionWithPassiveStart` `0xb5a8` | `0xb684: e2071e32  mov w2,#0xc` |

`0x0C` 的语义由同函数内的日志字面量直接确认：
`0xb610: adr x2, #0x20b08 ; CFSTR "send prehauthentification command to cidpu : %@"`。

**`0x0C` 不是 `startCalibration` 的命令。**
`-[IBDevice startCalibration]` @`0x4880` 只是把调用转发给 `[self.device startCalibration]`
（`0x4968 ldr x1,#0x27218`，receiver 是 `x19` = `self.device`），
它自己的方法体里**没有** `mov w2,#0xc`。

---

## 三、预认证 / 被动进入

| 结论 | 来源 |
|---|---|
| 进入区域 → `launchPrehautentification` | `checkRssiForPassiveStart` @`0xac04`：`0xb278 ldr x1,#0x276b8` |
| 离开区域 → `stopPreAuthentication` | 同上：`0xb284 ldr x1,#0x27650` |
| 区域标志写入 | 同上：`0xb308 mov w2,#1` / `0xb220 mov w2,#0`（`setIsInPassiveStartArea:`） |
| 重复启动被拦 | `launchPrehautentification` @`0xb32c`：`0xb348 didStartSendPassiveStartCommand` → `0xb350 tbz w0,#0` 直接返回 |
| 启动时置标志、清旧定时器 | 同上：`0xb408 mov w2,#1`、`0xb418 cancelPreviousPassiveStartCommands` |
| 发起连接：断开立即、已连延迟 1 秒 | `launchPassiveEntryCommands` @`0xb54c`：`0xb560 isDisconnected` → `0xb584 b _objc_msgSend`；`0xb590 fmov d0,#1.0` |
| 成功 → 6.5 秒后再来 | `didPassiveStartCompletedWithError:` @`0xb6cc`：`0xb7d4 cbz x20` → `0xb7d8 fmov d0,#6.5` |
| 失败 → 29.0 秒 | 同上：`0xb7e0 fmov d0,#29.0` |
| 停止时清标志、清定时器 | `stopPreAuthentication` @`0xb444`：`0xb50c mov w2,#0`、`0xb51c cancelPreviousPassiveStartCommands` |
| **原 App 不自动发 unlock/lock** | `launchPassiveEntryCommands` 全程只调 `openConnectionWithPassiveStart`，无 `lock`/`unlock` 选择器引用 |

---

## 四、`01` 明文顺序

| 结论 | 来源 |
|---|---|
| 明文 = `sd ‖ ed ‖ RndTRx ‖ RND1 ‖ rights` | `-[VCLSManager requestParametersforCidpu:]` @`0x11bec` |
| 格式串 5 个 `%@` | `0x11ddc: adr x2, #0x21348 ; CFSTR "%@%@%@%@%@"` |
| vararg1 = `sd` | `0x11cd4 CFSTR "sd"` → `0x11cec str x0,[sp,#0x30]` → `0x11dd0 ldr x20,[sp,#0x30]` → `0x11dd4 str x20,[sp]` |
| vararg2 = `ed` | `0x11d0c CFSTR "ed"` → `0x11d24 mov x28,x0` → `0x11dcc stp x28,x23,[sp,#8]` |
| vararg3 = `RndTRx` | `0x11d4c CFSTR "RndTRx"` → `0x11d64 mov x23,x0` → 同上 `stp` 的第二寄存器 |
| vararg4 = `RND1` | `0x11d6c @selector(RND1)` → `0x11d80 mov x24,x0` → `0x11dc8 stp x24,x0,[sp,#0x18]` |
| vararg5 = `rights` | `0x11da4 CFSTR "rights"` → `0x11dbc mov x27,x0`；`0x11dc8` 的 `x0` 仍为该返回值 |
| 拼接结果经 `stringToData:` 转字节 | `0x11dfc @selector(stringToData:)` |
| `RND1` 为 4 字节随机数 | `0x11c30 mov w2,#4` → `0x11c1c randomDataWithBytes:` |
| 两段都用 `CkTRxSP` 加密 | `0x11e84 objectForKey:@"CkTRxSP"` → `0x11edc AES128EncryptWithData:withKey:`；第二段 `0x11f24 CFSTR "628f073114ec49c78097e189ce8d2f92"` |

**注**：原 App 只有这一种顺序，没有候选/重试逻辑。

---

## 五、密钥帧（`0x0E`）切分

`-[VCLSManager saveKeysData:]` @`0x12660`，`location` 以含命令号的帧头为基准。

| 键名 | `(location, length)` | 证据 |
|---|---|---|
| `Dk1` | `(0x01, 0x10)` | `0x12810 mov w2,#1` / `0x12814 mov w3,#0x10` |
| `sd` | `(0x11, 0x04)` | `0x126c4 mov w2,#0x11` / `0x126c8 mov w3,#4` |
| `ed` | `(0x15, 0x04)` | `0x1271c mov w2,#0x15` |
| `CkTRxSP` | `(0x1E, 0x10)` | `0x1276c mov w2,#0x1e` / `0x12770 mov w3,#0x10` |
| `RndTRx` | `(0x19, 0x03)` | `0x127c0 mov w2,#0x19` |
| `rights` | `(0x1C, 0x01)` | `0x12860 mov w2,#0x1c` |
| `keyType` | `(0x1D, 0x01)` | `0x128b0 mov w2,#0x1d` |
| **CIDPU（字典键）** | `(0x2E, 0x10)` | `0x129a4 mov w2,#0x2e` / `0x129a8 mov w3,#0x10` → `0x129d0 hexString:` → `0x129f4 setObject:forKey:` |

`0x129f4` 的寄存器分配：`x0 = _keysData`、`x2 = 七元子字典`、`x3 = hexString(该 16 字节)`。
即 **`keysData[cidpu] = {Dk1, sd, ed, CkTRxSP, RndTRx, rights, keyType}`**，
`cidpu` 就是那 16 字节的 hex 串（32 字符）。

---

## 六、`04` 结果码

`-[IBMessageManager checkResultMessage:]` @`0x107d4`：

| 结论 | 证据 |
|---|---|
| 结果字节取 `data[1]` | `0x107f0 subdataWithRange:` 参数 `w2=1, w3=1` → `0x10820 ldrb w21,[x0]` |
| 非 0 → 失败，码 `699`（`0x2BB`） | `0x1082c cbz w21,0x10868`；非零分支 `0x1085c mov w3,#0x2bb`，串 `CFSTR "Send command failed. The vehicle refused the command"` @`0x21048` |
| `command == 0x0D` 时直接返回 | `0x1086c @selector(command)` → `0x10878 cmp w0,#0xd` → `0x1087c b.ne` → 相等则 `ret` |
| 其余 → `callDidSendCommandSuccess` | `0x108b0 @selector(callDidSendCommandSuccess)` |

---

## 七、`05` 帧

| 结论 | 来源 |
|---|---|
| 只打日志，不解析 | `performActionBasedOnPayloadType:andData:` @`0x101a0`：`CFSTR "Message 5 received"` @`0x20f88` → `NSLog` → `b 0x102ec`（直接返回） |
| 仅设置 `lastPacket` | 同一分支内无 `setLastPacket:` 调用（对比 `case 4` 在 `0x10188` 有 `mov w2,#4`） |

对照：`case 14` 才调 `saveKeysData:`（`0x101f4`）、`case 15` 才调 `parseDeviceNames:`（`0x1074`）。

---

## 八、广播匹配

| 结论 | 来源 |
|---|---|
| 魔数 `EE 01` | `-[VCB... isValeoDeviceWithAdvertisingData:]`，常量位于 `ValeoCoreCommunication` 文件偏移 `0x10808`（内容 `EE 01`） |
| Gen02 / Gen03 版本分支 | 版本字节 `== 0x02` 走 Gen02（长度 ≥23），否则 Gen03（≥19） |
| cryptedID 位置 | Gen02 `[7,23)`、Gen03 `[7,19)` |
| 归属校验 | `AES(cryptedID[0..8) ‖ "BC145356BAFE0028", key=cidpu, IV=0)`，取密文 `[2,6)` 与 `cryptedID[8,12)` 比较 |

> 这一节的地址来自 `ValeoCoreCommunication`（`vcbd.py` 反汇编），
> 与 `InBlue` 的偏移体系不同，引用时需注明框架。

---

## 九、RSSI 距离公式

`checkRssiForPassiveStart` @`0xac04`：

```asm
0xad90: fmov d9, #10.0
0xad94: fdiv d0, d0, d9        ; rssiOne / 10
0xad98: bl   ___exp10          ; 10^(rssiOne/10)
0xad9c: fmul d10, d0, d0       ; p1²
0xae98: fdiv d0, d0, d9        ; rssiTwo / 10
0xae9c: bl   ___exp10
0xaea0: fmul d0, d0, d0        ; p2²
0xaea4: fadd d0, d10, d0       ; p1² + p2²
0xaea8: fsqrt d0, d0
0xaeac: fmul d8, d8, d0        ; × pondOutToIn
```

即 `√(10^(r1/10)² + 10^(r2/10)²) × pondOutToIn`。

---

## 十、明确标注为「缺失」的项

| 项 | 为什么缺失 |
|---|---|
| `calibration` / `leaveOffset` 的取值来源 | `0xb02c sub w8,w22,w0` 只说明比较用二者之差，但它们的写入点未追出 |
| 比较式中 `w25` 的来源 | 来自更早的整数运算链，未逐条追踪完 |
| 被动启动成功后车端的实际动作 | 属于车端行为，App 内无对应实现 |
| `05` 帧 19 字节的字段含义 | 原 App 不解析，无任何解析代码可依 |
| `parseStatus:` 中 loc=2 字段语义 | 只有索引，无字符串或注释 |

**这些项在代码里都已标注「未确证 / 缺失」，不参与安全判断，也不作为对外结论。**

---

## 十一、与真机抓包的冲突

| 抓包观察 | 二进制结论 | 采用 |
|---|---|---|
| 静止时 `0x0C` 每 28 秒一次 | 失败路径 29.0 秒（`0xb7e0`） | **29.0 秒**（二进制）；28 秒应是定时器启动开销造成的表观间隔 |
| `0x02` 后 `05` 首字节由 `00` 变 `40` | `05` 无解析代码（`case 5` 仅 NSLog） | **不解析**；该字节语义按「缺失」处理 |
| 曾把 `0x02` 读作「锁车」 | `0x02` = `unlock`（`0xa164`） | **`0x02` 是解锁**；抓包那次状态变化正好是解锁 |

> 原则：抓包只能证明「发生了什么」，不能定义「字段是什么」。
> 一旦二者冲突，以二进制为准。
