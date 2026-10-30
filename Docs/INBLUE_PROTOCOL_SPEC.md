# InBlue / ValeoCoreCommunication 协议规格（反汇编权威版）

- 生成日期：2026-10-25（v1.9）
- 基线二进制：`XiaoKa.app` v1.5.11（iOS 版，显示名 GKUI）
  - `Frameworks/InBlue.framework/InBlue`（业务层：配对/鉴权/密钥/标定/RSSI）
  - `Frameworks/ValeoCoreCommunication.framework/ValeoCoreCommunication`（连接层：广播/扫描/连接/分包）
- 工具：`gkui_work/dk_re/ibd.py`、`dk_re/vcbd.py`（capstone arm64，打印 selref / CFSTR / 符号注释）
- 原则：**反汇编是唯一权威**；日志与抓包只作运行时佐证，不能反向否定反汇编。

> 本文覆盖 10 类运行时数据（帧 / 广播 / 连接时序 / bonding / 业务方法 /
> Keychain / UserDefaults / RSSI / 日志 / 生命周期-网络）的反汇编结论，
> 并标注本 App（GKUIBleKey）的对齐状态。

---

## 1. BLE 收发帧

### 1.1 帧结构
```
[0]      命令码 cmd
[1..n]   payload
```

### 1.2 消息分发（InBlue `IBMessageManager`）

`-[IBMessageManager analyzeMessage:]` @`0xfc64`：

```objc
cmd = data[0];
// 位掩码 0x4007 = bit0|bit1|bit2|bit14
if (cmd == 0x0E || (1 << cmd) & 0x4007) {   // 只接受 {0,1,2,14}
    if (isValidVehicle || lastPacket < cmd) {
        [self performActionBasedOnPayloadType:cmd andData:data];
    } else {
        // "Protocol failed. Message %d received before the message %d"
    }
} else {
    // 进入 isValidVehicle 检查分支
}
if (cmd <= lastPacket) {
    // "Protocol failed. Message %d received or the last message is %d or vehicle is not valid"
}
```

**关键**：`lastPacket` 是单调递增状态机；收到的 cmd 必须 **> `lastPacket`**（否则协议失败）。

### 1.3 动作分派 `performActionBasedOnPayloadType:andData:` @`0x10004`

| case | 行为 | 日志 |
|---|---|---|
| 2 | `setLastPacket:2` → `responseMessageWithData:`（生成 03 挑战应答） | `Message 2 received` |
| 4 | `setLastPacket:4` → `checkResultMessage:` | `Message 4 received` |
| 5 | （仅记录） | `Message 5 received` |
| 14 (0x0E) | `setLastPacket:0x0E` → `saveKeysData:` → `callDidPairingSuccess` | `Key received` |
| 15 (0x0F) | `setLastPacket:0x0F` → `parseDeviceNames:` → `callDidSendCommandSuccess` | `Message 15 received` |

### 1.4 挑战-应答（预认证/控车，**非配对**）

`-[IBMessageManager responseMessageWithData:]` @`0x104b4`：

```objc
if (![data isKindOfClass:NSData] || [data length] <= 0x10) {
    // ★ 长度 ≤16 直接判失败
    [device callDidSendCommandFailedWithMessage:@"Authentification is insufficient. Wrong challenge"
                                           code:0x278];
    return;
}
NSData *random = [data subdataWithRange:NSMakeRange(1, 16)];   // 跳过 cmd，取 16B
NSData *resp = [IBMessageFactory responseMessageWithCommand:cmd randomData:random cidpu:cidpu];
if (resp != nil) {
    [self setIsValidVehicle:1];
    [self setLastPacket:3];
    [self messageToSend:resp];   // 回 18 字节 03 帧
} else {
    [device callDidSendCommandFailedWithMessage:@"Authentification is insufficient. Wrong challenge"
                                           code:0x278];
}
```

