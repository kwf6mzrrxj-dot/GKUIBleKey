import Foundation

/// 内置钥匙 —— 从 iOS 加密备份里提取出来的原 App 密钥。
///
/// ## 来源（可复现，不是猜的）
///
/// ```
/// Finder 加密备份 → keybag 解密 → keychain-backup.plist
///   → 条目 acct = "IBSavedKeys"（agrp = 585HK3P4W9.cn.com.ecarx.xiaoka）
///   → NSKeyedArchiver → { cidpu: { Dk1, sd, ed, RndTRx, rights, keyType, CkTRxSP } }
/// ```
///
/// 提取工具：`tools/decrypt_keychain.py`；条目写入时间 `cdat = 2026-10-28 13:12:48Z`
/// （= 北京时间 21:12:48），正是原 App 最后一次配对成功的时刻。
///
/// ## 为什么要把密钥内置
///
/// 本机 Keychain 里原有的那把是 **2026-10-04** 配对拿到的
/// （`Dk1 = 94a1d624…`），但车端从未真正把它写进槽位（诊断仪判「配对失败」）。
///
/// 结果就是：`CkTRxSP` 与有效钥匙相同 → `0x01` 帧能构造、能发出去 →
/// 但 `Dk1` 不同 → 车端验不过 → **拒绝并断链**（用户观察到的「连上秒断」）。
///
/// 内置这把 `Dk1 = 3c71e819…` 是车端确认有效的（原 App 现在能正常控车），
/// 用它可以把「协议实现是否正确」和「配对环节」彻底分开验证。
///
/// ## 写入的字段（必须和 `MeasuredSession.saveKeys` 一致）
///
/// 一共 11 项。少写任何一项都会在界面上显示成 `—`，其中
/// **`communicationKey` 缺失会让 `verifyKeyIntegrity` 报错**，
/// 因为它不是可选项 —— `saveKeys` 里它是 `CkTRxSP` 的兼容别名（双写）。
///
/// | Key | 值 | 说明 |
/// |---|---|---|
/// | `dk1` | `3c71e819…b077` | 设备密钥，**每把钥匙独立** |
/// | `sd` / `ed` | `9742355f` | 起止标识（车端级常量） |
/// | `rndTRx` | `0dc312` | 车端随机数 |
/// | `rights1` | `f0` | 权限位 |
/// | `keyType` | `00` | 钥匙类型 |
/// | `ckTRxSP` | `7156d3cd…7466e` | `0x01` 帧的 AES 密钥 |
/// | `communicationKey` | 同 `ckTRxSP` | 兼容别名，完整性校验用 |
/// | `keyTail` | `01918d11…9ad4` | 密钥帧 `[46,62)` = cidpu 原始 16 字节 |
/// | `core` | 合成 `0x0E` 帧 62B | 见 `composeKeyFrame()` |
/// | `pairedCIDPU` | `01918d11…9ad4`（hex 字符串） | 车辆标识 |
///
/// ## 安全边界（务必遵守）
///
/// - **只在本机使用**：这是这台车、这台设备的真实数字钥匙凭据。
///   **不要把本 App 分发给任何人**。
/// - **只写一次**：`applyIfNeeded()` 带 `UserDefaults` 标记，之后自己配对
///   成功拿到的密钥不会被覆盖。需要重新应用时点「密钥管理 → 重新应用内置钥匙」。
/// - **与原 App 是同一把钥匙**：两个 App 共用 `Dk1`，使用时要把原 App 彻底关掉，
///   否则两边同时往 FF11 写帧，车端收到的字节流会混。
public enum BuiltInKeys {

    // MARK: - 密钥材料（来自 Resources/builtin-keys.txt，**不入版本库**）

