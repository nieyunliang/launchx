import AppKit
import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 2026-11-14 第 3 轮审查缺陷的回归测试


/// 记录交给回收站的 URL（TrashHandler 是 @Sendable，不能用可变捕获）。
final class TrashRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func record(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        storage.append(contentsOf: urls)
    }
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

@Suite(.serialized)
@MainActor
struct UninstallSafetyRegressionTests {

    private func tempDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LXAudit3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// P1：bundleId 带 `..` 时，扫描结果不得落在允许根之外（尤其不能是家目录本身）。
    @Test func bundleIdTraversalCannotEscapeAllowedRoots() throws {
        let home = tempDirectory("trav")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents", isDirectory: true),
            withIntermediateDirectories: true
        )

        let app = AppRecord(
            id: "evil", name: "Evil", bundleName: "Evil", bundleId: "../..",
            version: nil, path: "/Applications/Evil.app", category: nil
        )
        let items = UninstallScanner.scan(app: app, home: home)
        let roots = UninstallScanner.allowedRoots(home: home)
        for item in items {
            #expect(UninstallScanner.isContainedInAllowedRoots(item.url, roots: roots))
            #expect(item.url.standardizedFileURL.path != home.standardizedFileURL.path)
        }
        #expect(!items.contains { $0.url.standardizedFileURL.path == home.standardizedFileURL.path })
    }

    /// P1：应用显示名带 `..` 时同理（显示名可被用户重命名，也必须挡）。
    @Test func appNameTraversalCannotEscapeAllowedRoots() throws {
        let home = tempDirectory("trav-name")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents", isDirectory: true),
            withIntermediateDirectories: true
        )

        let app = AppRecord(
            id: "x", name: "../Documents", bundleName: "x", bundleId: "com.example.x",
            version: nil, path: "/Applications/X.app", category: nil
        )
        let items = UninstallScanner.scan(app: app, home: home)
        let roots = UninstallScanner.allowedRoots(home: home)
        for item in items {
            #expect(UninstallScanner.isContainedInAllowedRoots(item.url, roots: roots))
        }
    }

    /// P2：偏好设置按 bundleId 目录边界匹配，不再连带另一个应用。
    @Test func preferencesRespectBundleIDBoundary() throws {
        let home = tempDirectory("prefs")
        defer { try? FileManager.default.removeItem(at: home) }
        let prefs = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        for name in ["com.foo.plist", "com.foobar.plist", "com.foo.helper.plist"] {
            try Data("x".utf8).write(to: prefs.appendingPathComponent(name))
        }

        let app = AppRecord(
            id: "com.foo", name: "Foo", bundleName: "Foo", bundleId: "com.foo",
            version: nil, path: "/Applications/Foo.app", category: nil
        )
        let items = UninstallScanner.scan(app: app, home: home)
        let other = items.first { $0.url.lastPathComponent == "com.foobar.plist" }
        let exact = items.first { $0.url.lastPathComponent == "com.foo.plist" }
        let helper = items.first { $0.url.lastPathComponent == "com.foo.helper.plist" }

        #expect(other == nil)                       // 另一个应用的偏好：完全不出现在清单
        #expect(exact?.isSpeculative == false)      // 自身偏好：默认勾选
        #expect(helper?.isSpeculative == true)      // 子模块/helper：可能相关，默认不勾选
    }

    /// P1（纵深防御）：删除侧拒绝允许根之外的 URL 与根目录本身。
    @Test func trashGuardRejectsUnsafePaths() throws {
        let home = tempDirectory("guard")
        defer { try? FileManager.default.removeItem(at: home) }
        let library = home.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        #expect(!UninstallEngine.isSafeToTrash(home, home: home))                    // 家目录本身
        #expect(!UninstallEngine.isSafeToTrash(URL(fileURLWithPath: "/Library")))    // 真实根目录本身
        #expect(!UninstallEngine.isSafeToTrash(URL(fileURLWithPath: "/etc/hosts")))  // 系统目录
        #expect(!UninstallEngine.isSafeToTrash(URL(fileURLWithPath: "/"), home: home))
        #expect(UninstallEngine.isSafeToTrash(library.appendingPathComponent("Caches"), home: home))
        #expect(UninstallEngine.isSafeToTrash(URL(fileURLWithPath: "/Applications/Foo.app")))
        #expect(UninstallEngine.isSafeToTrash(URL(fileURLWithPath: "/Library/LaunchAgents/x.plist")))
    }

    /// 允许根内的条目照常进入回收站（闸门只拦越界项，不误伤正常清理）。
    @Test func removeTrashesAllowedItems() async throws {
        let home = tempDirectory("remove")
        defer { try? FileManager.default.removeItem(at: home) }
        let safe = home.appendingPathComponent("Library/Caches/com.example.x", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        let userFile = home.appendingPathComponent("Documents/Important.txt")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("k".utf8).write(to: userFile)

        let recorder = TrashRecorder()
        let result = await UninstallEngine.remove(
            items: [
                UninstallItem(url: userFile, category: .userFiles, byteSize: nil),
                UninstallItem(url: safe, category: .caches, byteSize: nil),
            ],
            home: home,
            trash: { urls in
                recorder.record(urls)
                return Dictionary(uniqueKeysWithValues: urls.map { ($0, $0) })
            },
            onEvent: { _ in }
        )

        #expect(recorder.urls.map(\.path).contains(safe.path))
        #expect(recorder.urls.map(\.path).contains(userFile.path))
        #expect(result.trashed == 2)
        #expect(result.failed.isEmpty)
    }

    @Test func removeRejectsItemOutsideAllowedRoots() async throws {
        let tmp = URL(fileURLWithPath: "/private/etc/hosts")
        let recorder = TrashRecorder()
        let result = await UninstallEngine.remove(
            items: [UninstallItem(url: tmp, category: .otherFiles, byteSize: nil)],
            trash: { urls in
                recorder.record(urls)
                return [:]
            },
            onEvent: { _ in }
        )
        #expect(recorder.urls.isEmpty)
        #expect(result.trashed == 0)
        #expect(result.failed.count == 1)
        #expect(result.failed[0].error.contains("已跳过"))
    }
}