`+[IBMessageFactory responseMessageWithCommand:randomData:cidpu:]` @`0x13904`：
构造 1 字节 cmd → `[VCLSManager calculateResponseforCidpu:randomData:command:]` →
拼成容量 `0x12`(18B) 的响应帧。

---

## 2. 广播（VCBAdvertisingData）

### 2.1 入口
`-[VCBAdvertisingData initWithAdvertisingDictionary:]` @`0xb6e4`：

```objc
self.isConnectable = [dict[@"kCBAdvDataIsConnectable"] boolValue];
self.txPower       = dict[@"kCBAdvDataTxPowerLevel"];
NSData *mfg        = dict[@"kCBAdvDataManufacturerData"];
self.isValeoDevice = [self isValeoDeviceWithAdvertisingData:mfg];
NSData *ver        = [mfg subdataWithRange:NSMakeRange(2, 1)];   // byte[2] = 协议版本
if ([ver isEqual:<0x02>]) [self parseAdvertisingGen02:mfg];
else                      [self parseAdvertisingGen03:mfg];
```

### 2.2 设备匹配 `isValeoDeviceWithAdvertisingData:` @`0xb960`
```objc
if (![data isKindOfClass:NSData] || [data length] < 2) return NO;
NSData *magic2 = [data subdataWithRange:NSMakeRange(0, 2)];
BOOL ok = [magic2 isEqualToData:<常量 2 字节>];   // ★ 魔数 = EE 01
if (ok) self.isValeoDevice = YES;
```

### 2.3 Gen02 字段（`parseAdvertisingGen02:` @`0xba8c`）

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0 | 2 | 魔数 `EE 01` |
| 2 | 1 | 协议版本（=0x02） |
| 3 | 1 | （antenna 输入，`setAntennaGen2WithData:`） |
| 4 | 2 | 保留字段 |
| 6 | 1 | 保留字段 |
| **7** | **16** | **cryptedID（AES 加密的车辆标识）** |

长度门槛：`cmp x0, #0x17`（≥23 才解析）。

### 2.4 Gen03 字段（`parseAdvertisingGen03:` @`0xbce8`）

| 偏移 | 长度 | 含义 |
|---|---|---|
| 0 | 2 | 魔数 `EE 01` |
| 2 | 1 | 协议版本（≠0x02） |
| 3 | 1 | antenna（`setAntennaGen3WithData:`） |
| 4 | 2 | 保留字段 |
| 6 | 1 | 保留字段 |
| **7** | **12** | **cryptedID** |
| 19 | 16 | broadcastData（扩展，门槛 `cmp #0x24` ≥36） |

### 2.5 antenna 解码（`setAntennaGen3WithData:` @`0xbecc`）
```asm
0xbf10: ldrb w8, [x20]
0xbf14: and  w8, w8, #0xf0      ; 取高 4 位
0xbf18: cmp  w8, #0x40
0xbf1c: b.eq → antenna = 2
0xbf20: cmp  w8, #0x80
0xbf24: b.ne → 未识别
        → antenna = 1
```
即 **高 4 位 `0x80` = 天线1，`0x40` = 天线2**（`addRSSI:` 据此分路）。

### 2.6 其他门槛
- cryptedID 最小长度：`checkCryptedID:` 要求 `cmp x0, #0xc`（≥12）
- RSSI 门槛：`ldr d0, #0x1fc10` = **−91.0**，`fcmp` 后 `b.le` 直接返回

---

## 3. 连接时序 + MTU / 分包

### 3.1 服务与特征
| UUID | 角色 |
|---|---|
| `F000FF10` | 主 Service |
| `F000FF11` | 写（属性 `0x0C`：write + writeWithoutResponse） |
| `F000FF12` | 通知（订阅） |

### 3.2 连接调用（VCBBluetoothManager `connectToDevice:` @`0x5cbc`）
```asm
0x5dd4: ldr x1, @selector(connectPeripheral:options:)
0x5dd8: mov x0, x20        ; centralManager
0x5ddc: mov x2, x22        ; peripheral
0x5de0: mov x3, #0         ; ★ options = nil（无任何连接选项）
```

