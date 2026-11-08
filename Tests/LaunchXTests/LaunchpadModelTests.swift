import AppKit
import Foundation
import Observation
import Testing
@testable import LaunchXCore

// MARK: - Launchpad 模型

@Suite(.serialized)
@MainActor
struct LaunchpadModelTests {

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func searchFiltersAndRanks() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps = [
                "a": makeApp("a", name: "Chrome 浏览器"),
                "b": makeApp("b", name: "Chrome Canary"),
                "c": makeApp("c", name: "Safari"),
                "h": makeApp("h", name: "Chrome Dev", hidden: true),
            ]
        }
        model.searchQuery = "chrome"
        #expect(model.searchHits.map(\.appID) == ["a", "b"])  // 前缀 > 包含；隐藏默认排除

        store.updateSettings { $0.showHiddenAppsInSearch = true }
        #expect(model.searchHits.map(\.appID) == ["a", "b", "h"])

        model.searchQuery = "  "
        #expect(model.searchHits.isEmpty)
    }

    @Test func hideAndUnhide() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["x"] = makeApp("x")
            layout.pages = [PageRecord(items: [.app(id: "x")])]
        }

        model.setHidden(true, appID: "x")
        #expect(store.state.layout.apps["x"]?.hidden == true)

        store.updateLayout { layout in
            layout.removeApp(id: "x")
            layout.apps["x"] = makeApp("x", hidden: true)
        }  // 模拟隐藏且不在网格
        model.unhide(appID: "x")
        #expect(store.state.layout.apps["x"]?.hidden == false)
        #expect(store.state.layout.placedAppIDs.contains("x"))  // 未摆放的取消隐藏后回到网格
    }

    @Test func pageNavigationClamps() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.pages = [PageRecord(items: [.app(id: "a")]), PageRecord(items: [.app(id: "b")])]
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
        }
        model.nextPage()
        #expect(model.currentPage == 1)
        model.nextPage()
        #expect(model.currentPage == 1)  // 封顶
        model.previousPage()
        model.previousPage()
        #expect(model.currentPage == 0)
        model.goToPage(99)
        #expect(model.currentPage == 1)
    }

    @Test func settlePageDragCommitsAndResets() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.pages = [PageRecord(items: [.app(id: "a")]), PageRecord(items: [.app(id: "b")])]
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
        }
        model.pageWidth = 1000

        // 松手回弹但本就在原位：不进入落位锁定
        model.settlePageDrag(commitDirection: 0)
        #expect(model.isSettlingPageDrag == false)

        // 松手完成翻页：偏移动画到整页宽，动画收尾后原子换页并复位
        model.settlePageDrag(commitDirection: 1)
        #expect(model.isSettlingPageDrag == true)
        #expect(model.pageDragOffset == -1000)
        try await Task.sleep(for: .seconds(0.65))
        #expect(model.currentPage == 1)
        #expect(model.pageDragOffset == 0)
        #expect(model.isSettlingPageDrag == false)
        #expect(model.lastPageDirection == .forward)
    }

    @Test func pageDirectionTracksNavigation() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.pages = (0..<3).map { _ in PageRecord(items: [.app(id: "a")]) }
            layout.apps["a"] = makeApp("a")
        }
        model.goToPage(2)
        #expect(model.currentPage == 2)
        #expect(model.lastPageDirection == .forward)
        model.goToPage(0)
        #expect(model.lastPageDirection == .backward)
        model.nextPage()
        #expect(model.lastPageDirection == .forward)
        model.previousPage()
        #expect(model.lastPageDirection == .backward)
        // 末页再 nextPage 是空操作：不改变方向状态
        model.goToPage(1)
        model.nextPage()  // → 末页 2，forward
        model.previousPage()  // → 1，backward
        model.nextPage()  // → 2，forward
        model.nextPage()  // 空操作，保持 forward
        #expect(model.lastPageDirection == .forward)
    }

    @Test func dropOnAppCreatesFolder() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }  // 拖拽仅自定义模式可用
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]
        }

        model.performDrop(draggingIDs: ["b"], sourceFolderID: nil, target: .onApp(page: 0, appID: "a"))
        #expect(store.state.layout.pages[0].items.count == 1)
        #expect(store.state.layout.pages[0].items[0].folder?.appIDs == ["a", "b"])
    }

    @Test func dropOnFolderMerges() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }  // 拖拽仅自定义模式可用
        let folder = FolderRecord(name: "F", appIDs: ["a"])
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = [PageRecord(items: [.folder(folder), .app(id: "b")])]
        }

        model.performDrop(draggingIDs: ["b"], sourceFolderID: nil, target: .onFolder(page: 0, folderID: folder.id))
        #expect(store.state.layout.pages[0].items.count == 1)
        #expect(store.state.layout.pages[0].items[0].folder?.appIDs == ["a", "b"])
    }

    @Test func slotDropReordersWithSpill() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        store.updateSettings { $0.gridDensity = GridDensity(columns: 1, rows: 1) }  // 容量 1
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.apps["c"] = makeApp("c")
            layout.pages = [
                PageRecord(items: [.app(id: "a")]),
                PageRecord(items: [.app(id: "b")]),
                PageRecord(items: [.app(id: "c")]),
            ]
        }

        // 把 a 拖到第 2 页 b 的位置 → a 插入，b 被挤到下一页，c 再顺延，空页被清理
        model.performDrop(draggingIDs: ["a"], sourceFolderID: nil, target: .slot(page: 1, slot: 0))
        #expect(store.state.layout.pages.map { $0.items.compactMap(\.appID) } == [["a"], ["b"], ["c"]])
    }

    @Test func dragBlockedOutsideCustomSort() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]
        }
        model.activeSortKey = .name

        model.performDrop(draggingIDs: ["b"], sourceFolderID: nil, target: .slot(page: 0, slot: 0))
        // 未变更：顺序保持
        #expect(store.state.layout.pages[0].items.map(\.appID) == ["a", "b"])
        #expect(!ToastManager.shared.items.isEmpty)  // 提示 toast
        ToastManager.shared.dismissAll()
    }

    @Test func marqueeSelectionIntersects() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }
        model.marqueeRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        model.updateMarqueeSelection(itemFrames: ["a": CGRect(x: 10, y: 10, width: 50, height: 50)], inPage: 0)
        #expect(model.selectedAppIDs == ["a"])

        model.updateMarqueeSelection(itemFrames: ["a": CGRect(x: 200, y: 200, width: 50, height: 50)], inPage: 0)
        #expect(model.selectedAppIDs.isEmpty)
    }

    @Test func mergeSelectionRequiresTwoApps() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }
        model.selectedAppIDs = ["a"]
        model.mergeSelectionIntoNewFolder()
        #expect(store.state.layout.pages[0].items.compactMap(\.folder).isEmpty)
        ToastManager.shared.dismissAll()
    }

    @Test func folderOpenAndUngroup() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        let folder = FolderRecord(name: "F", appIDs: ["a", "b"])
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = [PageRecord(items: [.folder(folder)])]
        }

        model.openFolder(page: 0, folderID: folder.id)
        #expect(model.openedFolderRecord?.name == "F")
        model.ungroupFolder(folderID: folder.id)
        #expect(model.openedFolder == nil)
        #expect(store.state.layout.pages[0].items.compactMap(\.appID).count == 2)
    }

    @Test func dropFolderMembersWithoutSourceDoesNotDuplicate() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        let folder = FolderRecord(name: "F", appIDs: ["a", "b"])
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.apps["c"] = makeApp("c")
            layout.pages = [PageRecord(items: [.folder(folder), .app(id: "c")])]
        }

        // 模拟文件夹整体拖拽（历史行为）：载荷是成员 id，但没有来源文件夹信息
        model.performDrop(draggingIDs: ["a", "b"], sourceFolderID: nil, target: .pageBackground(page: 0))

        let layout = store.state.layout
        let placed = layout.placedAppIDs
        #expect(Set(placed).count == placed.count)  // 同一应用不会重复摆放
        #expect(layout.pages[0].items.compactMap(\.folder).isEmpty)  // 被摘空的文件夹一并移除
        #expect(layout.pages[0].items.compactMap(\.appID).sorted() == ["a", "b", "c"])
    }

    @Test func dropFolderMemberOntoFolderMovesInsteadOfDuplicating() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        let source = FolderRecord(name: "S", appIDs: ["a"])
        let target = FolderRecord(name: "T", appIDs: ["b"])
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = [PageRecord(items: [.folder(source), .folder(target)])]
        }

        // 无 sourceFolderID 的载荷（文件夹整体拖拽 / 打开文件夹状态失效）拖到另一个文件夹
        model.performDrop(draggingIDs: ["a"], sourceFolderID: nil, target: .onFolder(page: 0, folderID: target.id))

        let layout = store.state.layout
        let placed = layout.placedAppIDs
        #expect(Set(placed).count == placed.count)
        #expect(layout.pages[0].items.compactMap(\.folder).count == 1)  // 源文件夹被摘空后移除
        #expect(layout.pages[0].items.compactMap(\.folder).first?.appIDs.sorted() == ["a", "b"])
    }

    @Test func performDropRecreatesPageWhenLayoutHasNone() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        // 模拟 resetLayout 之后仅剩应用记录、没有任何页面的状态
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = []
        }

        model.performDrop(draggingIDs: ["a"], sourceFolderID: nil, target: .slot(page: 0, slot: 0))

        #expect(store.state.layout.pages.count == 1)
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["a"])
    }

    @Test func createNewFolderRecreatesPageWhenLayoutHasNone() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.pages = []
        }

        model.createNewFolderOnCurrentPage()

        #expect(store.state.layout.pages.count == 1)
        #expect(store.state.layout.pages[0].items.compactMap(\.folder).count == 1)
    }

    @Test func mergeSelectionRecreatesPageWhenLayoutHasNone() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateSettings { $0.activeSortKey = .custom }
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a")
            layout.apps["b"] = makeApp("b")
            layout.pages = []
        }
        model.selectedAppIDs = ["a", "b"]

        model.mergeSelectionIntoNewFolder()

        #expect(store.state.layout.pages.count == 1)
        #expect(store.state.layout.pages[0].items.compactMap(\.folder).first?.appIDs.sorted() == ["a", "b"])
    }

    @Test func forceQuitNotRunningShowsInfo() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps["a"] = makeApp("a", name: "NotRunning", bundleId: "com.launchx.tests.not-running")
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }
        ToastManager.shared.dismissAll()

        model.forceQuit(appID: "a")

        #expect(ToastManager.shared.items.contains { $0.message.contains("未在运行") })
        ToastManager.shared.dismissAll()
    }

    @Test func launchFailureKeepsLayoutUntouchedAndShowsError() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        var app = makeApp("a", name: "MissingApp")
        app.path = "/nonexistent/LaunchXMissing.app"
        store.updateLayout { layout in
            layout.apps["a"] = app
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }
        ToastManager.shared.dismissAll()

        model.launch(appID: "a")

        // 用 lastLaunchError 而非 ToastManager 断言：Toast 是全局共享单例，
        // 并行测试的 dismissAll() 会把它清掉（偶发误报）。
        var sawError = false
        for _ in 0..<100 where !sawError {
            if model.lastLaunchError != nil {
                sawError = true
            } else {
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        #expect(model.lastLaunchError?.contains("无法打开") == true)  // 启动失败：给出错误提示
        #expect(store.state.layout.apps["a"]?.launchCount == 0)  // 不记使用
        #expect(store.state.layout.pages.count == 1)  // 不重排
    }

    @Test func selectedDropKeepsVisualOrder() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        model.activeSortKey = .custom
        store.updateLayout { layout in
            layout.apps = [
                "a": makeApp("a"), "b": makeApp("b"),
                "c": makeApp("c"), "d": makeApp("d"),
            ]
            // 页内视觉顺序：c, a, b, d（与字母序不同）
            layout.pages = [PageRecord(items: [
                .app(id: "c"), .app(id: "a"), .app(id: "b"), .app(id: "d"),
            ])]
        }
        model.toggleSelection(appID: "a")
        model.toggleSelection(appID: "b")
        model.toggleSelection(appID: "c")
        #expect(model.orderedSelection(onPage: 0) == ["c", "a", "b"])

        model.performDrop(
            draggingIDs: model.orderedSelection(onPage: 0),
            sourceFolderID: nil,
            target: .slot(page: 0, slot: 1)
        )
        // 拖拽块内部保持视觉顺序，不因插入算法反转
        #expect(store.state.layout.pages[0].items.map(\.appID) == ["d", "c", "a", "b"])
    }

    @Test func unhideUsesCurrentDensityCapacity() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        model.activeSortKey = .custom
        store.updateSettings { $0.gridDensity = GridDensity(columns: 10, rows: 6) }  // 容量 60
        store.updateLayout { layout in
            let ids = (0..<40).map { "app\($0)" }
            layout.apps = Dictionary(uniqueKeysWithValues: ids.map { ($0, makeApp($0)) })
            layout.apps["z"] = makeApp("z", hidden: true)
            layout.pages = [PageRecord(items: ids.map { .app(id: $0) })]
        }

        model.unhide(appID: "z")

        // 40 + 1 < 60：应留在同一页（旧实现硬编码 35 会错误地挤到新页）
        #expect(store.state.layout.pages.count == 1)
        #expect(store.state.layout.pages[0].items.last?.appID == "z")
    }

    @Test func reflowAfterDensityChangeCompactsPages() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        model.activeSortKey = .custom
        store.updateSettings { $0.gridDensity = GridDensity(columns: 10, rows: 6) }  // 容量 60
        store.updateLayout { layout in
            let ids = (0..<50).map { "app\($0)" }
            layout.apps = Dictionary(uniqueKeysWithValues: ids.map { ($0, makeApp($0)) })
            layout.pages = [PageRecord(items: ids.map { .app(id: $0) })]
        }
        #expect(store.state.layout.pages.count == 1)

        store.updateSettings { $0.gridDensity = .default }  // 容量 35
        model.reflowAfterDensityChange()

        #expect(store.state.layout.pages.count == 2)
        #expect(store.state.layout.pages[0].items.count == 35)
        #expect(store.state.layout.pages[1].items.count == 15)
        #expect(model.currentPage == 0)
    }

    @Test func moveOutOfFolderAppendsToPageEndAndDeletesEmptyFolder() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        model.activeSortKey = .custom
        store.updateLayout { layout in
            layout.apps = ["a": makeApp("a"), "b": makeApp("b")]
            layout.pages = [PageRecord(items: [
                .folder(FolderRecord(name: "工具", appIDs: ["a", "b"])),
            ])]
        }

        model.moveOutOfFolder(appID: "a")
        #expect(store.state.layout.placedAppIDs.contains("a"))
        #expect(store.state.layout.pages[0].items.count == 2)
        #expect(store.state.layout.pages[0].items.compactMap(\.folder).first?.appIDs == ["b"])
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["a"])

        model.moveOutOfFolder(appID: "b")
        // 文件夹被摘空：删除空文件夹，成员按移出顺序排在页尾
        #expect(store.state.layout.pages[0].items.compactMap(\.folder).isEmpty)
        #expect(store.state.layout.pages[0].items.compactMap(\.appID) == ["a", "b"])
    }

    @Test func searchMatchesBundleNameFolderNameAndPinyin() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            layout.apps = [
                // 显示名是中文，原始英文名保留在 bundleName
                "g": makeApp("g", name: "谷歌浏览器", bundleName: "Google Chrome"),
                "wx": makeApp("wx", name: "微信"),
                "n": makeApp("n", name: "Notes"),
            ]
            layout.pages = [PageRecord(items: [
                .app(id: "g"),
                .folder(FolderRecord(name: "工作", appIDs: ["n"])),
            ])]
        }

        model.searchQuery = "google"
        #expect(model.searchHits.map(\.appID) == ["g"])  // bundleName 命中

        model.searchQuery = "工作"
        #expect(model.searchHits.map(\.appID) == ["n"])  // 文件夹名命中其成员

        model.searchQuery = "wx"
        #expect(model.searchHits.map(\.appID) == ["wx"])  // 拼音首字母命中「微信」
    }

    // MARK: 拖拽会话（P3-10）

    @Test func dragPayloadRoundTripsSessionAndRejectsForeignText() {
        let session = UUID()
        let raw = DragPayload.encode(["a", "b"], sessionID: session)

        let payload = DragPayload.decode(raw)
        #expect(payload?.sessionID == session)
        #expect(payload?.appIDs == ["a", "b"])

        // 外部普通文本 / 旧版「id\nid」纯文本 / 空文本都不是合法拖拽载荷
        #expect(DragPayload.decode("a\nb") == nil)
        #expect(DragPayload.decode("hello world") == nil)
        #expect(DragPayload.decode("") == nil)
    }

    @Test func dragSessionLifecycleRejectsStalePayloadAndEndsOnHide() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)

        // 第一次拖拽：生成会话，载荷可被当前会话接受
        let first = DragObserver.shared.beginDrag(ids: ["a"])
        let firstPayload = DragPayload.decode(DragPayload.encode(["a"], sessionID: first))
        #expect(firstPayload?.sessionID == first)
        #expect(DragObserver.shared.isCurrent(first))
        #expect(DragObserver.shared.currentIDs() == ["a"])

        // 第二次拖拽：旧会话立即失效，旧载荷被拒绝
        let second = DragObserver.shared.beginDrag(ids: ["b"])
        #expect(second != first)
        #expect(DragObserver.shared.isCurrent(first) == false)
        #expect(firstPayload.map { DragObserver.shared.isCurrent($0.sessionID) } == false)
        #expect(DragObserver.shared.currentIDs() == ["b"])

        // 旧会话的迟到 drop 只能结束自己，不能清掉新会话
        DragObserver.shared.endDrag(sessionID: first)
        #expect(DragObserver.shared.currentIDs() == ["b"])
        #expect(DragObserver.shared.isCurrent(second))

        // 面板收起 = 拖拽取消：立即清空会话，端到端 currentIDs 为空
        model.show()
        model.hide()
        #expect(DragObserver.shared.currentIDs().isEmpty)
        #expect(DragObserver.shared.currentSession() == nil)
        #expect(DragObserver.shared.isCurrent(second) == false)
    }
}

