import AppKit
import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 卸载扫描器

struct UninstallScannerTests {

    private func fakeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXUninstall-\(UUID().uuidString)", isDirectory: true)
        for sub in [
            "Library/Caches/test.app.bundle",
            "Library/Application Support/test.app.bundle",
            "Library/Containers/test.app.bundle",
            "Library/WebKit/test.app.bundle",
            "Library/HTTPStorages/test.app.bundle",
            "Library/Saved Application State/test.app.bundle.savedState",
            "Library/Application Scripts/test.app.bundle",
            "Library/Group Containers/group.abc.test.app.bundle",
            "Library/Preferences",
            "Library/LaunchAgents",
            "Documents",
        ] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("x".utf8).write(to: home.appendingPathComponent("Library/Preferences/test.app.bundle.plist"))
        try Data("x".utf8).write(
            to: home.appendingPathComponent("Library/LaunchAgents/com.test.app.bundle.agent.plist")
        )
        return home
    }

    @Test func scanFindsAllCategories() throws {
        let home = try fakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let app = AppRecord(
            id: "test.app.bundle",
            name: "TestApp",
            bundleName: "TestApp",
            bundleId: "test.app.bundle",
            version: "1.0",
            path: "/Applications/TestApp.app",
            category: nil
        )
        let items = UninstallScanner.scan(app: app, home: home)

        let categories = Set(items.map(\.category))
        #expect(categories.contains(.caches))
        #expect(categories.contains(.applicationSupport))
        #expect(categories.contains(.containers))
        #expect(categories.contains(.groupContainers))
        #expect(categories.contains(.webKitData))
        #expect(categories.contains(.httpStorage))
        #expect(categories.contains(.savedState))
        #expect(categories.contains(.applicationScripts))
        #expect(categories.contains(.otherFiles))       // Preferences plist
        #expect(categories.contains(.launchItems))      // LaunchAgent

        // 大小可读
        let plistItem = items.first { $0.category == .otherFiles }
        #expect(plistItem?.byteSize == 1)
    }

    @Test func emptyEnvironmentProducesNoItems() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXEmpty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let app = AppRecord(
            id: "none", name: "None", bundleName: "None",
            bundleId: "none.bundle", version: nil, path: "/Applications/None.app", category: nil
        )
        let items = UninstallScanner.scan(app: app, home: home)
        #expect(items.allSatisfy { $0.category != .caches })
        #expect(items.allSatisfy { $0.category != .containers })
    }

    // MARK: P0-1 默认勾选与「可能相关」标记

    @Test func nameMatchedItemsAreMarkedSpeculative() throws {
        let home = try fakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("personal".utf8).write(
            to: home.appendingPathComponent("Documents/TestApp 项目计划.txt")
        )

        let app = AppRecord(
            id: "test.app.bundle",
            name: "TestApp",
            bundleName: "TestApp",
            bundleId: "test.app.bundle",
            version: "1.0",
            path: "/Applications/TestApp.app",
            category: nil
        )
        let items = UninstallScanner.scan(app: app, home: home)

        // 个人文件与自启项都来自名称模糊匹配 → 必须标记为「可能相关」
        let userFiles = items.filter { $0.category == .userFiles }
        #expect(!userFiles.isEmpty)
        #expect(userFiles.allSatisfy { $0.isSpeculative })

        let launchItems = items.filter { $0.category == .launchItems }
        #expect(!launchItems.isEmpty)
        #expect(launchItems.allSatisfy { $0.isSpeculative })

        // bundleId 精确派生的缓存目录不是模糊匹配
        let cacheItem = items.first { $0.category == .caches && $0.url.path.contains("test.app.bundle") }
        #expect(cacheItem?.isSpeculative == false)
    }

    @Test @MainActor func defaultSelectionExcludesUserFilesLaunchItemsAndSpeculative() throws {
        let home = try fakeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("personal".utf8).write(
            to: home.appendingPathComponent("Documents/TestApp 项目计划.txt")
        )

        let app = AppRecord(
            id: "test.app.bundle",
            name: "TestApp",
            bundleName: "TestApp",
            bundleId: "test.app.bundle",
            version: "1.0",
            path: "/Applications/TestApp.app",
            category: nil
        )
        let items = UninstallScanner.scan(app: app, home: home)
        let checked = UninstallModel.defaultCheckedItemIDs(in: items)
        let checkedItems = items.filter { checked.contains($0.id) }

        // 仍有明确归属的默认勾选项（缓存/容器等），否则卸载器会毫无清理内容
        #expect(!checkedItems.isEmpty)
        #expect(checkedItems.allSatisfy { !$0.isSpeculative })
        #expect(checkedItems.allSatisfy { !$0.category.isExcludedByDefault })

        // User Files / Launch Items 即使被扫到也默认不勾选
        #expect(items.filter { $0.category == .userFiles }.allSatisfy { !checked.contains($0.id) })
        #expect(items.filter { $0.category == .launchItems }.allSatisfy { !checked.contains($0.id) })
    }
}

