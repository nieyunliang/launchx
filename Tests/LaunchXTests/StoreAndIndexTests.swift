import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 存储

@MainActor
struct StoreTests {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func persistenceRoundTrip() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LayoutStore(directory: dir)
        store.updateLayout { layout in
            layout.apps["x"] = makeApp("x")
            layout.pages = [PageRecord(items: [.app(id: "x")])]
        }
        store.updateSettings { $0.hideAppNames = true }

        let reloaded = LayoutStore(directory: dir)
        #expect(reloaded.state.layout.apps["x"]?.name == "x")
        #expect(reloaded.state.settings.hideAppNames)
        #expect(!reloaded.state.sources.isEmpty)  // 默认来源初始化
    }

    @Test func corruptedStoreQuarantinesInsteadOfCrashing() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json {{{".utf8).write(to: dir.appendingPathComponent("store.json"))

        let store = LayoutStore(directory: dir)
        #expect(store.state.layout.pages.count == 1)  // 全新状态
        #expect(store.didRecoverFromCorruption)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func loadPurgesEmptyFoldersFromLegacyStore() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 写入一个含空文件夹的布局（旧版本 / 手工编辑 store.json 的残留形态）
        let store = LayoutStore(directory: dir)
        store.updateLayout { layout in
            layout.apps["x"] = makeApp("x")
            layout.pages = [
                PageRecord(items: [.app(id: "x")]),
                PageRecord(items: [.folder(FolderRecord(name: "Empty", appIDs: []))]),
            ]
        }

        // 重新加载：空文件夹被清扫，清空后的空页一并移除
        let reloaded = LayoutStore(directory: dir)
        #expect(reloaded.state.layout.pages.count == 1)
        #expect(reloaded.state.layout.pages[0].items.compactMap(\.appID) == ["x"])
    }

    @Test func missingAppFieldKeepsLayoutAndSettings() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LayoutStore(directory: dir)
        store.updateLayout { layout in
            layout.apps["x"] = makeApp("x")
            layout.pages = [PageRecord(items: [.app(id: "x")])]
        }
        store.updateSettings { $0.hideAppNames = true }

        // 模拟同步工具 / 手工编辑导致的应用字段缺失。
        let url = dir.appendingPathComponent("store.json")
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var layout = root["layout"] as! [String: Any]
        var apps = layout["apps"] as! [String: Any]
        var app = apps["x"] as! [String: Any]
        app.removeValue(forKey: "launchCount")
        app.removeValue(forKey: "addedAt")
        apps["x"] = app
        layout["apps"] = apps
        root["layout"] = layout
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        let reloaded = LayoutStore(directory: dir)
        #expect(!reloaded.didRecoverFromCorruption)
        #expect(reloaded.state.layout.apps["x"] != nil)
        #expect(reloaded.state.layout.apps["x"]?.launchCount == 0)
        #expect(reloaded.state.layout.pages.count == 1)
        #expect(reloaded.state.settings.hideAppNames)
    }

    @Test func malformedLayoutKeepsSettings() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // layout 整个类型错误：应回退默认布局，但设置仍保留。
        let payload = """
        {"version": 2, "layout": 42, "settings": {"hideAppNames": true, "activeSortKey": "custom"}, "sources": []}
        """
        try Data(payload.utf8).write(to: dir.appendingPathComponent("store.json"))

        let store = LayoutStore(directory: dir)
        #expect(store.state.settings.hideAppNames)
        #expect(store.state.layout.pages.count == 1)
    }

    @Test func saveNowWritesBackupOfPreviousState() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)

        store.updateLayout { layout in
            layout.apps["x"] = makeApp("x")
            layout.pages = [PageRecord(items: [.app(id: "x")])]
        }
        // 第二次落盘前，上一版（hideAppNames=false）应被复制为 store.json.bak。
        store.updateSettings { $0.hideAppNames = true }

        let backup = dir.appendingPathComponent("store.json.bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let previous = try decoder.decode(PersistState.self, from: Data(contentsOf: backup))
        #expect(previous.layout.apps["x"] != nil)
        #expect(!previous.settings.hideAppNames)
    }

    @Test func resetLayoutKeepsSettingsAndSources() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LayoutStore(directory: dir)
        let sourceCount = store.state.sources.count
        store.updateSettings { $0.showDockIcon = true }
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }

        store.resetLayout()
        // 只重置摆放结构：应用注册表与设置/来源保留。
        #expect(store.state.layout.apps["a"] != nil)
        #expect(store.state.layout.pages[0].items == [.app(id: "a")])
        #expect(store.state.settings.showDockIcon)
        #expect(store.state.sources.count == sourceCount)
    }

    @Test func resetLayoutKeepsHiddenStateAndUsageStats() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)

        var hidden = makeApp("hidden")
        hidden.hidden = true
        hidden.launchCount = 7
        hidden.lastOpenedAt = Date(timeIntervalSince1970: 1_000)
        var visible = makeApp("visible")
        visible.launchCount = 3
        store.updateLayout { layout in
            layout.apps["hidden"] = hidden
            layout.apps["visible"] = visible
            layout.pages = [PageRecord(items: [.folder(FolderRecord(name: "F", appIDs: ["hidden", "visible"]))])]
        }

        store.resetLayout()
        #expect(store.state.layout.apps["hidden"]?.hidden == true)
        #expect(store.state.layout.apps["hidden"]?.launchCount == 7)
        #expect(store.state.layout.apps["visible"]?.launchCount == 3)
        // 隐藏应用不回到网格；可见应用重新铺到首页。
        #expect(store.state.layout.pages[0].items == [.app(id: "visible")])
    }

    @Test func futureVersionStoreIsReadOnlyAndKeepsUnknownFields() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = """
        {"version": 99, "futureOnlyField": "keep-me", "layout": {"version": 1, "pages": [], "apps": {}},
         "settings": {"hideAppNames": false}, "sources": []}
        """
        let url = dir.appendingPathComponent("store.json")
        try Data(payload.utf8).write(to: url)

        let store = LayoutStore(directory: dir)
        #expect(store.isReadOnlyForFutureVersion)
        store.updateSettings { $0.hideAppNames = true }
        try store.saveNow()  // 只读模式下应静默跳过，不抛错

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("futureOnlyField"))
        #expect(text.contains("\"version\": 99"))
    }

    @Test func inMemorySettingsUpdateDefersDiskUntilSaveNow() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)

        // 动画关键路径：先提交内存态，不产生完整 JSON 编码与写盘。
        store.updateSettingsInMemory { $0.lastViewedPage = 2 }
        #expect(store.state.settings.lastViewedPage == 2)
        #expect(!FileManager.default.fileExists(atPath: store.storeFileURL.path))

        // 收起动画结束 / 应用退出时的显式落盘点。
        try store.saveNow()
        let reloaded = LayoutStore(directory: dir)
        #expect(reloaded.state.settings.lastViewedPage == 2)
    }

    @Test func recordLaunchUpdatesUsageAndClearsNew() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        store.updateLayout { layout in
            var app = makeApp("x")
            app.isNew = true
            layout.apps["x"] = app
        }
        store.recordLaunch(appID: "x")
        let app = store.state.layout.apps["x"]
        #expect(app?.isNew == false)
        #expect(app?.launchCount == 1)
        #expect(app?.lastOpenedAt != nil)
    }
}

