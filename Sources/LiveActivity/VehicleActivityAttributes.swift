import Foundation
import ActivityKit

/// 数字钥匙的实时活动（Live Activity）数据模型。
///
/// ## 为什么需要它 —— 不是装饰，是后台蓝牙权限的开关
///
/// Apple Core Bluetooth 文档（iOS 26+）明确写：
///
/// > If your app has an instantiated `CBManager` and starts a Live Activity,
/// > it can use the **same privileges while in the background** that it uses
/// > when it is in the foreground. This means activities like scanning without
/// > providing service UUID's and **scanning with duplicates filter disabled**
/// > will be allowed while in the background.
///
/// 也就是说：**没有 Live Activity 时，iOS 在后台会合并广播投递**
/// （同一设备十几秒才报一次），`AllowDuplicates` 被忽略；
/// 有了它，后台扫描等同于前台 —— 广播 0.5 秒一帧，
/// 预认证的 29 秒节奏才可能真正跑准。
///
/// 用户实测过一个关键现象：同一份原厂 App 在 iOS 26 稳定、在 iOS 27 要试很多次。
/// 差别**可能**在"系统给不给后台 BLE 权限"，但也可能是 N1 芯片的连接退化 ——
/// 尚未确认，别把这条当成结论。
///
/// 无论如何，主动申请这份权限没有代价，所以照文档做。
public struct VehicleActivityAttributes: ActivityAttributes, Sendable {

    /// 动态部分：随每次状态变化更新
    public struct ContentState: Codable, Hashable, Sendable {
        /// 车锁状态（`nil` = 还没收到过广播状态）
        public var isLocked: Bool?
        /// **车辆是否在线**（不是 BLE 链路状态）
        ///
        /// 原 App 实测：链路每 30 秒才建立 0.6 秒（占空比 2%），
        /// 用「链路就绪」驱动锁屏卡片会让它跟着 29 秒抖一次。
        /// 沿用字段名 `isConnected` 是为了不破坏已存在的活动解码
        /// （`ContentState` 是 `Codable`，改键名会让进行中的活动解不出来）。
        public var isConnected: Bool
        /// 最近一次成功发出 `0x0C` 的时间
        public var lastPreAuthAt: Date?
        /// 一句话状态，直接显示在锁屏上
        public var statusText: String

        // ── 以下字段全部 optional，**追加安全**（2026-11-02）──────
        //
        // `ContentState` 是 `Codable`，进行中的活动里存着旧结构的 JSON。
        // 新增非可选字段会让旧数据解码失败 → 活动直接消失。
        // 所以一律给默认值 nil：缺字段 = "这一项没上报过"，界面显示「—」。

        /// 四门是否全关
        public var isDoorClosed: Bool?
        /// 后备箱是否关闭
        public var isTrunkClosed: Bool?
        /// 引擎是否在转
        public var isEngineRunning: Bool?
        /// ACC 是否开
        public var isAccOn: Bool?
        /// 是否已上电（点火档）
        public var isIgnitionOn: Bool?
        /// **这份状态是什么时候从车上收到的** —— 离线后它就是"最后一次上报"
        public var lastReportedAt: Date?

        public init(
            isLocked: Bool? = nil,
            isConnected: Bool = false,
            lastPreAuthAt: Date? = nil,
            statusText: String = "待机",
            isDoorClosed: Bool? = nil,
            isTrunkClosed: Bool? = nil,
            isEngineRunning: Bool? = nil,
            isAccOn: Bool? = nil,
            isIgnitionOn: Bool? = nil,
            lastReportedAt: Date? = nil
        ) {
            self.isLocked = isLocked
            self.isConnected = isConnected
            self.lastPreAuthAt = lastPreAuthAt
            self.statusText = statusText
            self.isDoorClosed = isDoorClosed
            self.isTrunkClosed = isTrunkClosed
            self.isEngineRunning = isEngineRunning
            self.isAccOn = isAccOn
            self.isIgnitionOn = isIgnitionOn
            self.lastReportedAt = lastReportedAt
        }
    }

    /// 静态部分：整个活动期间不变
    public var vehicleName: String

    public init(vehicleName: String) {
        self.vehicleName = vehicleName
    }
}