// MARK: - 卸载删除引擎（P1-9 失败上报）

struct UninstallEngineTests {

    private enum StubError: Error, Sendable {
        case recycleFailed
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func reportsPartialRecycleFailureWithoutInflatingSuccess() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let accepted = dir.appendingPathComponent("accepted.dat")
        let rejected = dir.appendingPathComponent("rejected.dat")
        try Data("x".utf8).write(to: accepted)
        try Data("x".utf8).write(to: rejected)

        let items = [
            UninstallItem(url: accepted, category: .caches, byteSize: 1),
            UninstallItem(url: rejected, category: .caches, byteSize: 1),
        ]

        let result = await UninstallEngine.remove(
            items: items,
            trash: { urls in
                // 回收站只接受第一个文件：未出现在返回字典里的项即失败
                var moved: [URL: URL] = [:]
                if let first = urls.first, first == accepted {
                    moved[first] = URL(fileURLWithPath: "/tmp/Trash/accepted.dat")
                }
                return moved
            },
            onEvent: { _ in }
        )

        #expect(result.trashed == 1)
        #expect(result.failed.count == 1)
        #expect(result.failed.first?.path == rejected.path)
        #expect(result.failed.first?.error.isEmpty == false)
    }

    @Test func reportsThrownRecycleErrorsAndSkipsMissingFiles() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let throwing = dir.appendingPathComponent("throwing.dat")
        try Data("x".utf8).write(to: throwing)
        let missing = dir.appendingPathComponent("already-gone.dat")

        let items = [
            UninstallItem(url: throwing, category: .caches, byteSize: 1),
            UninstallItem(url: missing, category: .caches, byteSize: nil),
        ]

        let result = await UninstallEngine.remove(
            items: items,
            trash: { _ in throw StubError.recycleFailed },
            onEvent: { _ in }
        )

        // 抛错的项进入失败；扫描后已消失的文件既不算成功也不算失败
        #expect(result.trashed == 0)
        #expect(result.failed.count == 1)
        #expect(result.failed.first?.path == throwing.path)
    }
}

// MARK: - 唤起入口保底（P1-11，设置侧）

@MainActor
struct PreferencesEntryGuardTests {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXEntry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePreferences() -> (LayoutStore, PreferencesModel) {
        let dir = tempDirectory()
        let store = LayoutStore(directory: dir)
        return (store, PreferencesModel(store: store))
    }

    @Test func blocksClosingMenuBarIconWhenItIsTheLastEntry() {
        let (store, prefs) = makePreferences()
        // 默认：仅菜单栏图标；热键未设置、捏合关闭、Dock 图标关闭
        #expect(store.state.settings.showMenuBarIcon)
        #expect(store.state.settings.hotKey == .none)
        #expect(store.state.settings.pinchGesture == .off)
        #expect(!store.state.settings.showDockIcon)

        prefs.setMenuBarIconVisible(false)
        ToastManager.shared.dismissAll()
        #expect(store.state.settings.showMenuBarIcon)  // 被阻止，仍在
        #expect(prefs.hasAnyEntry)
    }