// MARK: - 应用索引 / 同步

struct AppIndexAndSyncTests {

    private func makeFakeAppBundle(at dir: URL, name: String, bundleID: String) throws {
        let bundle = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleShortVersionString": "2.0",
            "LSApplicationCategoryType": "public.app-category.productivity",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    @Test func scanDeduplicatesByBundleID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXScan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try makeFakeAppBundle(at: dir, name: "First", bundleID: "dup.app")
        let subDir = dir.deletingLastPathComponent()
            .appendingPathComponent("LaunchXScan2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: subDir) }
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try makeFakeAppBundle(at: subDir, name: "Second", bundleID: "dup.app")

        let records = AppIndex.scan(directories: [dir, subDir])
        #expect(records.count == 1)
        #expect(records[0].name == "First")
        #expect(records[0].category == "public.app-category.productivity")
        #expect(records[0].version == "2.0")
    }

    @Test func scanPicksUpAliasFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXAlias-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 替身 = 非 .app 目录的同名文件
        try Data("alias".utf8).write(to: dir.appendingPathComponent("Shortcut.app"))

        let records = AppIndex.scan(directories: [dir])
        #expect(records.count == 1)
        #expect(records[0].isAlias)
        #expect(records[0].name == "Shortcut")
    }

    // MARK: 自定义来源递归扫描（含子目录）

