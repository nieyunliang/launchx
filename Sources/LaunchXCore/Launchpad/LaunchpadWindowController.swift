import AppKit
import Metal
import ScreenCaptureKit
import SwiftUI

/// 面板层抽出的横滑事件（与 NSEvent 解耦，便于路由与单测）。
struct PageScrollEvent {
    /// 横向滚动增量（pt，符号与 scrollingDeltaX 一致：负 = 朝下一页方向）。
    var delta: CGFloat
    /// 手势开始（phase == .began）。
    var isGestureStart: Bool
    /// 手势结束、手指抬起（phase == .ended）。
    var isEnded: Bool
    /// 惯性事件（momentumPhase 非空）。
    var isMomentum: Bool
    /// 离散设备（phase 与 momentumPhase 均为空：鼠标横滚轮 / 普通滚轮）。
    var isDiscrete: Bool
}

/// 交互式横滑翻页手势（纯逻辑，便于单测）。
///
/// 跟手阶段：横滑增量实时累计为页面偏移（负 = 朝下一页），首/末页边界做橡皮筋衰减；
/// 松手（phase == .ended）：按进度（偏移 ≥ 页宽 × commitProgress）或速度（|v| ≥ commitVelocity）
/// 决定完成翻页（±1）或回弹（0），此后同一手势的惯性事件不再参与；
/// 离散设备：单次事件直接翻一页（带冷却），与旧版行为一致。
struct InteractivePageGesture {
    /// 松手时偏移达到页宽该比例即完成翻页。
    static let commitProgress: CGFloat = 0.25
    /// 松手时速度绝对值（pt/s）达到该值即完成翻页（轻快甩动）。
    static let commitVelocity: CGFloat = 600
    /// 边界橡皮筋渐近尺度（pt）：越界后偏移最多无限接近该值。
    static let rubberBandDimension: CGFloat = 100
    /// 离散滚轮事件的翻页冷却（秒）。
    static let discreteCooldown: TimeInterval = 0.35

    enum Action: Equatable {
        /// 事件未影响跟手偏移（惯性尾巴 / 已落位 / 冷却期离散事件）。
        /// 调用方不得同步偏移：此时 displayOffset 可能是上一手势的残留值。
        case ignored
        /// 跟手中，偏移已更新。
        case tracking
        /// 落位：+1 = 完成向前翻页，-1 = 完成向后翻页，0 = 回弹。
        case settle(Int)
    }

    private(set) var rawOffset: CGFloat = 0
    private var velocity: CGFloat = 0  // pt/s，EMA 平滑
    private var lastSampleAt = Date.distantPast
    private var lastSampleOffset: CGFloat = 0
    private var canGoBackward = true
    private var canGoForward = true
    private var dragging = false
    private var settled = true  // 当前手势是否已落位
    private var lastDiscreteAt = Date.distantPast

    /// 页面显示偏移（含边界橡皮筋），视图直接消费。
    var displayOffset: CGFloat {
        if rawOffset < 0, !canGoForward { return -Self.damp(magnitude: -rawOffset) }
        if rawOffset > 0, !canGoBackward { return Self.damp(magnitude: rawOffset) }
        return rawOffset
    }

    /// 滚动事件是否上报给翻页手势（面板层过滤规则）。
    /// 相位边界事件（.began/.ended）必须无条件上报：.ended 的滚动增量通常为 0，
    /// 若按幅度过滤会永远丢失"松手"信号，导致无法落位。
    static func shouldForward(deltaX: CGFloat, deltaY: CGFloat, isGestureBoundary: Bool) -> Bool {
        if isGestureBoundary { return true }
        return abs(deltaX) > abs(deltaY) && abs(deltaX) > 2
    }

    /// 边界外渐近衰减：越界越多每 pt 增量越小，回滑时平滑恢复 1:1。
    private static func damp(magnitude: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        return (1 - 1 / (magnitude / rubberBandDimension * c + 1)) * rubberBandDimension
    }

    /// 喂入一次横滑事件，返回本次事件要执行的动作。
    ///
    /// `resumingFrom`：落位动画期间新手势接管的起始偏移（动画曲线表现值），
    /// 与本事件（.began）增量一并作为跟手起点；nil = 正常新手势从零起滑。
    mutating func feed(
        delta: CGFloat,
        isGestureStart: Bool,
        isEnded: Bool,
        isMomentum: Bool,
        isDiscrete: Bool,
        canGoBackward backward: Bool,
        canGoForward forward: Bool,
        pageWidth: CGFloat,
        at now: Date,
        resumingFrom: CGFloat? = nil
    ) -> Action {
        canGoBackward = backward
        canGoForward = forward

        // 离散滚轮：单事件直接翻一页（冷却防连发）。
        // 离散通道独立于触控板手势，先清残留跟手偏移，落位动画从 0 起滑
        if isDiscrete {
            guard abs(delta) > 4, now.timeIntervalSince(lastDiscreteAt) >= Self.discreteCooldown else { return .ignored }
            lastDiscreteAt = now
            if !dragging { rawOffset = 0; velocity = 0 }
            if delta < 0, forward { return .settle(1) }
            if delta > 0, backward { return .settle(-1) }
            return .ignored
        }

        // 落位已在 .ended 决定，惯性尾巴不参与（也不同步偏移，rawOffset 是残留值）
        if isMomentum { return .ignored }

        if isGestureStart || !dragging {
            // 新手势：.began；异常丢了首事件时把首个 changed 当开始。
            // 接管场景从落位动画表现值续滑（含本事件增量）；
            // 起始事件的 delta 不采样速度（相对上一采样 dt≈0 会算出天文速度）
            dragging = true
            settled = false
            rawOffset = (resumingFrom ?? 0) + delta
            velocity = 0
        } else {
            guard dragging, !settled else { return .ignored }
            rawOffset += delta
            // 速度 EMA（pt/s），dt 下限避免单事件除零放大。
            // .ended 的增量恒近 0，不参与采样（否则把甩动速度EMA拉低导致误判回弹）
            if !isEnded {
                let dt = max(now.timeIntervalSince(lastSampleAt), 0.008)
                let instant = (rawOffset - lastSampleOffset) / dt
                velocity = velocity == 0 ? instant : velocity * 0.7 + instant * 0.3
            }
        }
        lastSampleAt = now
        lastSampleOffset = rawOffset

        guard isEnded else { return .tracking }
        dragging = false
        settled = true
        return decision(pageWidth: pageWidth, velocity: velocity)
    }

