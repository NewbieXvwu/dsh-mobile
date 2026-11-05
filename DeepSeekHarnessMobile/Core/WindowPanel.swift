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

    func updateUIViewController(_ controller: Presenter, context: Context) {
        if isPresented {
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
                controller.present(hosting, animated: false)
            }
            controller.presentedViewController?.presentationController?.containerView?.setNeedsLayout()
        } else if controller.presentedViewController != nil {
            controller.dismiss(animated: false)
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

/// 把系统 sheet 的内容放进窗口面板时，内容自带的 `NavigationStack` 工具栏会跑到
/// 窗口标题栏上（和卡片分离，就是"错位"）。这里统一给面板内内容补一条卡片内标题栏，
/// 并隐藏原来的导航栏工具栏。
struct PanelShell<PanelContent: View>: View {
    let title: String
    var onClose: (() -> Void)?
    var closeLabel: String = "完成"
    var headerLeading: AnyView? = nil
    @ViewBuilder var content: () -> PanelContent

    var body: some View {
        #if targetEnvironment(macCatalyst)
        if WindowPanelLayout.isEmbedded {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if let headerLeading { headerLeading }
                    Text(title).appFont(.headline)
                    Spacer(minLength: 8)
                    if let onClose {
                        Button(closeLabel, action: onClose)
                            .appFont(.subheadline.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(DSHColor.ocean)
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 48)
                .background(Color(uiColor: .secondarySystemBackground))
                Divider()
                content()
                    .toolbar(.hidden, for: .navigationBar)
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}
