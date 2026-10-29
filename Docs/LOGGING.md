# 日志系统（FileLogger）

- 版本：v2.1 起
- 实现：`Sources/Support/FileLogger.swift`
- 界面：`Sources/UI/LogView.swift`（级别过滤 + 导出）

---

## 1. 级别与使用场景

| 级别 | 数值 | 使用场景 | 默认是否落盘 |
|---|---|---|---|
| `debug` | 0 | 高频协议细节：TX/RX 帧字节、广播厂商数据、MTU、特征发现、分包、cidpu 解析、RSSI 匹配 | **是**（当前默认 `debug`，便于排障；量产建议调到 `info`） |
| `info` | 1 | 正常业务：连接/断开、配对开始/成功、动作执行结果、标定读取、设备名回执 | 是 |
| `warning` | 2 | 可恢复异常：RSSI 过低、标定缺失、订阅失败、协议乱序、UI 资源加载失败 | 是 |
| `error` | 3 | 需人工介入：密钥解析失败、鉴权自校验失败、写特征失败、命令超时（690）、非法命令 | 是 |

**取舍原则**：
- `debug` 面向**单次排障**（需要逐帧核对时才开），量大且含高频循环；
- `info` 面向**日常回溯**（"什么时候连上的、配对成没成"）；
- `warning` 面向**"还能继续但需注意"**；
- `error` 面向**"这条链路断了"**，且默认附带调用栈。

---

## 2. 统一格式

```
2026-10-25 20:31:49.123 [INFO ] [BLE] 收到 0x0E 密钥帧 ctx{cidpu=0191…9ad4 len=62}
2026-10-25 20:31:49.130 [ERROR] [DK] 构造 03 失败 ctx{reason=RND1 缺失}
  ⤷ 0   GKUIBleKey  0x0000000100a1b2c3 …
   1   GKUIBleKey  0x0000000100a1b450 …
```

| 字段 | 说明 |
|---|---|
| 时间戳 | `yyyy-MM-dd HH:mm:ss.SSS`（毫秒级，可与 HCI 抓包对齐） |
| 级别 | 固定 5 字符宽（`DEBUG` / `INFO ` / `WARN ` / `ERROR`），可按列 grep |
| 模块 | `BLE` / `DK` / `配对` / `TX` / `RX` / `广播` / `匹配` / `状态` / `UI` / `APP` |
| 消息 | 人类可读描述 |
| 上下文 | `ctx{k=v ...}`，按 key 字典序稳定输出 |
| 堆栈 | 仅 `error` 且 `includeStackForError=true` 时追加，最多 10 帧 |

---

## 3. 配置方式

### 3.1 代码

```swift
var cfg = FileLogger.shared.config
cfg.minimumLevel = .info            // 过滤阈值
cfg.maxFileBytes = 2 * 1024 * 1024  // 单文件 2MB
cfg.maxFiles = 5                    // 最多 5 份轮转文件
cfg.retentionDays = 7               // 保留 7 天
cfg.includeStackForError = true     // error 附堆栈
cfg.redactSensitive = true          // 敏感字段掩码
cfg.memoryCapacity = 300            // 实时浮窗保留行数
FileLogger.shared.config = cfg
```

### 3.2 UserDefaults（启动时由 `GKUIBleKeyApp.init()` 读取）

| key | 类型 | 示例 | 说明 |
|---|---|---|---|
| `gkuiblekey.log.level` | String | `"debug"` | `debug` / `info` / `warning` / `error` |
| `gkuiblekey.log.maxFileKB` | Int | `1024` | 单文件上限（KB） |
| `gkuiblekey.log.maxFiles` | Int | `5` | 轮转文件个数 |
| `gkuiblekey.log.retentionDays` | Int | `7` | 保留天数 |

写一次即可长期生效：

```bash
# 真机上通过 UserDefaults（需调试入口）或代码设置
UserDefaults.standard.set("debug", forKey: "gkuiblekey.log.level")
```

### 3.3 界面

「日志」页顶部新增 **落盘级别** 分段控件（DEBUG / INFO / WARN / ERROR）：
- 切换立即生效（`FileLogger.shared.config.minimumLevel`）
- 同时写入 `gkuiblekey.log.level`，下次启动保持
- 右上角 **导出** 按钮（`ShareLink`）可把全部轮转日志拼成文本分享出去

---

## 4. 轮转与保留

- 目录：`<沙盒>/Documents/Logs/`
- 文件：`gkuiblekey.log`（当前）、`gkuiblekey.1.log` … `gkuiblekey.N.log`
- 触发：当前文件 `> maxFileBytes` 时轮转，最旧一份删除
- 清理：每小时检查一次，删除 `mtime < now - retentionDays` 的文件
- 兜底：即使 `FileHandle` 打开失败，也会退化为「整文件追加」，不丢日志

---

## 5. 脱敏规则

`redactSensitive = true`（默认）时：

1. **消息体字段**：`Dk1=` / `sd=` / `ed=` / `RndTRx=` / `rights=` / `keyType=` / `CkTRxSP=`
   的值 → 掩码为 `前4…后4(len=N)`
2. **上下文字段**：key 名含 `dk1/cktrxsp/key/secret/token/password/idfv/auth/credential/private`
   的值 → 同样掩码
3. **不打码**：裸帧字节（`→ 01 09 …`）、cidpu、RSSI、时间戳

原因：帧字节是排障必需且不含长期密钥；真正的长期密钥是 `Dk1`/`CkTRxSP`，必须掩码。

---

## 6. 线程安全

| 资源 | 保护方式 |
|---|---|
| 文件写入 / 内存环形缓冲 / 轮转 | 单一串行队列 `com.mmxisme.gkuiblekey.filelog`（`qos: .utility`） |
| `config` 读写 | `NSLock`，持锁仅拷贝结构体，开销 < 1µs |
| `onNewLine` 回调 | 统一 `DispatchQueue.main.async` 派发 |

- `FileLogger` 声明为 `@unchecked Sendable`：所有可变状态都由上述队列/锁保护。
- 可从**任意线程、任意 actor**调用（含 `nonisolated` 的 BLE 回调、`Task` 并发域）。
- 级别过滤在**入队前**完成，低于阈值的调用不产生字符串、不排队。

---

## 7. 使用示例

```swift
// 高频协议细节（默认不落盘）
FileLogger.shared.debug("→ \(hex)", module: "TX")

// 业务流程节点
FileLogger.shared.info("配对成功", module: "DK", context: ["cidpu": cidpuHex])

// 可恢复异常
FileLogger.shared.warning("RSSI \(rssi) ≤ -91，原 App 会丢弃", module: "匹配")

// 需人工介入（自动附堆栈）
FileLogger.shared.error("构造 03 失败", module: "DK",
                        context: ["reason": "RND1 缺失"])

// 带 Error 对象
FileLogger.shared.error("订阅失败", module: "BLE", error: error)

// 兼容旧写法（等价 info）
FileLogger.shared.append(line, tag: "TX")
```

---

## 8. 已知限制

- `exportText()` 在主线程同步读文件；日志量很大（>20MB）时会有短暂卡顿，
  仅在用户主动点「导出」时触发。
- 实时浮窗只显示**首行**（多行堆栈不展开），避免把浮窗高度撑爆；
  完整堆栈在落盘文件里。
- 卸载 App 仍会清空沙盒（iOS 行为），更新时请勿卸载。
