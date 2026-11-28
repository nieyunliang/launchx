import Foundation
import Testing
@testable import LaunchXCore
import LaunchXTestSupport

// MARK: - 启动台代码质量评审 P2 的回归测试

@Suite(.serialized)
@MainActor
struct CodeReviewP2RegressionTests {

    private func tempDirectory(_ tag: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LXReviewP2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func threePageModel(_ dir: URL) -> (LayoutStore, LaunchpadModel) {
        let store = LayoutStore(directory: dir)
        store.updateLayout { layout in
            register([makeApp("a"), makeApp("b"), makeApp("c")], into: &layout)
            layout.pages = [
                PageRecord(items: [.app(id: "a")]),
                PageRecord(items: [.app(id: "b")]),
                PageRecord(items: [.app(id: "c")]),
            ]
        }
        return (store, LaunchpadModel(store: store))
    }

    /// 翻页防重入放在模型层：手指仍在跟手（偏移非零）时任何翻页入口都不改页码，
    /// 否则松手后按偏移再提交一次 = 跳两页。
    @Test func pageNavigationIsBlockedWhileFingerIsTracking() {
        let dir = tempDirectory("nav")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, model) = threePageModel(dir)

        model.pageDragOffset = -120
        model.nextPage()
        model.goToPage(2)
        #expect(model.currentPage == 0)
        #expect(!model.allowsPageNavigation)

        model.pageDragOffset = 0
        model.nextPage()
        #expect(model.currentPage == 1)
        model.previousPage()
        model.goToPage(2)
        #expect(model.currentPage == 2)
    }

    /// 搜索命中有缓存：同一查询重复读取结果一致；布局变化（改名）后缓存失效。
    @Test func searchHitsCacheInvalidatesOnLayoutChange() {
        let dir = tempDirectory("search")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        store.updateLayout { layout in
            register([makeApp("a", name: "Alpha"), makeApp("b", name: "Beta")], into: &layout)
            layout.pages = [PageRecord(items: [.app(id: "a"), .app(id: "b")])]
        }
        let model = LaunchpadModel(store: store)

        model.searchQuery = "al"
        #expect(model.searchResultAppIDs == ["a"])
        #expect(model.searchResultAppIDs == ["a"])  // 命中缓存

        model.rename(appID: "b", to: "Altair")
        #expect(model.searchResultAppIDs == ["a", "b"])

        model.searchQuery = "zzz"
        #expect(model.searchResultAppIDs.isEmpty)
    }

    /// 合并落盘：批内的多次变更不逐次写盘，批结束时写一次且包含全部变更。
    @Test func batchUpdatesPersistOnceAtEnd() throws {
        let dir = tempDirectory("batch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(directory: dir)
        store.updateLayout { layout in
            register([makeApp("a")], into: &layout)
            layout.pages = [PageRecord(items: [.app(id: "a")])]
        }
        let before = try Data(contentsOf: store.storeFileURL)

        store.batchUpdates {
            store.updateLayout { layout in
                register([makeApp("b")], into: &layout)
            }
            store.batchUpdates {  // 嵌套批不提前落盘
                store.updateLayout { layout in
                    layout.pages[0].items.append(.app(id: "b"))
                }
            }
            #expect((try? Data(contentsOf: store.storeFileURL)) == before)
        }

        let reloaded = LayoutStore(directory: dir)
        #expect(reloaded.state.layout.apps["b"] != nil)
        #expect(reloaded.state.layout.pages.first?.items.contains(.app(id: "b")) == true)
    }

    /// 网格格子的 ForEach 身份跟随条目：应用与文件夹的 id 互不冲突，与格位无关。
    @Test func slotItemStableIDFollowsItem() {
        let folder = FolderRecord(name: "F", appIDs: ["a"])
        let ids = [SlotItem.app(id: "a"), .folder(folder), .app(id: "b")].map(\.stableID)
        #expect(Set(ids).count == 3)
        #expect(SlotItem.folder(folder).stableID == SlotItem.folder(folder).stableID)
    }

    /// 网格高度预算与实际排布同源：底部页码区 = 命中区 24 + 上下 padding 8×2 + 底部留白 40。
    @Test func gridHeightBudgetMatchesChrome() {
        let indicator: CGFloat = 24 + 8 * 2 + 40
        let reserve: CGFloat = 62 + 40 + 26 + 44 + indicator
        #expect(LaunchpadChrome.pageIndicatorHeight == indicator)
        #expect(LaunchpadChrome.gridVerticalReserve == reserve)
    }
}
