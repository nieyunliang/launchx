import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 测试工具

func makeApp(
    _ id: String,
    name: String? = nil,
    bundleName: String? = nil,
    addedAt: Date = Date(timeIntervalSince1970: 1000),
    lastOpenedAt: Date? = nil,
    launchCount: Int = 0,
    hidden: Bool = false,
    bundleId: String? = nil
) -> AppRecord {
    AppRecord(
        id: id,
        name: name ?? id,
        bundleName: bundleName ?? name ?? id,
        bundleId: bundleId ?? id,
        version: "1.0",
        path: "/Applications/\(id).app",
        category: nil,
        hidden: hidden,
        isAlias: false,
        addedAt: addedAt,
        lastOpenedAt: lastOpenedAt,
        launchCount: launchCount,
        isNew: false
    )
}

func register(_ apps: [AppRecord], into layout: inout LayoutSnapshot) {
    for app in apps {
        layout.apps[app.id] = app
    }
}

// MARK: - 排序引擎

struct SortEngineTests {

    @Test func customIsNoOp() {
        var layout = LayoutSnapshot()
        register([makeApp("b"), makeApp("a")], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "b"), .app(id: "a")])]
        let changed = SortEngine.apply(
            &layout, key: .custom, ascending: true, scope: .allPages,
            options: SortOptions(alsoSortFolderContents: false, folderPosition: .afterApps, appleAppsPosition: .mixed)
        )
        #expect(!changed)
        #expect(layout.pages[0].items.map(\.appID) == ["b", "a"])
    }

    @Test func sortByNameAscendingAndDescending() {
        var layout = LayoutSnapshot()
        register([makeApp("c", name: "Charlie"), makeApp("a", name: "alpha"), makeApp("b", name: "Bravo")], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "c"), .app(id: "a"), .app(id: "b")])]

        SortEngine.apply(&layout, key: .name, ascending: true, scope: .allPages,
                         options: .init(alsoSortFolderContents: false))
        #expect(layout.pages[0].items.map(\.appID) == ["a", "b", "c"])

        SortEngine.apply(&layout, key: .name, ascending: false, scope: .allPages,
                         options: .init(alsoSortFolderContents: false))
        #expect(layout.pages[0].items.map(\.appID) == ["c", "b", "a"])
    }

    @Test func sortByDateAdded() {
        var layout = LayoutSnapshot()
        register([
            makeApp("old", addedAt: Date(timeIntervalSince1970: 1)),
            makeApp("new", addedAt: Date(timeIntervalSince1970: 100)),
            makeApp("mid", addedAt: Date(timeIntervalSince1970: 50)),
        ], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "old"), .app(id: "new"), .app(id: "mid")])]

        SortEngine.apply(&layout, key: .dateAdded, ascending: true, scope: .allPages,
                         options: .init(alsoSortFolderContents: false))
        #expect(layout.pages[0].items.map(\.appID) == ["old", "mid", "new"])

        SortEngine.apply(&layout, key: .newestFirst, ascending: true, scope: .allPages,
                         options: .init(alsoSortFolderContents: false))
        #expect(layout.pages[0].items.map(\.appID) == ["old", "mid", "new"])  // Newest First 键同 addedAt 升序语义
    }

    @Test func sortByLastUsedCount() {
        var layout = LayoutSnapshot()
        register([
            makeApp("x", launchCount: 3),
            makeApp("y", launchCount: 10),
            makeApp("z", launchCount: 1),
        ], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "x"), .app(id: "y"), .app(id: "z")])]

        SortEngine.apply(&layout, key: .lastUsed, ascending: true, scope: .allPages,
                         options: .init(alsoSortFolderContents: false))
        #expect(layout.pages[0].items.map(\.appID) == ["z", "x", "y"])
    }

    @Test func appleAppsPositionRule() {
        var layout = LayoutSnapshot()
        register([
            makeApp("third", name: "Zed", bundleId: "com.other.zed"),
            makeApp("apple1", name: "Calendar", bundleId: "com.apple.iCal"),
            makeApp("second", name: "Beta", bundleId: "com.other.beta"),
        ], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "third"), .app(id: "apple1"), .app(id: "second")])]

        SortEngine.apply(
            &layout, key: .name, ascending: true, scope: .allPages,
            options: SortOptions(alsoSortFolderContents: false, folderPosition: .afterApps, appleAppsPosition: .beforeApps)
        )
        #expect(layout.pages[0].items.map(\.appID) == ["apple1", "second", "third"])
    }

    @Test func folderPositionRule() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b")], into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["a"])
        layout.pages = [PageRecord(items: [.app(id: "b"), .folder(folder)])]

        SortEngine.apply(
            &layout, key: .name, ascending: true, scope: .allPages,
            options: SortOptions(alsoSortFolderContents: true, folderPosition: .beforeApps, appleAppsPosition: .mixed)
        )
        #expect(layout.pages[0].items.first?.folder?.name == "F")
    }

    @Test func alsoSortFolderContents() {
        var layout = LayoutSnapshot()
        register([makeApp("c"), makeApp("a"), makeApp("b")], into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["c", "a", "b"])
        layout.pages = [PageRecord(items: [.folder(folder)])]

        SortEngine.apply(&layout, key: .name, ascending: true, scope: .allPages,
                         options: .init(alsoSortFolderContents: true))
        #expect(layout.pages[0].items[0].folder?.appIDs == ["a", "b", "c"])
    }

    @Test func scopeCurrentPageOnly() {
        var layout = LayoutSnapshot()
        register([makeApp("z1"), makeApp("a1"), makeApp("m1")], into: &layout)
        layout.pages = [
            PageRecord(items: [.app(id: "z1")]),
            PageRecord(items: [.app(id: "m1"), .app(id: "a1")]),
        ]
        SortEngine.apply(&layout, key: .name, ascending: true, scope: .currentPage(1),
                         options: .init(alsoSortFolderContents: false))
        #expect(layout.pages[0].items.map(\.appID) == ["z1"])
        #expect(layout.pages[1].items.map(\.appID) == ["a1", "m1"])
    }

    @Test func scopeSelectedPages() {
        var layout = LayoutSnapshot()
        register([makeApp("z"), makeApp("a")], into: &layout)
        layout.pages = [
            PageRecord(items: [.app(id: "z")]),
            PageRecord(items: [.app(id: "a")]),
        ]
        SortEngine.apply(&layout, key: .name, ascending: false, scope: .selectedPages([0]),
                         options: .init(alsoSortFolderContents: false))
        // 单页单应用：顺序不变但未崩溃
        #expect(layout.pages[0].items.map(\.appID) == ["z"])
    }
}