// MARK: - Toast

@MainActor
struct ToastManagerTests {

    @Test func showAndAutoDismiss() async throws {
        let manager = ToastManager()
        manager.show(.success, "ok", duration: 0.05)
        #expect(manager.items.count == 1)
        // 轮询等待自动消失：并行测试会挤占主线程时间线，固定 sleep 余量不足会偶发超时
        for _ in 0..<50 where !manager.items.isEmpty {
            try await Task.sleep(for: .seconds(0.05))
        }
        #expect(manager.items.isEmpty)
    }

    @Test func capsAtThreeItems() {
        let manager = ToastManager()
        for index in 0..<5 {
            manager.show(.info, "m\(index)", duration: 60)
        }
        #expect(manager.items.count == 3)
        manager.dismissAll()
        #expect(manager.items.isEmpty)
    }

    @Test func manualDismiss() {
        let manager = ToastManager()
        manager.show(.error, "boom", duration: nil)
        #expect(manager.items.count == 1)
        let id = manager.items[0].id
        manager.dismiss(id: id)
        #expect(manager.items.isEmpty)
    }
}

// MARK: - Toast 面板尺寸（审查遗留：固定 460×160 吞点击）

/// 旧实现把 Toast 面板固定成 460×160，只有一条短提示时也会在屏幕底部中央
/// 留下一大块透明热区，吞掉下方窗口的点击。这里锁定「面板按内容收缩」的契约。
@MainActor
struct ToastPanelLayoutTests {