### 3.3 连接前置条件（`VCBDevice connect` @`0x8de4`）
```objc
if (![self isConnectable]) → 失败
if ([self state] != 0)     → [delegate device:willNotConnectedWithError:]  // 必须断开态
```
日志："The device is not disconnected"。

### 3.4 分包（`VCBTransportProtocolManager splitData:withMTU:` @`0xdcac`）
```objc
NSUInteger count = ceil((len + 4) / mtu);
NSUInteger maxPayload = mtu - 4;          // ★ 每包数据量 = MTU − 4
// 首包：4 字节头（= 包数，小端 uint32）+ (mtu-4)B 数据 = 正好 mtu
// 后续：每包 mtu 字节数据
```
反汇编：`add x8,x0,#4` → `ucvtf`/`fdiv`/`fcvtpu` 求 ceil；
`sub x8,x20,#4` 得 payload；`str x23,[sp,#0x28]` 存包数 →
`dataWithBytes:&count length:4` 作首包头。

**GKUIBleKey 处理**：MTU 足够（实测 182，最大帧 62B）时保持「整帧直发、不加头」
（已验证车端可正常回 0x0E）；仅在 `len > mtu-4` 时启用分包并前置 4 字节包头。

---

## 4. Bonding（订阅 = 加密协商）

### 4.1 订阅触发
`-[VCBDevice subscriptionToNotification]` @`0x95e4`：
```objc
if ([readCharacteristic isNotifying]) {
    // "Subscription to notification is already done for the %@ device."
}
// 否则 setNotifyValue:YES
```

### 4.2 结果判定（`peripheral:didUpdateNotificationStateForCharacteristic:error:` @`0xab1c`）
```objc
if (error != nil) {
    // "Notification failed for %@ device with error : %@."  (level 1 = Debug)
    [delegate device:didSubcriptionFailedWithError:error];
} else {
    // "Notification updated for %@ device."
    ...
}
```

**判据**：`vcc.log` 里出现 `Notification updated for ... device.` = 订阅成功 = bonding 成功；
出现 `Notification failed for ...` 则 bonding 失败，后续不会发 0x0D。

### 4.3 订阅成功后才发首帧
`-[IBDevice deviceDidSubscriptionDoneWithSuccess:]` @`0x6138`：
```objc
NSLog(@"didSubscriptionDoneWithSuccess");
[logger writeMessage:@"Subcription done with success." withLevel:3];
if (success) {
    NSData *msg = [[IBMessageManager sharedManager] messageTosend];
    if (msg != nil) [[self device] sendData:msg];   // ★ 发 0x0D
}
```

---

## 5. 业务方法（配对链路完整规格）

### 5.1 触发链
```
-[IBVehicle startPairing] @0xa350
  → [device openConnexionForCommand:0x55]
```

### 5.2 `-[IBDevice openConnexionForCommand:]` @`0x4988`
```objc
if (![self.device isValid]) {
    [self callDidSendCommandFailedWithMessage:@"Vehicle is not valid to send a command"
                                         code:0x276];
    return;
}
[self setCommand:cmd];
[self.device setDelegate:self];
[[centralManager sharedManager] stopScan];
if (cmd == 0x55) {
    // ★ 30 秒配对超时定时器
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                  target:self
                                                selector:@selector(closeConnexionForCommand)
                                                userInfo:nil repeats:NO];
    [self setCommandTimeoutTimer:t];
} else {
    // 用 [device commandTimeout]
}
[self.device connect];
```