    /// 兜底：异常收不到 .ended（手势被系统打断等）时按当前进度落位（速度视为 0）。
    mutating func timeoutSettle(pageWidth: CGFloat, at now: Date) -> Action {
        guard !settled, now.timeIntervalSince(lastSampleAt) > 0.3 else { return .ignored }
        dragging = false
        settled = true
        return decision(pageWidth: pageWidth, velocity: 0)
    }

    private func decision(pageWidth: CGFloat, velocity v: CGFloat) -> Action {
        let progress = abs(displayOffset) / max(pageWidth, 1)
        let fast = abs(v) >= Self.commitVelocity
        if rawOffset < 0, canGoForward, progress >= Self.commitProgress || (fast && v < 0) {
            return .settle(1)
        }
        if rawOffset > 0, canGoBackward, progress >= Self.commitProgress || (fast && v > 0) {
            return .settle(-1)
        }
        return .settle(0)
    }
}

/// 面板层键盘 / 滚轮事件处理器集合（由窗口控制器装配）。
@MainActor
final class PanelKeyHandlers: @unchecked Sendable {
    var onEscape: () -> Void = {}
    var onArrowLeft: () -> Void = {}
    var onArrowRight: () -> Void = {}
    var onArrowUp: () -> Void = {}
    var onArrowDown: () -> Void = {}
    var onPrintableKey: (String) -> Void = { _ in }
    var onPageScroll: (PageScrollEvent) -> Void = { _ in }
    /// Tab / Shift-Tab：在网格应用之间移动键盘焦点（P3-4）。
    var onTab: (Bool) -> Void = { _ in }
    /// Return / 小键盘 Enter：启动（或打开）当前键盘焦点项。
    var onActivate: () -> Void = {}
}

/// Esc 的三种归属（分层退出）。纯逻辑，供面板键盘路径与 SwiftUI `.onExitCommand`
/// 路径共用，避免两处判定漂移。
enum EscapeAction: Equatable {
    /// 输入法正在组字：不拦截，交给系统取消组字。
    case passThrough
    /// 搜索词非空：先清空搜索词，面板保持展开。
    case clearSearch
    /// 交给 `LaunchpadModel.handleBackgroundTap()` 的既有分层：关文件夹 → 清选择 → 收起。
    case background
    /// 有网格键盘焦点：先取消焦点，面板保持展开。
    case dismissGridFocus
}

enum EscapeKeyRouter {
    static func action(isComposingText: Bool, searchQuery: String) -> EscapeAction {
        if isComposingText { return .passThrough }
        if !searchQuery.isEmpty { return .clearSearch }
        return .background
    }

    /// 网格键盘焦点（P3-4）作为 Esc 的一层：有焦点先取消焦点，再走既有分层。
    /// 这样「方向键移动焦点」之后按 Esc 不会直接收起面板。
    static func action(isComposingText: Bool, searchQuery: String, hasGridFocus: Bool) -> EscapeAction {
        let base = action(isComposingText: isComposingText, searchQuery: searchQuery)
        if base == .background, hasGridFocus { return .dismissGridFocus }
        return base
    }
}