// MARK: - 批次 2：布局 / 选择 / 文件夹状态一致性

@Suite(.serialized)
@MainActor
struct LayoutStateRegressionTests {

    private func tempDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LXAudit3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A2：隐藏必须把应用从网格与文件夹里摘掉（不再「hidden 但仍摆放」）。
    @Test func hidingDetachesAppFromGridAndFolder() throws {
        let dir = tempDirectory("hide")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        let folderID = UUID()
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a", name: "Alpha")
            layout.apps["b"] = makeApp("b", name: "Beta")
            layout.apps["c"] = makeApp("c", name: "Gamma")
            layout.pages = [
                PageRecord(items: [.app(id: "a")]),
                PageRecord(items: [.folder(FolderRecord(id: folderID, name: "F", appIDs: ["b", "c"]))]),
            ]
        }

        model.setHidden(true, appID: "a")
        #expect(store.state.layout.apps["a"]?.hidden == true)
        #expect(!store.state.layout.placedAppIDs.contains("a"))

        model.setHidden(true, appID: "b")
        #expect(!store.state.layout.placedAppIDs.contains("b"))
        let remainingFolder = store.state.layout.pages.compactMap { page in
            page.items.compactMap(\.folder).first(where: { $0.id == folderID })
        }.first
        #expect(remainingFolder?.appIDs == ["c"])

