# InBlue 配对流程权威闭环（反汇编逐行还原）

> 还原时间：2026-10-25（v1.4）
> 判定基准：InBlue.framework 反汇编为唯一权威。
> 本文档纠正此前「配对 = 01→02→03 鉴权链」的**根本性错误**。

---

## 一、核心结论（一句话）

**配对不是挑战-响应鉴权链，而是「直发 0x0D 登记帧 → 收 0x0E 密钥」，中间没有任何 01/02/03 帧。**

此前把配对实现成「01 全零占位 → 02 挑战 → 03 自校验」，导致车端回 02 挑战、
03 自校验必失败（日志 `算出 F4 87... vs 期望 4C AC...`），是配对失败的根本原因。

---

## 二、发送侧：完整调用链

### 1. 入口 `startPairing` @0xa350（IBVehicle）
```
[self.device openConnexionForCommand:0x55]
```

### 2. `openConnexionForCommand:0x55` @0x4988（IBDevice）
```
[self device] → isValid 校验
setCommand: 0x55
setDelegate: self
stopScan
cmp #0x55 → 0x55 分支：
    closeConnexionForCommand      // 关旧连接
    scheduledTimer 30s → closeConnexionForCommand   // 30 秒超时
connect                          // 重新连接（触发 iOS 系统 LE 配对）
```
> `0x55` 在这里只是**命令类型标记**（用于 `cmp #0x55` 特判），
> **不是**发出去的消息字节。真正发的字节在下一步。

### 3. 连接成功 → `formatCommand:toDevice:` @0xfb48（IBMessageManager）
```objc
setDevice: device
setCommand: command
setIsValidVehicle: NO
cidpu = [device getCidpu]
if (command == 0x55 || cidpu != nil) {   // 0xfbec: cmp w21,#0x55 → b.eq
    [self generateFirstMessage: cidpu]
} else {
    [device callDidSendCommandFailedWithMessage:@"CIDPU is nil." code:0x276]
}
```
> **配对（0x55）跳过 cidpu 检查**（配对时还没有密钥）。

### 4. `generateFirstMessage:` @0xff98（IBMessageManager）
```objc
command = [self command]
if (command == 0x55) {                   // 0xffc4: cmp w0,#0x55
    [self generatePairingMessage]         // ★ 配对 → 0x0D 登记帧
} else {
    [self generateDerivationParametersMessage: cidpu]   // 普通命令 → 01 帧
}
```

### 5. `generatePairingMessage` @0xfecc（IBMessageManager）
```objc
message = [IBMessageFactory pairingMessage]
if (message == nil) {
    [device callDidPairingFailWithMessage:@"Cannot generate pairing message" code:0x277]
    return
}
setIsValidVehicle: YES
setLastPacket: 0x0D                       // 13
NSLog(@"Sending message 13")
[self messageToSend: message]
```

### 6. `+[IBMessageFactory pairingMessage]` @0x13afc（消息构造核心）

```
sidpu = getSidpu()                       // 16 字节固定常量
if (sidpu == nil) → "The sidpu is nil"  → 返回 nil

data = dataWithCapacity: 37
appendBytes: 0x0D (1 字节)               // 命令号
appendData: sidpu (16 字节)              // 固定常量
name = currentDevice.name UTF8 编码
// 设备名字段固定 20 字节（三分支）：
if (nameLen <= 19):  name 复制 + increaseLengthBy:(20-nameLen) 补零
if (nameLen == 20):  直接用
if (nameLen >= 21):  subdataWithRange:{0,20} 截断
appendData: 设备名(20 字节)

checkMessageLengthWithMessage:length:37
返回 37 字节消息
```

### 7. `getSidpu` @0x11a28（VCLSManager）
```objc
return [IBNSString stringToData:@"628f073114ec49c78097e189ce8d2f92"]  // 32 hex = 16 字节
```

### 配对消息最终格式（37 字节）
```
偏移  长度  内容
[0]    1   命令号 0x0D
[1]   16   sidpu = 628f073114ec49c78097e189ce8d2f92
[17]  20   设备名（UTF-8 + 零填充，或截断到 20）
```

---

## 三、接收侧：密钥闭环

### 8. 车端回 `0x0E` → `analyzeMessage:` → `performActionBasedOnPayloadType:andData:` case 14

### 9. `saveKeysData:` @0x12660（VCLSManager）—— 62 字节切分
```
偏移      长度  字段
[0x01,17) 16   Dk1
[0x11,21)  4   sd
[0x15,25)  4   ed
[0x19,28)  3   RndTRx
[0x1C,29)  1   rights
[0x1D,30)  1   keyType
[0x1E,46) 16   CkTRxSP
[0x2E,62) 16   tail（= CIDPU，hexString 后作 keysData 字典键）
```
> 帧含命令号 0x0E，总长 62 字节。`keysData[cidpu] = {Dk1, sd, ed, CkTRxSP, RndTRx, rights, keyType}`。

### 10. 配对成功回调
```
[device callDidPairingSuccess]   // 不需要回帧
```

---

## 四、与旧实现的差异（本次纠正）

| 环节 | 旧实现（错误） | 正确（反汇编） |
|------|--------------|--------------|
| 配对帧 | 01 全零占位鉴权帧（33B） | **0x0D 登记帧（37B）** |
| 消息内容 | 9零+RND1+3零，AES 全零加密 | **0x0D + sidpu + 设备名** |
| 后续交互 | 等 02 挑战 → 回 03 | **直接等 0x0E 密钥** |
| 自校验 | 03 帧 enc2[2..9]==challenge[9..16] | **无此环节** |

---

## 五、代码实现对照

| 环节 | 代码位置 | 状态 |
|------|---------|------|
| 配对帧构造 | `InBluePairing.buildPairingMessage` | ✅ 已改为 0x0D+sidpu+设备名20B |
| 发 0x0D | `AppModel.beginMeasuredAuthPairing` | ✅ 已改为发登记帧 |
| 收 0x0E | `AppModel.handlePairingFrame` + `MeasuredSession.handle(.keyData)` | ✅ 已实现 |
| 密钥切分 | `InBlueAuth.parseKeyFrame` | ✅ 与反汇编逐字段一致 |
| 落 Keychain | `MeasuredSession.saveKeyData` | ✅ 已实现 |
| 配对成功 | `MeasuredSession.saveKeyData` 后 UI 刷新 | ✅ 已实现 |

### 已清理的死代码（旧错误路线的产物）
- `MeasuredSession.preparePairing()` / `isPairing` 属性
- `MeasuredSession.buildAuth1()` / `buildAuth3()` 的 isPairing 分支
- `InBlueAuth.buildPairingFirstMessage()`

---

## 六、待真机验证的假设

1. sidpu 常量 `628f073114ec49c78097e189ce8d2f92` 是否对目标车型有效（反汇编权威，但车端固件版本可能有差异）。
2. 设备名字段是否严格 20 字节（反汇编明确，但车端可能按不同长度解析）。
3. 车端收到 0x0D 后是否直接回 0x0E（反汇编无中间帧，但可能有回显 0x0D）。