/// 始终可成为 key 的面板（非激活也能收键盘，对应原版 AlwaysKeyPanel）；
/// 键盘 / 滚轮在面板层拦截后经 PanelKeyHandlers 路由。
final class AlwaysKeyPanel: NSPanel {
    let keyHandlers = PanelKeyHandlers()
    /// 面板内的用户交互（点击 / 按键 / 滚动）→ 取消待执行的自动收起计时。
    /// 定时器可能由「点面板外」或失焦排下，用户回到面板继续操作时不能如期收起。
    var onUserInteraction: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .magnify:
            MainActor.assumeIsolated { onUserInteraction() }
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        MainActor.assumeIsolated {
            switch event.keyCode {
            case 53:
                keyHandlers.onEscape()
            case 123:
                keyHandlers.onArrowLeft()
            case 124:
                keyHandlers.onArrowRight()
            case 126:
                keyHandlers.onArrowUp()
            case 125:
                keyHandlers.onArrowDown()
            case 48:
                // Tab / Shift-Tab：搜索框聚焦时交给 field editor（系统在控件间移动焦点），
                // 否则在网格应用之间移动键盘焦点（P3-4）。
                if let responder = NSApp.keyWindow?.firstResponder as? NSTextView,
                   responder.isFieldEditor {
                    super.keyDown(with: event)
                    return
                }
                keyHandlers.onTab(InteractionModifiers.normalized(event.modifierFlags).contains(.shift))
            case 36, 76:
                // 输入法组字中 Return 用于上屏，不能当作「启动」
                if let responder = NSApp.keyWindow?.firstResponder as? NSTextView,
                   responder.hasMarkedText() {
                    super.keyDown(with: event)
                    return
                }
                // Return / 小键盘 Enter：启动当前焦点项（搜索态 = 当前高亮结果）
                keyHandlers.onActivate()
            default:
                // 无 ⌘⌃⌥ 修饰的可打印字符 → 输入即搜索。
                // 字符由面板层直接写入查询、再请求聚焦搜索框：程序化聚焦要等下一轮
                // SwiftUI 更新才生效，先写查询才不会丢掉首个字符（中文输入法同样适用）。
                // 消费后不再冒泡：既避免系统 beep，也避免聚焦生效后同一按键被 field
                // editor 再插入一次。只放行 ASCII 且非控制字符（排除退格/回车/Tab/DEL）。
                // 修饰键先剔掉 Caps Lock / 数字键盘等非意图位（P3-1）
                let hasBlockingModifiers = InteractionModifiers.blocksTypeToSearch(event.modifierFlags)
                if let characters = event.characters, characters.count == 1,
                   let scalar = characters.unicodeScalars.first,
                   scalar.isASCII,
                   !CharacterSet.controlCharacters.contains(scalar),
                   !hasBlockingModifiers {
                    keyHandlers.onPrintableKey(characters)
                    return
                }
                super.keyDown(with: event)
            }
        }
    }

    /// 搜索框等 field editor 获得键盘焦点时，Esc 以 cancelOperation 冒泡而非 keyDown，
    /// 在此路由到统一的 Esc 收起逻辑。
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated {
            keyHandlers.onEscape()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        MainActor.assumeIsolated {
            // 触控板双指横滑 → 交互式翻页：事件带 phase 上报，
            // 由窗口控制器驱动页面跟手偏移与松手落位
            let deltaX = event.scrollingDeltaX
            let isBoundary = event.phase == .began || event.phase == .ended
            if InteractivePageGesture.shouldForward(deltaX: deltaX, deltaY: event.scrollingDeltaY, isGestureBoundary: isBoundary) {
                keyHandlers.onPageScroll(PageScrollEvent(
                    delta: deltaX,
                    isGestureStart: event.phase == .began,
                    isEnded: event.phase == .ended,
                    isMomentum: !event.momentumPhase.isEmpty,
                    isDiscrete: event.phase.isEmpty && event.momentumPhase.isEmpty
                ))
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}

/// 桌面壁纸捕获器：ScreenCaptureKit 截取壁纸层窗口图像（需屏幕录制权限，失败回退 nil）。
///
/// 壁纸窗口的位置随系统版本变化（本机 macOS 26 实测）：
/// - layer = `kCGDesktopWindowLevel - 1`，owner 为 `WindowManager`（Ventura+）；
/// - 旧系统 layer = `kCGDesktopWindowLevel`，owner 为 `Window Server`/`Finder`；
/// - 枚举时不能用 `.excludeDesktopElements`（会把壁纸窗口整个从列表里剔除）。
/// 旧的 `CGWindowListCreateImage` 截到的壁纸窗口是黑图（视频壁纸走新合成路径），
/// 且该 API 已在 macOS 15 废弃，故改用 `SCScreenshotManager` 单窗口截图。
enum WallpaperCapture {

    /// 从窗口元数据中挑选覆盖目标屏的壁纸窗口（纯函数，便于单测）。
    ///
    /// - Parameters:
    ///   - infos: `CGWindowListCopyWindowInfo` 返回的原始字典数组；
    ///   - targetCGFrame: 目标屏在 CG 全局坐标（原点主屏左上、Y 向下）下的 frame。
    /// - Returns: 壁纸窗口 ID；找不到返回 nil。
    static func matchWallpaperWindow(infos: [[String: Any]], targetCGFrame: CGRect) -> CGWindowID? {
        let desktopLevel = CGWindowLevelForKey(.desktopWindow)
        var best: (id: CGWindowID, overlap: CGFloat)?

        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == desktopLevel - 1 || layer == desktopLevel else { continue }
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "WindowManager" || owner == "Window Server" || owner == "Finder" else { continue }
            if let name = info[kCGWindowName as String] as? String, name == "Backstop" { continue }
            guard let windowID = info[kCGWindowNumber as String] as? Int else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat else { continue }

            let frame = CGRect(x: x, y: y, width: width, height: height)
            let intersection = frame.intersection(targetCGFrame)
            guard !intersection.isNull, intersection.width > 2, intersection.height > 2 else { continue }
            let overlap = intersection.width * intersection.height
            if overlap > (best?.overlap ?? 0) {
                best = (CGWindowID(windowID), overlap)
            }
        }
        return best?.id
    }

    /// NSScreen 的 AppKit 全局 frame → CG 全局坐标（Y 轴翻转，原点移到主屏左上）。
    static func cgFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            return screen.frame
        }
        return CGRect(
            x: screen.frame.minX,
            y: primary.frame.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    /// 壁纸捕获结果。
    ///
    /// 区分「环境不满足」与「内部渲染失败」，避免把 CIContext 之类的内部故障
    /// 误报成「没有屏幕录制权限」；两种失败都静默回退毛玻璃背景，不中断启动台。
    enum Outcome {
        case captured(NSImage)
        /// 无 GUI 登录会话 / 无屏幕录制权限 / 找不到壁纸窗口。
        case unavailable
        /// 截图成功但预模糊失败（CIContext 不可用等）。
        case renderFailed
    }

    /// 是否需要/允许发起一次捕获（纯函数，便于单测）。
    ///
    /// - `blurWallpaper == false`：用户关闭了模糊壁纸，背景走毛玻璃，不截图也不模糊
    ///   （既省一次全屏 Retina 捕获，也不必为一张不会显示的图申请屏幕录制权限）；
    /// - 非控制台会话（SSH、无 GUI 登录）：WindowServer / Metal 不一定可用，直接跳过。
    static func shouldAttemptCapture(blurWallpaper: Bool, isOnConsole: Bool) -> Bool {
        blurWallpaper && isOnConsole
    }

    /// 当前进程是否运行在有控制台的 GUI 登录会话中。
    ///
    /// `CGSessionCopyCurrentDictionary` 在无 GUI 会话时可能返回 nil 或
    /// `kCGSSessionOnConsoleKey == false`；字典缺失时按「是」处理，与旧行为一致。
    static func isOnConsoleSession() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        guard let onConsole = session["kCGSSessionOnConsoleKey"] as? Bool else { return true }
        return onConsole
    }

    /// 截取指定屏的壁纸并预模糊（ScreenCaptureKit，需屏幕录制权限）。
    ///
    /// 模糊在捕获侧用 CoreImage 一次性完成，而非 SwiftUI `.blur`——
    /// 实测 macOS 26 上 `.blur` 修饰符（任意半径）会破坏 NSHostingView
    /// 内 ZStack 的合成层级：效果层盖住后续内容且同层图片不再渲染。
    /// 标 @MainActor 以规避 NSScreen 跨隔离传递；截图与模糊在 GPU 侧完成，
    /// await 挂起不阻塞主线程。
    @MainActor static func captureWallpaper(for screen: NSScreen, blurRadius: CGFloat = 64) async -> Outcome {
        guard shouldAttemptCapture(blurWallpaper: true, isOnConsole: isOnConsoleSession()) else {
            return .unavailable
        }
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return .unavailable }
        guard let windowID = matchWallpaperWindow(infos: windowList, targetCGFrame: cgFrame(of: screen)) else {
            return .unavailable
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return .unavailable }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        configuration.width = Int(screen.frame.width * scale)
        configuration.height = Int(screen.frame.height * scale)
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.queueDepth = 1

        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        ) else { return .unavailable }

        // createCGImage 会触发实际模糊渲染；即使主要由 GPU 执行，也可能同步等待
        // 图像提交。移出 MainActor，避免全屏 Retina 图像处理卡住展开动画。
        let radius = blurRadius * scale
        let blurred = await Task.detached(priority: .userInitiated) {
            preBlur(image, radius: radius)
        }.value
        guard let blurred else { return .renderFailed }
        return .captured(NSImage(cgImage: blurred, size: screen.frame.size))
    }

    /// CoreImage 上下文。Metal 后端优先；无 GPU（远程/后台会话）时退回软件渲染。
    /// 创建失败返回 nil，调用方降级为毛玻璃 —— `CIContext` 初始化在异常环境下可能
    /// 抛 Swift 无法捕获的 ObjC 异常，因此不做「无条件静态初始化」。
    private static let ciContext: CIContext? = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: true])
    }()

    /// CoreImage 高斯模糊：先 `clampedToExtent` 复制边缘像素，模糊后裁回原始尺寸，
    /// 避免直接模糊产生的半透明边缘。
    static func preBlur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        guard radius > 0, let ciContext, let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
        let source = CIImage(cgImage: image)
        blur.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = blur.value(forKey: kCIOutputImageKey) as? CIImage else { return nil }
        return ciContext.createCGImage(output, from: source.extent)
    }
}

