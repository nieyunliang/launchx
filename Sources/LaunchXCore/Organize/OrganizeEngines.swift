import Foundation

// MARK: - SortKey

/// 排序键（原版 9 种；Custom 为唯一可拖拽模式）。
public enum SortKey: String, Codable, CaseIterable, Sendable {
    case custom
    case name
    case dateAdded
    case dateLastOpened
    case lastUsed
    case mostRecent
    case leastRecent
    case oldestFirst
    case newestFirst

    public var label: String {
        switch self {
        case .custom: "自定义"
        case .name: "名称"
        case .dateAdded: "添加日期"
        case .dateLastOpened: "最近打开日期"
        case .lastUsed: "使用次数"
        case .mostRecent: "最近使用"
        case .leastRecent: "较早使用"
        case .oldestFirst: "最早添加"
        case .newestFirst: "最新添加"
        }
    }

    /// 方向固定的键（自身已含方向语义，设置里不显示升序开关）。
    public var hasFixedDirection: Bool {
        switch self {
        case .mostRecent, .leastRecent, .newestFirst, .oldestFirst: true
        default: false
        }
    }

    /// 排序生效方向：固定方向键强制取自身方向；其余键回退到设置的升序开关。
    public func effectiveAscending(fallback: Bool) -> Bool {
        switch self {
        case .mostRecent, .newestFirst: false
        case .leastRecent, .oldestFirst: true
        default: fallback
        }
    }
}

// MARK: - SortScope

/// 排序 / 整理作用域。
public enum SortScope: Equatable, Sendable {
    case allPages
    case currentPage(Int)
    case selectedPages([Int])

    /// 展开为升序页下标集合（越界安全）。
    public func pageIndices(totalPages: Int) -> [Int] {
        switch self {
        case .allPages:
            Array(0..<totalPages)
        case .currentPage(let index):
            (0..<totalPages).contains(index) ? [index] : []
        case .selectedPages(let indices):
            indices.filter { (0..<totalPages).contains($0) }.sorted()
        }
    }

    public var label: String {
        switch self {
        case .allPages: "全部页面"
        case .currentPage: "当前页面"
        case .selectedPages(let indices): "\(indices.count) 个页面"
        }
    }
}

// MARK: - SortOptions

public struct SortOptions: Sendable, Equatable {
    /// 排序时同时排序文件夹内应用。
    public var alsoSortFolderContents: Bool
    public var folderPosition: FolderPosition
    public var appleAppsPosition: AppleAppsPosition

    public init(
        alsoSortFolderContents: Bool = true,
        folderPosition: FolderPosition = .afterApps,
        appleAppsPosition: AppleAppsPosition = .mixed
    ) {
        self.alsoSortFolderContents = alsoSortFolderContents
        self.folderPosition = folderPosition
        self.appleAppsPosition = appleAppsPosition
    }
}

// MARK: - SortEngine

/// 排序引擎：对作用域内每页的直接应用排序（不跨页搬运），
/// 文件夹按 folderPosition 摆到页首/页尾，Apple 应用按 appleAppsPosition 分组。
public enum SortEngine {

    /// 应用排序键（custom 无效，直接 no-op 返回 false）。
    /// 返回是否发生了变更。
    @discardableResult
    public static func apply(
        _ layout: inout LayoutSnapshot,
        key: SortKey,
        ascending: Bool,
        scope: SortScope,
        options: SortOptions
    ) -> Bool {
        guard key != .custom else { return false }
        let pageIndices = scope.pageIndices(totalPages: layout.pages.count)
        guard !pageIndices.isEmpty else { return false }

        for pageIndex in pageIndices {
            sortPage(&layout.pages[pageIndex], apps: layout.apps, key: key, ascending: ascending, options: options)
        }

        if options.alsoSortFolderContents {
            sortAllFolderContents(&layout, key: key, ascending: ascending, pageIndices: pageIndices)
        }
        return true
    }