    private func item(_ message: String, kind: ToastItem.Kind = .success) -> ToastItem {
        ToastItem(kind: kind, message: message, duration: nil)
    }

    @Test func emptyQueueHasZeroSize() {
        #expect(ToastPanelLayout.panelSize(for: []) == .zero)
    }

    @Test func singleShortToastDoesNotKeepLegacyDeadZone() {
        let size = ToastPanelLayout.panelSize(for: [item("已保存")])
        #expect(size.width > 0 && size.height > 0)
        // 旧面板固定 460×160：短提示的面板必须明显小于它，透明热区才随内容一起消失。
        #expect(size.width < 150)
        // 面板只剩气泡 + 6pt 阴影边（实测 107×46）：给不同 macOS 字体行高留余量，
        // 关键是不再接近旧面板的 160 高，也不留 24pt 底部空白。
        #expect(size.height < 60)
    }

    @Test func panelWidthTracksWidestToast() {
        let short = ToastPanelLayout.panelSize(for: [item("好")])
        let long = ToastPanelLayout.panelSize(for: [item(String(repeating: "提示文字", count: 8))])
        #expect(long.width > short.width)
        // 超长文案：宽度封顶在 maxWidth 内（另加左右阴影留白）。
        #expect(long.width <= ToastPanelLayout.maxWidth + ToastPanelLayout.shadowMargin * 2)
    }

