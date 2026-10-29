import Foundation

/// 车辆展示信息（爱称等）。
///
/// ## 为什么不做多车抽象
///
/// 本 App 只服务一台车（当前 cidpu 固定为 `01918d11…6ac89ad4`，
/// 密钥也只有一份）。所以爱称存在**一个全局 UserDefaults 键**里，
/// 不按 cidpu 分键 —— 按车分键只在「同一台手机管理多辆车」时才有意义。
///
/// 换车（重新配对另一台车）时密钥会被新的 `0x0E` 覆盖，
/// 爱称留在原处由用户手动改；这比猜一个默认值更不容易出错。
public enum VehicleProfile {

    /// UserDefaults 键（用 `@AppStorage` 读写，SwiftUI 会自动刷新）
    public static let nicknameKey = "vehicle.nickname"

    /// 默认爱称 —— 未设置时显示
    public static let defaultNickname = "爱车"

    /// 爱称最大长度。
    /// 主界面用小字显示（`.subheadline`），超过这个长度在 4.7 寸屏上会换行挤掉车图。
    public static let maxNicknameLength = 12

    /// 规范化用户输入。
    ///
    /// - 去掉首尾空白与换行（中文输入法很容易带入全角空格）
    /// - 超长按字符截断（`prefix` 按 Character，不会把一个汉字切坏）
    /// - 空串回退到默认值，避免主界面出现空白行
    public static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultNickname }
        return String(trimmed.prefix(maxNicknameLength))
    }
}