    /// 全局排序 + 跨页重铺：把全部页面的应用按排序键统一排序后连续重铺（页满顺延），
    /// 文件夹按 folderPosition 摆放，页数随内容增减。
    /// 用于排序方式切换与启动后的自动重排（非 Custom 模式，Custom 直接 no-op）。
    public static func applyGlobally(
        _ layout: inout LayoutSnapshot,
        key: SortKey,
        ascending: Bool,
        capacityPerPage capacity: Int,
        options: SortOptions
    ) {
        guard key != .custom, capacity > 0 else { return }

        let allItems = layout.pages.flatMap(\.items)
        var sortedAppIDs = sortedAppIDs(allItems.compactMap(\.appID), apps: layout.apps, key: key, ascending: ascending)

        // Apple 应用分组规则（与 sortPage 一致）
        switch options.appleAppsPosition {
        case .mixed:
            break
        case .beforeApps:
            sortedAppIDs = appleIDs(sortedAppIDs, apps: layout.apps) + nonAppleIDs(sortedAppIDs, apps: layout.apps)
        case .afterApps:
            sortedAppIDs = nonAppleIDs(sortedAppIDs, apps: layout.apps) + appleIDs(sortedAppIDs, apps: layout.apps)
        }

        var items: [SlotItem] = sortedAppIDs.map { .app(id: $0) }
        let folders = allItems.compactMap(\.folder)
        switch options.folderPosition {
        case .beforeApps:
            items = folders.map(SlotItem.folder) + items
        case .afterApps:
            items = items + folders.map(SlotItem.folder)
        }

        var newPages: [PageRecord] = []
        var currentPage = PageRecord()
        for item in items {
            if currentPage.items.count >= capacity {
                newPages.append(currentPage)
                currentPage = PageRecord()
            }
            currentPage.items.append(item)
        }
        if !currentPage.items.isEmpty || newPages.isEmpty {
            newPages.append(currentPage)
        }
        layout.pages = newPages

        if options.alsoSortFolderContents {
            sortAllFolderContents(&layout, key: key, ascending: ascending)
        }
    }

    /// 文件夹内应用按排序键重排。
    /// - Parameter pageIndices: 限定作用域；`nil` 表示全部页面（全局重排时使用）。
    static func sortAllFolderContents(
        _ layout: inout LayoutSnapshot,
        key: SortKey,
        ascending: Bool,
        pageIndices: [Int]? = nil
    ) {
        let indices = pageIndices ?? Array(layout.pages.indices)
        for pageIndex in indices where layout.pages.indices.contains(pageIndex) {
            for slotIndex in layout.pages[pageIndex].items.indices {
                guard var folder = layout.pages[pageIndex].items[slotIndex].folder else { continue }
                folder.appIDs = sortedAppIDs(folder.appIDs, apps: layout.apps, key: key, ascending: ascending)
                layout.pages[pageIndex].items[slotIndex] = .folder(folder)
            }
        }
    }

    // MARK: 单页排序

    static func sortPage(
        _ page: inout PageRecord,
        apps: [String: AppRecord],
        key: SortKey,
        ascending: Bool,
        options: SortOptions
    ) {
        let directAppIDs = page.items.compactMap(\.appID)
        let folders = page.items.compactMap(\.folder)

        var sortedAppIDs = sortedAppIDs(directAppIDs, apps: apps, key: key, ascending: ascending)

        // Apple 应用分组规则
        switch options.appleAppsPosition {
        case .mixed:
            break
        case .beforeApps:
            sortedAppIDs = appleIDs(sortedAppIDs, apps: apps) + nonAppleIDs(sortedAppIDs, apps: apps)
        case .afterApps:
            sortedAppIDs = nonAppleIDs(sortedAppIDs, apps: apps) + appleIDs(sortedAppIDs, apps: apps)
        }

        var items: [SlotItem] = sortedAppIDs.map { .app(id: $0) }
        switch options.folderPosition {
        case .beforeApps:
            items = folders.map(SlotItem.folder) + items
        case .afterApps:
            items = items + folders.map(SlotItem.folder)
        }
        page.items = items
    }

