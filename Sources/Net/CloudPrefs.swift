import Foundation

/// 云端相关的本地偏好，key 集中在这里。
///
/// 之前空调温度的 key `"gkuicloud.acTemperature"` 硬编码在两个文件里
/// （`RootView` 的 `@AppStorage` 和 `AppModel+Cloud` 的 `UserDefaults`）——
/// 改 key 要改两处，漏一处就静默不同步：界面上选 24°，同步给手表的还是 22°。
enum CloudPrefs {

    /// 上次设定的空调温度（摄氏度）
    static let acTemperature = "gkuicloud.acTemperature"

    /// 没设过时的默认温度
    static let defaultACTemperature = 22

    /// 读当前设置（给非 SwiftUI 的调用方用）
    static var currentACTemperature: Int {
        UserDefaults.standard.object(forKey: acTemperature) as? Int ?? defaultACTemperature
    }
}