    @Test func allowsClosingMenuBarIconAfterConfiguringHotKey() {
        let (store, prefs) = makePreferences()
        store.updateSettings { $0.hotKey = HotKeySpec(keyCode: 49, modifiers: 0x0100) }

        prefs.setMenuBarIconVisible(false)
        ToastManager.shared.dismissAll()
        #expect(!store.state.settings.showMenuBarIcon)
        #expect(prefs.hasAnyEntry)
    }

    @Test func blocksClearingHotKeyWhenItIsTheLastEntry() {
        let (store, prefs) = makePreferences()
        store.updateSettings {
            $0.showMenuBarIcon = false
            $0.showDockIcon = false
            $0.pinchGesture = .off
            $0.hotKey = HotKeySpec(keyCode: 49, modifiers: 0x0100)
        }

        prefs.clearHotKey()
        ToastManager.shared.dismissAll()
        #expect(store.state.settings.hotKey != .none)  // 拒绝清除
    }

    @Test func blocksTurningOffLastPinchGestureEntry() {
        let (store, prefs) = makePreferences()
        store.updateSettings {
            $0.showMenuBarIcon = false
            $0.showDockIcon = false
            $0.hotKey = .none
            $0.pinchGesture = .fourFinger
        }

        prefs.setPinchGesture(.off)
        ToastManager.shared.dismissAll()
        #expect(store.state.settings.pinchGesture == .fourFinger)  // 拒绝关闭
    }

    @Test func allowsDisablingEntryWhenDockIconRemains() {
        let (store, prefs) = makePreferences()
        store.updateSettings { $0.showDockIcon = true }

        prefs.setMenuBarIconVisible(false)
        ToastManager.shared.dismissAll()
        #expect(!store.state.settings.showMenuBarIcon)
        #expect(prefs.hasAnyEntry)
    }
}

// MARK: - 整理会话撤销 / 补空位反馈（P2-6、P2-7）

@MainActor
struct ReorganizeSessionTests {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXReorganize-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSession() -> (LayoutStore, ReorganizeSession) {
        let dir = tempDirectory()
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        return (store, ReorganizeSession(store: store, model: model))
    }

    @Test func fillEmptySlotsOnCompactLayoutReportsUnchanged() {
        let (store, session) = makeSession()
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]
        }

        let outcome = session.apply(ReorganizeRequest(
            action: .fillEmptySlots,
            sortKey: .name,
            ascending: true,
            scope: .allPages,
            alsoSortFolderContents: false
        ))

        ToastManager.shared.dismissAll()
        #expect(outcome == .unchanged)
        #expect(!session.canUndo)  // 无变化则不提供撤销
    }

    @Test func undoRestoresLayoutChangedByFillEmptySlots() {
        let (store, session) = makeSession()
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = [
                PageRecord(items: [.app(id: "a")]),
                PageRecord(items: []),
            ]
        }
        #expect(store.state.layout.pages.count == 2)

        let outcome = session.apply(ReorganizeRequest(
            action: .fillEmptySlots,
            sortKey: .name,
            ascending: true,
            scope: .allPages,
            alsoSortFolderContents: false
        ))

        ToastManager.shared.dismissAll()
        #expect(outcome == .changed)
        #expect(session.canUndo)
        #expect(store.state.layout.pages.count == 1)

        session.undo()
        ToastManager.shared.dismissAll()
        #expect(store.state.layout.pages.count == 2)
        #expect(!session.canUndo)
    }

    @Test func undoRestoresPageOrderAfterSort() {
        let (store, session) = makeSession()
        store.updateLayout { layout in
            layout.apps["b"] = makeApp("b", name: "Beta")
            layout.apps["a"] = makeApp("a", name: "Alpha")
            layout.pages = [PageRecord(items: [.app(id: "b"), .app(id: "a")])]
        }

        let outcome = session.apply(ReorganizeRequest(
            action: .sort,
            sortKey: .name,
            ascending: true,
            scope: .allPages,
            alsoSortFolderContents: false
        ))
        ToastManager.shared.dismissAll()
        #expect(outcome == .changed)
        #expect(store.state.layout.pages[0].items == [.app(id: "a"), .app(id: "b")])

        session.undo()
        ToastManager.shared.dismissAll()
        #expect(store.state.layout.pages[0].items == [.app(id: "b"), .app(id: "a")])
        #expect(!session.canUndo)
    }
}