### 5.3 `-[IBMessageManager formatCommand:toDevice:]` @`0xfb48`
```objc
[self setDevice:device];
[self setCommand:cmd];
[self setIsValidVehicle:0];
NSString *cidpu = [device getCidpu];
if (cmd == 0x55) {
    // ★ 配对跳过 cidpu 检查
    [self generateFirstMessage:cidpu];
} else if (cidpu == nil) {
    [self.device callDidSendCommandFailedWithMessage:@"CIDPU is nil." code:0x276];
} else {
    [self generateFirstMessage:cidpu];
}
```

### 5.4 `-[IBMessageManager generateFirstMessage:]` @`0xff98`
```objc
if ([self command] == 0x55) [self generatePairingMessage];
else                        [self generateDerivationParametersMessage:cidpu];
```

### 5.5 `+[IBMessageFactory pairingMessage]` @`0x13afc` —— 0x0D 帧
```objc
NSData *sidpu = [[VCLSManager sharedManager] getSidpu];   // 16B 常量
NSMutableData *out = [NSMutableData dataWithCapacity:0x25];  // 37B
uint8_t cmd = 0x0D;  [out appendBytes:&cmd length:1];
[out appendData:sidpu];                                    // 16B
NSData *name = [[[UIDevice currentDevice] name] dataUsingEncoding:NSUTF8StringEncoding];
if ([name length] <= 0x13) {
    NSMutableData *padded = [name mutableCopy];
    [padded increaseLengthBy:(0x14 - name.length)];         // 零填充到 20B
    [out appendData:padded];
} else if ([name length] >= 0x15) {
    [out appendData:[name subdataWithRange:NSMakeRange(0, 0x14)]];  // 截断到 20B
} else {
    [out appendData:name];                                  // 正好 20B
}
```

**sidpu**（`-[VCLSManager getSidpu]` @`0x11a28`）：
```asm
adr x2, CFSTR "628f073114ec49c78097e189ce8d2f92"
bl  [IBNSString stringToData:]
```
→ 16 字节 `62 8F 07 31 14 EC 49 C7 80 97 E1 89 CE 8D 2F 92`

### 5.6 配对成功收尾
`-[IBDevice callDidPairingSuccess]` @`0x6d6c`：
```objc
[logger writeMessage:@"Pairing succeeed" withLevel:3];
IBVehicle *v = [[IBVehicleManager sharedManager] unpairedVehicleWithIBDevice:self];
if (v == nil) {
    [logger writeMessage:@"The unpaired vehicle doesn't exist"];
    return;
}
if ([v.delegate respondsToSelector:@selector(vehicleDidPairingSucceed:)]) {
    [v.delegate vehicleDidPairingSucceed:v];
}
[self disconnect];   // 见 5.7
```

### 5.7 `-[IBDevice disconnect]` @`0x6588` —— **名不副实，不断 BLE**
```objc
[self resetCommandTimeout];              // 取消 30s 定时器
VCBDevice *dev = [self device];
if (dev == nil) return;
[[IBManager sharedManager] startScan];   // 重新扫描
```

### 5.8 30 秒超时（失败路径）
`-[IBDevice closeConnexionForCommand]` @`0x62dc`：
```objc
[device state];
[didNeedReconnect ...];                  // 标记需重连
NSLog(@"Reconnect with cidpu: %@", cidpu);
// → 断开并重连
```

### 5.9 完整时序
```
startPairing
 → openConnexionForCommand:0x55（30s 定时器 + connect(options:nil)）
 → [连接] didConnectPeripheral
 → discoverServices(F000FF10)
 → discoverCharacteristics → setNotifyValue(FF12) + setWrite(FF11)
 → didUpdateNotificationState(error==nil)          ← bonding 完成
 → deviceDidSubscriptionDoneWithSuccess → sendData(messageTosend)
 → TX 0x0D (37B)
 → RX 0x0E (62B)
 → saveKeysData → callDidPairingSuccess
 → vehicleDidPairingSucceed: + disconnect(resetCommandTimeout + startScan)
```

### 5.10 配对的前置条件（**现场流程，不是反汇编推断**）

