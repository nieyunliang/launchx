import AppKit

/// 通用窗口淡入 / 淡出工具（时长与 Launchpad 面板过渡保持一致）。
@MainActor
enum WindowFade {
    static let inDuration: TimeInterval = 0.18
    static let outDuration: TimeInterval = 0.15

    /// 每个窗口的淡出代数：fadeIn 也会推进代数，使进行中的淡出收尾失效。
    /// 没有它时「关闭窗口后 150ms 内再次打开」会被旧的 completionHandler
    /// `orderOut` 掉（窗口闪一下又消失）。
    private static var fadeTokens: [ObjectIdentifier: Int] = [:]

    private static func advanceToken(for window: NSWindow) -> Int {
        let key = ObjectIdentifier(window)
        let token = (fadeTokens[key] ?? 0) + 1
        fadeTokens[key] = token
        return token
    }

    /// 淡入显示：已在屏的窗口仅前置（淡出中则直接复位不透明，避免新旧 alpha 动画竞争）；
    /// 隐藏窗口从 0 淡入。同时推进代数，让进行中的淡出收尾不再把窗口移出屏幕。
    static func fadeIn(_ window: NSWindow) {
        _ = advanceToken(for: window)
        if window.isVisible {
            // 淡出进行中（alpha < 1）：直接复位。若再起一条 0→1 动画，会与旧淡出动画
            // 争抢同一个 alpha 属性，可能停在半透明。
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 不可见窗口（orderOut 后 alpha 已复位为 1）从 0 淡入
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
        let token = advanceToken(for: window)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = outDuration
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // 淡出期间窗口被重新打开（fadeIn 已推进代数）：旧收尾不得再 orderOut。
                guard fadeTokens[ObjectIdentifier(window)] == token else { return }
                window.orderOut(nil)
                window.alphaValue = 1
            }
        })
    }
}