    @Test func longMessageHeightIsCappedAtTwoLines() {
        let shortHeight = ToastPanelLayout.panelSize(for: [item("A")]).height
        let longHeight = ToastPanelLayout.panelSize(for: [item(String(repeating: "很长的提示", count: 40))]).height
        // 换行后更高，但必须按 lineLimit(2) 封顶，不能继续把面板撑高。
        #expect(longHeight > shortHeight)
        #expect(longHeight < 80)
    }

    @Test func narrowScreenRecomputesHeightAfterClamp() {
        // 窄屏不能只裁宽度：换行后高度必须同步重算，否则最后一行被裁。
        let message = String(repeating: "窄屏长文案", count: 4)
        let wide = ToastPanelLayout.panelSize(for: [item(message)])
        let narrow = ToastPanelLayout.panelSize(for: [item(message)], maxPanelWidth: 120)
        #expect(narrow.width <= 120)
        #expect(wide.height < narrow.height)
    }

    @Test func multipleToastsStackVertically() {
        let one = ToastPanelLayout.panelSize(for: [item("一")])
        let three = ToastPanelLayout.panelSize(for: [item("一"), item("二"), item("三")])
        #expect(three.height > one.height + ToastPanelLayout.itemSpacing * 2)
        #expect(three.width >= one.width)
    }
}