这一节是排障与移植（如 Apple Watch）时最容易被忽略的部分：
**BLE 链路上的 `0x0D → 0x0E` 只是整件事的后半段。**

| # | 前置条件 | 依据 |
|---|---|---|
| 1 | **诊断仪先登记一个手机槽位**（车端进入配对窗口） | `DEPLOY_TO_IPHONE.md`：「用诊断仪重新匹配一次，把本 App 作为一台新手机登记进蓝牙钥匙模块（**一车可挂 5 台，不用解绑原有的**）」 |
| 2 | 连接后走 **Passkey Entry（6 位码）** 完成 bonding | CHANGELOG v1.6：6 位码协商期间**不能 readRSSI**，否则诊断仪判「配对失败」 |
| 3 | 订阅成功（bonding 完成）后才发 `0x0D` | 5.9 时序：`didUpdateNotificationState(error==nil)` 在 TX 之前 |
| 4 | `0x0D` 的 **sidpu 是固定 16B 常量**，与手机身份无关；只有设备名来自 `UIDevice.name` | 5.5（`628f07…2f92`） |
| 5 | 车端回 `0x0E`（62B）→ 落 Keychain → **必须断开**，车端才判「配对完成」 | 5.6 / 5.7 / v1.5 |
| 6 | 每个槽位下发自己那份密钥（是否与手机上那份完全相同 —— **未验证**） | 推断，待实测 |

**推论（对手表/第二台设备）**：想让另一台设备控车，正确做法是**让它自己走一遍
「诊断仪窗口 → 6 位码 → 0x0D → 0x0E」**，而不是把手机的密钥拷过去。
拷过去能不能过车端校验，取决于车端是否把密钥与槽位/设备绑定 —— 未验证。

**手表端的两个未知**（真要移植时先验这两条）：
1. watchOS 的配对弹窗能不能输入 6 位码（Passkey Entry）；
2. 诊断仪登记槽位时，是否接受「一台手表」当作一台手机。

---

## 6. Keychain（IBKeyChainManager）

### 6.1 存储（`storeDictionary:toKeychainWithKey:` @`0x131b4`）
```objc
NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:dictionary];
[self deleteFromKeychainWithKey:key];          // 先删
SecItemAdd(@{ kSecClass:       kSecClassGenericPassword,
              kSecAttrService: key,
              kSecAttrAccount: key,
              kSecValueData:   archived }, NULL);
```

### 6.2 key 与内容
- `saveKeysData:` 传入 key = **`IBSavedKeys`**（`CFSTR` @`0x12a2c`）
- 字典结构：`{ "<cidpu32hex>" : { Dk1, sd, ed, RndTRx, rights, keyType, CkTRxSP } }`
- **7 个值全部为 hex 字符串**（小写、无分隔符），不是原始字节

### 6.3 读取 / 删除
- `dictionaryFromKeychainWithKey:` @`0x13338`
- `deleteFromKeychainWithKey:` @`0x1348c`

### 6.4 0x0E 字段切片（`saveKeysData:` @`0x12660`）

| 字段 | 偏移 | 长度 | 反汇编证据 |
|---|---|---|---|
| Dk1 | 1 | 16 | `0x12810 mov w2,#1` / `0x12814 mov w3,#0x10` |
| sd | 17 | 4 | `0x126c4 mov w2,#0x11` / `0x126c8 mov w3,#4` |
| ed | 21 | 4 | `0x1271c mov w2,#0x15` |
| RndTRx | 25 | **3** | `0x127c0 mov w2,#0x19` / `0x127c4 mov w3,#3` |
| rights | 28 | 1 | `0x12860 mov w2,#0x1c` |
| keyType | 29 | 1 | `0x128b0 mov w2,#0x1d` |
| CkTRxSP | 30 | 16 | `0x1276c mov w2,#0x1e` / `0x12770 mov w3,#0x10` |
| tail / cidpu | 46 | 16 | `0x129a4 mov w2,#0x2e` / `0x129ac mov w3,#0x10` |