    /// 密钥存储（格式：每行 `key=value`，`#` 开头为注释）。
    ///
    /// ## ⚠️ 为什么不在代码里硬编码
    ///
    /// 这 7 个字段是**车端认可的真实凭据**（同一把钥匙能解锁、能点火）。
    /// 一旦写进源码提交，它会永久留在 Git 历史里 —— 即使之后删掉文件，
    /// 仍然能从历史提交里翻出来。所以改成运行时从资源文件读，
    /// 而该文件被 `.gitignore` 排除，仓库里只保留 `builtin-keys.example.txt`。
    ///
    /// 读不到时 `isConfigured == false`，写入逻辑整体跳过，
    /// 不影响「自己配对」这条正常路径。
    private static let seed: [String: String] = loadSeed()

    /// 是否配置了内置钥匙（`Resources/builtin-keys.txt` 存在且非空）
    public static var isConfigured: Bool { !seed.isEmpty }

    static var cidpuHex: String { seed["cidpu"] ?? "" }
    static var dk1Hex: String { seed["dk1"] ?? "" }
    static var sdHex: String { seed["sd"] ?? "" }
    static var edHex: String { seed["ed"] ?? "" }
    static var rndTRxHex: String { seed["rndTRx"] ?? "" }
    static var rightsHex: String { seed["rights"] ?? "" }
    static var keyTypeHex: String { seed["keyType"] ?? "" }
    static var ckTRxSPHex: String { seed["ckTRxSP"] ?? "" }

