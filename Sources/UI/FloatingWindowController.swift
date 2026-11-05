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
    /// 安全区顶部（每次改高度时要用它重算内容矩形）
    private var topInset: CGFloat = 0

    private let marginX: CGFloat = 16
    private let marginY: CGFloat = 8

    /// 宿主视图比内容四周各大一圈，专门留给投影。
    ///
    /// ## 为什么必须留
    /// SwiftUI 的 `.shadow` 画在内容自身边界**之外**。宿主视图的 frame
    /// 原来严格等于 300×260，于是投影只剩上沿和左沿一点点能画出来，
    /// 右沿和下沿直接被宿主视图的边界切掉 —— 表现为"阴影只出现在两个边"，
    /// 比完全没有阴影更难看。
    ///
    /// 多留 24pt（`.floating` 的 radius 20 + 余量），投影才有地方落。
    /// 多出来的这圈是**透明区**，靠 `contentRect` 做点击穿透，不影响下层操作。
    private let shadowPad: CGFloat = 24

    /// 浮窗内容在窗口坐标系里的矩形（300 × currentHeight）。点击只在这个范围内生效。
    private var contentRect: CGRect {
        CGRect(x: marginX,
               y: topInset + marginY,
               width: LiveLogFloatingView.width,
               height: currentHeight)
    }

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
        topInset = scene.windows.first?.safeAreaInsets.top ?? 0
        // 宿主比内容四周各大 24pt，给 `.floating` 投影留出绘制空间（见 shadowPad 注释）
        hosting.view.frame = contentRect.insetBy(dx: -shadowPad, dy: -shadowPad)
        hosting.view.autoresizingMask = []
        hosting.view.backgroundColor = .clear
        hosting.view.clipsToBounds = false

        // 点击只认内容矩形，外圈那 24pt 投影区穿透到下层
        win.contentRect = contentRect

        self.window = win
        self.hosting = hosting
    }

    /// 隐藏浮窗（保留窗口对象，仅隐藏，下次 show 直接复用）。
    func hide() {
        window?.isHidden = true
    }

    /// 折叠 / 展开后调整宿主视图高度（触摸区随之收缩，见类型注释）。
    func setContentHeight(_ height: CGFloat) {
        guard abs(currentHeight - height) > 0.5 else { return }
        currentHeight = height
        guard let hosting, let window else { return }
        hosting.view.frame = contentRect.insetBy(dx: -shadowPad, dy: -shadowPad)
        window.contentRect = contentRect
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
    /// 浮窗内容在窗口坐标系里的矩形。宿主视图为了投影向外扩了一圈，
    /// 那一圈是透明的，必须显式放过，否则 24pt 的"空"区域会吃掉点击 ——
    /// 用户会发现浮窗边缘一小条点不动，却看不出原因。
    var contentRect: CGRect = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard contentRect != .zero, contentRect.contains(point) else { return nil }
        let view = super.hitTest(point, with: event)
        if view == self {
            return nil
        }
        return view
    }
}