`tail` 的 hex 字符串（32 字符）就是 `keysData` 的外层键（CIDPU）。

---

## 7. UserDefaults / 标定

- 标定值 key：`CFSTR "%@_CALIBRATION"`（`-[IBVehicle getCalibrationSavedValues]` @`0xb83c`）
  → 实际 key 形如 `<cidpu32hex>_CALIBRATION`，值为 `double`（实测 `-42.0089`）
- 清理：`-[IBVehicle clearCalibrationData]` @`0xb978`
- 完成判定：`-[IBVehicle isCalibrationDone]` @`0xbaf4`

---

## 8. RSSI

`-[IBVehicle addRSSI:]` @`0x8d38`：
```objc
// rssis 数组：最多 10 个（cmp x25, #0xa，超出 removeObjectAtIndex:0）
// rssiDates 数组：最多 3 个（cmp x24, #3）
```
- 被动启动判定：`-[IBVehicle checkRssiForPassiveStart]` @`0xac04`
- 门槛 −91.0（见 2.6）
- 天线分路：antenna 1/2 分别记录（见 2.5）

---

## 9. 日志

| 来源 | 方法 | 输出文件 |
|---|---|---|
| InBlue | `+[IBLoggerManager writeMessage:withLevel:forClass:]` @`0x136f0` | `gl.log` |
| VCC | `-[VCCLoggerManager writeMessage:withLevel:ofClass:]` | `vcc.log` |

`IBLoggerManager` 内部：`[sharedManagerWithName:@"gl"]` → `writeMessage:withLevel:ofClass:`。

日志级别（CocoaLumberjack）：`0=Verbose, 1=Debug, 2=Info, 3=Warn, 4=Error`。
实测：`"Pairing succeeed"` 用 3(Warn)，`"Subcription done with success."` 用 3(Warn)。

落盘目录：`<App容器>/Documents/valeo/logs/`。

---

## 10. 生命周期 / 页面 / 网络

- App 容器：`/var/mobile/Containers/Data/Application/<UUID>/`
- 日志：`Documents/valeo/logs/{gl,vcc}.log`
- UserDefaults：`Library/Preferences/cn.com.ecarx.xiaoka.plist`
- TSP 服务：`al_mp_servers = 47.101.29.75:443`（非硬编码域名，走配置）
- URL Scheme：配置在 `Info.plist` 的 `CFBundleURLTypes`
- **与 BLE 配对无关**：配对全程不依赖网络。

---

## 附录 A：本 App 对齐状态

| # | 数据类 | 状态 |
|---|---|---|
| 1 | 帧结构 / 命令码语义 | ✅ |
| 2 | 广播解析（魔数/Gen02/Gen03/antenna/RSSI 门槛） | ✅ |
| 3 | 连接时序 + 分包（MTU−4） | ✅（v1.9 补分包） |
| 4 | Bonding（订阅成功才发 0x0D） | ✅ |
| 5 | 配对链路（0x0D 37B / 0x0E 切片 / 收尾） | ✅ |
| 6 | Keychain（`IBSavedKeys` 归档字典） | ✅（v1.9 双写） |
| 7 | UserDefaults 标定 | ✅ |
| 8 | RSSI 滑动窗口 | ✅ |
| 9 | 日志 | ✅ |
| 10 | 生命周期 / 网络 | 不适用 |

## 附录 B：对"诊断仪判配对失败"的排障顺序

1. `vcc.log` 是否出现 `Notification updated for ... device.` → bonding 是否成功
2. 是否出现 `Key received` → 是否真收到 0x0E
3. 是否出现 `Pairing failed. Code : 690` → 是否 30s 超时
4. 6 位码弹窗是 **iOS 系统级 SMP Passkey**（`isValidCodeString:` 为死代码，
   主 App 无相关字符串），App 代码不参与；弹窗后必须完成输入/确认，bonding 才会保存
