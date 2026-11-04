import SwiftUI
import UIKit
import OSLog

private let sheetCloseLog = Logger(subsystem: "com.clarklevis.dshmobile", category: "MacSheetClose")

/// 无头自测/诊断开关：`open ... --args DSH_SHEET_SELFTEST 1` 启动时，
/// sheet 打开/关闭的关键节点（open-request / appeared / close-request /
/// disappeared）都会以 category=SheetSelfTest 打进 unified log，
/// 用于离线定位 Catalyst sheet 的打开/关闭延迟，不依赖人工点击。
enum SheetDiagnostics {
    static let selfTestEnabled = ProcessInfo.processInfo.arguments.contains("DSH_SHEET_SELFTEST")
    static let log = Logger(subsystem: "com.clarklevis.dshmobile", category: "SheetSelfTest")
}

// Mac Catalyst 的 sheet 没有下拉关闭手势，也没有系统提供的关闭按钮；
// 只能靠手势关闭的 sheet 在 Mac 上是"陷阱"。本修饰器为 Catalyst 补：
// 1) 右上角显式"关闭"按钮（topBarTrailing + Esc 快捷键）；关闭动作优先走
//    调用方提供的闭包（绑定置回），环境 dismiss 作为兜底。
// 2) 点击 sheet 以外的空白区域关闭（窗口级手势，按命中位置过滤；
//    sheet 内容内的触摸不受影响）。iOS 上两者均不生效，保持原样。
// 若上游后续为各 sheet 补了显式关闭入口，可整体移除本文件。

private struct MacSheetCloseModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var close: (() -> Void)?

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "关闭")) {
                        sheetCloseLog.log("close button tapped (hasClose=\(close != nil ? "1" : "0", privacy: .public))")
                        close?()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .background(MacSheetOutsideTapCatcher { sheetCloseLog.log("outside tap"); close?(); dismiss() })
#else
        content
#endif
    }
}
extension View {
    /// 为 Mac Catalyst 补充 sheet 的关闭能力（右上角关闭按钮 + 点击外部关闭 + Esc）。
    /// `close` 可选：提供时（通常是把 sheet 的 isPresented/item 置回）优先调用；
    /// 需用在 sheet 内容的 NavigationStack 根视图上，按钮才会出现在导航栏。
    func macSheetClose(_ close: (() -> Void)? = nil) -> some View {
        modifier(MacSheetCloseModifier(close: close))
    }
}

#if targetEnvironment(macCatalyst)
/// Catalyst sheet 的"点击外部关闭"。挂在 sheet 内容的背景里，出现时向所在
/// UIWindow 注册一个穿透式手势；点击位置不在本 sheet 内容帧内即触发关闭。
private struct MacSheetOutsideTapCatcher: UIViewControllerRepresentable {
    let onTapOutside: () -> Void

    func makeUIViewController(context: Context) -> HostController {
        HostController(onTapOutside: onTapOutside)
    }

    func updateUIViewController(_ controller: HostController, context: Context) {
        controller.onTapOutside = onTapOutside
    }

    @objc final class HostController: UIViewController, UIGestureRecognizerDelegate {
        var onTapOutside: () -> Void
        private var gesture: UITapGestureRecognizer?

        init(onTapOutside: @escaping () -> Void) {
            self.onTapOutside = onTapOutside
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            sheetCloseLog.log("sheet content disappeared")
            remove()
        }

        private func install() {
            // A/B: 窗口级 tap 手势疑似拖慢 sheet 内真实鼠标点击（Catalyst 手势-触摸
            // 管线），默认禁用；需要时 defaults write <bundle-id> enableOutsideTapCatcher -bool YES。
            guard UserDefaults.standard.bool(forKey: "enableOutsideTapCatcher") else {
                sheetCloseLog.log("outside-tap catcher disabled by default")
                return
            }
            guard gesture == nil, let window = view.window else { return }
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            gesture = recognizer
        }

        private func remove() {
            guard let gesture else { return }
            gesture.view?.removeGestureRecognizer(gesture)
            self.gesture = nil
        }

        @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let window = view.window else { return }
            let location = recognizer.location(in: window)
            // 本 sheet 的内容帧：从 presentation 层取当前被呈现控制器的视图。
            guard let presentedView = presentingViewController?.presentedViewController?.view ??
                navigationController?.view ?? view else { return }
            let frame = presentedView.convert(presentedView.bounds, to: window)
            if !frame.contains(location) {
                onTapOutside()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
