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
/// 这解释了用户实测的关键现象：**同一份原厂 App 在 iOS 26 稳定、
/// 在 iOS 27 抽奖** —— 差别不在 App，在系统给不给后台 BLE 权限。
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

        public init(
            isLocked: Bool? = nil,
            isConnected: Bool = false,
            lastPreAuthAt: Date? = nil,
            statusText: String = "待机"
        ) {
            self.isLocked = isLocked
            self.isConnected = isConnected
            self.lastPreAuthAt = lastPreAuthAt
            self.statusText = statusText
        }
    }

    /// 静态部分：整个活动期间不变
    public var vehicleName: String

    public init(vehicleName: String) {
        self.vehicleName = vehicleName
    }
}
