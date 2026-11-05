import SwiftUI
import UIKit

/// ★ **全局浮窗控制器** —— 用独立的 `UIWindow` 承载实时日志浮窗，
/// 使其**悬浮在所有界面之上**（包括 sheet、导航、其他 window）。
///
/// ## 为什么用独立 window 而不是 SwiftUI overlay
/// `RootView` 里的 overlay 只覆盖 RootView 自己，一旦弹出 sheet
/// （开发者菜单、配对页、诊断页），浮窗就被盖住了。
/// 独立的 `UIWindow` 挂在 `windowScene` 上、`windowLevel` 设为
/// `alert + 1`，就能稳定地浮在所有 UIKit/SwiftUI 界面之上。
///
/// ## 交互穿透
/// 浮窗本身占据一个小矩形，其余区域 `hitTest` 返回 nil，让触摸穿透到
/// 下层界面 —— 用户仍可正常操作 App，只是浮窗区域会拦截。
///
/// ★ 所以 **frame 必须跟着内容一起变**：折叠时若只缩小 SwiftUI 内容、
/// 不缩 hosting view，那 200 多 pt 的透明区仍属于 hosting view，
/// `hitTest` 会命中它并吃掉点击（`FloatingWindow` 只在命中 window 自身时穿透）。
@MainActor
final class FloatingWindowController {

    static let shared = FloatingWindowController()

    private var window: FloatingWindow?
    private var hosting: UIHostingController<AnyView>?
    private var currentHeight: CGFloat = LiveLogFloatingView.expandedHeight

    private let marginX: CGFloat = 16
    private let marginY: CGFloat = 8

    /// 显示浮窗（若已显示则无操作）
    ///
    /// - Parameter retry: 内部重试计数。冷启动时 `AppModel.init` 就会调这里，
    ///   而那一刻 `windowScene` 可能还没连上（`connectedScenes` 为空）——
    ///   直接放弃会出现「开关是开的、浮窗不出来，且再也不会自己出现」。
    ///   所以拿不到 scene 时退避重试几次（总共约 1.5 秒）。
    func show(retry: Int = 0) {
        // ★ 复用单例窗口：不重建，避免 UIWindowScene 强持有旧窗口导致泄漏累积。
        if let win = window {
            win.isHidden = false
            return
        }
        guard let scene = activeScene() else {
            guard retry < 5 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self.show(retry: retry + 1)
            }
            return
        }

        let hosting = UIHostingController(rootView: AnyView(LiveLogFloatingView()))
        hosting.view.backgroundColor = .clear

        let win = FloatingWindow(windowScene: scene)
        win.rootViewController = hosting
        // ★ 用 `.normal + 1` 而不是 `.alert + 1`：
        //   前者足以浮在本 App 的所有界面（含 sheet）之上，
        //   后者会盖住**系统 alert**（权限请求、Face ID 提示、低电量）——
        //   那些弹窗一被挡住，用户就无法完成授权，表现成「点了没反应」。
        win.windowLevel = .normal + 1
        win.backgroundColor = .clear
        win.isOpaque = false
        win.isHidden = false

        // hosting 视图定位到顶部（安全区下方 + 靠左）
        let topInset = scene.windows.first?.safeAreaInsets.top ?? 0
        hosting.view.frame = CGRect(x: marginX,
                                    y: topInset + marginY,
                                    width: LiveLogFloatingView.width,
                                    height: currentHeight)
        hosting.view.autoresizingMask = []

        self.window = win
        self.hosting = hosting
    }

    /// 隐藏浮窗（保留窗口对象，仅隐藏，下次 show 直接复用）。
    func hide() {
        window?.isHidden = true
    }

    /// 折叠 / 展开后调整宿主视图高度（触摸区随之收缩，见类型注释）。
    func setContentHeight(_ height: CGFloat) {
        currentHeight = height
        guard let hosting else { return }
        var f = hosting.view.frame
        guard abs(f.height - height) > 0.5 else { return }
        f.size.height = height
        hosting.view.frame = f
    }

    private func activeScene() -> UIWindowScene? {
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene,
               ws.activationState == .foregroundActive {
                return ws
            }
        }
        // 兜底：取任意一个 windowScene
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
    }
}

/// 触摸穿透的窗口：hosting 视图只占浮窗大小，其余透明区命中 window 自身 → 穿透。
private final class FloatingWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        // 透明区（hosting 视图之外）命中 window 自身 → 穿透到下层
        if view == self {
            return nil
        }
        return view
    }
}
