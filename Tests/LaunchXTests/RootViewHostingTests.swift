import AppKit
import SwiftUI
import Testing
@testable import LaunchXCore

// MARK: - 根视图挂载冒烟（防环境缺失崩溃回归）

/// 回归背景：根视图曾声明 `@Environment(Model.self)` 却在自身 body 内 `.environment(model)`
/// 注入（只对子视图生效），NSHostingView 挂窗时根视图取值触发 SwiftUI 断言直接崩溃
/// （EXC_BREAKPOINT，EnvironmentValues.subscript.getter）。
/// 此处把各窗口根视图按控制器同款方式挂入 NSWindow 并跑一轮 runloop——
/// 修复缺失时进程会直接 SIGTRAP，测试无法通过。
@MainActor
struct RootViewHostingTests {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXHostingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeWindow(hosting: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        return window
    }

    @Test func launchpadRootViewMountsWithoutCrash() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps = [
                "a": AppRecord(
                    id: "a", name: "App A", bundleName: "App A",
                    bundleId: "dev.test.a", version: "1.0",
                    path: "/Applications/App A.app", category: nil
                ),
            ]
            layout.pages = [PageRecord(id: UUID(), items: [.app(id: "a")])]
        }

        let hosting = NSHostingView(
            rootView: LaunchpadContentView(
                model: model,
                wallpaper: LaunchpadWallpaperStore(),
                gridFocus: GridKeyboardFocus()
            )
        )
        let window = makeWindow(hosting: hosting)
        spinRunLoop(0.3)

        #expect(window.contentView === hosting)
        window.orderOut(nil)
    }

    @Test func uninstallRootViewMountsWithoutCrash() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let app = AppRecord(
            id: "a", name: "App A", bundleName: "App A",
            bundleId: "dev.test.a", version: "1.0",
            path: "/Applications/App A.app", category: nil
        )
        let hosting = NSHostingView(
            rootView: UninstallContentView(
                model: UninstallModel(app: app, layoutStore: store),
                onClose: {}
            )
        )
        let window = makeWindow(hosting: hosting)
        spinRunLoop(0.3)

        #expect(window.contentView === hosting)
        window.orderOut(nil)
    }

    @Test func uninstallLimitedAccessBannerMountsWithoutCrash() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let app = AppRecord(
            id: "a", name: "App A", bundleName: "App A",
            bundleId: "dev.test.a", version: "1.0",
            path: "/Applications/App A.app", category: nil
        )
        let model = UninstallModel(app: app, layoutStore: store)
        model.needsFullDiskAccess = true
        let hosting = NSHostingView(
            rootView: UninstallContentView(model: model, onClose: {})
        )
        let window = makeWindow(hosting: hosting)
        spinRunLoop(0.3)

        #expect(window.contentView === hosting)
        window.orderOut(nil)
    }

    @Test func preferencesRootViewMountsWithoutCrash() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let content = PreferencesRootView()
            .environment(PreferencesModel(store: store))
        let hosting = NSHostingView(rootView: content.frame(minWidth: 680, minHeight: 520))
        let window = makeWindow(hosting: hosting)
        spinRunLoop(0.3)

        #expect(window.contentView === hosting)
        window.orderOut(nil)
    }
}

// MARK: - Esc 分层 / 框选坐标换算（P1-5、P1-7 回归）

/// P1-5：Esc 必须分层退出（组字 → 清搜索 → 关文件夹/清选择/收起），而不是无条件收起面板。
/// P1-7：复核时用合成鼠标事件实测确认，`PagedGridArea` 的 `.coordinateSpace("pageViewSpace")`
/// 锚在页带视图自身、原点即视口左上角，所以 DragGesture 上报的 location 已经是视口坐标，
/// 各页稳态下框选本身是准的；真正会错位的是「跟手/落位偏移未归零」期间——页内 frame 与
/// 视口坐标相差 `pageDragOffset`。这里锁定换算契约，防止后续回归。
@MainActor
struct EscapeAndMarqueeCoordinateTests {

    // MARK: Esc 分层

    @Test func escapeClearsSearchBeforeDismissing() {
        #expect(EscapeKeyRouter.action(isComposingText: false, searchQuery: "chrome") == .clearSearch)
        #expect(EscapeKeyRouter.action(isComposingText: false, searchQuery: "a") == .clearSearch)
    }

    @Test func escapeFallsBackToBackgroundTapWhenSearchEmpty() {
        #expect(EscapeKeyRouter.action(isComposingText: false, searchQuery: "") == .background)
    }