    @Test func customSourceIncludesSubdirectoryApps() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXRecursive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 根 / 一层 / 两层 / 三层子目录各放一个应用，全部应被收进扫描结果
        let level1 = dir.appendingPathComponent("分类", isDirectory: true)
        let level2 = level1.appendingPathComponent("工具", isDirectory: true)
        let level3 = level2.appendingPathComponent("更深", isDirectory: true)
        try FileManager.default.createDirectory(at: level3, withIntermediateDirectories: true)
        try makeFakeAppBundle(at: dir, name: "TopApp", bundleID: "rec.top")
        try makeFakeAppBundle(at: level1, name: "LevelOne", bundleID: "rec.l1")
        try makeFakeAppBundle(at: level2, name: "LevelTwo", bundleID: "rec.l2")
        try makeFakeAppBundle(at: level3, name: "LevelThree", bundleID: "rec.l3")

        let records = AppIndex.scan(sources: [SourceConfig(path: dir.path, kind: .custom)])
        #expect(Set(records.map(\.id)) == ["rec.top", "rec.l1", "rec.l2", "rec.l3"])
    }

    @Test func customSourceStopsRecursionAtDepthLimit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXDeepLimit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 第 4 层子目录超过深度上限（3），里面的应用不收
        let level3 = dir
            .appendingPathComponent("一", isDirectory: true)
            .appendingPathComponent("二", isDirectory: true)
            .appendingPathComponent("三", isDirectory: true)
        let level4 = level3.appendingPathComponent("四", isDirectory: true)
        try FileManager.default.createDirectory(at: level4, withIntermediateDirectories: true)
        try makeFakeAppBundle(at: level3, name: "Boundary", bundleID: "rec.boundary")
        try makeFakeAppBundle(at: level4, name: "TooDeep", bundleID: "rec.deep")

        let records = AppIndex.scan(sources: [SourceConfig(path: dir.path, kind: .custom)])
        #expect(records.map(\.id) == ["rec.boundary"])
    }

    @Test func customSourceDoesNotDescendIntoAppBundle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXNestBundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 应用 bundle 内部的 Helper 不应被当作独立应用
        try makeFakeAppBundle(at: dir, name: "Outer", bundleID: "nest.outer")
        let pluginDir = dir.appendingPathComponent("Outer.app/Contents/PlugIns", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        try makeFakeAppBundle(at: pluginDir, name: "Helper", bundleID: "nest.helper")

        let records = AppIndex.scan(sources: [SourceConfig(path: dir.path, kind: .custom)])
        #expect(records.map(\.id) == ["nest.outer"])
    }

    @Test func customSourceSkipsHiddenSubdirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXHiddenDir-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hidden = dir.appendingPathComponent(".备份", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try makeFakeAppBundle(at: hidden, name: "HiddenApp", bundleID: "rec.hidden")

        let records = AppIndex.scan(sources: [SourceConfig(path: dir.path, kind: .custom)])
        #expect(records.isEmpty)
    }

    @Test func scanSpecsMarkCustomSourcesAndUserAppsRecursive() {
        let builtin = SourceConfig.defaultApps()
        let legacy = SourceConfig(path: "/Legacy/Apps", kind: .userApps)
        let custom = SourceConfig(path: "/Custom/Apps", kind: .custom)
        let specs = SourceConfig.scanSpecs(from: [builtin, legacy, custom])
        let byPath = Dictionary(uniqueKeysWithValues: specs.map { ($0.url.path, $0.recursive) })
        #expect(byPath["/Applications"] == false)  // 内置标准目录对齐 Launchpad，不递归
        #expect(byPath["/Legacy/Apps"] == false)   // 旧版默认来源（存量兼容）不递归
        #expect(byPath["/Custom/Apps"] == true)    // 自定义目录递归下钻
        // ~/Applications 例外：浏览器等工具把应用快捷方式放进其子文件夹（如「Chrome Apps」）
        let userApps = SourceConfig.userApplicationsPath()
        if FileManager.default.fileExists(atPath: userApps) {
            #expect(byPath[userApps] == true)
        }
    }

    @Test func customSourceUpgradesOverlappingBuiltinDirectoryToRecursive() {
        // 内置「应用程序」对 ~/Applications 本身就递归；用户把同一目录又添加为自定义来源时，
        // 该目录不能被去重丢弃，递归标记取并集后仍为 true（含子目录）
        let homeApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        let specs = SourceConfig.scanSpecs(from: [
            SourceConfig.defaultApps(),
            SourceConfig(path: homeApps, kind: .custom),
        ])
        let byPath = Dictionary(uniqueKeysWithValues: specs.map { ($0.url.path, $0.recursive) })
        #expect(byPath[homeApps] == true)
        // 未被显式添加的标准目录保持只扫第一层
        #expect(byPath["/Applications"] == false)
    }

    @Test func watchDirectoriesExpandRecursiveSubdirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXWatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let level1 = dir.appendingPathComponent("分类", isDirectory: true)
        let level2 = level1.appendingPathComponent("工具", isDirectory: true)
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
        try makeFakeAppBundle(at: level1, name: "Nested", bundleID: "watch.nested")

        let rootURL = URL(fileURLWithPath: dir.path, isDirectory: true)
        // /var 等路径存在符号链接前缀，统一用标准化路径比较（监听集合本身与链接前缀无关）
        let paths = Set([rootURL, level1, level2].map(\.standardizedFileURL.path))
        // 递归来源：根与全部子目录都纳入监听（子目录新增应用也能触发重扫）
        let customDirs = SourceConfig.watchDirectories(from: [SourceConfig(path: dir.path, kind: .custom)])
        #expect(Set(customDirs.map(\.standardizedFileURL.path)) == paths)
        // 非递归来源（旧版默认来源兼容）：只监听根目录本身
        let legacyDirs = SourceConfig.watchDirectories(from: [SourceConfig(path: dir.path, kind: .userApps)])
        #expect(legacyDirs.map(\.standardizedFileURL.path) == [rootURL.standardizedFileURL.path])
    }

    @Test func displayNameFallbackChain() {
        #expect(AppIndex.displayName(infoPlist: ["CFBundleDisplayName": "显示名"], bundlePath: "/X.app") == "显示名")
        #expect(AppIndex.displayName(infoPlist: ["CFBundleName": "BName"], bundlePath: "/X.app") == "BName")
        #expect(AppIndex.displayName(infoPlist: [:], bundlePath: "/Applications/Fallback.app") == "Fallback")
    }

    @Test func syncMergesNewAppsAsDirectPlacements() {
        var layout = LayoutSnapshot(pages: [PageRecord()])
        let scanned = [makeApp("a"), makeApp("b")]

        let result = SyncEngine.merge(scanned: scanned, into: &layout, capacityPerPage: 35)
        #expect(result.addedAppIDs.sorted() == ["a", "b"])
        #expect(layout.pages[0].items.compactMap(\.appID).sorted() == ["a", "b"])
        // 基线扫描（注册表原为空）不标 NEW
        #expect(layout.apps["a"]?.isNew == false)

        // 增量扫描发现的新应用才亮 NEW
        _ = SyncEngine.merge(scanned: scanned + [makeApp("c")], into: &layout, capacityPerPage: 35)
        #expect(layout.apps["c"]?.isNew == true)
    }

    @Test func syncRemovesVanishedAppsButKeepsAlias() {
        var layout = LayoutSnapshot()
        register([makeApp("gone"), makeApp("kept")], into: &layout)
        var aliasApp = makeApp("alias")
        aliasApp.isAlias = true
        layout.apps["alias"] = aliasApp
        layout.pages = [PageRecord(items: [.app(id: "gone"), .app(id: "kept"), .app(id: "alias")])]

        // 第一次缺失只做标记（安装中 / 瞬时不可读的宽限）。
        let first = SyncEngine.merge(scanned: [makeApp("kept")], into: &layout, capacityPerPage: 35)
        #expect(first.removedAppIDs.isEmpty)
        #expect(layout.placedAppIDs.contains("gone"))
        #expect(layout.apps["gone"]?.missingScans == 1)

        // 连续第二次缺失才真正移除。
        let second = SyncEngine.merge(scanned: [makeApp("kept")], into: &layout, capacityPerPage: 35)
        #expect(second.removedAppIDs == ["gone"])
        #expect(layout.apps["alias"] != nil)       // alias 永不因扫描消失
        #expect(layout.placedAppIDs.contains("alias"))
    }

    @Test func scanDiagnosticsReportsUnreadableDirectories() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXMissing-\(UUID().uuidString)", isDirectory: true)
        let diagnostics = AppIndex.scanWithDiagnostics(directories: [missing])
        #expect(diagnostics.records.isEmpty)
        #expect(diagnostics.failedDirectories.count == 1)
    }

    @Test func syncRefreshesMetadataButKeepsUserEdits() {
        var layout = LayoutSnapshot(pages: [PageRecord()])
        var existing = makeApp("a", name: "我的改名")
        existing.name = "我的改名"
        layout.apps["a"] = existing
        layout.pages[0].items = [.app(id: "a")]

        var updated = makeApp("a", name: "New System Name")
        updated.version = "9.9"
        _ = SyncEngine.merge(scanned: [updated], into: &layout, capacityPerPage: 35)

        #expect(layout.apps["a"]?.name == "New System Name")  // 未改名记录跟随系统名
        #expect(layout.apps["a"]?.version == "9.9")
    }

    @Test func syncKeepsCustomRename() {
        var layout = LayoutSnapshot(pages: [PageRecord()])
        var existing = makeApp("a", name: "系统名")
        existing.name = "自定义名"
        // bundleName 保持系统名 → 视为用户改过名
        layout.apps["a"] = existing
        layout.pages[0].items = [.app(id: "a")]

        let updated = makeApp("a", name: "新系统名")
        _ = SyncEngine.merge(scanned: [updated], into: &layout, capacityPerPage: 35)
        #expect(layout.apps["a"]?.name == "自定义名")
    }
}