/// 显示/隐藏路由（纯函数，便于单测）。
enum PresentationRouter {
    enum Intent: Equatable {
        case show
        case hide
    }

    /// 触发唤出快捷键时应展开还是收起。
    ///
    /// 不能用窗口 `isVisible` 判定：`hide()` 之后还要等 `hideSettleDelay`(0.4s) 的
    /// 收起动画与 `orderOut` 才真正下屏，这段时间窗口仍然 `isVisible == true`，
    /// 用窗口可见性判定会把「再按一次唤出」误判成收起，表现为「连按快捷键打不开」。
    static func intent(isVisible: Bool, isHiding: Bool) -> Intent {
        if isHiding { return .show }
        return isVisible ? .hide : .show
    }
}

/// 翻页入口的落位守护（纯函数，便于单测）。
enum PageSettleGuard {
    /// 横滑松手后的落位动画（约 0.3–0.35s）还没结束、`currentPage` 尚未提交时，
    /// 方向键 / 页码点等翻页入口必须让路：否则新翻页立刻改 `currentPage`，
    /// 落位收尾的 `finishDragCommit(direction:)` 会在其上再提交一次，
    /// 表现为「按一次 → 跳两页」。
    static func allowsNavigation(isSettlingPageDrag: Bool) -> Bool {
        !isSettlingPageDrag
    }
}

/// 多屏位置选择（纯函数，便于单测）。
enum ScreenPick {
    /// CG 全局坐标（原点 = 主屏左上、Y 向下）→ AppKit 全局坐标（原点 = 主屏左下、Y 向上）。
    static func appKitRect(fromCG rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// 找出与给定 CG 矩形重叠面积最大的屏幕（返回屏幕 frame）；没有重叠返回 nil。
    ///
    /// 用于「按 Dock 所在屏」定位：Dock 可能被拖到任意一块屏的任意边缘，
    /// 只有它的窗口位置能可靠反映实际所在屏。
    static func screenFrame(
        mostOverlapping cgRects: [CGRect],
        screenFrames: [CGRect],
        primaryFrame: CGRect
    ) -> CGRect? {
        guard !cgRects.isEmpty, !screenFrames.isEmpty else { return nil }
        var best: (frame: CGRect, area: CGFloat)?
        for cgRect in cgRects {
            let rect = appKitRect(fromCG: cgRect, primaryFrame: primaryFrame)
            for frame in screenFrames {
                let overlap = rect.intersection(frame)
                guard !overlap.isNull, !overlap.isEmpty else { continue }
                let area = overlap.width * overlap.height
                if area > (best?.area ?? 0) {
                    best = (frame, area)
                }
            }
        }
        return best?.frame
    }
}

/// Launchpad 全屏覆盖层窗口控制器。
///
/// - borderless 全屏覆盖于目标屏幕，背景 = 壁纸捕获（可选模糊）+ GlassTint 叠色
///   / 失败或关闭时退回 NSVisualEffectView 毛玻璃；
/// - 展开/收起为「整屏由大缩小淡入 / 由小放大淡出」（对齐系统 Launchpad）：窗口层不做
///   alpha 过渡，由 SwiftUI 根视图按 `isVisible` 驱动（中心对称，1.15 ↔ 1.0）；
/// - 显示位置跟随设置（主屏 / 激活屏 / 鼠标屏 / Dock 屏）；
/// - 失焦延时收起（Never / Always / 5s…5min）；
/// - Esc 收起、←→ 翻页、双指横滑跟手翻页（松手按进度/速度落位，分页模式）。
@MainActor
public final class LaunchpadWindowController: NSObject, NSWindowDelegate {

    public let model: LaunchpadModel

