import AppKit
import Foundation
import Testing
@testable import LaunchXCore
import LaunchXTestSupport

// MARK: - 2026-11-14 复查缺陷的回归测试（F1–F12）

@Suite(.serialized)
@MainActor
struct BugFixRegressionTests {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXBugFix-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(in directory: URL) -> LayoutStore {
        LayoutStore(directory: directory)
    }

    private func folderAppIDs(on page: PageRecord) -> [[String]] {
        page.items.compactMap(\.folder).map(\.appIDs)
    }

    // MARK: F1 来源目录整体读不到时保留排列

    @Test func unreadableSourceDirectoryPreservesAppsAndMissingCount() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unmounted = dir.appendingPathComponent("UnmountedVolume", isDirectory: true)

        var app = makeApp("a")
        app.path = unmounted.appendingPathComponent("a.app").path
        var layout = LayoutSnapshot()
        layout.apps["a"] = app
        layout.pages = [PageRecord(items: [.app(id: "a")])]

        let diagnostics = AppIndex.scanWithDiagnostics(directories: [unmounted])
        #expect(diagnostics.records.isEmpty)
        #expect(diagnostics.failedDirectories.count == 1)

        // 连续两次重扫（启动一次 + 目录变化触发一次）都不得移除应用或累计缺失。
        for _ in 0..<2 {
            let result = SyncEngine.merge(
                scanned: diagnostics.records,
                into: &layout,
                capacityPerPage: 35,
                unreadablePrefixes: diagnostics.failedDirectories.map(\.path)
            )
            #expect(result.removedAppIDs.isEmpty)
        }
        #expect(layout.apps["a"] != nil)
        #expect(layout.placedAppIDs == ["a"])
        #expect(layout.apps["a"]?.missingScans == 0)
    }

    @Test func unreadablePrefixMatchesDirectoryBoundaryOnly() {
        let prefixes = ["/Volumes/Extern"]
        #expect(SyncEngine.isUnderUnreadableDirectory("/Volumes/Extern/A.app", prefixes: prefixes))
        #expect(SyncEngine.isUnderUnreadableDirectory("/Volumes/Extern", prefixes: prefixes))
        #expect(!SyncEngine.isUnderUnreadableDirectory("/Volumes/Extern2/A.app", prefixes: prefixes))
        #expect(!SyncEngine.isUnderUnreadableDirectory("", prefixes: prefixes))
        #expect(!SyncEngine.isUnderUnreadableDirectory("/Applications/A.app", prefixes: []))
    }

    /// F1 的完整入口回归：`LaunchpadModel.rescan()` 必须使用带诊断的扫描，
    /// 否则「启动一次 + 目录变化触发一次」两次重扫就会丢掉整卷应用的排列。
    @Test func rescanKeepsAppsWhenSourceDirectoryUnreadable() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let unmounted = dir.appendingPathComponent("UnmountedVolume", isDirectory: true)
        store.updateSources { sources in
            sources = [SourceConfig(path: unmounted.path, enabled: true, kind: .custom)]
        }
        var app = makeApp("a")
        app.path = unmounted.appendingPathComponent("a.app").path
        store.updateLayout { layout in
            layout.apps["a"] = app
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }

        let model = LaunchpadModel(store: store)
        for _ in 0..<2 {  // 两次重扫：旧实现第二次就会移除应用
            model.rescan()
            for _ in 0..<300 where model.isScanning {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!model.isScanning)
        }
        ToastManager.shared.dismissAll()
        #expect(store.state.layout.apps["a"] != nil)
        #expect(store.state.layout.placedAppIDs == ["a"])
    }

    // MARK: F6 只存在注册表的应用被卸载后清理

    @Test func registryOnlyAppPrunedAfterTwoScansWhenFileGone() {
        var hidden = makeApp("hidden", hidden: true)
        hidden.path = tempDirectory().appendingPathComponent("hidden.app").path  // 不存在
        var layout = LayoutSnapshot()
        layout.apps["hidden"] = hidden
        layout.pages = [PageRecord()]

        let first = SyncEngine.merge(scanned: [], into: &layout, capacityPerPage: 35)
        #expect(first.removedAppIDs.isEmpty)
        #expect(layout.apps["hidden"]?.missingScans == 1)

        let second = SyncEngine.merge(scanned: [], into: &layout, capacityPerPage: 35)
        #expect(second.removedAppIDs == ["hidden"])
        #expect(layout.apps["hidden"] == nil)
    }

    @Test func registryOnlyAppKeptWhileFileStillExists() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appPath = dir.appendingPathComponent("kept.app")
        try Data("x".utf8).write(to: appPath)

        var hidden = makeApp("kept", hidden: true)
        hidden.path = appPath.path
        var layout = LayoutSnapshot()
        layout.apps["kept"] = hidden
        layout.pages = [PageRecord()]

        for _ in 0..<3 {
            _ = SyncEngine.merge(scanned: [], into: &layout, capacityPerPage: 35)
        }
        #expect(layout.apps["kept"] != nil)  // 扫描不到但文件仍在：不判定为卸载
    }

    // MARK: F2 多选陈旧选择 / 重复成员

    @Test func droppingOntoAppPrunesStaleSelectionThenMergeRefuses() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        store.updateLayout { layout in
            layout.apps = [
                "a": makeApp("a"), "b": makeApp("b"), "c": makeApp("c"),
            ]
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b"), .app(id: "c")])]
        }

        // UI 序列：⌘ 选 A、B → 把未选中的 C 拖到 A 上建夹
        model.selectedAppIDs = ["a", "b"]
        model.performDrop(draggingIDs: ["c"], sourceFolderID: nil, target: .onApp(page: 0, appID: "a"))

        // A 已被合入文件夹，必须从选择集里摘除（旧实现会留下陈旧选择）
        #expect(model.selectedAppIDs == ["b"])

        // 只剩 1 项：合并入口应拒绝，不会创建第二个包含 A 的文件夹
        model.mergeSelectionIntoNewFolder()
        ToastManager.shared.dismissAll()
        let layout = store.state.layout
        let folders = layout.pages.flatMap(folderAppIDs(on:))
        #expect(folders.count == 1)
        #expect(layout.placedAppIDs.filter { $0 == "a" }.count == 1)
    }

    @Test func mergeIntoNewFolderRemovesMemberFromExistingFolder() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        let existing = FolderRecord(name: "F", appIDs: ["a"])
        store.updateLayout { layout in
            layout.apps = ["a": makeApp("a"), "b": makeApp("b")]
            layout.pages = [PageRecord(items: [.folder(existing), .app(id: "b")])]
        }

        // 防御层：即使调用方传入了「已属于文件夹」的成员（陈旧选择），也不得复制到两处
        model.selectedAppIDs = ["a", "b"]
        model.mergeSelectionIntoNewFolder()
        ToastManager.shared.dismissAll()

        let layout = store.state.layout
        let placed = layout.placedAppIDs
        #expect(Set(placed).count == placed.count)  // 无重复
        #expect(layout.pages.flatMap(folderAppIDs(on:)).count == 1)  // 旧文件夹被摘空删除
        #expect(layout.pages[0].items.compactMap(\.folder).first?.appIDs.sorted() == ["a", "b"])
    }

    @Test func mergeIntoNewFolderDeduplicatesInput() {
        var layout = LayoutSnapshot()
        layout.apps = ["a": makeApp("a"), "b": makeApp("b")]
        layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]

        FolderEngine.mergeIntoNewFolder(appIDs: ["a", "a", "b"], page: 0, layout: &layout)
        #expect(layout.pages[0].items.compactMap(\.folder).first?.appIDs == ["a", "b"])
    }

    // MARK: F3 设置页取消隐藏走模型层

    @Test func settingsUnhidePlacesUnplacedHiddenAppWithoutCallback() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        store.updateLayout { layout in
            layout.apps["visible"] = makeApp("visible")
            layout.apps["hidden"] = makeApp("hidden", hidden: true)
            layout.pages = [PageRecord(items: [.app(id: "visible")])]
        }
        store.resetLayout()  // 隐藏项只留在注册表、不在网格

        let prefs = PreferencesModel(store: store)
        prefs.unhideApp(id: "hidden")  // 未接线：走等价后备实现

        #expect(store.state.layout.apps["hidden"]?.hidden == false)
        #expect(store.state.layout.placedAppIDs.contains("hidden"))
    }

    @Test func settingsUnhideUsesModelCallbackWhenWired() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["hidden"] = makeApp("hidden", hidden: true)
            layout.pages = [PageRecord()]
        }
        let prefs = PreferencesModel(store: store)
        prefs.onUnhideApp = { model.unhide(appID: $0) }
        prefs.unhideApp(id: "hidden")
        #expect(store.state.layout.placedAppIDs.contains("hidden"))
    }

    // MARK: F4 搜索框聚焦后的键盘路由

    @Test func searchFieldArrowKeysMoveSelection() {
        func action(_ key: UInt16, query: String = "c", hits: Int = 3, selected: Int = 0, marked: Bool = false, shift: Bool = false) -> SearchFieldKeyRouter.Action {
            SearchFieldKeyRouter.action(
                keyCode: key,
                hasMarkedText: marked,
                searchQuery: query,
                hitCount: hits,
                selectedIndex: selected,
                shiftPressed: shift
            )
        }
        #expect(action(125) == .moveSelection(1))  // ↓
        #expect(action(125, selected: 2) == .moveSelection(2))  // 到底钳住
        #expect(action(126, selected: 1) == .moveSelection(0))  // ↑
        #expect(action(126, selected: 0) == .moveSelection(0))
        // 无搜索词 / 无结果 / 输入法组字：一律放行给 field editor
        #expect(action(125, query: "") == .passThrough)
        #expect(action(125, hits: 0) == .passThrough)
        #expect(action(125, marked: true) == .passThrough)
        #expect(action(36, marked: true) == .passThrough)
    }

    @Test func searchFieldReturnActivatesAndTabRestoresGridFocus() {
        let returnAction = SearchFieldKeyRouter.action(
            keyCode: 36, hasMarkedText: false, searchQuery: "c",
            hitCount: 2, selectedIndex: 1, shiftPressed: false
        )
        #expect(returnAction == .activate)
        let tabAction = SearchFieldKeyRouter.action(
            keyCode: 48, hasMarkedText: false, searchQuery: "",
            hitCount: 0, selectedIndex: 0, shiftPressed: true
        )
        #expect(tabAction == .focusGrid(shifted: true))
        // 有搜索词时 Tab 保持 field editor 默认行为（不抢去网格）
        let tabWithQuery = SearchFieldKeyRouter.action(
            keyCode: 48, hasMarkedText: false, searchQuery: "c",
            hitCount: 2, selectedIndex: 0, shiftPressed: false
        )
        #expect(tabWithQuery == .passThrough)
    }

    // MARK: F5 落点页 / 滚动模式当前页

    @Test func multiDropOntoAppUsesTargetPageNotCurrentPage() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        store.updateLayout { layout in
            layout.apps = [
                "a": makeApp("a"), "b": makeApp("b"),
                "x": makeApp("x"), "t": makeApp("t"),
            ]
            layout.pages = [
                PageRecord(items: [.app(id: "a"), .app(id: "b"), .app(id: "x")]),
                PageRecord(items: [.app(id: "t")]),
            ]
        }
        model.currentPage = 0  // 滚动模式下 currentPage 可能滞后于可视页（第 2 页）

        model.performDrop(draggingIDs: ["a", "b"], sourceFolderID: nil, target: .onApp(page: 1, appID: "t"))
        ToastManager.shared.dismissAll()

        let pages = store.state.layout.pages
        #expect(pages.count == 2)
        #expect(pages[1].items.compactMap(\.folder).first?.appIDs.sorted() == ["a", "b", "t"])
        #expect(pages[0].items.compactMap(\.appID) == ["x"])
    }

    @Test func mergeSelectionUsesPageContainingSelection() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        store.updateLayout { layout in
            layout.apps = [
                "x": makeApp("x"), "a": makeApp("a"), "b": makeApp("b"),
            ]
            layout.pages = [
                PageRecord(items: [.app(id: "x")]),
                PageRecord(items: [.app(id: "a"), .app(id: "b")]),
            ]
        }
        model.currentPage = 0
        model.selectedAppIDs = ["a", "b"]

        model.mergeSelectionIntoNewFolder()
        ToastManager.shared.dismissAll()

        let pages = store.state.layout.pages
        #expect(pages[0].items.compactMap(\.appID) == ["x"])
        #expect(pages[1].items.compactMap(\.folder).first?.appIDs.sorted() == ["a", "b"])
    }

    // MARK: F7 整理窗口固定方向排序键

    @Test func reorganizeFixedDirectionSortIgnoresAscendingToggle() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        let session = ReorganizeSession(store: store, model: model)
        store.updateLayout { layout in
            layout.apps = [
                "old": makeApp("old", lastOpenedAt: Date(timeIntervalSince1970: 100)),
                "new": makeApp("new", lastOpenedAt: Date(timeIntervalSince1970: 2000)),
            ]
            layout.pages = [PageRecord(items: [.app(id: "old"), .app(id: "new")])]
        }

        _ = session.apply(ReorganizeRequest(
            action: .sort, sortKey: .mostRecent, ascending: true,  // 固定方向键：开关应被忽略
            scope: .allPages, alsoSortFolderContents: false
        ))
        ToastManager.shared.dismissAll()
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["new", "old"])

        // 下次启动 / 重扫走 applyActiveSort：方向必须与整理结果一致，不能翻转
        store.applyActiveSort()
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["new", "old"])
        #expect(store.state.settings.sortAscending == false)  // 固定方向键不写升序开关
    }

    @Test func reorganizeReverseSortKeyPersistsDirectionForNextLaunch() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        let session = ReorganizeSession(store: store, model: model)
        store.updateLayout { layout in
            layout.apps = ["a": makeApp("a"), "b": makeApp("b")]
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]
        }
        store.updateSettings { $0.sortAscending = true }

        _ = session.apply(ReorganizeRequest(
            action: .sort, sortKey: .name, ascending: false,  // 降序
            scope: .allPages, alsoSortFolderContents: false
        ))
        ToastManager.shared.dismissAll()
        #expect(store.state.settings.sortAscending == false)
        #expect(store.state.settings.activeSortKey == .name)

        store.applyActiveSort()
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["b", "a"])
    }

    // MARK: F8 打开文件夹悬空

    @Test func movingLastMemberOutClosesOpenedFolder() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(in: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        let folder = FolderRecord(name: "Solo", appIDs: ["x"])
        store.updateLayout { layout in
            layout.apps["x"] = makeApp("x")
            layout.pages = [PageRecord(items: [.folder(folder)])]
        }
        model.openFolder(page: 0, folderID: folder.id)
        #expect(model.openedFolderRecord != nil)
        ToastManager.shared.dismissAll()

        model.moveOutOfFolder(appID: "x")
        ToastManager.shared.dismissAll()

        #expect(model.openedFolder == nil)  // 旧实现会留下空白打开态
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["x"])
    }

    // MARK: F9 玻璃材质

    @Test func glassMaterialOffIsDistinctFromThin() {
        #expect(GlassMaterial.off.material == nil)
        #expect(GlassMaterial.thin.material != nil)
        let materials = [GlassMaterial.thin, .regular, .thick].compactMap(\.material)
        #expect(materials.count == 3)
        #expect(Set(materials).count == 3)  // 三档观感不同
    }

    // MARK: F10 窗口淡出期间重新打开

    @Test func reopeningDuringFadeOutKeepsWindowVisible() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        WindowFade.fadeIn(window)
        #expect(window.isVisible)
        try await Task.sleep(for: .milliseconds(40))

        WindowFade.fadeOut(window)  // 淡出 150ms
        try await Task.sleep(for: .milliseconds(40))
        WindowFade.fadeIn(window)  // 未结束时重新打开

        // 等到旧淡出 completion 的时限之后：不得被旧的 orderOut 移出屏幕
        try await Task.sleep(for: .milliseconds(400))
        #expect(window.isVisible)
        #expect(window.alphaValue == 1)
        window.orderOut(nil)
    }

    // MARK: F11 更高版本 store 只读提示

    @Test func futureVersionStoreIsReadOnlyAndSurfacesNotice() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("store.json")
        let payload = """
        {"version": 999, "layout": {"apps": {}, "pages": []}, "settings": {}, "sources": []}
        """
        try Data(payload.utf8).write(to: storeURL)
        let original = try String(contentsOf: storeURL, encoding: .utf8)

        let store = LayoutStore(directory: dir)
        #expect(store.isReadOnlyForFutureVersion)
        let notice = try #require(store.futureVersionReadOnlyNotice)
        #expect(notice.contains("只读"))

        store.updateLayout { $0.apps["x"] = makeApp("x") }
        try? store.saveNow()
        let after = try String(contentsOf: storeURL, encoding: .utf8)
        #expect(after == original)  // 绝不覆盖更高版本文件
    }

    // MARK: F12 最低系统版本对齐

    @Test func minimumSystemVersionMatchesPackagePlatform() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LaunchXTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let package = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(package.contains(".macOS(.v26)"))

        let plistData = try Data(contentsOf: repoRoot.appendingPathComponent("resources/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        #expect(plist?["LSMinimumSystemVersion"] as? String == "26.0")
    }

    // MARK: F13 冷启动点击 Dock 图标唤起面板

    /// 进程未运行时点击 Dock 图标走全新启动，系统不投递 reopen 事件，
    /// 必须由启动完成时的冷启动兜底唤起（见 AppDelegate.showPanelOnColdLaunchIfWanted）。
    @Test func coldLaunchAutoShowDecision() {
        // 常规用户打开：唤起
        #expect(AppDelegate.shouldShowPanelOnColdLaunch(
            onboardingCompleted: true, isSmokeMode: false,
            loginItemEnabled: false, secondsSinceLogin: nil))
        // 引导未完成：只出引导页，不在其下叠启动台
        #expect(!AppDelegate.shouldShowPanelOnColdLaunch(
            onboardingCompleted: false, isSmokeMode: false,
            loginItemEnabled: false, secondsSinceLogin: nil))
        // 冒烟模式：自带 1s 后的定时展示，避免双重展开
        #expect(!AppDelegate.shouldShowPanelOnColdLaunch(
            onboardingCompleted: true, isSmokeMode: true,
            loginItemEnabled: false, secondsSinceLogin: nil))
        // 登录项拉起（登录后数秒内）：开机不弹面板
        #expect(!AppDelegate.shouldShowPanelOnColdLaunch(
            onboardingCompleted: true, isSmokeMode: false,
            loginItemEnabled: true, secondsSinceLogin: AppDelegate.loginLaunchGracePeriod - 1))
        // 登录项已启用但很久之后才打开：照常唤起
        #expect(AppDelegate.shouldShowPanelOnColdLaunch(
            onboardingCompleted: true, isSmokeMode: false,
            loginItemEnabled: true, secondsSinceLogin: AppDelegate.loginLaunchGracePeriod + 1))
        // 登录项已启用但读不到登录时间：宁可多弹，不能把 Dock 入口变哑
        #expect(AppDelegate.shouldShowPanelOnColdLaunch(
            onboardingCompleted: true, isSmokeMode: false,
            loginItemEnabled: true, secondsSinceLogin: nil))
    }

    // MARK: 安装中的 .app（Info.plist 尚未写入）

    @Test func scanReportsIncompleteBundleAndPicksItUpOnceComplete() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 拖拽 / cp 安装：bundle 目录先出现，Contents/Info.plist 稍后才写入
        let contents = dir.appendingPathComponent("Fresh.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let first = AppIndex.scanWithDiagnostics(directories: [dir])
        #expect(first.records.isEmpty)
        #expect(first.incompleteBundles.map(\.lastPathComponent) == ["Fresh.app"])
        #expect(first.failedDirectories.isEmpty)

        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.fresh", "CFBundleName": "Fresh"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let second = AppIndex.scanWithDiagnostics(directories: [dir])
        #expect(second.records.map(\.id) == ["com.example.fresh"])
        #expect(second.incompleteBundles.isEmpty)
    }

    @Test func wrappediOSAppIsNotReportedAsIncompleteBundle() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Apple Silicon 上的 iOS 应用：外层只有 Wrapper/ 与 WrappedBundle 链接，没有 Contents/
        let app = dir.appendingPathComponent("Phone.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Wrapper", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: app.appendingPathComponent("WrappedBundle"), withDestinationURL: URL(fileURLWithPath: "Wrapper/Phone.app"))

        let result = AppIndex.scanWithDiagnostics(directories: [dir])
        #expect(result.incompleteBundles.isEmpty)
    }

    @Test func bundleBeingOverwrittenIsNotCountedAsMissing() {
        var app = makeApp("a")
        app.path = "/Applications/A.app"
        var layout = LayoutSnapshot()
        layout.apps["a"] = app
        layout.pages = [PageRecord(items: [.app(id: "a")])]

        // 覆盖更新期间 Info.plist 暂缺：扫描把该 bundle 报为未完成，合并时视同暂时不可读
        for _ in 0..<3 {
            let result = SyncEngine.merge(
                scanned: [],
                into: &layout,
                capacityPerPage: 35,
                unreadablePrefixes: ["/Applications/A.app"]
            )
            #expect(result.removedAppIDs.isEmpty)
        }
        #expect(layout.apps["a"]?.missingScans == 0)
        #expect(layout.placedAppIDs == ["a"])
    }

    @Test func incompleteBundleRetryKeepsPendingProbeAcrossUnrelatedScans() {
        var retry = IncompleteBundleRetry()
        #expect(retry.scanCompleted(incomplete: ["/A/X.app"]) == .arm(IncompleteBundleRetry.delays[0]))
        _ = retry.probeFailed()
        // 无关重扫报告同一批未完成 bundle：不重置、不消耗次数
        #expect(retry.scanCompleted(incomplete: ["/A/X.app"]) == .keep)
        #expect(retry.attempt == 1)
        // 集合变化（新装了另一个应用）重新计数
        #expect(retry.scanCompleted(incomplete: ["/A/X.app", "/A/Y.app"]) == .arm(IncompleteBundleRetry.delays[0]))
        #expect(retry.attempt == 0)
        #expect(retry.scanCompleted(incomplete: []) == .cancel)
        #expect(retry.pending.isEmpty)
    }

    @Test func exhaustedIncompleteBundleStopsProbingButKeepsArrangement() {
        var retry = IncompleteBundleRetry()
        _ = retry.scanCompleted(incomplete: ["/Applications/A.app"])
        for _ in 1..<IncompleteBundleRetry.delays.count { #expect(retry.probeFailed() != nil) }
        #expect(retry.probeFailed() == nil)
        // 已放弃的不再排探测
        #expect(retry.scanCompleted(incomplete: ["/Applications/A.app"]) == .cancel)

        // 超过补扫窗口的长时间覆盖更新：合并仍把未完成 bundle 当作暂时读不到，排列不丢
        var app = makeApp("a")
        app.path = "/Applications/A.app"
        var layout = LayoutSnapshot()
        layout.apps["a"] = app
        layout.pages = [PageRecord(items: [.app(id: "a")])]
        var removed: [String] = []
        for _ in 0..<3 {
            removed += SyncEngine.merge(
                scanned: [], into: &layout, capacityPerPage: 35,
                unreadablePrefixes: ["/Applications/A.app"]
            ).removedAppIDs
        }
        #expect(removed.isEmpty)
        #expect(layout.placedAppIDs == ["a"])

        // 恢复正常一次后清出已放弃集合：再次覆盖更新时重新排探测
        _ = retry.scanCompleted(incomplete: [])
        #expect(retry.scanCompleted(incomplete: ["/Applications/A.app"]) == .arm(IncompleteBundleRetry.delays[0]))
    }
}
