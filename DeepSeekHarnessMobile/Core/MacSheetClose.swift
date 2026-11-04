import SwiftUI

// Mac Catalyst 的 sheet 没有下拉关闭手势，也没有系统提供的关闭按钮；
// 只能靠手势关闭的 sheet 在 Mac 上是"陷阱"。本修饰器为 Catalyst 补一个
// cancellationAction 工具栏关闭按钮（并绑定 Esc），iOS 上保持原样。
// 若上游后续为各 sheet 补了显式关闭入口，可整体移除本文件。

private struct MacSheetCloseModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var label: String

    func body(content: Content) -> some View {
#if targetEnvironment(macCatalyst)
        content.toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(label) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
#else
        content
#endif
    }
}

extension View {
    /// 为 Mac Catalyst 补充 sheet 的显式关闭按钮（cancellationAction + Esc）。
    /// 需用在 sheet 内容的 NavigationStack 根视图上，才会出现在导航栏。
    func macSheetClose(_ label: String = String(localized: "关闭")) -> some View {
        modifier(MacSheetCloseModifier(label: label))
    }
}
