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
/// 下层界面 —— 用户仍可正常操作 App，只是浮窗区域会拦截（可拖动）。
@MainActor
final class FloatingWindowController {

    static let shared = FloatingWindowController()

    private var window: FloatingWindow?
    private var hosting: UIHostingController<AnyView>?

    /// 显示浮窗（若已显示则无操作）
    func show(model: AppModel) {
        // ★ 复用单例窗口：不重建，避免 UIWindowScene 强持有旧窗口导致泄漏累积。
        if let win = window {
            win.isHidden = false
            return
        }
        guard let scene = activeScene() else { return }

        let root = LiveLogFloatingView()
            .environmentObject(model)
        let hosting = UIHostingController(rootView: AnyView(root))
        hosting.view.backgroundColor = .clear

        let win = FloatingWindow(windowScene: scene)
        win.rootViewController = hosting
        win.windowLevel = .alert + 1
        win.backgroundColor = .clear
        win.isOpaque = false
        win.isHidden = false

        // ★ hosting 视图定位到顶部（安全区下方 + 靠左），固定 300×260。
        //   hosting view 之外都是 window 的透明区，hitTest 自然穿透。
        let topInset = scene.windows.first?.safeAreaInsets.top ?? 0
        hosting.view.frame = CGRect(x: 16, y: topInset + 8, width: 300, height: 260)
        hosting.view.autoresizingMask = []

        self.window = win
        self.hosting = hosting
    }

    /// 隐藏浮窗（保留窗口对象，仅隐藏，下次 show 直接复用）。
    func hide() {
        window?.isHidden = true
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