// MARK: - P3-2：类目中文化 / P3-6：卸载模型复用重置

struct UninstallCategoryLocalizationTests {

    @Test func everyCategoryHasChineseDisplayName() {
        for category in UninstallCategory.allCases {
            #expect(category.displayName.contains { $0.isCJKUnifiedIdeograph })
            #expect(category.displayName != category.rawValue)
        }
    }

    @Test func displayNamesAreUnique() {
        let names = UninstallCategory.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test func rawValueStaysEnglishAsStableIdentifier() {
        // rawValue 参与 UninstallItem.id，必须保持英文稳定值，不能翻译。
        #expect(UninstallCategory.caches.rawValue == "Caches")
        #expect(UninstallCategory.userFiles.rawValue == "User Files")
        #expect(UninstallCategory.launchItems.rawValue == "Launch Items")
        #expect(UninstallCategory.caches.displayName == "缓存")
    }
}

extension Character {
    fileprivate var isCJKUnifiedIdeograph: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}

@MainActor
struct UninstallModelResetTests {

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXUninstallReset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/test.app.bundle", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func makeApp() -> AppRecord {
        AppRecord(
            id: "test.app.bundle",
            name: "TestApp",
            bundleName: "TestApp",
            bundleId: "test.app.bundle",
            version: "1.0",
            path: "/Applications/TestApp.app",
            category: nil
        )
    }

    @Test func resetClearsScanResultsSelectionAndPhase() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXResetStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = UninstallModel(
            app: makeApp(),
            layoutStore: LayoutStore(directory: dir),
            homeDirectory: home
        )

        model.startScan()
        for _ in 0..<60 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(model.phase == .ready)
        #expect(!model.items.isEmpty)

        model.checkedItemIDs = [model.items[0].id]
        model.needsFullDiskAccess = true

        model.reset()

        #expect(model.items.isEmpty)
        #expect(model.checkedItemIDs.isEmpty)
        #expect(model.phase == .idle)
        #expect(!model.needsFullDiskAccess)
    }

    @Test func resetOnFreshModelIsIdempotent() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXResetStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = UninstallModel(app: makeApp(), layoutStore: LayoutStore(directory: dir))
        model.reset()
        model.reset()
        #expect(model.items.isEmpty)
        #expect(model.phase == .idle)
    }
}

// MARK: - P3-5：快捷键录制控件的 VoiceOver 动作

@MainActor
struct HotKeyRecorderAccessibilityTests {

    private func makeView() -> HotKeyRecorderControl.RecorderControlView {
        HotKeyRecorderControl.RecorderControlView(frame: NSRect(x: 0, y: 0, width: 140, height: 28))
    }

    @Test func accessibilityExposesButtonRoleLabelAndValue() {
        let view = makeView()
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .button)
        #expect(view.accessibilityLabel() == "全局快捷键")
        #expect(view.accessibilityValue() is String)
        #expect(view.accessibilityHelp()?.isEmpty == false)
    }

    @Test func pressWithoutWindowDoesNotStartRecording() {
        // 未挂到窗口时按 VoiceOver 的 press 应安全返回 false（不进入录制态）。
        let view = makeView()
        var events: [Bool] = []
        view.onRecordingChanged = { events.append($0) }
        #expect(view.accessibilityPerformPress() == false)
        #expect(events.isEmpty)
        #expect(view.accessibilityValue() as? String != "录制中")
    }

    @Test func recordingStateIsReflectedInAccessibilityValue() {
        let view = makeView()
        view.displayText = "⌥⌘L"
        #expect(view.accessibilityValue() as? String == "⌥⌘L")
        view.recording = true
        #expect(view.accessibilityValue() as? String == "录制中")
        view.recording = false
        #expect(view.accessibilityValue() as? String == "⌥⌘L")
    }
}
