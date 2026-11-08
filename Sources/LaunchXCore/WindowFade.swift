import AppKit

/// 通用窗口淡入 / 淡出工具（时长与 Launchpad 面板过渡保持一致）。
@MainActor
enum WindowFade {
    static let inDuration: TimeInterval = 0.18
    static let outDuration: TimeInterval = 0.15

    /// 淡入显示：已在屏且完全不透明的窗口仅前置，不重复动画。
    static func fadeIn(_ window: NSWindow) {
        if window.isVisible, window.alphaValue >= 1 {
            window.makeKeyAndOrderFront(nil)
            return
        }
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = inDuration
            window.animator().alphaValue = 1
        }
    }

    /// 淡出并从屏幕移除；窗口对象保留（alpha 复位），供下次复用。
    static func fadeOut(_ window: NSWindow) {
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = outDuration
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                window.alphaValue = 1
            }
        })
    }
}