    static func sortedAppIDs(_ ids: [String], apps: [String: AppRecord], key: SortKey, ascending: Bool) -> [String] {
        ids.sorted { lhs, rhs in
            let a = apps[lhs]
            let b = apps[rhs]
            let primary: ComparisonResult
            switch key {
            case .custom:
                return false
            case .name:
                primary = (a?.name ?? lhs).localizedStandardCompare(b?.name ?? rhs)
            case .dateAdded, .oldestFirst, .newestFirst:
                primary = compareOptionalDates(a?.addedAt, b?.addedAt)
            case .dateLastOpened, .mostRecent, .leastRecent:
                primary = compareOptionalDates(a?.lastOpenedAt, b?.lastOpenedAt)
            case .lastUsed:
                primary = compareInts(a?.launchCount ?? 0, b?.launchCount ?? 0)
            }
            // 主键相同 → 名称升序作稳定回退（不随 ascending 翻转）
            if primary == .orderedSame, key != .name {
                return (a?.name ?? lhs).localizedStandardCompare(b?.name ?? rhs) == .orderedAscending
            }
            return ascending ? primary == .orderedAscending : primary == .orderedDescending
        }
    }

    static func compareOptionalDates(_ a: Date?, _ b: Date?) -> ComparisonResult {
        let da = a ?? .distantPast
        let db = b ?? .distantPast
        if da == db { return .orderedSame }
        return da < db ? .orderedAscending : .orderedDescending
    }

    static func compareInts(_ a: Int, _ b: Int) -> ComparisonResult {
        if a == b { return .orderedSame }
        return a < b ? .orderedAscending : .orderedDescending
    }

    static func appleIDs(_ ids: [String], apps: [String: AppRecord]) -> [String] {
        ids.filter { AppCategory.isAppleApp(bundleId: apps[$0]?.bundleId) }
    }

    static func nonAppleIDs(_ ids: [String], apps: [String: AppRecord]) -> [String] {
        ids.filter { !AppCategory.isAppleApp(bundleId: apps[$0]?.bundleId) }
    }
}

// MARK: - ReorganizeEngine

/// 整理布局引擎：补空位（页内前压）与跨页整体重排（覆盖现有布局）。
public enum ReorganizeEngine {

    /// Fill Empty Slots：把作用域内的槽位按视觉顺序前压重铺，
    /// 跨页连续填充（页满顺延下一页）、保持相对顺序、去掉空页；作用域外的页不动。
    ///
    /// - Parameter capacityPerPage: 每页容量；默认按默认密度 7×5=35。
    ///   UI 调用（整理布局窗口）应传入当前 `settings.gridDensity.capacity`。
    /// - Returns: 布局是否发生变化（页内顺序或页数改变）。页对象会重建，不能拿页 UUID 比较。
    @discardableResult
    public static func fillEmptySlots(
        _ layout: inout LayoutSnapshot,
        scope: SortScope,
        capacityPerPage capacity: Int = GridDensity.default.capacity
    ) -> Bool {
        guard capacity > 0 else { return false }
        let before = layout.pages.map(\.items)
        reorganizeAcrossPages(&layout, scope: scope, capacityPerPage: capacity)
        return layout.pages.map(\.items) != before
    }

    /// Reorganize Across Pages：把作用域内全部槽位按当前视觉顺序取出，
    /// 连续重铺（页满顺延下一页），页数随内容增减；作用域外的页保持不动。
    ///
    /// 作用域可能不连续（「选择页面」允许只勾第 1、3 页）。此时必须按**连续段**分别重铺，
    /// 段与段之间未选中的页原样保留——旧实现用 `indices.min()...max()` 覆盖整个跨度，
    /// 会把夹在中间、未选中的页整页丢弃（内容仍在注册表里，但网格上再也看不到）。
    public static func reorganizeAcrossPages(
        _ layout: inout LayoutSnapshot,
        scope: SortScope,
        capacityPerPage capacity: Int
    ) {
        guard capacity > 0 else { return }
        let selected = Set(scope.pageIndices(totalPages: layout.pages.count))
        guard !selected.isEmpty else { return }

        var newPages: [PageRecord] = []
        var pageIndex = 0
        while pageIndex < layout.pages.count {
            guard selected.contains(pageIndex) else {
                newPages.append(layout.pages[pageIndex])
                pageIndex += 1
                continue
            }
            // 收集一段连续选中页，段内内容一起重铺
            var runEnd = pageIndex
            var collected: [SlotItem] = []
            while runEnd < layout.pages.count, selected.contains(runEnd) {
                collected.append(contentsOf: layout.pages[runEnd].items)
                runEnd += 1
            }
            if !collected.isEmpty {
                var currentPage = PageRecord()
                for item in collected {
                    if currentPage.items.count >= capacity {
                        newPages.append(currentPage)
                        currentPage = PageRecord()
                    }
                    currentPage.items.append(item)
                }
                newPages.append(currentPage)
            }
            pageIndex = runEnd
        }
        if newPages.isEmpty { newPages = [PageRecord()] }
        layout.pages = newPages
    }
}

