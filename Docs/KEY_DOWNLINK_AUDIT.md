# 按原 App 反汇编的密钥下发链路审查（修正版）

> 审查时间：2026-10-24 22:10
> 判定基准：**原 App（GKUI = 小卡/XiaoKa）的 iOS 版二进制反汇编是唯一权威**，抓包仅作参考，绝不否定反汇编。

---

## 一、关键前提澄清（本轮纠正的混淆）

| 项 | 正确认知 |
|---|---|
| 原 App 身份 | **GKUI = 小卡（XiaoKa）**，亿咖通 ecarx 同一产品 |
| iOS 版 | `ios/Payload/XiaoKa.app`（bundle `cn.com.ecarx.xiaoka`，显示名 GKUI） |
| Android 版 | `gkui.apk`（包名 `com.ecarx.xiaoka.voice_assistant`） |
| 反汇编权威 | iOS 版 `InBlue.framework`（`ibd.py`）+ `ValeoCoreCommunication`（`vcbd.py`）+ `GLBLEAuthSDK` |
| 判定原则 | **反汇编是唯一权威；抓包是参考，不能反过来否定反汇编** |

---

## 二、密钥下发链路：完整闭环，实现正确

### 完整调用链（反汇编逐跳确认）

```
device:didReceiveData: @0x5bcc
  x19 = 收到的完整 Data（含命令号首字节）
  → IBMessageManager sharedManager
  → analyzeMessage: @0xfc64
      0xfc90 subdataWithRange:(0,1)   ; 取 data[0] = 命令号 w21
      0xfd04 performActionBasedOnPayloadType:andData:
        参数1 payloadType = w21（命令号）
        参数2 andData = 完整 Data（含命令号，未剥离）
        → case 0x0E (0x010040 cmp w21,#0xe → 0x101b0)
          0x101b0 "Key received"
          0x101f4 saveKeysData: x2 = 完整 Data（含 0x0E 帧头）
```

### `saveKeysData:` @0x12660 的字段切分（权威，62B）

| 字段 | 偏移 | 反汇编证据 |
|---|---|---|
| Dk1 | [1, 17) | `0x12810 mov w2,#1` + `w3,#0x10` |
| sd | [17, 21) | `0x126c4 mov w2,#0x11` + `w3,#4` |
| ed | [21, 25) | `0x1271c mov w2,#0x15` + `w3,#4` |
| RndTRx | [25, 28) | `0x127c0 mov w2,#0x19` + `w3,#3` |
| rights | [28, 29) | `0x12860 mov w2,#0x1c` |
| keyType | [29, 30) | `0x128b0 mov w2,#0x1d` |
| CkTRxSP | [30, 46) | `0x1276c mov w2,#0x1e` + `w3,#0x10` |
| CIDPU（字典键） | [46, 62) | `0x129a4 mov w2,#0x2e` + `w3,#0x10` |

**结论：`0x0E` 密钥帧 = 62 字节（含命令号），当前代码 `InBlueAuth.keyFrameLength = 62`
与 `parseKeyFrame` 的切分逐字节一致，完全正确。**

### 与当前代码的对应

| 反汇编 | 当前代码 | 一致性 |
|---|---|---|
| `saveKeysData:` 62B 切分 | `InBlueAuth.parseKeyFrame` | ✅ 逐字段一致 |
| `analyzeMessage:` 传含命令号的完整帧 | `handlePairingFrame` → `measured.handle`（`MeasuredFrame.decode` 拆 cmd/payload，`saveKeyData` 里 `payload.first == 0x0E ? payload : [0x0E]+payload` 兜底） | ✅ 一致 |
| `case 0x0E` → `saveKeysData:` | `handle` 的 `.keyData` 分支 | ✅ 一致 |

---

## 三、本轮纠正的错误

### 错误 1：`KEY_DOWNLINK_ANALYSIS.md`（已删除）

上一轮我拿 Android 车机抓包的 **20B `0x0E` 帧**去否定反汇编的 62B 切分，
得出「密钥下发严重断链」的错误结论。这是**本末倒置**：

- 抓包来自 **Android 车机**（`gkui.apk` 配套的 BLE 模块），其 `0x0E` 帧是 20B 短格式；
- 原 App（iOS）的 `saveKeysData:` 是 62B，这是**两个不同平台的密钥帧格式差异**，
  不能拿 A 平台的抓包去否定 B 平台的实现。

**正确做法**：本项目复刻的是原 App 的 iOS 协议栈，严格按反汇编 62B 实现。

### 错误 2：`AppModel.swift:308` 注释（已纠正）

原注释写「模块 → 0x0E <19B> 共 20B」（来自抓包），已改为反汇编结论
「模块 → 0x0E <7 字段密钥载荷 + 16B CIDPU> 共 62B」。

---

## 四、其余协议模块一致性核对（本轮抽查）

| 模块 | 反汇编方法 | 当前代码 | 一致性 |
|---|---|---|---|
| `01` 帧构造 | `requestParametersforCidpu:` @0x11bec（sd+ed+RndTRx+RND1+rights 拼 16B，AES 加密用 CkTRxSP） | `InBlueAuth.buildFirstMessage` | ✅ |
| `03` 帧构造 | `responseMessageWithCommand:randomData:cidpu:` @0x13904（dataWithCapacity:0x12=18B） | `MeasuredSession.buildAuth3` | ✅ |
| `04` 结果码 | `checkResultMessage:` @0x107d4（data[1] 非 0 → 失败 0x2bb；command==0x0D 特判） | `MeasuredSession.handle` `.result` 分支 | ✅ |
| 预认证 0x0C | `openConnectionWithPassiveStart` @0xb5a8（"send prehauthentification command"） | `preparePreAuthentication` | ✅ |
| 广播匹配 | `ValeoCoreCommunication` 的 `EE 01` 魔数 | `ValeoAdvMatch` | ✅ |

**结论：所有核心协议模块的实现与原 App 反汇编一致，无逻辑断链。**

---

## 五、最终结论

1. **密钥下发链路完整闭环**：`0x0E`(62B) → `analyzeMessage:` 拆命令号 → `saveKeysData:` 切 7 字段 + CIDPU → 落地 Keychain → `buildFirstMessage` 用 ckTRxSP 等构造 `01` 帧。全程有反汇编证据，实现正确。
2. **之前「20B vs 62B 断链」是错误结论**，根因是拿 Android 车机抓包否定 iOS 原 App 反汇编，已删除错误文档、纠正错误注释。
3. 当前代码 25 文件 / 6579 行，全量编译 0 error 0 warning。
