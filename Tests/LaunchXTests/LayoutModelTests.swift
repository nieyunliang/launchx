import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 布局模型

struct LayoutModelTests {

    @Test func appendAppSpillsToNextPageWhenFull() {
        var layout = LayoutSnapshot(pages: [PageRecord(items: (0..<35).map { .app(id: "a\($0)") })])
        layout.appendApp(id: "new", toPage: 0, capacityPerPage: 35)
        #expect(layout.pages.count == 2)
        #expect(layout.pages[1].items.map(\.appID) == ["new"])
    }

    @Test func appendAppBeyondLastPageCreatesPage() {
        var layout = LayoutSnapshot(pages: [PageRecord(items: [.app(id: "x")])])
        let landed = layout.appendApp(id: "y", toPage: 5, capacityPerPage: 10)
        #expect(landed == 1)
        #expect(layout.pages.count == 2)
        #expect(layout.pages[1].items.map(\.appID) == ["y"])
    }

    @Test func removeAppClearsDirectAndFolderPlacements() {
        var layout = LayoutSnapshot()
        layout.apps = [
            "a": AppRecord(id: "a", name: "A", bundleName: "A", bundleId: "a", version: nil, path: "/A", category: nil),
            "b": AppRecord(id: "b", name: "B", bundleName: "B", bundleId: "b", version: nil, path: "/B", category: nil),
        ]
        layout.pages = [
            PageRecord(items: [
                .app(id: "a"),
                .folder(FolderRecord(name: "F", appIDs: ["b"])),
            ]),
        ]
        layout.removeApp(id: "a")
        layout.removeApp(id: "b")
        #expect(layout.pages[0].items.isEmpty)
        #expect(layout.apps.isEmpty)
        #expect(layout.placedAppIDs.isEmpty)
    }

    @Test func removeEmptyPagesKeepsAtLeastOne() {
        var layout = LayoutSnapshot(pages: [PageRecord(), PageRecord(items: [.app(id: "x")]), PageRecord()])
        layout.removeEmptyPages()
        #expect(layout.pages.count == 1)
        #expect(layout.pages[0].items.map(\.appID) == ["x"])
    }

    @Test func folderLocationAndPageLookup() {
        var layout = LayoutSnapshot()
        let folder = FolderRecord(name: "F", appIDs: ["inner"])
        layout.pages = [
            PageRecord(items: [.app(id: "outer")]),
            PageRecord(items: [.folder(folder)]),
        ]
        #expect(layout.pageIndexOfDirectApp("outer") == 0)
        #expect(layout.folderLocation(of: "inner")?.page == 1)
        #expect(layout.pageIndexOfFolder(folder.id) == 1)
        #expect(layout.folderLocation(of: "outer") == nil)
    }

    // MARK: - 网格密度

    @Test func gridDensityHasEightLevels() {
        #expect(GridDensity.allCases.count == 8)
        #expect(GridDensity.allCases.map(\.capacity) == [35, 42, 40, 48, 45, 54, 50, 60])
        #expect(GridDensity.default == GridDensity(columns: 7, rows: 5))
    }

    // MARK: - 容错解码（P0-2）

    @Test func appRecordMissingFieldsUsesDefaults() throws {
        let json = "{\"id\": \"x\"}"
        let app = try JSONDecoder().decode(AppRecord.self, from: Data(json.utf8))
        #expect(app.id == "x")
        #expect(app.name == "x")
        #expect(app.path == "")
        #expect(app.launchCount == 0)
        #expect(app.hidden == false)
    }

    @Test func slotItemJSONFormatStaysCompatible() throws {
        let items: [SlotItem] = [
            .app(id: "a"),
            .folder(FolderRecord(name: "文件夹", appIDs: ["b", "c"])),
        ]
        let data = try JSONEncoder().encode(items)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"app\""))
        #expect(text.contains("\"folder\""))
        let decoded = try JSONDecoder().decode([SlotItem].self, from: data)
        #expect(decoded == items)
    }

    @Test func layoutSnapshotSkipsCorruptEntriesAndKeepsValidOnes() throws {
        let json = """
        {"version": 1,
         "pages": [{"id": "11111111-1111-1111-1111-111111111111", "items": [{"app": {"id": "a"}}]}, "broken"],
         "apps": {"a": {"id": "a", "name": "A"}, "b": 42}}
        """
        let layout = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(json.utf8))
        #expect(layout.pages.count == 1)
        #expect(layout.pages[0].items == [.app(id: "a")])
        #expect(layout.apps["a"]?.name == "A")
        #expect(layout.apps["b"] == nil)  // 坏条目被跳过，其余保留
    }

    // MARK: - 分类词典

    @Test func categoryDisplayName() {
        #expect(AppCategory.displayName(for: "public.app-category.productivity") == "效率")
        #expect(AppCategory.displayName(for: "public.app-category.games") == "游戏")
        #expect(AppCategory.displayName(for: nil) == "其他")
        #expect(AppCategory.displayName(for: "unknown") == "其他")
    }

    @Test func appleAppDetection() {
        #expect(AppCategory.isAppleApp(bundleId: "com.apple.Safari"))
        #expect(!AppCategory.isAppleApp(bundleId: "com.google.Chrome"))
        #expect(!AppCategory.isAppleApp(bundleId: nil))
    }
}
