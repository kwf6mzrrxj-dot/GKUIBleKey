# 证据分级表 —— GKUIBleKey 协议实现

> 目的：把每一处「结论」标注到来源，区分**硬证据**与**推断**。
> 后续任何人（包括我自己）改代码前，先看这张表，避免把推断当事实用。
>
> 最后更新：2026-10-24

---

## 等级定义

| 等级 | 含义 | 判据 |
|---|---|---|
| **A** | 反汇编直接读出 | 立即数 / `CFSTR` / `ivar` 偏移 / 段边界 |
| **B** | 反汇编多段互证 | 两处以上独立指令链指向同一结论 |
| **C** | 真机实测 | btsnoop 抓包，含**前后对照** |
| **D** | 推断 | 有理由、但不排除其他解释 |
| **E** | 假设 | 无直接证据，仅为让代码跑起来 |

**只有 A/B/C 可以作为设计依据；D 必须留可切换开关；E 必须留注释并避免影响安全路径。**

---

## 一、连接与扫描

| 结论 | 等级 | 依据 |
|---|---|---|
| 扫描过滤 Service = `10FF`（16-bit） | A | `-[VCBManager startScan]` @`0xd288`，`CFSTR "10FF"` |
| 必须带 `AllowDuplicates=YES` | A | 同上，`numberWithBool:1` |
| 连接 options = nil | A | `-[VCBDevice connect]` @`0x8de4`，`mov x3, #0` |
| 服务 `F000FF10`、写 `FF11`、通知 `FF12` | A | `peripheral:didDiscoverServices:` + `CFSTR` |
| 写特征必须 withoutResponse | B | 实测断链现象 + props `0x0C` |
| CCCD `0100` 用 Write Request | C | 抓包 `Write Request handle=0x000E value=0100` |
| MTU 150→238 | C | 抓包 |

## 二、广播匹配

| 结论 | 等级 | 依据 |
|---|---|---|
| 魔数 `EE 01` | A | `0x10808` 处 2 字节常量，`isEqualToData:` 比较 |
| 长度 < 2 → 非 Valeo | A | `cmp x0, #2` |
| 版本字节 = `manufacturer[2]` | A | `subdataWithRange:NSMakeRange(2,1)` |
| `version == 0x02` → Gen02，否则 Gen03 | A | `0x1080a` 处常量为 `0x02` |
| Gen02 门槛 23 / Gen03 门槛 19 | A | `cmp x0, #0x17` / `#0x13` |
| Gen03 ≥36 才有 `broadcastData`/`oemID` | A | `cmp x0, #0x24` |
| Gen02 `cryptedID=[7,23)`(16B) | A | `NSMakeRange(7,16)` |
| Gen03 `cryptedID=[7,19)`(12B) | A | `NSMakeRange(7,12)` |
| 归属校验：`AES(head8‖盐)[2..6) == cryptedID[8..12)` | A/B | `checkCryptedID:` `NSMakeRange(8,4)`+`(0,8)`；盐 `CFSTR "BC145356BAFE0028"`；比较 `NSMakeRange(2, tail.length)` |
| `cryptedID.length < 12` → 否 | A | `cmp x0, #0xc` |
| `enc.length <= tail+2` → 否 | A | `cmp` + `b.ls` |
| RSSI 门限 `-91.0`，严格大于 | A | `0x1fc10` = double -91.0，`b.le` |
| 原 App **不看广播名** | B | `isValeoDevice…` 只查厂商数据；`updateVehicleWithDevice:` 无名字分支 |

## 三、密钥帧与鉴权