    private var panel: AlwaysKeyPanel?
    private var hostingView: NSHostingView<LaunchpadContentView>?
    private var closeWorkItem: DispatchWorkItem?
    private var hideWorkItem: DispatchWorkItem?
    /// show() 下一 tick 回调的代数：hide() 发生在 tick 前时令其失效，
    /// 防止过期的 show 回调把刚收起的面板复活（.isVisible 翻回 true）。
    private var showTickGeneration = 0
    private var pageGesture = InteractivePageGesture()
    /// 当前跟手方向：true = 张开展开，false = 捏合收起；nil = 无进行中的手势。
    private var pinchOpening: Bool?
    /// 网格键盘焦点（P3-4）：与内容视图共享，方向键/Tab/Return 由控制器驱动。
    private let gridFocus = GridKeyboardFocus()
    private var pageIdleSettleWork: DispatchWorkItem?
    private var globalClickMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    /// 壁纸图片容器：捕获完成后只更新 `image`，不替换 `NSHostingView.rootView`。
    /// 替换 rootView 会重建整棵视图，正在输入的搜索词、搜索框焦点、滚动位置
    /// 与所有 @State 都会被重置（P2-12）。
    private let wallpaperStore = LaunchpadWallpaperStore()
    private var wallpaperTask: Task<Void, Never>?
    /// 延迟到展开动画结束后的壁纸刷新；快速收起时取消，避免隐藏状态做无效捕获。
    private var wallpaperRefreshWork: DispatchWorkItem?
    /// 每会话只提示一次「屏幕录制未授权」（避免反复打开面板时刷屏）。
    private var hasNotifiedWallpaperPermission = false
    /// 收起动画 + orderOut 延迟期间为 true（窗口此时仍然 isVisible）。
    private var isHiding = false

    public init(model: LaunchpadModel) {
        self.model = model
        super.init()
    }

    // MARK: - 显示 / 隐藏

    public func show() {
        resetPinchInteraction()
        prepareForShowing()
        // 下一 runloop tick 再翻 isVisible：先让 SwiftUI 渲染出收起态（放大+透明），
        // 否则面板首次创建时初渲染即终态，展开动画会被吞掉。
        showTickGeneration += 1
        let generation = showTickGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.model.isVisible, self.showTickGeneration == generation else { return }
            // 收起→快速再展开时，orderOut 计时可能在本 tick 之后才到期
            self.hideWorkItem?.cancel()
            withAnimation(transitionAnimation) {
                self.model.show()
            }
            // 内容已可见：结束事件穿透，恢复正常点击
            self.panel?.ignoresMouseEvents = false
        }
    }

    public func hide() {
        // 防御：模型 isVisible 与窗口实际可见性可能短暂脱节（如遗留状态），
        // 只要窗口还真实在屏，就允许收起，避免遮罩永久卡死。
        guard model.isVisible || panel?.isVisible == true else { return }
        resetPinchInteraction()
        closeWorkItem?.cancel()
        wallpaperRefreshWork?.cancel()
        wallpaperRefreshWork = nil
        cancelPageIdleSettle()
        pageGesture = InteractivePageGesture()  // 中断未完成的横滑手势
        gridFocus.clear()  // 收起后键盘焦点不跨会话保留
        removeAutoHideMonitors()
        showTickGeneration += 1
        withAnimation(transitionAnimation) {
            model.hide()
        }
        // 淡出动画期间内容透明但仍全屏在屏，禁止透明网格误收点击。
        panel?.ignoresMouseEvents = true
        isHiding = true
        scheduleHideCompletion()
    }

    public func toggle() {
        switch PresentationRouter.intent(isVisible: model.isVisible, isHiding: isHiding) {
        case .hide:
            hide()
        case .show:
            show()
        }
    }

    /// 面板展开/收起动画；「减弱动态效果」时退化为快速淡入淡出（P3-3）。
    private var transitionAnimation: Animation {
        MotionPreference.panelTransition(reduceMotion: reduceMotion)
    }

    /// 系统「减弱动态效果」当前值（每次动画前读取，改设置后无需重启）。
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 展开/收起动画共用的面板前置准备，不包含可见性状态切换。
    private func prepareForShowing() {
        let screen = prepareWindow()
        scheduleWallpaperRefresh(for: screen)
        closeWorkItem?.cancel()
        hideWorkItem?.cancel()
        isHiding = false
        panel?.alphaValue = 1
        panel?.ignoresMouseEvents = !model.isVisible
        panel?.orderFrontRegardless()
        panel?.makeKey()
        installAutoHideMonitors()
    }