// MARK: - 跨页重排

struct ReorganizeEngineTests {

    @Test func reorganizeAcrossPagesRedistributes() {
        var layout = LayoutSnapshot()
        register((0..<5).map { makeApp("a\($0)") }, into: &layout)
        layout.pages = [
            PageRecord(items: [.app(id: "a0")]),                       // 半空页
            PageRecord(items: [.app(id: "a1"), .app(id: "a2")]),
            PageRecord(items: [.app(id: "a3"), .app(id: "a4")]),
        ]
        ReorganizeEngine.reorganizeAcrossPages(&layout, scope: .allPages, capacityPerPage: 3)
        #expect(layout.pages.count == 2)
        #expect(layout.pages[0].items.map(\.appID) == ["a0", "a1", "a2"])
        #expect(layout.pages[1].items.map(\.appID) == ["a3", "a4"])
    }

    @Test func reorganizeScopedKeepsOtherPages() {
        var layout = LayoutSnapshot()
        register([makeApp("k")], into: &layout)
        layout.pages = [
            PageRecord(items: [.app(id: "k")]),
            PageRecord(),
            PageRecord(items: [.app(id: "other")]),
        ]
        layout.apps["other"] = makeApp("other")
        ReorganizeEngine.reorganizeAcrossPages(&layout, scope: .selectedPages([0, 1]), capacityPerPage: 10)
        #expect(layout.pages.map { $0.items.map(\.appID) } == [["k"], ["other"]])
    }