| 结论 | 等级 | 依据 |
|---|---|---|
| 帧长 62（含 `0x0E`） | C | 文档记录 + 抓包时序 |
| `Dk1=[1,17)` | A | `NSMakeRange(1,16)` + `CFSTR "Dk1"` |
| `sd=[17,21)` / `ed=[21,25)` / `RndTRx=[25,28)` | A | `NSMakeRange(17,4)`/`(21,4)`/`(25,3)` |
| `rights=[28,29)` / `keyType=[29,30)` | A | `NSMakeRange(28,1)`/`(29,1)` |
| `CkTRxSP=[30,46)` | A | `NSMakeRange(30,16)` + `CFSTR "CkTRxSP"` |
| 存在 `[46,62)` 的 16 字节切片 | A | `NSMakeRange(46,16)` 的调用 |
| **该 16 字节 = 完整 cidpu** | **D** | 见 §六 专项 |
| AES = CBC / IV=0 / 无 padding | A | `CCCrypt(op,0,options=0,iv=NULL)` |
| `01` 帧 = `[01] + AES(明文,CkTRxSP) + AES(常量,CkTRxSP)` | A/B | `requestParametersforCidpu:` 两条 `AES128Encrypt` 链 |
| 常量 = `628f073114ec49c78097e189ce8d2f92` | A | `CFSTR` @`0x21328` |
| `01` 明文 = sd/ed/RndTRx/RND1/rights 共 16 字节 | A | 5 个 `subdataWithRange` + `stringToData` 长度自洽 |
| **五段的先后顺序** | **D** | 见 §六 专项 |
| `03` 帧 = `[03] + AES(buf3,enc1) + cmd` | A | `responseMessageWithCommand:…` 外壳 |
| `enc1 = AES(rnd1 重排, Dk1)`，重排为 `rev+rev[1:4]+rev[0:1]+rev[2:4]+rev[0:2]+rev[3:4]+rev[0:3]` | A | `0x12168`–`0x12288` 六个 `subdataWithRange` |
| 自校验 `enc2[2..9) == challenge[9..16)` | A | `NSMakeRange(2,7)` vs `(9,7)` |

## 四、车控与状态

| 结论 | 等级 | 依据 |
|---|---|---|
| 控制码 `0x02` = 锁车 | **C** | 20:59:59 →`03…02`，←`05 40…` |
| 控制码 `0x0C` = 解锁 | **C** | 21:00:03 →`03…0c`，←`05 00…` |
| `05` 帧首字节 bit6（`0x40`）= 已锁 | **C** | 同上两帧对照 |
| 控制码 `0x01` 语义 | 未知 | 出现 1 次，`05` 未变化 |
| 业务命令 1..6 / 0x0D / 0x11 / 0x12 / 0x55 | A | `-[IBVehicle …]` 各自 `mov w2, #N` |
| 业务命令与 `03` 控制码的映射 | 未知 | App 内无映射表 |
| `05` 帧 19 字节逐位结构 | 未知 | 原 App `case 5:` 只 `setLastPacket:5` |
| 广播明文切分 `[0,4)random/[4]status/[5]oem/[6]doors/[7]power/[8,16)` | A | `parseBroadcastData:` 五个 `NSMakeRange` |
| `parseStatus:` 内 `(7,1)` = 该字节 bit0 | A | `hexToBinary:` 高位在前 |
| 该位序在真车上成立 | **E** | 无实测（厂商数据 19B，根本走不到这条路径） |

## 五、错误码

| 码 | 含义 | 等级 | 依据 |
|---|---|---|---|
| `0x276` | CIDPU is nil | A | `CFSTR` + `mov w3,#0x276` |
| `0x277` | Derivation parameter is nil | A | `CFSTR` + `#0x277` |
| `0x278` | Wrong challenge | A | `CFSTR` + `#0x278` |
| `699` | Invalid Message type | A | `analyzeMessage:` default |
| `40001` | 重发次数已满 | 文档记录 | 主 App，未复核 |
| `04` 结果码 `0x00` = 成功 | C | 每次控车均回 `04 00` |
| `04` 其余码语义 | 未知 | 无失败样本 |

---

## 六、D 级结论的专项说明

### D-1：`cidpu` = 密钥帧 `[46,62)` 的 16 字节

**推断理由**

1. `checkCryptedID` 的 AES 要求 key 恰为 16 字节（`CCCrypt` 会因长度不符失败）；
2. 该 16 字节的末 4 字节 `6A C8 9A D4` 等于详情页显示的 `6ac89ad4`；
3. 该 16 字节的 `[9,16)` = `3F 26 C6 6A C8 9A D4`，等于设备名 `InBlue3f26c66ac89ad4` 的后 14 个 hex。

**为什么仍是 D 而不是 A**

反汇编只证明「存在一个 `NSMakeRange(46,16)` 的切片并被 `setObject:forKey:`」，
但那个 key 字符串是从栈上取的，**没有取到字面量**。所以「这 16 字节就是 cidpu」
仍是推断——也可能是「cipherID」「salt」之类，只是恰好含 CIDPU 的后半段。

**若推断错误的后果**：广播归属判定全部失败（表现为扫描到设备但始终判为「其他 Valeo 车辆」），
不影响已有钥匙的控车。

**验证方式**：拿一帧 `manufacturerData` ≥36 字节的广播（含 `broadcastData`），
用这 16 字节解密，明文应能切成有意义的状态；否则换 key。

### D-2：`01` 明文的五段顺序