        // 取消隐藏后能重新回到网格（unhide 的补摆路径）
        model.unhide(appID: "a")
        #expect(store.state.layout.placedAppIDs.contains("a"))
    }

    /// A3：打开态文件夹按 id 跨页解析，换页不再悬空。
    @Test func openedFolderRecordResolvesAcrossPages() throws {
        let dir = tempDirectory("folder")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        let folderID = UUID()
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = [
                PageRecord(),
                PageRecord(items: [.folder(FolderRecord(id: folderID, name: "F", appIDs: ["a", "b"]))]),
            ]
        }
        model.openFolder(page: 0, folderID: folderID)  // 记录里的页下标是故意的旧值
        #expect(model.openedFolderRecord?.id == folderID)
        #expect(model.isFolderViewActive)
    }

    /// A3：文件夹被外部删除后，首次点空白即可收起面板（不再被幽灵文件夹吃掉一次点击）。
    @Test func staleOpenedFolderDoesNotBlockFirstBackgroundTap() throws {
        let dir = tempDirectory("stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        let folderID = UUID()
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = [PageRecord(items: [.folder(FolderRecord(id: folderID, name: "F", appIDs: ["a"]))])]
        }
        model.openFolder(page: 0, folderID: folderID)
        store.updateLayout { layout in
            layout.pages[0].items.removeAll { $0.folder?.id == folderID }
        }
        #expect(!model.isFolderViewActive)

        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.handleBackgroundTap()
        #expect(model.openedFolder == nil)
        #expect(dismissed)
    }

    /// B10：陈旧选择（应用已被移除）不得让「合并」通过 >=2 守卫生成单人文件夹。
    @Test func mergeSelectionRequiresTwoLiveApps() throws {
        let dir = tempDirectory("merge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }
        model.selectedAppIDs = ["a", "ghost"]
        model.mergeSelectionIntoNewFolder()
        #expect(!store.state.layout.pages.contains { page in page.items.contains { $0.folder != nil } })
        #expect(model.selectedAppIDs.contains("a"))  // 未满足条件时不清选择
    }

    /// B11：同一应用被历史数据放进多个文件夹时，一次调用必须全部摘除。
    @Test func removeAppFromAnyFolderRemovesEveryCopy() {
        var layout = LayoutSnapshot()
        layout.apps["a"] = makeApp("a")
        layout.pages = [
            PageRecord(items: [.folder(FolderRecord(name: "F1", appIDs: ["a", "b"]))]),
            PageRecord(items: [.folder(FolderRecord(name: "F2", appIDs: ["a", "c"]))]),
        ]
        layout.removeAppFromAnyFolder("a")
        let members = layout.pages.flatMap { $0.items.compactMap(\.folder).flatMap(\.appIDs) }
        #expect(!members.contains("a"))
        #expect(members.sorted() == ["b", "c"])
    }

    /// A14：页容量非法时 appendApp 必须立即返回，不能无限建页。
    @Test func zeroCapacityAppendDoesNotHang() {
        var layout = LayoutSnapshot()
        layout.pages = [PageRecord()]
        _ = layout.appendApp(id: "x", toPage: 0, capacityPerPage: 0)
        #expect(layout.pages.count <= 1)
        #expect(layout.placedAppIDs.isEmpty)
    }

    /// A14：损坏的 gridDensity 解码后收敛到合法范围（1...32），不会让容量为 0。
    @Test func gridDensityDecodeClampsCorruptValues() throws {
        let dir = tempDirectory("density")
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = """
        {"version": 2, "layout": {"apps": {}, "pages": []},
         "settings": {"gridDensity": {"columns": 0, "rows": -5}}, "sources": []}
        """
        try Data(payload.utf8).write(to: dir.appendingPathComponent("store.json"))
        let store = LayoutStore(directory: dir)
        #expect(store.state.settings.gridDensity.columns == 1)
        #expect(store.state.settings.gridDensity.rows == 1)
        #expect(store.state.settings.gridDensity.capacity > 0)
    }
}

// MARK: - 批次 2：整理窗口

@Suite(.serialized)
@MainActor
struct ReorganizeRegressionTests {

