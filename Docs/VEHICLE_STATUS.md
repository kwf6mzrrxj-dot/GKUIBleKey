# 车辆状态：纠正「05 帧只 NSLog」的错误结论

## 背景

之前多轮错误地认为「车辆状态走 TSP、BLE 的 `05` 帧只 NSLog 不解析」。
用户明确指出：**原 App 蓝牙车控里会显示门锁、后备箱、上电、启动等状态**。
重新用反汇编核实后，确认之前的结论是错的。

## 反汇编权威证据

### 状态解析入口：`parseBroadcastData:` @`0x4bc0`（IBDevice）

```asm
0x4bec: cidpu getter              ; 取 cidpu
0x4c18: stringToData:             ; cidpu hex → 16B（AES key）
0x4c38: decryptData:withKey:      ; VSSecurity AES-CBC / IV=0 解密
0x4c7c: subdataWithRange:(0,4)    ; → _randomNumber
0x4cbc: subdataWithRange:(4,1)    ; → parseStatus:（状态字节）
0x4d44: parseDoorsStatus:         ; plain[6] 四门
0x4d80: parsePowerStatus:         ; plain[7] 电源
```

解密结果 16 字节，切分：
`randomNumber[0,4) + status[4] + oemID[5] + doors[6] + power[7] + additional[8,16)`

### `parseStatus:` @`0x4de4` —— 8 个字段

| loc | ivar | 含义 |
|---|---|---|
| 7 | `_isLocked` | 门锁 |
| 6 | `_isDoorClosed` | 车门 |
| 5 | `_isTruckLocked` | 后备箱锁 |
| 4 | `_isTruckClosed` | 后备箱 |
| 3 | `_isIgnitionOn` | 上电（点火开关）|
| 2 | `_isEnginRunning` | 发动机运行 |
| 1 | `_isHoodClosed` | 引擎盖 |

### `parseDoorsStatus:` @`0x5274` —— 四门

| loc | ivar | 含义 |
|---|---|---|
| 7 | `_isFLDoorClosed` | 前左门 |
| 6 | `_isFRDoorClosed` | 前右门 |
| 5 | `_isRLDoorClosed` | 后左门 |
| 4 | `_isRRDoorClosed` | 后右门 |

### `parsePowerStatus:` @`0x517c` —— ACC

| loc | ivar | 含义 |
|---|---|---|
| 7 | `_isAccOn` | ACC 电源 |

### 位序：`hexToBinary:` @`0x112c0`

标准 hex→4 位二进制（`'0'→"0000"` … `'a'→"1010"`），**MSB 在前**。
因此 `substringWithRange:(7,1)` 取 8 位串末位 = **bit0（LSB）**，
`(6,1)` = bit1，依此类推。

## 代码改动

1. **`VehicleStatus`**：补全全部字段（8 状态 + 4 四门 + ACC + oemID + randomNumber + additionalData），
   新增 `init(decryptedPlain:)` 从解密明文构造完整状态；`decodeStatusByte` 补全 `isHoodClosed`/`reservedBit7`，
   修正 `isEngineRunning` 位（loc 2 → bit5）。
2. **`MeasuredSession`**：新增 `updateVehicleStatus(plain:)`，填充 `status` 字段。
3. **`BLECentral`**：新增 `onBroadcastStatus` 回调；`didDiscover` 里用 `adv.broadcastData`（Gen03 16B）
   + cidpu 解密，回调明文。
4. **`AppModel`**：接线 `onBroadcastStatus` → `measured.updateVehicleStatus`。
5. **UI**：车辆详情页新增「车辆状态」卡片，栅格展示门锁/车门/后备箱/上电/发动机/ACC + 全文明细。

## 清理

- 删除 `BroadcastParser.parse`（旧解密，数据源用完整厂商数据是错的）和 `describe`（切分未确认的旧诊断）。
- 删除 `BLECentral.parsedBroadcast` 字段（诊断遗留，已无引用）。
- 状态解密统一走 `VehicleStatus.decryptBroadcast`（正确的 broadcastData 16B + cidpu key）。

## 数据源（不再纠结抓包）

状态密文 = Gen03 广播的 `broadcastData = manufacturer[19..35)`（16B），
用 cidpu 作 AES key 解密。Gen02 的 `broadcastData` 只有 1B，无法解密（原 App 同样）。

## 验证

- `swiftc -typecheck`：0 error，25 文件 / 6576 行
- `xcodebuild build`：BUILD SUCCEEDED