**推断理由**：`0x11dc8`–`0x11dd4` 把 5 个 `NSString` 依次写入 `sp+0 / +8 / +0x10 / +0x18 / +0x20`，
顺序为 `sd, ed, RndTRx, RND1, rights`。

**为什么是 D**：这 5 个参数既没有走 `x3..x7`，压栈后也没有 `ldp` 回填。
无法排除「它们是临时 spill、真实参数另在寄存器」的可能。

**已采取的措施**：`MeasuredSession.orderCandidates` 提供两种顺序，
发出后 2.5s 无 `02` 自动切换，成功后持久化。

**若两个都错**：`01` 全部无响应，App 会明确报「已尝试全部 2 种顺序」。
此时需要从一次真实会话的 `seg1` + 已知 `CkTRxSP` 反推（AES 不可逆，只能穷举顺序）。

---

## 七、已推翻的结论（禁止再引用）

| # | 旧结论 | 推翻依据 |
|---|---|---|
| 1 | `01` 帧 = `broadcastRandom` + `communicateKey` | `01` 是两段 AES，无此字段 |
| 2 | `CkTRxSP = [1,17)` | `[1,17)` 是 `Dk1`；`CkTRxSP` 在 `[30,46)` |
| 3 | `isLocked` = 首字节 bit0 | `05` 帧实测为 `0x40`（bit6）；bit0 是广播明文的编码 |
| 4 | 广播名（`INBLUE`/`GKUI`）参与设备匹配 | 原 App 只查厂商数据 |
| 5 | `cidpu` 是 4 字节、AES key 补零 | 需 16 字节，见 D-1 |
| 6 | `BroadcastParser` 用 `cidpu.utf8` 当 AES key | 应为 hex 解码（已修） |
| 7 | `broadcastRandom`（Tbox 码 `[17,25)`）用于 `01` 帧 | `01` 不含该字段（`TboxBroadcastCode` 已降级为诊断） |
| 8 | `InBluePairing` 的 HMAC-SHA256 流程是配对算法 | 配对只有 `0D`→`0E`，无 HMAC；该实现属 `GLBLEAuthSDK` 旧假设 |
| 9 | `05` 帧 19 字节是位图，可逐位解析 | 原 App 不解析；只有 `0x40` 有实测 |

---

## 八、代码内的等级标注约定

- 文件头注释含 `## 证据` 段落 → 至少 A/B；
- 常量旁写 `// 实测` → C；
- 含「推断」「假设」「待确认」字样 → D/E，调用方不得用于安全判断；
- `InBlueAuth.PlainOrder`、`VehicleStatus.decode*Byte` 属可切换/待验证项。

---

## 九、2026-10-24 清理后新增的「已移除」条目

以下内容已从代码中删除，仅在此留档，避免有人从 git 历史里翻出来后误用：

| 已删除 | 原假设 | 删除理由 |
|---|---|---|
| `DKSession` / `ExSession` / `ExMessages` / `ExVehicleState` / `VehicleKeys` | 原 App 走「五步 DK 协议」（`FE 01` 帧头 + CRC16） | 实测帧首字节即命令号，无 `FE` 头、无 CRC |
| `DKTuning` / `TuningStore` / `InBlueTuning` / `CommandSequencer` | 协议参数需要真机调参 | 参数已由反汇编定死，无调参空间 |
| `InBluePairing` 的 `calculateResponse` / `buildResponseMessage` / `makeResponseFrame` | 配对需 HMAC-SHA256 挑战响应 | InBlue 配对只有 `0D→0E`，无挑战 |
| 诊断页 10 个调参项（ID 2/3/4/5、CRC 覆盖/配置） | 同上 | 对当前链路无效 |
| `TboxBroadcastCode` 参与 `01` 帧 | `01` 第一段是 `broadcastRandom` | `01` 是 AES 两段，不含该字段（文件保留但已移出主链路） |

---

## 十、2026-10-24 晚：命令号定案（推翻此前 D 级判定）

### 10.1 由 D/E 升为 A 的条目