    private func tempDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LXAudit3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A7：非连续选页重排不得丢弃中间未选中的页。
    @Test func acrossPagesKeepsUnselectedMiddlePage() {
        var layout = LayoutSnapshot()
        for id in ["a", "b", "c"] { layout.apps[id] = makeApp(id) }
        layout.pages = [
            PageRecord(items: [.app(id: "a")]),
            PageRecord(items: [.app(id: "b")]),
            PageRecord(items: [.app(id: "c")]),
        ]
        ReorganizeEngine.reorganizeAcrossPages(
            &layout,
            scope: .selectedPages([0, 2]),
            capacityPerPage: 35
        )
        #expect(layout.pages.count == 3)
        #expect(layout.pages.flatMap { $0.items.compactMap(\.appID) } == ["a", "b", "c"])
    }

    /// A6：撤销必须同时回滚排序设置，否则拖拽仍被禁、下次重扫又会重排。
    @Test func undoRestoresSortSettingsAndLayout() throws {
        let dir = tempDirectory("undo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a", name: "Alpha")
            layout.apps["b"] = makeApp("b", name: "Beta")
            layout.pages = [PageRecord(items: [.app(id: "b"), .app(id: "a")])]
        }
        #expect(store.state.settings.activeSortKey == .custom)

        let session = ReorganizeSession(store: store, model: model)
        let request = ReorganizeRequest(
            action: .sort,
            sortKey: .name,
            ascending: true,
            scope: .allPages,
            alsoSortFolderContents: false
        )
        let outcome = session.apply(request)
        #expect(outcome == .changed)
        #expect(store.state.settings.activeSortKey == .name)
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["a", "b"])

        session.undo()
        #expect(store.state.settings.activeSortKey == .custom)
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["b", "a"])
        #expect(model.dragAllowed)
    }

    /// B8：「同时排序文件夹内应用」只作用于选中页，不得改动其它页的文件夹。
    @Test func folderContentSortRespectsScope() {
        var layout = LayoutSnapshot()
        for id in ["a", "b", "x", "y"] { layout.apps[id] = makeApp(id, name: id.uppercased()) }
        layout.pages = [
            PageRecord(items: [.app(id: "y"), .app(id: "x")]),
            PageRecord(items: [.folder(FolderRecord(name: "F", appIDs: ["b", "a"]))]),
        ]
        _ = SortEngine.apply(
            &layout,
            key: .name,
            ascending: true,
            scope: .currentPage(0),
            options: SortOptions(alsoSortFolderContents: true, folderPosition: .afterApps, appleAppsPosition: .mixed)
        )
        let folder = layout.pages[1].items.compactMap(\.folder).first
        #expect(folder?.appIDs == ["b", "a"])  // 未选中第 2 页，文件夹内顺序保持原样
    }
}

// MARK: - 批次 3：快捷键 / 搜索 / 入口

@Suite(.serialized)
@MainActor
struct InputRegressionTests {