    @Test func escapePassesThroughWhileComposingText() {
        // 输入法组字中：即使搜索框里已有候选串，Esc 也只应取消组字，不拦面板
        #expect(EscapeKeyRouter.action(isComposingText: true, searchQuery: "zhong") == .passThrough)
        #expect(EscapeKeyRouter.action(isComposingText: true, searchQuery: "") == .passThrough)
    }

    // MARK: 框选坐标换算

    @Test func settledPageKeepsFramesUnchanged() {
        // 稳态：页带 offset 与 settled 页正好抵消，页内坐标 == 视口坐标
        let frames = ["a": CGRect(x: 10, y: 10, width: 50, height: 50)]
        #expect(MarqueeCoordinate.viewSpaceFrames(frames, pageOriginX: 0) == frames)
    }

    @Test func draggingPageShiftsFramesIntoViewSpace() {
        let frames = ["a": CGRect(x: 300, y: 40, width: 60, height: 60)]
        let shifted = MarqueeCoordinate.viewSpaceFrames(frames, pageOriginX: -200)
        #expect(shifted["a"] == CGRect(x: 100, y: 40, width: 60, height: 60))
    }

    @Test func marqueeOnSecondPageSelectsWithViewSpaceFrames() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXMarqueeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps = [
                "a": AppRecord(
                    id: "a", name: "App A", bundleName: "App A",
                    bundleId: "dev.test.a", version: "1.0",
                    path: "/Applications/App A.app", category: nil
                ),
            ]
            layout.pages = [PageRecord(id: UUID(), items: []), PageRecord(id: UUID(), items: [.app(id: "a")])]
        }

        // 第 2 页（index 1）的页内 frame → 视口坐标需减去落位偏移
        let pageLocal = ["a": CGRect(x: 300, y: 100, width: 100, height: 100)]

        // 稳态（落位结束、偏移归零）：第 2 页页内坐标 == 视口坐标，框选本就命中
        // （合成鼠标事件实测：pageViewSpace 的原点就是视口左上角，不随 settled 页索引平移）
        model.marqueeRect = CGRect(x: 290, y: 90, width: 100, height: 100)
        model.updateMarqueeSelection(
            itemFrames: MarqueeCoordinate.viewSpaceFrames(pageLocal, pageOriginX: 0), inPage: 1
        )
        #expect(model.selectedAppIDs == ["a"])

        model.marqueeRect = CGRect(x: 50, y: 50, width: 100, height: 100)  // 视口坐标，命中 x ∈ 50...150

        // 未换算：页内坐标 300...400 与框选不相交（这正是"跨页错位"的表现）
        model.updateMarqueeSelection(itemFrames: pageLocal, inPage: 1)
        #expect(model.selectedAppIDs.isEmpty)

        // 换算到视口坐标后（originX = -200 → x 100...200）应与框选相交并选中第 2 页的 a
        let viewSpace = MarqueeCoordinate.viewSpaceFrames(pageLocal, pageOriginX: -200)
        model.updateMarqueeSelection(itemFrames: viewSpace, inPage: 1)
        #expect(model.selectedAppIDs == ["a"])
    }
}

// MARK: - Wave 2 交互回归（P2-12 / P2-13 / P2-15 / P2-16 / P2-17）

/// 这些用例锁定的是纯函数/状态机契约：显示路由、落位守护、壁纸兜底策略、
/// 多屏换算，以及壁纸容器「只换图、不换视图」的语义。
@MainActor
struct Wave2InteractionRegressionTests {

    // MARK: P2-15 收起动画期间再唤出应当展开

    @Test func toggleDuringHideAnimationShowsAgain() {
        // 刚 hide()、窗口还没 orderOut（isVisible 仍为 true）时，再按唤出键应重新展开
        #expect(PresentationRouter.intent(isVisible: true, isHiding: true) == .show)
        #expect(PresentationRouter.intent(isVisible: false, isHiding: true) == .show)
        // 收起完成后的正常语义不变
        #expect(PresentationRouter.intent(isVisible: true, isHiding: false) == .hide)
        #expect(PresentationRouter.intent(isVisible: false, isHiding: false) == .show)
    }

    // MARK: P2-13 落位动画期间翻页入口让路

    @Test func pageNavigationWaitsForSettle() {
        #expect(PageSettleGuard.allowsNavigation(isSettlingPageDrag: false))
        #expect(!PageSettleGuard.allowsNavigation(isSettlingPageDrag: true))
    }

    // MARK: P2-16 壁纸捕获兜底

    @Test func wallpaperCaptureSkipsWhenDisabledOrOffConsole() {
        // 只在「启用模糊壁纸」且「当前在控制台会话」时才截图
        #expect(WallpaperCapture.shouldAttemptCapture(blurWallpaper: true, isOnConsole: true))
        #expect(!WallpaperCapture.shouldAttemptCapture(blurWallpaper: false, isOnConsole: true))
        #expect(!WallpaperCapture.shouldAttemptCapture(blurWallpaper: true, isOnConsole: false))
        #expect(!WallpaperCapture.shouldAttemptCapture(blurWallpaper: false, isOnConsole: false))
    }