// MARK: - Toast 窗口尺寸/显隐集成回归

/// 回归背景：面板固定 460×160 时，单条短提示在屏幕底部中央留下一大块透明热区。
/// 这里用真实的 ToastWindowController 验证「按内容收缩」和「队列清空后下屏」。
@MainActor
struct ToastWindowIntegrationTests {

    @Test func panelShrinksToContentAndHidesWhenQueueEmpties() async throws {
        // 测试进程没有 NSApplication.run 事件循环：显式初始化 AppKit 才能验证窗口可见性；
        // 用 async sleep 让 observation → Task 的回调真正执行。
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let manager = ToastManager()
        let controller = ToastWindowController(manager: manager)
        controller.install()
        defer { manager.dismissAll() }

        manager.show(.success, "已保存", duration: nil)
        try await Task.sleep(for: .milliseconds(400))

        let frame = try #require(controller.panelFrame)
        #expect(controller.isPanelVisible)
        // 旧实现固定 460×160：单条短提示必须收缩到内容附近
        #expect(frame.width > 0)
        #expect(frame.width < 300)
        #expect(frame.height < 120)
        // 窗口尺寸必须等于布局函数的结果（没有额外的底部空白）
        let expected = ToastPanelLayout.panelSize(
            for: manager.items,
            maxPanelWidth: max((NSScreen.main?.visibleFrame.width ?? 10_000) - 16, 32)
        )
        #expect(abs(frame.width - expected.width) < 1)
        #expect(abs(frame.height - expected.height) < 1)

        // 队列清空后面板必须下屏，不能留下透明热区
        manager.dismissAll()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!controller.isPanelVisible)
    }

    @Test func addingSecondToastResizesVisiblePanel() async throws {
        let manager = ToastManager()
        let controller = ToastWindowController(manager: manager)
        controller.install()
        defer { manager.dismissAll() }

        manager.show(.info, "第一条", duration: nil)
        try await Task.sleep(for: .milliseconds(400))
        let oneHeight = try #require(controller.panelFrame?.height)

        manager.show(.info, "第二条", duration: nil)
        try await Task.sleep(for: .milliseconds(400))
        let twoHeight = try #require(controller.panelFrame?.height)

        // 观察整个 items 数组（而非 isEmpty）后，新增条目应立即触发重排
        #expect(twoHeight > oneHeight)
    }
}