    /// 淡出或手势回退落位后统一下屏并持久化。
    private func scheduleHideCompletion() {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.isHiding = false
            try? self.model.store.saveNow()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideSettleDelay, execute: work)
    }

    /// 收起动画的落位预留：spring(duration: 0.3, bounce: 0.12) 完全收敛约需 0.4s。
    static let hideSettleDelay: TimeInterval = 0.4

    // MARK: - 捏合展开 / 收起（逐帧跟手）

    /// 张开只负责展开、捏合只负责收起；反方向手势不改变当前窗口状态。
    public func handlePinchGesture(_ event: PinchGestureEvent) {
        switch event.phase {
        case .began:
            // 上一手势若缺少终帧，先回退，避免新会话继承半透明状态。
            if pinchOpening != nil {
                settlePinchGesture(commit: false, animated: false)
            }
        case .changed:
            if pinchOpening == nil {
                guard event.signedProgress != 0 else { return }
                let opening = event.signedProgress > 0
                // 已展开时忽略继续张开，已收起时忽略继续捏合。
                guard opening != model.isVisible else { return }
                beginPinchGesture(opening: opening)
            }
            model.pinchTransitionProgress = min(max(abs(event.signedProgress), 0), 1)
        case .ended:
            guard pinchOpening != nil else { return }
            let commit = Self.shouldCommitPinch(progress: event.signedProgress, cancelled: false)
            settlePinchGesture(commit: commit)
        case .cancelled:
            guard pinchOpening != nil else { return }
            settlePinchGesture(commit: false)
        }
    }

    nonisolated static func shouldCommitPinch(progress: CGFloat, cancelled: Bool) -> Bool {
        !cancelled && abs(progress) >= 0.5
    }

    private func beginPinchGesture(opening: Bool) {
        showTickGeneration += 1
        closeWorkItem?.cancel()
        hideWorkItem?.cancel()
        wallpaperRefreshWork?.cancel()
        wallpaperRefreshWork = nil
        removeAutoHideMonitors()
        pinchOpening = opening
        model.pinchTransitionProgress = 0
        if opening {
            prepareForShowing()
            // isVisible 表示逻辑会话已开始；视觉仍完全由 pinchTransitionProgress 驱动。
            model.show()
        } else {
            cancelPageIdleSettle()
            pageGesture = InteractivePageGesture()
        }
        removeAutoHideMonitors()
        panel?.ignoresMouseEvents = true
    }

    /// 松手后从当前表现值继续弹簧落位，不重新播放完整动画。
    private func settlePinchGesture(commit: Bool, animated: Bool = true) {
        guard let opening = pinchOpening else { return }
        let shouldRemainVisible = opening == commit
        let update = {
            self.model.pinchTransitionProgress = nil
            if shouldRemainVisible {
                if !self.model.isVisible { self.model.show() }
            } else {
                self.model.hide()
            }
        }
        if animated {
            withAnimation(transitionAnimation, update)
        } else {
            update()
        }
        pinchOpening = nil

        if shouldRemainVisible {
            hideWorkItem?.cancel()
            panel?.ignoresMouseEvents = false
            installAutoHideMonitors()
            scheduleWallpaperRefresh(for: targetScreen())
        } else {
            wallpaperRefreshWork?.cancel()
            wallpaperRefreshWork = nil
            removeAutoHideMonitors()
            panel?.ignoresMouseEvents = true
            isHiding = true
            scheduleHideCompletion()
        }
    }

    /// 快捷键、Esc 等非手势入口接管时，清掉实时进度但保留当前逻辑可见性。
    private func resetPinchInteraction() {
        pinchOpening = nil
        model.pinchTransitionProgress = nil
    }

    // MARK: - 窗口构建

    private func prepareWindow() -> NSScreen {
        let screen = targetScreen()
        let frame = screen.frame

        if let panel {
            // 屏幕变化时同步 frame；壁纸沿用缓存，刷新延后到展开动画结束。
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            return screen
        }

        let panel = AlwaysKeyPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = LaunchpadContentView(
            model: model,
            wallpaper: wallpaperStore,
            gridFocus: gridFocus
        )
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hosting
        hostingView = hosting
        self.panel = panel
        installKeyHandlers(on: panel)
        return screen
    }

    /// 装配面板键盘 / 滚轮路由。
    private func installKeyHandlers(on panel: AlwaysKeyPanel) {
        let handlers = panel.keyHandlers
        // 面板内交互即取消「点外部/失焦」排下的收起计时（P2-18）
        panel.onUserInteraction = { [weak self] in
            self?.cancelAutoClose()
        }
        handlers.onEscape = { [weak self] in
            self?.handleEscapeKey()
        }
        handlers.onArrowLeft = { [weak self] in self?.handleArrow(.left) }
        handlers.onArrowRight = { [weak self] in self?.handleArrow(.right) }
        handlers.onArrowUp = { [weak self] in self?.handleArrow(.up) }
        handlers.onArrowDown = { [weak self] in self?.handleArrow(.down) }
        handlers.onTab = { [weak self] shifted in self?.handleTab(shiftedBy: shifted) }
        handlers.onActivate = { [weak self] in self?.activateFocusedItem() }
        handlers.onPrintableKey = { [weak self] characters in
            self?.handleTypeToSearch(characters)
        }
        handlers.onPageScroll = { [weak self] event in
            self?.handlePageScroll(event)
        }
    }

    /// Esc 分层：组字中交给输入法；搜索词非空先清空搜索词；否则按空白点击语义
    /// （关文件夹 → 清选择 → 收起）。与 `LaunchpadContentView` 的 `.onExitCommand`
    /// 共用 `EscapeKeyRouter` 判定。
    private func handleEscapeKey() {
        let composing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        switch EscapeKeyRouter.action(
            isComposingText: composing,
            searchQuery: model.searchQuery,
            // 文件夹打开时优先关文件夹（既有分层），焦点层让位
            hasGridFocus: gridFocus.focusedIndex != nil && model.openedFolder == nil
        ) {
        case .passThrough:
            return
        case .clearSearch:
            model.searchQuery = ""
            model.searchFocusTrigger += 1  // 清空后保持搜索框焦点，便于接着输入
        case .dismissGridFocus:
            // 有键盘焦点时 Esc 只退出焦点，不收起面板（P3-4）
            gridFocus.clear()
        case .background:
            model.handleBackgroundTap()
        }
    }

    /// 「输入即搜索」：面板层先收到的可打印字符直接写入查询，再请求聚焦搜索框。
    /// 聚焦是异步的，先写查询才不会丢掉首个字符；聚焦生效后按键由 field editor
    /// 处理，不再经面板 keyDown，因此不会重复插入。
    private func handleTypeToSearch(_ characters: String) {
        model.searchQuery += characters
        model.searchFocusTrigger += 1
    }

    // MARK: - 网格键盘导航（P3-4）

    /// 方向键统一路由。优先级：搜索态结果选择 → 网格焦点移动 → ←→ 翻页。
    /// 有焦点时方向键只移动焦点，不会与翻页叠加；无焦点时维持原 ←→ 翻页语义。
    private func handleArrow(_ direction: GridFocusNavigator.Direction) {
        if !model.searchQuery.isEmpty {
            switch direction {
            case .up:
                model.searchSelectedIndex = max(model.searchSelectedIndex - 1, 0)
            case .down:
                let hits = model.searchHits
                guard !hits.isEmpty else { return }
                model.searchSelectedIndex = min(model.searchSelectedIndex + 1, hits.count - 1)
            case .left, .right, .next, .previous:
                break
            }
            return
        }
        guard model.openedFolder == nil else { return }

        if gridFocus.focusedIndex != nil {
            moveGridFocus(direction)
            return
        }
        // 无焦点：↑↓ 不做事，←→ 仍是翻页（分页模式、且落位动画未结束不翻页）
        guard direction == .left || direction == .right,
              model.settings.browsingStyle == .paged,
              PageSettleGuard.allowsNavigation(isSettlingPageDrag: model.isSettlingPageDrag) else { return }
        if direction == .left {
            model.previousPage()
        } else {
            model.nextPage()
        }
    }

    /// Tab / Shift-Tab：进入网格焦点或在应用之间移动。
    private func handleTab(shiftedBy shifted: Bool) {
        guard model.searchQuery.isEmpty, model.openedFolder == nil else { return }
        moveGridFocus(shifted ? .previous : .next)
    }

    @discardableResult
    private func moveGridFocus(_ direction: GridFocusNavigator.Direction) -> Bool {
        let items = currentPageItems
        guard !items.isEmpty else {
            gridFocus.clear()
            return false
        }
        switch GridFocusNavigator.move(
            from: gridFocus.focusedIndex,
            direction: direction,
            count: items.count,
            columns: model.density.columns
        ) {
        case let .focus(index):
            gridFocus.set(index: index, page: model.currentPage)
            return true
        case .turnPage:
            let forward = direction == .right || direction == .down || direction == .next
            return turnPageForGridFocus(forward: forward)
        case .stay:
            // 垂直方向到边界：消费按键，不做翻页
            return true
        case .clear:
            gridFocus.clear()
            return false
        }
    }

    /// 焦点走到行首/行尾时翻页，并把焦点落到新页的第一个/最后一个格位。
    private func turnPageForGridFocus(forward: Bool) -> Bool {
        guard model.settings.browsingStyle == .paged,
              model.openedFolder == nil,
              model.searchQuery.isEmpty,
              PageSettleGuard.allowsNavigation(isSettlingPageDrag: model.isSettlingPageDrag) else { return true }
        let target = model.currentPage + (forward ? 1 : -1)
        guard target >= 0, target < model.pageCount else { return true }
        let pages = model.layout.pages
        let items = pages.indices.contains(target) ? pages[target].items : []
        // 先把 pageIndex 对齐目标页：视图层 onChange(currentPage) 只在 pageIndex
        // 不一致时清焦点，这样键盘翻页不会把刚落的焦点误清掉。
        gridFocus.set(index: items.isEmpty ? nil : (forward ? 0 : items.count - 1), page: target)
        model.goToPage(target)
        return true
    }

    /// Return / Enter：启动网格焦点项（文件夹则打开）；搜索态启动当前高亮结果。
    private func activateFocusedItem() {
        if !model.searchQuery.isEmpty {
            let hits = model.searchHits
            guard !hits.isEmpty else { return }
            let index = min(max(model.searchSelectedIndex, 0), hits.count - 1)
            model.launch(appID: hits[index].appID)
            return
        }
        guard model.openedFolder == nil,
              let focused = gridFocus.focusedIndex,
              gridFocus.pageIndex == model.currentPage else { return }
        let items = currentPageItems
        guard items.indices.contains(focused) else { return }
        switch items[focused] {
        case let .app(appID):
            model.launch(appID: appID)
        case let .folder(folder):
            withAnimation(MotionPreference.pageSlide(reduceMotion: reduceMotion)) {
                model.openFolder(page: model.currentPage, folderID: folder.id)
            }
        }
    }

    private var currentPageItems: [SlotItem] {
        let pages = model.layout.pages
        guard pages.indices.contains(model.currentPage) else { return [] }
        return pages[model.currentPage].items
    }

    // MARK: - 交互式翻页（横滑跟手）

    /// 横滑事件入口：写入跟手偏移；松手/离散事件返回落位动作。
    private func handlePageScroll(_ event: PageScrollEvent) {
        guard model.settings.browsingStyle == .paged,
              model.searchQuery.isEmpty,
              model.openedFolder == nil else { return }
        // 落位动画期间：离散滚轮与惯性事件照旧不参与（等落位收尾）；
        // 新手势开始则按动画曲线解析表现值无缝接管跟手（消除落位期输入死窗）
        var resumingFrom: CGFloat?
        if model.isSettlingPageDrag {
            guard event.isGestureStart, !event.isMomentum, !event.isDiscrete,
                  let presentation = model.takeOverPageSettle() else { return }
            resumingFrom = presentation
        }
        let action = pageGesture.feed(
            delta: event.delta,
            isGestureStart: event.isGestureStart,
            isEnded: event.isEnded,
            isMomentum: event.isMomentum,
            isDiscrete: event.isDiscrete,
            canGoBackward: model.currentPage > 0,
            canGoForward: model.currentPage < model.pageCount - 1,
            pageWidth: model.pageWidth,
            at: Date(),
            resumingFrom: resumingFrom
        )
        switch action {
        case .ignored:
            return  // 不同步偏移：displayOffset 是上一手势残留
        case .tracking:
            model.pageDragOffset = pageGesture.displayOffset
            schedulePageIdleSettle()
        case .settle(let direction):
            model.pageDragOffset = pageGesture.displayOffset
            cancelPageIdleSettle()
            model.settlePageDrag(commitDirection: direction)
        }
    }

    /// 兜底：异常收不到 .ended（手势被系统打断等）时按当前进度落位。
    /// .ended 正常都会送达，取较长的 0.6s 以免打断"按住手指停顿"中的手势。
    private func schedulePageIdleSettle() {
        cancelPageIdleSettle()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let action = pageGesture.timeoutSettle(pageWidth: model.pageWidth, at: Date())
            guard case let .settle(direction) = action else { return }
            model.settlePageDrag(commitDirection: direction)
        }
        pageIdleSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func cancelPageIdleSettle() {
        pageIdleSettleWork?.cancel()
        pageIdleSettleWork = nil
    }

    /// 设置的目标屏幕。
    private func targetScreen() -> NSScreen {
        let position = model.settings.screenPosition
        let screens = NSScreen.screens
        switch position {
        case .main:
            return NSScreen.main ?? screens.first ?? NSScreen()
        case .active:
            // 「当前激活屏幕」：
            // 1) 有键盘焦点窗口（例如从设置/卸载窗口唤起）→ 用该窗口所在屏；
            // 2) 否则用鼠标所在屏 —— 全局快捷键唤起时面板还没有焦点窗口，
            //    LaunchX 又从不 NSApp.activate，keyWindow 通常为 nil；
            //    若此处退回主屏，多屏下「激活屏」就等价于「主屏」（P2-17）；
            // 3) 都取不到时退回菜单栏所在屏。
            if let keyWindow = NSApp.keyWindow,
               let screen = keyWindow.screen ?? screens.first(where: { $0.frame.intersects(keyWindow.frame) }) {
                return screen
            }
            return screenContainingMouse() ?? NSScreen.main ?? screens.first ?? NSScreen()
        case .cursor:
            return screenContainingMouse() ?? NSScreen.main ?? screens.first ?? NSScreen()
        case .dock:
            // Dock 可能被拖到任意屏的任意边缘，只有 Dock 窗口的位置能反映真实所在屏；
            // 读不到（例如自动隐藏时窗口不在屏上）就退回菜单栏所在屏（主屏），
            // 不再把「主屏」当成「Dock 屏」的等价说法（P2-17）。
            return dockScreen() ?? NSScreen.main ?? screens.first ?? NSScreen()
        }
    }

    /// 鼠标所在屏。
    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }

    /// Dock 停靠的屏幕：枚举 Dock 的窗口位置（图标条/放大镜/全屏遮罩都算），
    /// 取与屏幕重叠面积最大者；读不到返回 nil，由调用方退回主屏。
    private func dockScreen() -> NSScreen? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var dockRects: [CGRect] = []
        for info in infos {
            guard (info[kCGWindowOwnerName as String] as? String) == "Dock",
                  let layer = info[kCGWindowLayer as String] as? Int, layer > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat, let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
            else { continue }
            dockRects.append(CGRect(x: x, y: y, width: width, height: height))
        }
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) else { return nil }
        guard let frame = ScreenPick.screenFrame(
            mostOverlapping: dockRects,
            screenFrames: screens.map(\.frame),
            primaryFrame: primary.frame
        ) else { return nil }
        return screens.first { $0.frame == frame }
    }

    /// 展开期间直接沿用已有缓存，把新截图和根视图更新延后到动画结束。
    /// 快速展开→收起会取消本次刷新，不在隐藏面板中做无效捕获。
    /// 冒烟/自动化模式：只验证窗口装配，不做壁纸截图（无 GUI 的自动化会话里
    /// Metal/CoreImage 初始化可能抛 ObjC 异常，进程无法捕获）。
    private var skipsWallpaperCapture: Bool {
        ProcessInfo.processInfo.arguments.contains("-launchx-smoke")
    }

    private func scheduleWallpaperRefresh(for screen: NSScreen) {
        wallpaperRefreshWork?.cancel()
        // 关闭「模糊壁纸」：背景走毛玻璃，既不需要截图也不需要缓存
        guard model.settings.blurWallpaper, !skipsWallpaperCapture else {
            wallpaperTask?.cancel()
            wallpaperTask = nil
            wallpaperStore.image = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.isVisible else { return }
            self.wallpaperRefreshWork = nil
            self.refreshWallpaper(for: screen)
        }
        wallpaperRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideSettleDelay, execute: work)
    }

    /// 刷新壁纸：当前缓存继续显示，捕获完成后只更新图片容器（不重建根视图）。
    ///
    /// - 视频壁纸每次展开都会取到当前帧；
    /// - 无屏幕录制权限 / 无 GUI 会话 / 渲染失败时静默回退毛玻璃，仅无权限时提示一次授权入口；
    /// - 关闭「模糊壁纸」时清空缓存并跳过捕获（不截图、不模糊，也不申请权限）。
    private func refreshWallpaper(for screen: NSScreen) {
        guard model.settings.blurWallpaper, !skipsWallpaperCapture else {
            wallpaperTask?.cancel()
            wallpaperTask = nil
            wallpaperStore.image = nil
            return
        }
        wallpaperTask?.cancel()
        wallpaperTask = Task { [weak self] in
            let outcome = await WallpaperCapture.captureWallpaper(for: screen)
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .captured(let image):
                // 只改图片：rootView 不动，搜索焦点与 @State 全部保留
                self.wallpaperStore.image = image
            case .unavailable, .renderFailed:
                self.wallpaperStore.image = nil
            }
            // 面板实际展开时提示授权（预热/收起状态不打扰）；每会话一次
            if case .unavailable = outcome, self.model.isVisible, self.model.settings.blurWallpaper,
               !self.hasNotifiedWallpaperPermission {
                self.hasNotifiedWallpaperPermission = true
                ToastManager.shared.info("开启「屏幕录制」权限后可显示壁纸背景（系统设置 → 隐私与安全性 → 屏幕录制）")
            }
        }
    }

    /// 启动时预热一次壁纸捕获，首次展开即刻可用；关闭模糊壁纸时不预热。
    public func preheatWallpaper() {
        guard model.settings.blurWallpaper, !skipsWallpaperCapture else { return }
        guard wallpaperTask == nil, wallpaperStore.image == nil else { return }
        refreshWallpaper(for: targetScreen())
    }

    // MARK: - 失焦延时收起

    private func installAutoHideMonitors() {
        removeAutoHideMonitors()
        // 点击面板外任意处 → 按延时收起
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleAutoClose()
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleAutoClose()
            }
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isVisible else { return }
                let screen = self.targetScreen()
                self.panel?.setFrame(screen.frame, display: true)
                self.refreshWallpaper(for: screen)
            }
        }
    }

    private func removeAutoHideMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let observer = activationObserver {
            NotificationCenter.default.removeObserver(observer)
            activationObserver = nil
        }
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            screenChangeObserver = nil
        }
    }

    /// 面板之外还有我们自己的窗口在前台（设置/卸载窗口、重命名等 sheet）时暂停自动收起。
    /// 否则「右键菜单 → 设置 / 重命名」会先让面板消失，流程被打断（P2-18）。
    private var isSystemUIPresenting: Bool {
        guard NSApp.isActive else { return false }  // 真正切走 App 时仍照常收起
        if panel?.attachedSheet != nil { return true }
        if let key = NSApp.keyWindow, key !== panel, key.isVisible { return true }
        return false
    }

    /// 按设置延时收起。
    private func scheduleAutoClose() {
        closeWorkItem?.cancel()
        guard model.isVisible else { return }
        guard !isSystemUIPresenting else { return }  // 系统弹窗/sheet 期间暂停
        guard let seconds = model.settings.closeDelay.seconds else { return }  // never
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.isVisible else { return }
            self.hide()
        }
        closeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 面板内点击（取消待收起计时）。
    public func cancelAutoClose() {
        closeWorkItem?.cancel()
    }

    // MARK: - NSWindowDelegate

    nonisolated public func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            // 面板失焦（切到其他窗口）也按延时收起
            if self.model.isVisible {
                self.scheduleAutoClose()
            }
        }
    }
}
