import UIKit
import os

/// 触摸事件时间线探针（`DSH_TOUCH_TRACE=1` 或 `DSH_SHEET_SELFTEST=1` 时启用）。
///
/// 目的：把「点击慢」拆成可测量的三段——
///   A) 手指/鼠标抬起 → 按钮 action 执行（UIKit 事件派发 + SwiftUI 手势识别）
///   B) action 执行 → sheet 出现（呈现管线）
///   C) 关闭请求 → sheet 消失（解散管线 + 动画）
/// 只记录事件时间戳，不改任何交互行为；关闭开关后完全不安装。
enum TouchTrace {
    static let enabled =
        ProcessInfo.processInfo.environment["DSH_TOUCH_TRACE"] == "1"
        || SheetDiagnostics.selfTestEnabled
        || SheetDiagnostics.pairingSelfTestEnabled

    static let log = Logger(subsystem: "com.clarklevis.dshmobile", category: "TouchTrace")

    private static var installed = false

    /// 在 UIApplication 上交换 sendEvent(_:)，记录每个触摸的开始/结束时刻。
    static func install() {
        guard enabled, !installed else { return }
        installed = true
        let original = #selector(UIApplication.sendEvent(_:))
        let replacement = #selector(UIApplication.trace_sendEvent(_:))
        guard
            let a = class_getInstanceMethod(UIApplication.self, original),
            let b = class_getInstanceMethod(UIApplication.self, replacement)
        else {
            log.fault("swizzle unavailable")
            return
        }
        method_exchangeImplementations(a, b)
        log.fault("touch trace installed")
    }
}

extension UIApplication {
    /// 交换后的实现：交换后调用自身即调用原实现。
    @objc func trace_sendEvent(_ event: UIEvent) {
        if TouchTrace.enabled, event.type == .touches,
           let touches = event.allTouches, let touch = touches.first {
            switch touch.phase {
            case .began:
                TouchTrace.log.fault("touch-began")
            case .ended, .cancelled:
                TouchTrace.log.fault("touch-ended")
            default:
                break
            }
        }
        trace_sendEvent(event)
    }
}