// MARK: - FolderEngine

/// 文件夹操作引擎：建夹 / 合并 / 解散（单夹与全部）。
public enum FolderEngine {

    /// 拖 appA 到 appB 上：建新文件夹（appB 在前，appA 加入），文件夹落在 appB 的位置。
    /// 若 appB 已在文件夹内，则等效合并进该文件夹。
    public static func createFolder(
        dragging appID: String,
        onto targetAppID: String,
        layout: inout LayoutSnapshot
    ) {
        // 隐藏应用不能进文件夹（调用方拦截，此处防御再挡一次）
        if layout.apps[appID]?.hidden == true || layout.apps[targetAppID]?.hidden == true { return }

        if let (_, folder) = layout.folderLocation(of: targetAppID) {
            mergeIntoFolder(appIDs: [appID], folderID: folder.id, layout: &layout)
            return
        }
        // 拖拽源必须是直接摆放的应用
        guard layout.folderLocation(of: appID) == nil,
              let targetPage = layout.pageIndexOfDirectApp(targetAppID) else { return }

        removeAppFromDirectLayout(appID, layout: &layout)
        guard let slotIndex = layout.pages[targetPage].items.firstIndex(where: { $0.appID == targetAppID }) else { return }
        let folder = FolderRecord(name: defaultFolderName(layout: layout), appIDs: [targetAppID, appID])
        layout.pages[targetPage].items[slotIndex] = .folder(folder)
    }

    /// 合并应用进已有文件夹（拖到文件夹上）。
    public static func mergeIntoFolder(
        appIDs: [String],
        folderID: UUID,
        layout: inout LayoutSnapshot
    ) {
        let movable = uniqueVisibleAppIDs(appIDs, layout: layout)
        guard !movable.isEmpty,
              let pageIndex = layout.pageIndexOfFolder(folderID),
              let currentFolder = layout.pages[pageIndex].items.compactMap(\.folder).first(where: { $0.id == folderID }) else { return }
        // 全部已经是该文件夹成员：无需移动（否则「先摘除再追加」会改变成员顺序）
        if Set(movable).isSubset(of: Set(currentFolder.appIDs)) { return }
        for appID in movable {
            // 防御：应用可能已被别的文件夹持有（历史数据 / 陈旧选择），先摘除再合入，
            // 保证「一个应用只出现一次」的布局不变量。
            layout.removeAppFromAnyFolder(appID)
            removeAppFromDirectLayout(appID, layout: &layout)
        }
        // 重查（移除后下标可能变化）
        guard let slotIndex = layout.pages[pageIndex].items.firstIndex(where: { $0.folder?.id == folderID }) else { return }
        var folder = layout.pages[pageIndex].items[slotIndex].folder!
        for appID in movable where !folder.appIDs.contains(appID) {
            folder.appIDs.append(appID)
        }
        layout.pages[pageIndex].items[slotIndex] = .folder(folder)
        layout.removeEmptyPages()
    }

    /// 「合并到新文件夹」（多选后菜单）：把一组应用合入一个新建文件夹。
    public static func mergeIntoNewFolder(
        appIDs: [String],
        page: Int,
        layout: inout LayoutSnapshot,
        existingFolderID: UUID? = nil
    ) {
        if let folderID = existingFolderID {
            mergeIntoFolder(appIDs: appIDs, folderID: folderID, layout: &layout)
            return
        }
        // 去重：同一 id 重复出现会让文件夹里出现两份
        let movable = uniqueVisibleAppIDs(appIDs, layout: layout)
        guard movable.count >= 1 else { return }
        // 防御：成员可能已属于某个文件夹（陈旧多选 / 跨页合并且未先摘除），
        // 先摘除所有旧位置，否则同一应用会同时出现在两个文件夹里。
        for appID in movable {
            layout.removeAppFromAnyFolder(appID)
            removeAppFromDirectLayout(appID, layout: &layout)
        }
        if layout.pages.isEmpty {
            layout.pages = [PageRecord()]
        }
        let folder = FolderRecord(name: defaultFolderName(layout: layout), appIDs: movable)
        let pageIndex = min(max(page, 0), layout.pages.count - 1)
        layout.pages[pageIndex].items.append(.folder(folder))
        layout.removeEmptyPages()
    }