// MARK: - 排序默认值 / 迁移

@MainActor
struct SortSettingsMigrationTests {

    @Test func defaultSettingsSortByCustom() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.activeSortKey == .custom)  // 默认自由摆放，拖拽立即可用
        #expect(settings.sortAscending == false)
    }

    @Test func v1StoreKeepsCustomSortKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXMigrate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // v1 store.json：activeSortKey 只可能来自旧默认值 custom
        let payload = """
        {"version": 1, "layout": {"version": 1, "pages": [], "apps": {}}, \
        "settings": {"activeSortKey": "custom"}, "sources": []}
        """
        try Data(payload.utf8).write(to: dir.appendingPathComponent("store.json"))

        let store = LayoutStore(directory: dir)
        #expect(store.state.settings.activeSortKey == .custom)
        #expect(store.state.version == PersistState.currentVersion)
    }

    @Test func v1StoreKeepsDeliberateNonCustomSortKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXMigrate2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let payload = """
        {"version": 1, "layout": {"version": 1, "pages": [], "apps": {}}, \
        "settings": {"activeSortKey": "name"}, "sources": []}
        """
        try Data(payload.utf8).write(to: dir.appendingPathComponent("store.json"))

        let store = LayoutStore(directory: dir)
        #expect(store.state.settings.activeSortKey == .name)
    }

    @Test func applyActiveSortKeepsGridConsistentAfterLaunch() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXSort-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        store.updateSettings { $0.activeSortKey = .mostRecent }
        let old = Date(timeIntervalSince1970: 1000)
        let mid = Date(timeIntervalSince1970: 2000)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a", lastOpenedAt: mid)
            layout.apps["b"] = makeApp("b", lastOpenedAt: old)
            layout.apps["c"] = makeApp("c")
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b"), .app(id: "c")])]
        }

        // 启动 c（从未用过 → lastOpenedAt = now，最新）后重排，c 应排最前
        store.recordLaunch(appID: "c")
        store.applyActiveSort()
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["c", "a", "b"])
    }
}
