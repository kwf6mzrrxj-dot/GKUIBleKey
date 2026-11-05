import Foundation

/// 手机 → 手表的同步载荷。
///
/// ## 为什么单独一层
///
/// 手表端重构后不再有蓝牙协议栈，它需要的东西只有两类：
///
/// 1. **账号**（手机号 / VIN / 密码 MD5 / token）—— 否则它没法以同一账号调云端
/// 2. **车况快照** —— 让手表一抬腕就有内容，不必等一次网络往返
///
/// 两类都必须是 `Codable`：`WCSession` 的 `applicationContext` / `userInfo`
/// 只接受属性列表类型，`Data` 是最省事的载体。
///
/// ## 为什么不用 App Group / iCloud Keychain
///
/// - App Group：watchOS 与 iOS 是**两个独立 App**，共享容器要把数据落盘再同步，
///   反而比 `WCSession` 多一层时序问题
/// - iCloud Keychain：同步延迟不可控（几分钟到几小时），且手表拿不到"最新一次"的语义
///
/// `WCSession` 是 Apple 给这一对 App 的官方通道，`updateApplicationContext`
/// 天然是「最新一份覆盖上一份」的语义 —— 正好是车况要的。
struct CloudAccountPayload: Codable, Sendable {
    var phone: String
    var vin: String
    var userId: String
    var clientId: String
    /// 密码的 MD5（服务端就收这个）
    var passMD5: String
    var accessToken: String?
    var refreshToken: String?
    var tokenExpiry: Date?
    var sentAt: Date

    init(phone: String, vin: String, userId: String, clientId: String,
                passMD5: String, accessToken: String?, refreshToken: String?,
                tokenExpiry: Date?, sentAt: Date = Date()) {
        self.phone = phone
        self.vin = vin
        self.userId = userId
        self.clientId = clientId
        self.passMD5 = passMD5
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenExpiry = tokenExpiry
        self.sentAt = sentAt
    }

    /// 手机号脱敏（138****8000）—— 手表屏幕小，完整号码也没用。
    ///
    /// 2026-11-04 第二轮审查 L7：原来按"正好 11 位"判断，其它长度直接返回原文 ——
    /// 一旦手机号带 `+86` 或空格，就会把完整号码显示在手表上。
    /// 现在按数字位数判断，够长就打码，不够长也不暴露。
    var maskedPhone: String {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 7 else { return phone.isEmpty ? "" : "已登录" }
        return String(digits.prefix(3)) + "****" + String(digits.suffix(4))
    }
}

/// 车况快照的传输形态。
///
/// ## 为什么要单独一层，而不是直接让 `VehicleSnapshot: Codable`
///
/// 真实原因是**两端要的东西不一样**：
///
/// - 手机端的 `VehicleSnapshot` 会跟着 UI 需求长（加一个"充电中"、加一个"座椅加热"），
///   这些字段手表未必需要，而 `Codable` 自动合成会把它们全部塞进同步载荷；
/// - 手表屏幕只有 40mm，多一个字段就多一份解码风险 —— 一旦某个字段类型变了
///   （比如 `Int` 改 `Double`），`JSONDecoder` 会整体失败，手表拿到的是"什么都没有"。
///
/// 显式映射把"跨端协议"和"本地 UI 类型"解耦：手机加字段不影响协议，
/// 手表只解它认识的那几个。
///
/// ⚠️ 代价是两边都要改。这一点上一版注释写反了（原文说"免得加字段时忘了改协议"，
/// 但显式映射恰恰**要求**两处都改）。真正的保障是：这里字段少、改动时需要
/// 明确决定"要不要同步过去"，比自动合成更可控。
struct CloudSnapshotPayload: Codable, Sendable {
    var isLocked: Bool?
    var isDoorsClosed: Bool?
    var isTrunkClosed: Bool?
    var isEngineRunning: Bool?
    var doorClosed: [Bool]?
    var isWindowsKnown: Bool
    var isWindowsClosed: Bool?
    var isSunroofOpen: Bool?
    /// 远程空调是否开着（`climateStatus.preClimateActive`）
    var acOn: Bool?
    /// 手机端设定的空调温度 —— 手表开空调时用它，避免两边各设一个
    var acTemperature: Int?
    var updatedAt: Date

    init(isLocked: Bool?, isDoorsClosed: Bool?, isTrunkClosed: Bool?,
                isEngineRunning: Bool?, doorClosed: [Bool]?,
                isWindowsKnown: Bool, isWindowsClosed: Bool?,
                isSunroofOpen: Bool?, acOn: Bool?, acTemperature: Int? = nil,
                updatedAt: Date) {
        self.isLocked = isLocked
        self.isDoorsClosed = isDoorsClosed
        self.isTrunkClosed = isTrunkClosed
        self.isEngineRunning = isEngineRunning
        self.doorClosed = doorClosed
        self.isWindowsKnown = isWindowsKnown
        self.isWindowsClosed = isWindowsClosed
        self.isSunroofOpen = isSunroofOpen
        self.acOn = acOn
        self.acTemperature = acTemperature
        self.updatedAt = updatedAt
    }

    init(snapshot: VehicleSnapshot, acOn: Bool?, acTemperature: Int? = nil) {
        self.init(isLocked: snapshot.isLocked,
                  isDoorsClosed: snapshot.isDoorsClosed,
                  isTrunkClosed: snapshot.isTrunkClosed,
                  isEngineRunning: snapshot.isEngineRunning,
                  doorClosed: snapshot.doorClosed,
                  isWindowsKnown: snapshot.isWindowsKnown,
                  isWindowsClosed: snapshot.isWindowsClosed,
                  isSunroofOpen: snapshot.isSunroofOpen,
                  acOn: acOn,
                  acTemperature: acTemperature,
                  updatedAt: snapshot.updatedAt)
    }

    /// 还原成 UI 用的快照
    var snapshot: VehicleSnapshot {
        VehicleSnapshot(isLocked: isLocked,
                        isTrunkClosed: isTrunkClosed,
                        isDoorsClosed: isDoorsClosed,
                        isEngineRunning: isEngineRunning,
                        doorClosed: doorClosed,
                        isWindowsKnown: isWindowsKnown,
                        isWindowsClosed: isWindowsClosed,
                        isSunroofOpen: isSunroofOpen,
                        updatedAt: updatedAt)
    }
}

/// 两端约定的 key —— 写死字符串容易拼错，集中在这里
enum CloudSyncKey {
    static let account = "cloud.account"
    static let snapshot = "cloud.snapshot"
}
