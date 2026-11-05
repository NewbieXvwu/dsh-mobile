import SwiftUI

/// 平台的 sheet 呈现方式。
///
/// iOS 用系统 `.sheet`；Mac Catalyst 上系统 sheet 有一条已知的坏路径——
/// `@Environment(\.dismiss)` 调用返回后界面可以长时间不消失（真机上观察到 15s+ 乃至永不消失），
/// 现有证据见 `Docs/macOS-catalyst.md`。所以 Catalyst 上改用窗口内自定义面板：
/// 呈现/解散都由绑定驱动，`animated: false`，实测开 8–55ms、关 5–18ms。
enum WindowPanelLayout {
    #if targetEnvironment(macCatalyst)
    static let isEmbedded = true
    #else
    static let isEmbedded = false
    #endif
}

/// 关闭当前窗口面板。
///
/// Catalyst 上面板覆盖窗口期间，SwiftUI 可能推迟下层视图的重新求值，
/// 于是「把绑定置回 false」并不保证 `updateUIViewController` 会马上被叫到。
/// 关闭动作统一走这里：先改状态（iOS/后续渲染仍需要），再直接收掉呈现层。
func closePanel(_ reset: @escaping () -> Void) {
    reset()
    #if targetEnvironment(macCatalyst)
    WindowPanelRegistry.activePresenter?.dismiss(animated: false)
    WindowPanelRegistry.activePresenter = nil
    for panel in WindowPanelRegistry.presentedPanels() {
        panel.dismiss(animated: false)
    }
    #endif
}