    @Test func fillEmptySlotsIsIdempotent() {
        var layout = LayoutSnapshot(pages: [PageRecord(items: [.app(id: "x")])])
        layout.apps["x"] = makeApp("x")
        ReorganizeEngine.fillEmptySlots(&layout, scope: .allPages)
        #expect(layout.pages[0].items.map(\.appID) == ["x"])
    }

    @Test func fillEmptySlotsCompactsAcrossPages() {
        var layout = LayoutSnapshot()
        register(
            [makeApp("a0"), makeApp("a1"), makeApp("a2"), makeApp("a3"), makeApp("a4")],
            into: &layout
        )
        layout.pages = [
            PageRecord(items: [.app(id: "a0")]),
            PageRecord(),
            PageRecord(items: [.app(id: "a1"), .app(id: "a2")]),
            PageRecord(items: [.app(id: "a3"), .app(id: "a4")]),
        ]

        let changed = ReorganizeEngine.fillEmptySlots(&layout, scope: .allPages, capacityPerPage: 2)
        #expect(changed)
        // 跨页前压：保序铺满 2/页，空页被删除
        #expect(layout.pages.map { $0.items.map(\.appID) } == [["a0", "a1"], ["a2", "a3"], ["a4"]])

        // 已无空位时再次执行应为 no-op
        let changedAgain = ReorganizeEngine.fillEmptySlots(&layout, scope: .allPages, capacityPerPage: 2)
        #expect(!changedAgain)
        #expect(layout.pages.map { $0.items.map(\.appID) } == [["a0", "a1"], ["a2", "a3"], ["a4"]])
    }

    @Test func fillEmptySlotsKeepsPagesOutsideScope() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b"), makeApp("c")], into: &layout)
        layout.pages = [
            PageRecord(items: [.app(id: "a")]),
            PageRecord(),
            PageRecord(items: [.app(id: "b")]),
            PageRecord(items: [.app(id: "c")]),
        ]
        ReorganizeEngine.fillEmptySlots(&layout, scope: .currentPage(1), capacityPerPage: 1)
        // 作用域内的空页被删除，其他页原样保留
        #expect(layout.pages.map { $0.items.map(\.appID) } == [["a"], ["b"], ["c"]])
    }
}

// MARK: - 文件夹引擎

struct FolderEngineTests {

    @Test func createFolderFromTwoApps() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b")], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]