    /// 从 App Bundle 读取 `builtin-keys.txt`。
    ///
    /// 用 Bundle 资源而不是沙盒文件：`Resources/` 下的文件会被打进 .app，
    /// 重装不丢，也不需要额外的文件管理。
    private static func loadSeed() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "builtin-keys", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !v.isEmpty {
                out[String(k)] = String(v).lowercased()
            }
        }
        return out
    }


    /// 要写入的二进制度字段（顺序即 `0x0E` 帧的字段顺序，便于核对）
    private static var binaryFields: [(KeyStore.Key, String)] {
        [
            (.dk1, dk1Hex),
            (.sd, sdHex),
            (.ed, edHex),
            (.rndTRx, rndTRxHex),
            (.rights1, rightsHex),
            (.keyType, keyTypeHex),
            (.ckTRxSP, ckTRxSPHex),
            // ★ 必写：`saveKeys` 把它当作 `ckTRxSP` 的兼容别名双写，
            //   缺了 `verifyKeyIntegrity` 会报「缺少 communicationKey」。
            (.communicationKey, ckTRxSPHex),
            // 密钥帧 [46,62) 的 16 字节 = cidpu 原始字节
            (.keyTail, cidpuHex),
        ]
    }

    /// 合成完整 `0x0E` 密钥帧（62 字节）—— 存进 `.core`。
    ///
    /// 布局照 `+[IBMessageFactory …]` 的 `0x0E` 帧：
    /// `0E | Dk1(16) | sd(4) | ed(4) | RndTRx(3) | rights(1) | keyType(1) | CkTRxSP(16) | tail(16)`
    /// = 1 + 16 + 4 + 4 + 3 + 1 + 1 + 16 + 16 = **62**
    ///
    /// 目前没有任何代码读 `.core`（原 App 的遗留键），但保持与
    /// `MeasuredSession.saveKeys` 的存储形状一致，界面上也不会缺项。
    private static func composeKeyFrame() -> [UInt8] {
        var f: [UInt8] = [0x0E]
        f += FrameCodec.bytes(fromHex: dk1Hex)
        f += FrameCodec.bytes(fromHex: sdHex)
        f += FrameCodec.bytes(fromHex: edHex)
        f += FrameCodec.bytes(fromHex: rndTRxHex)
        f += FrameCodec.bytes(fromHex: rightsHex)
        f += FrameCodec.bytes(fromHex: keyTypeHex)
        f += FrameCodec.bytes(fromHex: ckTRxSPHex)
        f += FrameCodec.bytes(fromHex: cidpuHex)
        return f
    }

    // MARK: - 状态

    private static let appliedFlagKey = "builtInKeys.applied.20261029"

    /// 标记的值是**版本串**，不是 Bool。
    ///
    /// 原因：v3.2 第一版只写了 9 个字段（漏了 `communicationKey` / `core`），
    /// 但已经把标记置成了 `true`。如果这里只判 Bool，升级到修复版后
    /// `applyIfNeeded()` 会继续跳过 → 缺的字段永远补不上。
    ///
    /// 用版本串就能做到：v3.2 留下的 `true` 读成 nil ≠ `"v2"` → 自动重写一次；
    /// 之后写入 `"v2"` → 不再重复。
    private static let appliedVersion = "v2"

    /// Keychain 里 11 项是否齐全（用于界面提示与自查）
    public static var isComplete: Bool {
        let store = KeyStore.shared
        let allBinary = binaryFields.allSatisfy {
            (store.get($0.0)?.isEmpty == false)
        }
        return allBinary && store.getString(.pairedCIDPU) != nil
    }

    /// 当前 Keychain 里的 `dk1` 是否就是内置的这把。
    ///
    /// ⚠️ 必须读**二进制**再转 hex —— `KeyStore.getString(.dk1)` 会拿 16 字节
    /// 原始密钥去做 UTF-8 解码，必然返回 nil（v3.2 初次实现就踩了这个坑，
    /// 导致「点了应用内置钥匙却仍显示非内置」）。
    public static var isActive: Bool {
        guard let d = KeyStore.shared.get(.dk1), !d.isEmpty else { return false }
        return d.map { String(format: "%02x", $0) }.joined() == dk1Hex
    }

    // MARK: - 写入

    /// 首次启动时应用一次。已应用过（且版本匹配）则跳过。
    ///
    /// 不会覆盖之后自己配对成功拿到的密钥 —— 那时标记已是当前版本，
    /// 直接返回 `false`。
    ///
    /// - Returns: 是否真的写入成功（调用方据此决定要不要 `reloadKeys()`）
    @discardableResult
    public static func applyIfNeeded() -> Bool {
        if UserDefaults.standard.string(forKey: appliedFlagKey) == appliedVersion {
            return false
        }
        return apply()
    }

    /// 强制应用内置钥匙（会覆盖 Keychain 里现有的密钥）。
    ///
    /// 成功与否以**写完后读回 `dk1` 实际比对**为准，而不是写入条数 ——
    /// 这样按钮提示不会出现「说成功了但其实没写进去」。
    @discardableResult
    public static func apply() -> Bool {
        // ★ 没有密钥文件就什么都不做。
        //   这里必须挡在写 Keychain 之前：否则会把空值写进去、
        //   还会生成 1 字节的垃圾 `core` 帧，把已有的有效密钥**破坏掉**。
        guard isConfigured else {
            NSLog("[BuiltInKeys] 未配置内置钥匙（缺 Resources/builtin-keys.txt），跳过")
            return false
        }

        let store = KeyStore.shared

        for (key, hex) in binaryFields {
            let bytes = FrameCodec.bytes(fromHex: hex)
            guard !bytes.isEmpty else { continue }
            store.set(Data(bytes), for: key)
        }
        // pairedCIDPU 存的是 hex **字符串**（不是二进制），与 saveKeys 一致
        store.setString(cidpuHex, for: .pairedCIDPU)
        // core = 合成 62B 密钥帧
        store.set(Data(composeKeyFrame()), for: .core)

        guard isActive else { return false }
        UserDefaults.standard.set(appliedVersion, forKey: appliedFlagKey)
        return true
    }

    /// 清除「已应用」标记 —— 解绑车辆时**不**调用（见下方说明）。
    ///
    /// 解绑后应该是干净的无密钥状态，让用户能直接走自己的配对流程；
    /// 想改回内置钥匙，点「重新应用内置钥匙」按钮即可（`apply()` 不看标记）。
    public static func resetAppliedFlag() {
        UserDefaults.standard.removeObject(forKey: appliedFlagKey)
    }
}