    private func tempDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LXAudit3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A9：字母 F（键码 3）不是功能键，必须被执行安全校验；F6 允许任意组合。
    @Test func letterFIsNotTreatedAsFunctionKey() {
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 3, modifiers: 0)) != nil)          // 裸 F
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 3, modifiers: KeyCodes.cmdKey)) != nil)  // ⌘F
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 3, modifiers: KeyCodes.optionKey)) != nil) // ⌥F
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 97, modifiers: 0)) == nil)         // F6 正常
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 97, modifiers: KeyCodes.cmdKey)) == nil)
    }

    /// B13：CapsLock 是键盘状态位，不能映射进热键掩码。
    @Test func capsLockIsNotMappedIntoHotKeyModifiers() {
        #expect(KeyCodes.carbonFlags(from: [.capsLock]) == 0)
        #expect(KeyCodes.carbonFlags(from: [.capsLock, .command]) == KeyCodes.cmdKey)
        #expect(KeyCodes.carbonFlags(from: [.capsLock, .option]) == KeyCodes.optionKey)
    }

    /// A12：搜索结果变化 / 面板重开时，高亮下标不得残留越界。
    @Test func searchSelectionResetsWhenQueryChanges() throws {
        let dir = tempDirectory("search")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a", name: "Alpha 1")
            layout.apps["b"] = makeApp("b", name: "Alpha 2")
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]
        }
        model.show()
        model.searchQuery = "alpha"
        model.searchSelectedIndex = 5
        #expect(model.clampedSearchSelectedIndex == 1)   // 读到时就钳到命中范围

        model.searchQuery = "alpha 1"                    // 收窄 → 下标归零
        #expect(model.searchSelectedIndex == 0)
        #expect(model.clampedSearchSelectedIndex == 0)

        model.searchSelectedIndex = 3
        model.hide()
        model.show()
        #expect(model.searchSelectedIndex == 0)
    }

    /// A8：录制结束后控件不能再消费按键（否则设置窗里任意按键都会换绑热键）。
    @Test func hotKeyRecorderIgnoresKeysAfterRecordingEnds() throws {
        let view = HotKeyRecorderControl.RecorderControlView()
        var recorded: [HotKeySpec?] = []
        view.onRecorded = { recorded.append($0) }
        view.recording = false

        view.keyDown(with: Self.makeKeyEvent(keyCode: 49))   // Space
        #expect(recorded.isEmpty)

        view.recording = true
        view.keyDown(with: Self.makeKeyEvent(keyCode: 49))
        #expect(recorded.count == 1)                          // 录制中的这一击正常收下
        #expect(view.recording == false)

        view.keyDown(with: Self.makeKeyEvent(keyCode: 12))    // 录制已结束的下一击
        #expect(recorded.count == 1)
    }

    /// A15：手势入口有效性与开关一致（原始触点通道无需辅助功能权限）。
    @Test func gestureEntryAvailabilityFollowsToggle() {
        #expect(!TrackpadTouchMonitor.isEntryAvailable(enabled: false))
        #expect(TrackpadTouchMonitor.isEntryAvailable(enabled: true))
    }

    /// A4：子窗口层级必须高于全屏面板（statusBar），否则设置/整理/卸载窗会被完全盖住。
    @Test func childWindowLevelIsAboveLaunchpadPanel() {
        #expect(LaunchpadWindowController.overlayChildWindowLevel.rawValue > NSWindow.Level.statusBar.rawValue)
    }

    private static func makeKeyEvent(keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

// MARK: - 批次 4：解码容错 / 配色 / 图标渲染

@Suite(.serialized)
@MainActor
struct HardeningRegressionTests {

    private func tempDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LXAudit3-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// B1：一个设置字段写坏只回退该字段，其它设置与来源保持。
    @Test func brokenSettingsFieldDoesNotResetEverything() throws {
        let dir = tempDirectory("decode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = """
        {"version": 2,
         "layout": {"apps": {}, "pages": []},
         "settings": {"showMenuBarIcon": false, "onboardingCompleted": true,
                      "closeDelay": "not-a-valid-enum", "hotKey": 12345,
                      "gridDensity": {"columns": 9, "rows": 6}},
         "sources": [{"id": "3E7B4E7C-8A0A-4D2F-9A1E-6C2B8F7D5A10", "path": "/Applications/Optional", "enabled": false, "kind": "defaultApps"},
                     {"id": "4E7B4E7C-8A0A-4D2F-9A1E-6C2B8F7D5A11", "path": "/Users/someone/Apps", "enabled": true, "kind": "bogus-kind"}]}
        """
        try Data(payload.utf8).write(to: dir.appendingPathComponent("store.json"))
        let store = LayoutStore(directory: dir)

        #expect(store.state.settings.showMenuBarIcon == false)      // 合法字段保留
        #expect(store.state.settings.onboardingCompleted == true)
        #expect(store.state.settings.closeDelay == .s1)            // 坏枚举回退默认
        #expect(store.state.settings.hotKey == .none)              // 坏类型回退默认
        #expect(store.state.settings.gridDensity.columns == 9)     // 其它字段不受影响
        #expect(store.state.settings.gridDensity.rows == 6)

        #expect(store.state.sources.count == 2)                     // 两个来源都在
        #expect(store.state.sources[1].kind == .custom)             // 未知 kind 回退 .custom
        #expect(store.state.sources[1].path == "/Users/someone/Apps")
    }

    /// B3：染色模式的目标色与文案方向一致（「白色→红」= 红色轮廓）。
    @Test func iconTintTargetsMatchLabels() {
        #expect(IconColorMode.original.tintTarget == nil)
        #expect(IconColorMode.whiteToRed.tintTarget == .themeRed)
        #expect(IconColorMode.redToWhite.tintTarget == .white)
    }

    /// B14：图标改由分辨率无关绘制生成，仍能栅格化出非空位图。
    @Test func renderedIconsAreRasterizable() throws {
        let dock = AppIconRenderer.appIcon(for: .brand, dark: true)
        #expect(dock.size == NSSize(width: 128, height: 128))
        let dockTIFF = try #require(dock.tiffRepresentation)
        let dockRep = try #require(NSBitmapImageRep(data: dockTIFF))
        #expect(dockRep.pixelsWide > 0 && dockRep.pixelsHigh > 0)

        let menu = AppIconRenderer.menuBarIcon(for: .brand)
        #expect(menu.size == NSSize(width: 18, height: 18))
        #expect(menu.isTemplate)
        #expect(menu.tiffRepresentation != nil)
    }

    /// 程序坞图标遵循苹果图标网格：底板四周留透明边，不铺满画布（否则比其他应用图标大一圈）。
    @Test func dockIconLeavesSystemGridPadding() throws {
        let dock = AppIconRenderer.appIcon(for: .brand, dark: true)
        let tiff = try #require(dock.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let w = rep.pixelsWide, h = rep.pixelsHigh
        // 边缘中点（底板外的透明边）应全透明；画布中心应不透明。
        let pad = Int(CGFloat(w) * AppIconRenderer.gridInsetRatio / 3)
        for (x, y) in [(w / 2, pad), (pad, h / 2), (w - 1 - pad, h / 2)] {
            #expect((rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.05)
        }
        #expect((rep.colorAt(x: w / 2, y: h / 2)?.alphaComponent ?? 0) > 0.95)
    }
}

// MARK: - 批次 3：窗口层级（相对全屏面板）

@Suite(.serialized)
@MainActor
struct WindowLayerRegressionTests {

    /// A4：从启动台打开设置窗时，设置窗必须排在面板之上（layer 26 > 25），
    /// 否则用户看到的是「点了设置没反应」，而键盘焦点已经落到看不见的窗口里。
    @Test func settingsWindowIsAboveLaunchpadPanel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LXAudit3-window-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = NSApplication.shared

        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        let launchpad = LaunchpadWindowController(model: model)
        launchpad.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let prefs = PreferencesWindowController(model: PreferencesModel(store: store))
        prefs.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        defer { launchpad.hide() }

        let pid = ProcessInfo.processInfo.processIdentifier
        let infos = (CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]) ?? []
        let mine = infos.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
        let prefsIndex = mine.firstIndex { ($0[kCGWindowName as String] as? String) == "LaunchX 设置" } ?? -1

        #expect(prefsIndex == 0)  // 前→后列表里设置窗排在最前
        #expect(mine.contains { ($0[kCGWindowLayer as String] as? Int ?? 0) > NSWindow.Level.statusBar.rawValue })
        #expect(LaunchpadWindowController.isOverlayOnScreen)
    }
}