    /// 去重并过滤隐藏 / 未知应用的 id 列表（保持输入顺序）。
    private static func uniqueVisibleAppIDs(_ appIDs: [String], layout: LayoutSnapshot) -> [String] {
        var seen = Set<String>()
        return appIDs.filter { appID in
            guard layout.apps[appID] != nil, layout.apps[appID]?.hidden != true else { return false }
            return seen.insert(appID).inserted
        }
    }

    /// 解散文件夹：应用追加到文件夹所在页末尾（页满顺延下一页）。
    public static func ungroup(folderID: UUID, layout: inout LayoutSnapshot, capacityPerPage capacity: Int) {
        guard let pageIndex = layout.pageIndexOfFolder(folderID),
              let slotIndex = layout.pages[pageIndex].items.firstIndex(where: { $0.folder?.id == folderID }) else { return }
        let appIDs = layout.pages[pageIndex].items[slotIndex].folder?.appIDs ?? []
        layout.pages[pageIndex].items.remove(at: slotIndex)
        for appID in appIDs {
            layout.appendApp(id: appID, toPage: pageIndex, capacityPerPage: capacity)
        }
        layout.removeEmptyPages()
    }

    /// 解散全部文件夹：应用按页末尾追加、页满顺延下一页。
    public static func ungroupAll(layout: inout LayoutSnapshot, capacityPerPage capacity: Int) {
        // 先收集并移除全部文件夹槽位，再按原页顺序追加（避免边追加边改的交错）
        var appIDsByPage: [(page: Int, appIDs: [String])] = []
        for pageIndex in layout.pages.indices {
            let folderAppIDs = layout.pages[pageIndex].items.compactMap(\.folder).flatMap(\.appIDs)
            appIDsByPage.append((pageIndex, folderAppIDs))
        }
        for entry in appIDsByPage {
            layout.pages[entry.page].items.removeAll { $0.folder != nil }
        }
        for entry in appIDsByPage {
            for appID in entry.appIDs {
                layout.appendApp(id: appID, toPage: entry.page, capacityPerPage: capacity)
            }
        }
        layout.removeEmptyPages()
    }

    /// 重命名文件夹。
    public static func renameFolder(folderID: UUID, to name: String, layout: inout LayoutSnapshot) {
        guard let pageIndex = layout.pageIndexOfFolder(folderID),
              let slotIndex = layout.pages[pageIndex].items.firstIndex(where: { $0.folder?.id == folderID }) else { return }
        var folder = layout.pages[pageIndex].items[slotIndex].folder!
        folder.name = name
        layout.pages[pageIndex].items[slotIndex] = .folder(folder)
    }

    // MARK: 内部

    /// 默认文件夹名：「新建文件夹」/「新建文件夹 2」/ …（跟随已有命名）。
    /// 与 UI 文案保持一致（不再使用英文 Untitled）。
    static func defaultFolderName(layout: LayoutSnapshot) -> String {
        let baseName = "新建文件夹"
        let existingNames = Set(
            layout.pages.flatMap { page in page.items.compactMap(\.folder).map(\.name) }
        )
        if !existingNames.contains(baseName) { return baseName }
        var n = 2
        while existingNames.contains("\(baseName) \(n)") { n += 1 }
        return "\(baseName) \(n)"
    }

    /// 把应用从直接摆放位置移除（不动文件夹内与注册表）。
    static func removeAppFromDirectLayout(_ appID: String, layout: inout LayoutSnapshot) {
        for pageIndex in layout.pages.indices {
            layout.pages[pageIndex].items.removeAll { $0.appID == appID }
        }
    }
}