| 项 | 原等级 | 现等级 | 新证据 |
|---|---|---|---|
| 锁车命令号 `0x01` | D（误记为 `0x02`） | **A** | `0xa120: mov w2,#1` + 抓包 idx99 |
| 解锁命令号 `0x02` | D（误记为 `0x0C`） | **A** | `0xa164: mov w2,#2` + 抓包 idx104 |
| 后备箱 `0x03` | E（无值） | **A** | `0xa1a8: mov w2,#3` |
| 关窗 `0x04` | E | **A** | `0xa1ec: mov w2,#4` |
| 开窗 `0x05` | E | **A** | `0xa230: mov w2,#5` |
| 寻车 `0x06` | E | **A** | `0xa274: mov w2,#6` |
| 设备名册 `0x0D` | D | **A** | `0xa338: mov w2,#0xd` |
| 无感进入开 `0x11` | D | **A** | `0xa404: mov w2,#0x11` |
| 无感进入关 `0x12` | D | **A** | `0xa3c0: mov w2,#0x12` |
| 配对 `0x55` | A | **A** | `0xa37c: mov w2,#0x55` |
| `03` 末字节 = command | B | **A** | `@0x13904` 的 `strb w23` + 帧长 18 自洽 |
| `0x0C` = RSSI 校准 | 误记为"解锁" | **A** | `@0x4880` 转发 `[device startCalibration]` |
| `04` 非零 → 699 拒绝 | — | **A** | `checkResultMessage:` @`0x107d4` |
| `05` 不解析 | C | **A** | `case 5:` 只有 NSLog |

### 10.2 新增的作废清单

| 已作废结论 | 曾出现在 | 推翻依据 |
|---|---|---|
| `03` 帧控制码 `0x02` = 锁车 | 第 18.4 / 19.2.1 节 | 抓包 `0x02` 后状态才改变 → 是解锁 |
| `03` 帧控制码 `0x0C` = 解锁 | 同上 | `0x0C` 是 `startCalibration`，51 次定时 |
| `05` 首字节 `0x40` = 已锁 | 第 19.2.1 节 | `05` 原 App 不解析，任何断言均无据 |
| `IBVehicle` 命令号 ≠ `03` 控制码 | `ProtocolConstants.swift` 旧注释 | `@0x13904` 直接 append 同一字节 |

### 10.3 仍需实测但**不影响功能**的项

| 项 | 等级 | 影响 |
|---|---|---|
| `01` 明文五段顺序 | D | 有 2 候选自动探测，装车首连自适应 |
| `cidpu` = 密钥帧 `[46,62)` | D | 错则扫描判为"其他车"，不影响已配对控车 |
| 被动进入自动命令的具体动作 | D | 已实现但默认关闭，用户可关 |

---

## 十一、2026-10-24 20:10：两项 D 级升 A，一项作废

### 11.1 升级

| 项 | 原等级 | 现等级 | 证据 |
|---|---|---|---|
| `01` 明文顺序 sd→ed→RndTRx→RND1→rights | D（ABI 歧义） | **A** | `requestParametersforCidpu:` @`0x11bec`：`0x11ddc CFSTR "%@%@%@%@%@"` + 栈参数 `0x11dd0/0x11dcc/0x11dc8` |
| `cidpu` = 密钥帧 `[46,62)` | D（键名未取到） | **A** | `saveKeysData:` @`0x129f4` 的 `setObject:forKey:`，key = `hexString(subdataWithRange:(0x2E,0x10))` |

### 11.2 作废

| 已作废 | 曾写在哪 | 推翻依据 |
|---|---|---|
| `0x0C` = `startCalibration`（RSSI 校准） | 第 20.2 节初版 | `openConnectionWithPassiveStart` @`0xb5a8`：`0xb684 mov w2,#0xc` + CFSTR `"send prehauthentification command to cidpu : %@"` |
| `01` 明文有 2 个候选顺序、需运行时探测 | `MeasuredSession.orderCandidates` | 原 App 只有一种顺序，且无重试逻辑 |
| RSSI 距离 = `(r/10)²` 之和 | `PassiveStart.distanceSquared` | `0xad98/0xae9c ___exp10`、`0xaea8 fsqrt` |

### 11.3 新增的「缺失」登记

| 项 | 原因 |
|---|---|
| `calibration` / `leaveOffset` 取值来源 | `0xb02c sub w8,w22,w0` 只给出"用二者之差"，写入点未追出 |
| 该比较中 `w25` 的来源 | 上游整数运算链未追完 |
| 被动启动成功后车端动作 | App 内无实现（`launchPassiveEntryCommands` 只发 `0x0C`） |

### 11.4 代码侧的对应清理

- 删除 `MeasuredSession.orderCandidates` / `advancePlainOrder` / `persistOrderIfNeeded`
- 删除 `InBlueAuth.PlainOrder` 的第二个 case
- 删除 `AppModel` 里"换顺序重发"的超时分支（保留纯超时提示）
- 诊断页的"顺序切换 Picker"改为只读文本
- `PassiveEntryController`（自造的"自动解锁 + 28s 校准"）整体删除，
  替换为 `PreAuthenticationController`（只发 `0x0C`，6.5s / 29.0s）
