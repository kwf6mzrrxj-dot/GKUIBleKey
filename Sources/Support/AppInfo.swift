import Foundation

/// App 版本信息 —— 从 `Info.plist` 读取，供 UI 展示。
///
/// 版本号采用 **0.1 步进**：每次对外发布（新功能/修复）时，
/// 将 `CFBundleShortVersionString`（即 `versionString`）+0.1。
/// `buildNumber`（`CFBundleVersion`）为整数，每次构建 +1，用于区分同一版本的内部构建。
public enum AppInfo {

    /// 用户可见版本号（如 `0.1`），对应 `CFBundleShortVersionString`。
    /// 约定：每次发布按 0.1 步进。
    public static var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    /// 构建号（整数），对应 `CFBundleVersion`。
    public static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