extension View {
    /// 统一的弹层入口：iOS 走系统 sheet，Catalyst 走窗口内面板。
    ///
    /// - Parameters:
    ///   - isPresented: 绑定即唯一真相；面板的关闭必须由它驱动，不要依赖 `dismiss()`。
    ///   - size: 面板首选尺寸（Catalyst 生效，过高的内容会在面板内滚动）。
    @ViewBuilder
    func windowPanel<PanelContent: View>(
        isPresented: Binding<Bool>,
        size: CGSize = CGSize(width: 560, height: 620),
        @ViewBuilder content: @escaping () -> PanelContent
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        background(WindowPanel(isPresented: isPresented, size: size, content: content))
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

extension View {
    /// `.sheet(item:)` 的面板版本；`onDismiss` 语义保持一致。
    @ViewBuilder
    func windowPanel<Item: Identifiable, PanelContent: View>(
        item: Binding<Item?>,
        size: CGSize = CGSize(width: 560, height: 620),
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> PanelContent
    ) -> some View {
        #if targetEnvironment(macCatalyst)
        let isPresented = Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
        WindowPanel(isPresented: isPresented, size: size) {
            if let value = item.wrappedValue { content(value) }
        }
        .onChangeCompat(of: isPresented.wrappedValue) { _, presented in
            if !presented { onDismiss?() }
        }
        #else
        sheet(item: item, onDismiss: onDismiss, content: content)
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// 面板呈现者的进程级登记表（泛型类型不能有静态存储属性）。
enum WindowPanelRegistry {
    static weak var activePresenter: UIViewController?
    /// 面板呈现层视图的固定标识：面板覆盖窗口期间 SwiftUI 可能不再驱动
    /// representable，关闭时只能自己到视图控制器树里把它找出来。
    static let marker = "dsh-window-panel"

    static func presentedPanels() -> [UIViewController] {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows: [UIWindow] = scenes.flatMap { $0.windows }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        guard let root = window?.rootViewController else { return [] }
        var found: [UIViewController] = []
        var queue: [UIViewController] = [root]
        var visited = 0
        while let vc = queue.popLast(), visited < 200 {
            visited += 1
            if let presented = vc.presentedViewController {
                queue.append(presented)
                if presented.view.accessibilityIdentifier == marker { found.append(presented) }
            }
            queue.append(contentsOf: vc.children)
            // 自定义呈现把面板挂在 presenter 的 presentedViewController 上，
            // 继续沿 children/presented 两条链走，能覆盖嵌套容器。
            if let nav = vc as? UINavigationController { queue.append(contentsOf: nav.viewControllers) }
            if let tab = vc as? UITabBarController, let tabs = tab.viewControllers {
                queue.append(contentsOf: tabs)
            }
        }
        return found
    }
}


/// 用自定义 `UIPresentationController` 在窗口内呈现任意 SwiftUI 内容。
///
/// 关键点（都是踩过的坑）：
/// - `animated: false`：走系统过渡会重新引入不可控的解散等待；
/// - 内容宿主的背景必须显式设成 `.systemBackground` 且 `isOpaque`，否则面板会透出下层窗口；
/// - 面板边框、圆角、阴影、外部暗化都在 `Panel` 里画，SwiftUI 内容不需要自带这些。
struct WindowPanel<PanelContent: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var size: CGSize
    @ViewBuilder var content: () -> PanelContent

    func makeUIViewController(context: Context) -> Presenter { Presenter() }

    static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
        controller.dismiss(animated: false)
        if activePresenter === controller { activePresenter = nil }
    }

    /// 面板的呈现者可能因为 SwiftUI 重新求值而换掉；保留最后一次呈现的引用，
    /// 这样即使绑定由旧实例驱动，关闭请求也一定能把面板收掉。
    static var activePresenter: Presenter? {
        get { WindowPanelRegistry.activePresenter as? Presenter }
        set { WindowPanelRegistry.activePresenter = newValue }
    }

    func updateUIViewController(_ controller: Presenter, context: Context) {
        if isPresented {
            Self.activePresenter = controller
            let root = AnyView(content().environment(\.self, context.environment))
            if let hosting = controller.presentedViewController as? UIHostingController<AnyView> {
                hosting.rootView = root
                hosting.preferredContentSize = size
                hosting.view.setNeedsLayout()
            } else {
                let hosting = UIHostingController(rootView: root)
                hosting.modalPresentationStyle = .custom
                hosting.transitioningDelegate = controller
                hosting.preferredContentSize = size
                hosting.view.backgroundColor = .systemBackground
                hosting.view.isOpaque = true
                hosting.view.accessibilityIdentifier = WindowPanelRegistry.marker
                controller.present(hosting, animated: false)
            }
            controller.presentedViewController?.presentationController?.containerView?.setNeedsLayout()
        } else {
            var dismissed = false
            if controller.presentedViewController != nil {
                controller.dismiss(animated: false)
                dismissed = true
            }
            if let orphan = Self.activePresenter, orphan !== controller,
               orphan.presentedViewController != nil {
                orphan.dismiss(animated: false)
                dismissed = true
            }
            if dismissed, Self.activePresenter === controller { Self.activePresenter = nil }
        }
    }

    final class Presenter: UIViewController, UIViewControllerTransitioningDelegate {
        func presentationController(forPresented presented: UIViewController,
                                    presenting: UIViewController?,
                                    source: UIViewController) -> UIPresentationController? {
            Panel(presentedViewController: presented, presenting: presenting)
        }
    }

    private final class Panel: UIPresentationController {
        private let dimmingView = UIView()

        override var frameOfPresentedViewInContainerView: CGRect {
            guard let bounds = containerView?.bounds else { return .zero }
            let width = min(size.width, bounds.width - 48)
            let wanted = presentedViewController.preferredContentSize.height
            let height = min(max(200, wanted > 0 ? wanted : size.height), bounds.height - 48)
            return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                          width: width, height: height)
        }

        private var size: CGSize { presentedViewController.preferredContentSize }

        override func presentationTransitionWillBegin() {
            super.presentationTransitionWillBegin()
            dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
            containerView?.insertSubview(dimmingView, at: 0)
            presentedView?.layer.cornerRadius = 14
            presentedView?.layer.masksToBounds = false
            presentedView?.layer.shadowColor = UIColor.black.cgColor
            presentedView?.layer.shadowOpacity = 0.32
            presentedView?.layer.shadowRadius = 22
            presentedView?.layer.shadowOffset = CGSize(width: 0, height: 10)
            presentedView?.accessibilityViewIsModal = true
        }

        override func containerViewWillLayoutSubviews() {
            super.containerViewWillLayoutSubviews()
            dimmingView.frame = containerView?.bounds ?? .zero
            presentedView?.frame = frameOfPresentedViewInContainerView
        }
    }
}
#endif

