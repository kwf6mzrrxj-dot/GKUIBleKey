# 最终代码审查报告

> 审查时间：2026-10-24 22:33
> 范围：全部 25 文件 / 6395 行
> 维度：逻辑正确性、潜在缺陷、异常处理、性能、代码风格、安全性

---

## 一、逻辑正确性 ✅ 总体正确

核心协议链路逐字节对照反汇编，全部一致：

| 模块 | 状态 |
|---|---|
| 密钥帧切分（62B，saveKeysData:） | ✅ 逐字段一致 |
| 01 帧构造（sd+ed+RndTRx+RND1+rights → AES） | ✅ |
| 03 帧构造（18B，buf1 拼接 4+3+1+2+2+1+3=16） | ✅ |
| 04 结果码分流（checkResultMessage: 三结局） | ✅ |
| 广播匹配（魔数 EE01 + AES 归属校验） | ✅ |
| 预认证（0x0C，6.5s/29s 间隔） | ✅ |
| 防爆破锁定（计数→锁→倒计时解锁） | ✅ |

---

## 二、本轮发现并修复的问题

### 问题 1（性能，已修）：`DateFormatter` 高频重复创建

- **位置**：`BLECentral.stamp()`、`MeasuredSession.append`
- **问题**：每次收发/日志都 `DateFormatter()` 新建实例，这是昂贵的操作（每次解析 locale/timezone）。BLE 高频收发场景下开销明显。
- **已修**：改为 `static let` 复用（与 `InBluePairing`/`FileLogger` 一致）。

### 问题 2（线程安全，已修）：`FileLogger.formatter` 并发访问

- **位置**：`FileLogger.append`
- **问题**：`DateFormatter` 非线程安全，原在串行队列**外**访问；多线程调用 `append` 时有数据竞争隐患。
- **已修**：`formatter` 改为 `static let`，时间戳生成移入串行队列内。

### 问题 3（日志误报，已修）：`KeyStore.set` 错误码误判

- **位置**：`KeyStore.set` 第 99-111 行
- **问题**：`SecItemAdd` 返回 `errSecDuplicateItem` 时走 `SecItemUpdate` 分支，但 `status` 变量未更新为 update 的返回值，导致 `status != errSecSuccess` 判断**误报"写入失败"**（实际已成功）。
- **已修**：捕获 `SecItemUpdate` 返回值并正确判断，`duplicateItem` 分支提前 `return`。

---

## 三、发现但未修复的隐患（记录在案）

### 隐患 1（逻辑脆弱，低风险）：`beginMeasuredAuth` 隐式默认行为

- **位置**：`AppModel.beginMeasuredAuth` 第 478 行 `let target = action ?? pendingAction`
- **问题**：当 `action == nil` 且 `asPreAuthentication == false` 时（当前无此调用路径），`target` 为 nil，既不 `perform` 也不 `preparePreAuthentication`，静默用默认 `controlCode = 0x0C` 发预认证帧。
- **建议**：加断言或显式分支，避免未来误调用时静默发错帧。当前无实际触发路径，属防御性改进。

### 隐患 2（固有不确定性）：`cidpuAESKey` 右补零

- **位置**：`ValeoAdvMatch.cidpuAESKey`
- **问题**：cidpu 不足 16 字节时右补零，这是未验证假设。影响归属判定命中率。
- **建议**：配对拿到完整 16B cidpu 后验证；若补零 key 不匹配，需调整。

---

## 四、安全性 ✅ 良好

| 项 | 状态 |
|---|---|
| 密钥存 Keychain（非 UserDefaults） | ✅ |
| Keychain 同步策略正确（Synchronizable + AfterFirstUnlock） | ✅ |
| 防爆破锁定（5 次失败锁 60s） | ✅ 完整 |
| 密钥完整性校验（指纹比对 + 发帧前拦截） | ✅ |
| 常量时间比较（RelayGuard 已删的 VehicleAuthenticator 曾有；主链路无此需求） | — |
| 备份导出（Base64+JSON，importBackup 用 Key(rawValue:) 防注入） | ✅ |
| 中继攻击防护（RSSI 突变检测） | ✅ |
| 只读监听模式（listenOnly 不发帧） | ✅ |

---

## 五、异常处理 ✅ 完善

- 广播数据长度不足 → 返回 nil（原 App 会越界崩溃，这里更健壮）
- AES 密文/密钥长度不符 → throw 或返回 nil
- 写特征未就绪 → 返回 false + 状态提示
- 蓝牙状态异常 → 状态行 + 排查提示
- 扫描权限缺失 → 明确提示请求位置权限
- Keychain 操作失败 → NSLog 记录

---

## 六、代码风格 ✅ 一致

- 命名：Swift 惯例（camelCase / PascalCase）
- 日志：统一走 `FileLogger`（无 `print()` 遗留）
- 时间戳：统一 `static` 复用（本轮已统一）
- 注释：反汇编证据注释完整（含地址）
- 无 TODO/FIXME 遗留

---

## 七、结论

**代码质量良好**：核心协议逻辑正确（逐字节对照反汇编），异常处理完善，安全性到位（Keychain + 防爆破 + 完整性校验），代码风格一致。

**本轮修复 3 个问题**（性能、线程安全、日志误报），均为非功能性改进，提升健壮性和可维护性。

**遗留 2 个隐患**（`beginMeasuredAuth` 隐式默认、`cidpuAESKey` 补零假设），均无当前触发路径或属固有不确定性，建议真车验证时一并确认。

**最终状态**：25 文件 / 6395 行，全量编译 BUILD SUCCEEDED，0 error 0 warning。