// MARK: - KeyCodes / HotKeySpec

struct KeyCodesTests {

    @Test func displayString() {
        #expect(KeyCodes.displayString(for: HotKeySpec(keyCode: 49, modifiers: 0x0800)) == "⌥Space")
        #expect(KeyCodes.displayString(for: HotKeySpec(keyCode: 97, modifiers: 0x0100 | 0x0200)) == "⌘⇧F6")
        #expect(KeyCodes.displayString(for: HotKeySpec(keyCode: 9999, modifiers: 0)) == "Key9999")
    }

    @Test func flagsRoundTrip() {
        let carbon: UInt32 = KeyCodes.cmdKey | KeyCodes.optionKey | KeyCodes.shiftKey
        let cocoa = KeyCodes.cocoaFlags(from: carbon)
        #expect(KeyCodes.carbonFlags(from: cocoa) == carbon)
    }

    @Test func validationBlocksRiskyCombos() {
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 7, modifiers: KeyCodes.cmdKey)) != nil)  // ⌘X
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 49, modifiers: KeyCodes.cmdKey)) != nil) // ⌘Space
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 97, modifiers: 0)) == nil)               // F6
        #expect(KeyCodes.validate(HotKeySpec(keyCode: 49, modifiers: KeyCodes.optionKey)) == nil) // ⌥Space
    }

    @Test func noneSpecSentinel() {
        #expect(HotKeySpec.none.modifiers == 0xFFFF)
        #expect(HotKeySpec.none != HotKeySpec(keyCode: 49, modifiers: 0))
    }
}