    // MARK: P2-17 多屏 / Dock 屏换算

    @Test func cgToAppKitConversionFlipsY() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let converted = ScreenPick.appKitRect(
            fromCG: CGRect(x: 100, y: 100, width: 50, height: 40),
            primaryFrame: primary
        )
        #expect(converted == CGRect(x: 100, y: 940, width: 50, height: 40))
    }

    @Test func dockOnSecondaryScreenMapsToSecondaryScreen() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        // Dock 贴在副屏左缘（CG 坐标）。之前 .dock 直接返回 NSScreen.main，
        // 多屏下会把面板放到主屏。
        let dockCG = CGRect(x: 1920, y: 200, width: 60, height: 600)
        let frame = ScreenPick.screenFrame(
            mostOverlapping: [dockCG],
            screenFrames: [primary, secondary],
            primaryFrame: primary
        )
        #expect(frame == secondary)
    }

    @Test func screenPickReturnsNilWithoutOverlap() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(ScreenPick.screenFrame(
            mostOverlapping: [CGRect(x: 5000, y: 0, width: 60, height: 600)],
            screenFrames: [primary],
            primaryFrame: primary
        ) == nil)
        #expect(ScreenPick.screenFrame(
            mostOverlapping: [],
            screenFrames: [primary],
            primaryFrame: primary
        ) == nil)
    }

    // MARK: P2-12 壁纸容器只换图，不重建视图

    @Test func wallpaperStoreKeepsIdentityWhenImageChanges() {
        let store = LaunchpadWallpaperStore()
        let identity = ObjectIdentifier(store)
        let view = NSHostingView(rootView: Text("wallpaper").environment(store))
        store.image = NSImage(size: NSSize(width: 10, height: 10))
        store.image = NSImage(size: NSSize(width: 20, height: 20))
        // 容器对象身份不变 —— 控制器只改 image，NSHostingView 与视图树都不需要重建
        #expect(ObjectIdentifier(store) == identity)
        #expect(store.image != nil)
        withExtendedLifetime(view) {}
    }
}

// MARK: - Wave 3 键盘导航 / 减弱动态效果 / 修饰键归一化（P3-1 / P3-3 / P3-4）

/// P3-1：Caps Lock、数字键盘等功能键位不得影响「⌘ 点击 = 多选」「输入即搜索」判定。
/// P3-3：减弱动态效果时关闭内容缩放与弹簧，只留快速淡入淡出。
/// P3-4：网格键盘焦点状态机——Tab/方向键移动、行首行尾翻页、边界不越界，
///        且 Esc 在有焦点时只退出焦点（分层不回归）。
@MainActor
struct Wave3KeyboardAndMotionTests {

    // MARK: P3-1 修饰键归一化

    @Test func capsLockDoesNotBreakCommandClick() {
        #expect(InteractionModifiers.hasCommand([.command, .capsLock]))
        #expect(InteractionModifiers.hasCommand([.command, .capsLock, .numericPad]))
        #expect(InteractionModifiers.hasCommand([.command]))
        // 没有 ⌘ 时不算
        #expect(!InteractionModifiers.hasCommand([.capsLock]))
        #expect(!InteractionModifiers.hasCommand([]))
        #expect(!InteractionModifiers.hasCommand([.option, .capsLock]))
    }

    @Test func capsLockDoesNotBlockTypeToSearch() {
        #expect(!InteractionModifiers.blocksTypeToSearch([.capsLock]))
        #expect(!InteractionModifiers.blocksTypeToSearch([]))
        // ⌘⌃⌥ 仍然阻断（这些是快捷键前缀）
        #expect(InteractionModifiers.blocksTypeToSearch([.command, .capsLock]))
        #expect(InteractionModifiers.blocksTypeToSearch([.option]))
        #expect(InteractionModifiers.blocksTypeToSearch([.control]))
    }

    // MARK: P3-3 减弱动态效果

    @Test func reducedMotionDisablesScaleAndSpring() {
        let reduced = MotionPreference.profile(reduceMotion: true)
        #expect(reduced.contentScaleStart == 1)
        #expect(!reduced.usesSpringTransition)
        #expect(reduced.transitionDuration <= 0.15)

        let standard = MotionPreference.profile(reduceMotion: false)
        #expect(standard.contentScaleStart == 1.15)
        #expect(standard.usesSpringTransition)
    }