        FolderEngine.createFolder(dragging: "b", onto: "a", layout: &layout)
        #expect(layout.pages[0].items.count == 1)
        #expect(layout.pages[0].items[0].folder?.appIDs == ["a", "b"])
        #expect(layout.pages[0].items[0].folder?.name == "新建文件夹")
    }

    @Test func createFolderSecondTimeGetsNumberedName() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b"), makeApp("c"), makeApp("d")], into: &layout)
        layout.pages = [
            PageRecord(items: [
                .folder(FolderRecord(name: "新建文件夹", appIDs: ["a"])),
                .app(id: "b"),
                .app(id: "c"),
                .app(id: "d"),
            ]),
        ]
        FolderEngine.createFolder(dragging: "c", onto: "d", layout: &layout)
        let folders = layout.pages[0].items.compactMap(\.folder)
        #expect(folders.count == 2)
        #expect(folders[1].name == "新建文件夹 2")
    }

    @Test func dragOntoFolderAppMergesIntoFolder() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b"), makeApp("c")], into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["a", "b"])
        layout.pages = [PageRecord(items: [.folder(folder), .app(id: "c")])]

        FolderEngine.createFolder(dragging: "c", onto: "b", layout: &layout)
        #expect(layout.pages[0].items.count == 1)
        #expect(layout.pages[0].items[0].folder?.appIDs == ["a", "b", "c"])
    }

    @Test func hiddenAppsCannotEnterFolder() {
        var layout = LayoutSnapshot()
        register([makeApp("a", hidden: true), makeApp("b")], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]

        FolderEngine.createFolder(dragging: "b", onto: "a", layout: &layout)
        #expect(layout.pages[0].items.compactMap(\.folder).isEmpty)
    }

    @Test func mergeIntoFolder() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b"), makeApp("c")], into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["a"])
        layout.pages = [
            PageRecord(items: [.app(id: "b"), .app(id: "c")]),
            PageRecord(items: [.folder(folder)]),
        ]
        FolderEngine.mergeIntoFolder(appIDs: ["b", "c"], folderID: folder.id, layout: &layout)
        // 第一页被清空后移除，文件夹成为唯一的第 1 页
        #expect(layout.pages.count == 1)
        #expect(layout.pages[0].items[0].folder?.appIDs == ["a", "b", "c"])
    }

    @Test func ungroupAppendsAtPageEndWithSpill() {
        var layout = LayoutSnapshot()
        register((0..<4).map { makeApp("f\($0)") } + (0..<3).map { makeApp("pad\($0)") }, into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["f0", "f1", "f2", "f3"])
        layout.pages = [
            PageRecord(items: [.folder(folder), .app(id: "pad0"), .app(id: "pad1"), .app(id: "pad2")]),
        ]

        FolderEngine.ungroup(folderID: folder.id, layout: &layout, capacityPerPage: 5)
        // 页容量 5：3 个 pad + f0/f1 放满第一页，f2/f3 顺延第二页
        #expect(layout.pages.count == 2)
        #expect(layout.pages[0].slotCount == 5)
        #expect(layout.pages[1].slotCount == 2)
    }

    @Test func ungroupAllKeepsPageOrder() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b"), makeApp("c"), makeApp("d")], into: &layout)
        layout.pages = [
            PageRecord(items: [.folder(FolderRecord(name: "F1", appIDs: ["a", "b"]))]),
            PageRecord(items: [.app(id: "c"), .folder(FolderRecord(name: "F2", appIDs: ["d"]))]),
        ]
        FolderEngine.ungroupAll(layout: &layout, capacityPerPage: 35)
        #expect(layout.pages[0].items.map(\.appID) == ["a", "b"])
        #expect(layout.pages[1].items.map(\.appID) == ["c", "d"])
    }

    @Test func mergeIntoNewFolderPlacesOnPage() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b"), makeApp("c")], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b"), .app(id: "c")])]

        FolderEngine.mergeIntoNewFolder(appIDs: ["a", "c"], page: 0, layout: &layout)
        #expect(layout.pages[0].items.count == 2)  // b + folder
        #expect(layout.pages[0].items[1].folder?.appIDs == ["a", "c"])
    }

    @Test func removeAppFromFolderLeavesEmptyFolderDeleted() {
        var layout = LayoutSnapshot()
        register([makeApp("solo"), makeApp("other")], into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["solo"])
        layout.pages = [
            PageRecord(items: [.folder(folder)]),
            PageRecord(items: [.app(id: "other")]),
        ]
        FolderEngine.removeAppFromFolder(appID: "solo", folderID: folder.id, toPage: 1, layout: &layout)
        #expect(layout.pages[0].items.isEmpty)
        #expect(layout.pages[1].items.map(\.appID) == ["other", "solo"])
    }

    @Test func renameFolderPersists() {
        var layout = LayoutSnapshot()
        let folder = FolderRecord(name: "Old", appIDs: [])
        layout.pages = [PageRecord(items: [.folder(folder)])]
        FolderEngine.renameFolder(folderID: folder.id, to: "New", layout: &layout)
        #expect(layout.pages[0].items[0].folder?.name == "New")
    }
}

// MARK: - 全局排序（applyGlobally）

struct GlobalSortTests {

