# 配对流程重构：从 0x0D 直发改为 0x55 鉴权链

## 背景

之前多轮把「抓包只看到 `0x0D`、没有 `0x55`」当作依据，判定「`0x55` 非必需」，
配对走 `0x0D` 直发登记帧。这是**本末倒置** —— 原 App 反汇编才是唯一权威。

按原 App `InBlue.framework` 反汇编逐跳追查，确认了配对流程的真实实现。

## 反汇编权威证据（逐跳）

| 步骤 | 方法 | 地址 | 关键指令 |
|---|---|---|---|
| 入口 | `startPairing` | `0xa350` | `mov w2,#0x55` → `openConnexionForCommand:` |
| 连接 | `openConnexionForCommand:` | `0x4988` | `cmp w21,#0x55` → `closeConnexionForCommand` + 30s 超时 |
| 分派 | `formatCommand:toDevice:` | `0xfb48` | `cmp w21,#0x55` → `b.eq` **跳过 cidpu 检查** → `generateFirstMessage:` |
| 首帧 | `generateDerivationParametersMessage:` | `0xfe20` | → `derivationParametersMessageWithCidpu:`（= 01 帧） |
| 收密钥 | `performActionBasedOnPayloadType:` case 14 | `0x101b0` | `saveKeysData:` + `callDidPairingSuccess` |

完整时序：`01 → 02 → 03(末字节 0x55) → 0x0E(Key received) → saveKeysData + 配对成功`。

## 决定性发现：配对时 01 帧 = 全零占位

`requestParametersforCidpu:` @`0x11bec` **没有任何 nil 检查**，配对时 `keysData` 为空：

1. `objectForKey:cidpu` → nil
2. `[nil objectForKey:"sd"]` → nil（ObjC 对 nil 发消息返回 nil）
3. `stringWithFormat:@"%@%@%@%@%@"` → 得到一串 `"(null)"`
4. `stringToData:` @`0x111c0` 用 `strtoul(base=16)` 每 2 字符转 1 字节，
   `"("` 不是合法 hex → `strtoul` 返回 0 → 每个字段变 `0x00`
5. AES 密钥 `CkTRxSP` 也是 nil → 全零

**结论**：配对时 `01` 帧 = 全零 sd/ed/RndTRx/rights + 真实随机 RND1，用全零 CkTRxSP 加密。
车端识别「这是配对命令（0x55）」后**不校验密钥内容**，直接下发 `0x0E`。

## 代码改动

### 1. `InBlueAuth.buildPairingFirstMessage()`
新增配对占位帧构造：全零 sd(4)+ed(4)+RndTRx(3)+RND1(4 随机)+rights(1)，AES 密钥全零。

### 2. `MeasuredSession`
- 新增 `isPairing` 私有标志
- 新增 `preparePairing()`：设 `isPairing=true`、`pendingAction=.pairing`、`controlCode=0x55`
- `buildAuth1()`：`isPairing` 时走占位帧，否则原逻辑
- `buildAuth3()`：`isPairing` 时用全零 Dk1 派生临时密钥（车端不校验）
- `saveKeyData()`：成功切分密钥后复位 `isPairing=false`

### 3. `AppModel`
- `startFullPairing` 注释更新为 0x55 鉴权链
- linkState 就绪订阅：`sendPairingRequest()`（0x0D）→ `beginMeasuredAuthPairing()`（0x55 鉴权链）
- 新增 `beginMeasuredAuthPairing()`：`reset` → `preparePairing` → `buildAuth1` → `send`

### 4. `InBluePairing` 头部注释
澄清两条路径：`0x0D`（`generatePairingMessage` 登记帧）与 `0x55`（`startPairing` 鉴权链）。
`0x0D` 路径的 `buildPairingMessage` **保留**（原 App 真实存在，对应「重新登记」场景）。

## 保留的 `0x0D` 路径

`InBluePairing.buildPairingMessage` 现在无 UI 入口调用，但它是原 App
`generatePairingMessage` @`0xfecc` 的反汇编实现（"Sending message 13"），
按「不删原 App 逻辑」原则保留，用于未来可能的「重新登记」场景。

## 验证

- `swiftc -typecheck`：0 error，25 文件 / 6497 行
- `xcodebuild build`：**BUILD SUCCEEDED**
