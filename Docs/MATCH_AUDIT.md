# 匹配流程深度审查报告

> 审查时间：2026-10-24 22:28
> 范围：广播匹配（ValeoAdvMatch）、广播解析（BroadcastParser）、扫描发现与连接衔接（BLECentral.didDiscover）
> 判定基准：原 App（GKUI/小卡）iOS 版反汇编为唯一权威

---

## 一、匹配算法正确性

### 1. 两级判定结构 ✅ 正确

原 App 分两道：**Valeo 设备判定**（魔数）→ **归属判定**（cryptedID AES）。代码完整还原：

```
isValeoDeviceWithAdvertisingData:  →  厂商数据前 2 字节 == EE 01
checkCryptedID:                    →  用 cidpu 做 AES，密文 [2..6) == 广播 tail4
```

### 2. 魔数与门槛 ✅ 逐字节一致

| 项 | 代码 | 反汇编 | 一致 |
|---|---|---|---|
| 魔数 | `EE 01` | `dataWithBytes:0x10808 length:2` | ✅ |
| 版本字节 | `raw[2] == 0x02 → Gen02` | `version==2 → Gen02` | ✅ |
| Gen02 门槛 | 23 | `cmp x0,#0x17` | ✅ |
| Gen03 门槛 | 19 | `cmp x0,#0x13` | ✅ |
| Gen03 扩展 | 36 | `cmp x0,#0x24` | ✅ |
| cryptedID 门槛 | 12 | `cmp x0,#0xc` | ✅ |

### 3. 归属校验 `isOwnVehicle` ✅ 算法正确

反汇编 `checkCryptedID:` @0x71dc + `checkCryptedID:withCidpu:random:` @0x13e20：
- 盐 `BC145356BAFE0028`（8 字节）✅
- `plain = head8 + 盐`（16 字节）✅
- `CCCrypt(encrypt, AES, key=cidpu)` ✅
- 比较 `enc[2..6) == tail4` ✅

---

## 二、发现的问题

### 问题 1（已修复）：`parseCidpu` 注释与代码不一致

- **位置**：`BroadcastParser.parseCidpu(from:)` 头注释
- **问题**：注释写「取后 14 个 hex = 7 字节」，但代码 `suffix(6)` 实际取**后 6 个 hex = 3 字节**
- **影响**：误导后续维护者（以为拿到 7 字节，实际 3 字节）
- **已修**：注释改为「取后 6 个 hex（3 字节）」

### 问题 2（未验证假设，保留）：`cidpuAESKey` 右补零

- **位置**：`ValeoAdvMatch.cidpuAESKey`
- **问题**：cidpu 不足 16 字节时**右补零**。这是注释明确标注的"未验证假设"——真正的 16 字节 cidpu 要等车端下发完整值（`KeyStore.cidpuFullHex`）
- **影响**：补零得到的 key 如果与车端真实 key 不符，`isOwnVehicle` 判定会**恒 false**（所有 Valeo 车都判成"其他车"）
- **建议**：这是「归属判定」的关键不确定性。当前车广播数据只有 19B（Gen03 短格式），`cryptedID` 只有 12B，归属判定能否命中取决于 cidpu 是否已从密钥帧 `[46,62)` 拿到完整 16B。**一旦配对成功拿到完整 cidpu，此假设即解除**。

### 问题 3（性能隐患）：AllowDuplicates=YES 高频回调

- **位置**：`BLECentral.startScan` / `startScanWithService`
- **问题**：`AllowDuplicatesKey: YES` 让 iOS 对同一设备的**每次广播都回调** `didDiscover`，设备持续广播时回调频率可达每秒数十次
- **影响**：
  1. `discoverCount` 快速膨胀（无意义）
  2. 每次回调都走 `FileLogger` 刷 3~5 行日志（广播名/厂商数据/cidpu/解密结果/ServiceData），日志文件快速增大
  3. `MainActor` 上频繁执行 `identify`（AES 加密）—— 虽然单次很快，但高频累积会占用主线程
- **建议**：
  1. 对同一设备做**时间节流**（如 500ms 内同一 identifier 只处理一次匹配）
  2. 日志降级：匹配命中/变化时才记日志，稳定重复的广播不刷屏
  3. `discoverCount` 改为「去重后的唯一设备数」，或单独计数

### 问题 4（代码冗余，非 bug）：`startScan` 与 `startScanWithService` 重复

- **位置**：`BLECentral.startScan`（339 行）vs `startScanWithService`（319 行）
- **问题**：两者现在都带 `[GATT.advServiceUUID]` + `AllowDuplicates`，**功能完全重复**
- **影响**：`startScanWithService` 是之前 `startScanDefault` 删除后的残留，`DeviceListView` 里还有个「扫描（指定服务）」按钮，用户看到两个一模一样的操作
- **建议**：合并为一个 `startScan`，删掉 `startScanWithService` 及其 UI 按钮

### 问题 5（衔接语义，需关注）：`identify` 的 RSSI 门限处理

- **位置**：`ValeoAdvMatch.identify` 第 227 行
- **现状**：`rssi <= -91` 时返回 `.valeoTarget`（仍标记 Valeo，但注释说"上层应按弱信号处理"）
- **衔接**：`BLECentral.didDiscover` 里 `weak = rssi <= -91`，`if hit && !weak` 才连接。逻辑自洽 ✅
- **但注意**：`identify` 内部判断 RSSI 后**没有提前返回**，继续走了 `isOwnVehicle`（AES）。弱信号时本可以跳过昂贵的 AES 判定。这是**轻微的性能浪费**（弱信号设备仍做 AES），非正确性问题。

---

## 三、边界与异常处理 ✅ 基本完善

| 场景 | 处理 | 评价 |
|---|---|---|
| 厂商数据 < 2B | `parse` 返回 nil | ✅ 防御（原 App 会越界崩溃） |
| 魔数不匹配 | 返回 nil → `.notValeo` | ✅ |
| 版本字节取不到（< 3B） | 返回 nil | ✅ |
| Gen02 < 23B / Gen03 < 19B | 返回 nil | ✅ |
| cryptedID < 12B | `isOwnVehicle` 返回 false | ✅ |
| cidpu 为空 | `.valeoTarget`（不判归属） | ✅ |
| AES 密文长度不足 | `enc.count > tail4+2` 保护 | ✅ 还原原 App 的 `cmp/b.ls` |
| cidpu 空 hex | `cidpuAESKey` 返回 nil | ✅ |

---

## 四、结论

**匹配流程整体正确**：两级判定、魔数/门槛、AES 归属校验都与原 App 反汇编一致，边界处理完善（甚至比原 App 更健壮，原 App 在短数据时会越界崩溃）。

**需要改进的（按优先级）**：
1. **【建议】性能节流**（问题 3）：AllowDuplicates 高频回调 + 每帧刷日志，建议加 500ms 去重节流
2. **【建议】合并重复扫描方法**（问题 4）：`startScanWithService` 与 `startScan` 重复
3. **【已修】注释错误**（问题 1）：`parseCidpu` 头注释
4. **【关注】cidpu 补零假设**（问题 2）：配对拿到完整 16B cidpu 后即可解除

其中 1、2 属于性能/代码整洁改进，不影响正确性；3 已修；4 是归属判定的固有不确定性，需真车配对后验证。