    @Test func contentScaleInterpolatesBetweenStartAndOne() {
        #expect(MotionPreference.contentScale(progress: 0, reduceMotion: false) == 1.15)
        #expect(MotionPreference.contentScale(progress: 1, reduceMotion: false) == 1.0)
        // 减弱动态效果：任何进度都不缩放
        #expect(MotionPreference.contentScale(progress: 0, reduceMotion: true) == 1.0)
        #expect(MotionPreference.contentScale(progress: 1, reduceMotion: true) == 1.0)
        // 越界进度按端点钳制
        #expect(MotionPreference.contentScale(progress: -1, reduceMotion: false) == 1.15)
        #expect(MotionPreference.contentScale(progress: 2, reduceMotion: false) == 1.0)
    }

    // MARK: P3-4 网格焦点状态机

    private let columns = 5

    @Test func tabEntersGridAtFirstOrLastItem() {
        #expect(GridFocusNavigator.move(from: nil, direction: .next, count: 8, columns: columns) == .focus(0))
        #expect(GridFocusNavigator.move(from: nil, direction: .previous, count: 8, columns: columns) == .focus(7))
        // 空页没有可聚焦项
        #expect(GridFocusNavigator.move(from: nil, direction: .next, count: 0, columns: columns) == .clear)
    }

    @Test func horizontalMovesStayInRowUntilEdge() {
        // 行内：第 0 行 0…4 列
        #expect(GridFocusNavigator.move(from: 2, direction: .right, count: 8, columns: columns) == .focus(3))
        #expect(GridFocusNavigator.move(from: 2, direction: .left, count: 8, columns: columns) == .focus(1))
        // 行尾继续右键 → 交给翻页；行首继续左键 → 交给翻页
        #expect(GridFocusNavigator.move(from: 4, direction: .right, count: 8, columns: columns) == .turnPage)
        #expect(GridFocusNavigator.move(from: 0, direction: .left, count: 8, columns: columns) == .turnPage)
        // 末项（不满一行）右键也翻页
        #expect(GridFocusNavigator.move(from: 7, direction: .right, count: 8, columns: columns) == .turnPage)
    }

    @Test func verticalMovesStopAtGridEdge() {
        #expect(GridFocusNavigator.move(from: 0, direction: .down, count: 8, columns: columns) == .focus(5))
        #expect(GridFocusNavigator.move(from: 5, direction: .up, count: 8, columns: columns) == .focus(0))
        // 顶行继续上 / 末行继续下：停在原地，不翻页（翻页只在水平方向）
        #expect(GridFocusNavigator.move(from: 1, direction: .up, count: 8, columns: columns) == .stay)
        #expect(GridFocusNavigator.move(from: 6, direction: .down, count: 8, columns: columns) == .stay)
        #expect(GridFocusNavigator.move(from: 7, direction: .down, count: 8, columns: columns) == .stay)
    }

    @Test func tabWrapsToPageTurnAtBoundaries() {
        #expect(GridFocusNavigator.move(from: 6, direction: .next, count: 8, columns: columns) == .focus(7))
        #expect(GridFocusNavigator.move(from: 7, direction: .next, count: 8, columns: columns) == .turnPage)
        #expect(GridFocusNavigator.move(from: 1, direction: .previous, count: 8, columns: columns) == .focus(0))
        #expect(GridFocusNavigator.move(from: 0, direction: .previous, count: 8, columns: columns) == .turnPage)
        // 单页单项目：Tab 也要求翻页
        #expect(GridFocusNavigator.move(from: 0, direction: .next, count: 1, columns: columns) == .turnPage)
    }

    @Test func staleFocusFallsBackToEdgeItem() {
        // 页面收缩后焦点索引可能越界：重新落到边界项而不是崩溃
        #expect(GridFocusNavigator.move(from: 99, direction: .right, count: 8, columns: columns) == .focus(0))
        #expect(GridFocusNavigator.move(from: 99, direction: .left, count: 8, columns: columns) == .focus(7))
    }

    // MARK: P3-4 Esc 分层：有焦点先退出焦点

    @Test func escapeDismissesGridFocusBeforePanel() {
        #expect(EscapeKeyRouter.action(
            isComposingText: false, searchQuery: "", hasGridFocus: true
        ) == .dismissGridFocus)
        #expect(EscapeKeyRouter.action(
            isComposingText: false, searchQuery: "", hasGridFocus: false
        ) == .background)
        // 搜索词优先清空；组字优先放行
        #expect(EscapeKeyRouter.action(
            isComposingText: false, searchQuery: "chr", hasGridFocus: true
        ) == .clearSearch)
        #expect(EscapeKeyRouter.action(
            isComposingText: true, searchQuery: "", hasGridFocus: true
        ) == .passThrough)
    }
}