    private let t0 = Date(timeIntervalSince1970: 1000)
    private let t1 = Date(timeIntervalSince1970: 2000)
    private let t2 = Date(timeIntervalSince1970: 3000)

    @Test func globalSortOrdersAppsAcrossPagesByMostRecent() {
        var layout = LayoutSnapshot()
        register([
            makeApp("a", lastOpenedAt: t1),
            makeApp("b", lastOpenedAt: t0),
            makeApp("c", lastOpenedAt: t2),
        ], into: &layout)
        // 初始摆放打乱：b a | c
        layout.pages = [
            PageRecord(items: [.app(id: "b"), .app(id: "a")]),
            PageRecord(items: [.app(id: "c")]),
        ]

        SortEngine.applyGlobally(
            &layout, key: .mostRecent, ascending: false, capacityPerPage: 2,
            options: SortOptions(alsoSortFolderContents: false)
        )
        // 全局按最近使用排序后重铺：c t2 > a t1 > b t0
        #expect(layout.pages.map { $0.items.compactMap(\.appID) } == [["c", "a"], ["b"]])
    }

    @Test func globalSortCustomIsNoOp() {
        var layout = LayoutSnapshot()
        register([makeApp("a"), makeApp("b")], into: &layout)
        layout.pages = [PageRecord(items: [.app(id: "b"), .app(id: "a")])]

        SortEngine.applyGlobally(
            &layout, key: .custom, ascending: false, capacityPerPage: 35,
            options: SortOptions()
        )
        #expect(layout.pages[0].items.map(\.appID) == ["b", "a"])
    }

    @Test func globalSortFoldersFollowPositionRule() {
        var layout = LayoutSnapshot()
        register([makeApp("a", lastOpenedAt: t0), makeApp("b", lastOpenedAt: t1)], into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["a"])
        layout.pages = [PageRecord(items: [.app(id: "b"), .folder(folder)])]

        SortEngine.applyGlobally(
            &layout, key: .mostRecent, ascending: false, capacityPerPage: 35,
            options: SortOptions(alsoSortFolderContents: false, folderPosition: .beforeApps)
        )
        // 文件夹摆到页首，直接应用按最近使用排序（a 在文件夹内，不参与直接排序）
        #expect(layout.pages[0].items.first?.folder == folder)
        #expect(layout.pages[0].items.compactMap(\.appID) == ["b"])
    }

    @Test func globalSortAlsoSortsFolderContents() {
        var layout = LayoutSnapshot()
        register([
            makeApp("x", lastOpenedAt: t2),
            makeApp("y", lastOpenedAt: t0),
            makeApp("z", lastOpenedAt: t1),
        ], into: &layout)
        let folder = FolderRecord(name: "F", appIDs: ["y", "z"])
        layout.pages = [PageRecord(items: [.folder(folder), .app(id: "x")])]

        SortEngine.applyGlobally(
            &layout, key: .mostRecent, ascending: false, capacityPerPage: 35,
            options: SortOptions(alsoSortFolderContents: true)
        )
        // 默认 folderPosition = .afterApps：应用在前，文件夹在页尾；夹内按最近使用 z > y
        #expect(layout.pages[0].items.compactMap(\.appID) == ["x"])
        #expect(layout.pages[0].items.last?.folder?.appIDs == ["z", "y"])
    }

    @Test func effectiveAscendingMapping() {
        #expect(SortKey.mostRecent.effectiveAscending(fallback: true) == false)
        #expect(SortKey.leastRecent.effectiveAscending(fallback: false) == true)
        #expect(SortKey.newestFirst.effectiveAscending(fallback: true) == false)
        #expect(SortKey.oldestFirst.effectiveAscending(fallback: false) == true)
        #expect(SortKey.name.effectiveAscending(fallback: true) == true)
        #expect(SortKey.name.effectiveAscending(fallback: false) == false)
        #expect(SortKey.mostRecent.hasFixedDirection)
        #expect(!SortKey.name.hasFixedDirection)
    }
}
