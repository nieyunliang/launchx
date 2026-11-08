import Foundation

// MARK: - 容错解码辅助

/// 单个元素解码失败时返回 nil，而不是让整个数组 / 字典解码失败。
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent` 的宽松版本：字段缺失 / 类型不符都返回默认值。
    func tolerant<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func tolerantOptional<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

// MARK: - AppRecord

/// 一个被管理的应用条目（对应原版 AppEntity 的 JSON 化重建）。
///
/// 字段对照原版：id / name / bundleName / bundleId / version / url / path / category /
/// hidden / alias；`order` 与 `page` 不落在记录上，由所在 PageRecord 的位置表达。
public struct AppRecord: Codable, Hashable, Identifiable, Sendable {
    /// 稳定主键：bundleId ?? path。
    public var id: String
    /// 当前显示名（Rename 改这里，原始名保留在 bundleName）。
    public var name: String
    /// 原始 CFBundleName（Rename 的回退来源）。
    public var bundleName: String
    public var bundleId: String?
    public var version: String?
    /// .app bundle 绝对路径（alias 条目为替身文件路径）。
    public var path: String
    /// LSApplicationCategoryType 原始值（如 public.app-category.productivity）。
    public var category: String?
    /// 隐藏标记（隐藏项不出现在网格，搜索默认排除）。
    public var hidden: Bool
    /// 是否为替身文件启动项。
    public var isAlias: Bool
    /// 首次进入索引的时间（Date Added / Newest First 排序与 NEW 徽章依据）。
    public var addedAt: Date
    /// 最近一次启动时间（Date Last Opened / Last Used 排序依据）。
    public var lastOpenedAt: Date?
    /// 累计启动次数（Most/Least Recent 使用强度参考）。
    public var launchCount: Int
    /// NEW 徽章状态；启动一次或用户清除后置 false。
    public var isNew: Bool
    /// 连续多少次扫描未发现该应用（宽限：安装中/外置卷瞬时不可用不立刻移除排列）。
    public var missingScans: Int

    public init(
        id: String,
        name: String,
        bundleName: String,
        bundleId: String?,
        version: String?,
        path: String,
        category: String?,
        hidden: Bool = false,
        isAlias: Bool = false,
        addedAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        launchCount: Int = 0,
        isNew: Bool = true,
        missingScans: Int = 0
    ) {
        self.id = id
        self.name = name
        self.bundleName = bundleName
        self.bundleId = bundleId
        self.version = version
        self.path = path
        self.category = category
        self.hidden = hidden
        self.isAlias = isAlias
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.launchCount = launchCount
        self.isNew = isNew
        self.missingScans = missingScans
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, bundleName, bundleId, version, path, category
        case hidden, isAlias, addedAt, lastOpenedAt, launchCount, isNew, missingScans
    }

    /// 容错解码：旧版本 / 手工编辑 / 同步工具造成的单字段缺失不应让整份布局失效。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = c.tolerantOptional(String.self, forKey: .name)
        let bundleName = c.tolerantOptional(String.self, forKey: .bundleName)
        self.id = c.tolerant(String.self, forKey: .id, default: bundleName ?? name ?? "")
        self.name = name ?? bundleName ?? self.id
        self.bundleName = bundleName ?? name ?? self.id
        self.bundleId = c.tolerantOptional(String.self, forKey: .bundleId)
        self.version = c.tolerantOptional(String.self, forKey: .version)
        self.path = c.tolerant(String.self, forKey: .path, default: "")
        self.category = c.tolerantOptional(String.self, forKey: .category)
        self.hidden = c.tolerant(Bool.self, forKey: .hidden, default: false)
        self.isAlias = c.tolerant(Bool.self, forKey: .isAlias, default: false)
        self.addedAt = c.tolerant(Date.self, forKey: .addedAt, default: Date())
        self.lastOpenedAt = c.tolerantOptional(Date.self, forKey: .lastOpenedAt)
        self.launchCount = c.tolerant(Int.self, forKey: .launchCount, default: 0)
        self.isNew = c.tolerant(Bool.self, forKey: .isNew, default: false)
        self.missingScans = c.tolerant(Int.self, forKey: .missingScans, default: 0)
    }
}

// MARK: - FolderRecord

/// 文件夹（对应原版 GroupEntity 的 isFolder 形态）。
public struct FolderRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// 文件夹内应用（有序）。
    public var appIDs: [String]

    public init(id: UUID = UUID(), name: String, appIDs: [String] = []) {
        self.id = id
        self.name = name
        self.appIDs = appIDs
    }

    private enum CodingKeys: String, CodingKey { case id, name, appIDs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerant(UUID.self, forKey: .id, default: UUID())
        self.name = c.tolerant(String.self, forKey: .name, default: "文件夹")
        self.appIDs = c.tolerant([String].self, forKey: .appIDs, default: [])
    }
}

// MARK: - SlotItem

/// 页面上的一个槽位：直接摆放的应用或文件夹（保持拖拽产生的任意交错顺序）。
public enum SlotItem: Codable, Hashable, Sendable {
    case app(id: String)
    case folder(FolderRecord)

    private struct AppSlot: Codable, Hashable { let id: String }
    private enum CodingKeys: String, CodingKey { case app, folder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let folder = ((try? c.decodeIfPresent(FolderRecord.self, forKey: .folder)) ?? nil) {
            self = .folder(folder)
            return
        }
        if let slot = ((try? c.decodeIfPresent(AppSlot.self, forKey: .app)) ?? nil) {
            self = .app(id: slot.id)
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .app,
            in: c,
            debugDescription: "SlotItem 既不是 app 也不是 folder"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .app(id):
            try c.encode(AppSlot(id: id), forKey: .app)
        case let .folder(folder):
            try c.encode(folder, forKey: .folder)
        }
    }

    public var appID: String? {
        if case let .app(id) = self { return id }
        return nil
    }

    public var folder: FolderRecord? {
        if case let .folder(folder) = self { return folder }
        return nil
    }
}

// MARK: - PageRecord

/// 一页网格（对应原版非 folder 的 GroupEntity；页序即数组顺序）。
public struct PageRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// 本页槽位（应用与文件夹交错有序）。
    public var items: [SlotItem]

    public init(id: UUID = UUID(), items: [SlotItem] = []) {
        self.id = id
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case id, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.tolerant(UUID.self, forKey: .id, default: UUID())
        let items = (try? c.decodeIfPresent([Lossy<SlotItem>].self, forKey: .items)) ?? nil
        self.items = items?.compactMap(\.value) ?? []
    }

    /// 本页应用总数（不含文件夹内）。
    public var directAppCount: Int {
        items.reduce(0) { $0 + ($1.appID != nil ? 1 : 0) }
    }

    /// 本页槽位总数（应用 + 文件夹）。
    public var slotCount: Int { items.count }
}

// MARK: - LayoutSnapshot

/// 完整布局快照：页面列表 + 应用注册表。
public struct LayoutSnapshot: Codable, Hashable, Sendable {
    public var version: Int
    public var pages: [PageRecord]
    /// 全部应用记录（含隐藏、不在网格上的），按 id 索引。
    public var apps: [String: AppRecord]

    public static let currentVersion = 1

    public init(version: Int = LayoutSnapshot.currentVersion, pages: [PageRecord] = [], apps: [String: AppRecord] = [:]) {
        self.version = version
        self.pages = pages
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey { case version, pages, apps }

    /// 容错解码：页面 / 应用注册表整体缺失或单条损坏时保留其余数据，避免静默重置整份布局。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = c.tolerant(Int.self, forKey: .version, default: Self.currentVersion)
        let pages = (try? c.decodeIfPresent([Lossy<PageRecord>].self, forKey: .pages)) ?? nil
        self.pages = pages?.compactMap(\.value) ?? []
        let apps = (try? c.decodeIfPresent([String: Lossy<AppRecord>].self, forKey: .apps)) ?? nil
        self.apps = apps?.compactMapValues(\.value) ?? [:]
    }

    /// 网格上的全部应用 id（不含隐藏在注册表但未摆放的）。
    public var placedAppIDs: [String] {
        pages.flatMap { page in page.items.compactMap(\.appID) }
            + pages.flatMap { page in page.items.compactMap(\.folder).flatMap(\.appIDs) }
    }

    /// 查找应用所在的页下标（直接摆放，不含文件夹内）。
    public func pageIndexOfDirectApp(_ appID: String) -> Int? {
        pages.firstIndex { page in page.items.contains { $0.appID == appID } }
    }

    /// 查找应用所在的（页下标, 文件夹）。
    public func folderLocation(of appID: String) -> (page: Int, folder: FolderRecord)? {
        for (pageIndex, page) in pages.enumerated() {
            if let folder = page.items.compactMap(\.folder).first(where: { $0.appIDs.contains(appID) }) {
                return (pageIndex, folder)
            }
        }
        return nil
    }

    /// 查找文件夹所在的页下标。
    public func pageIndexOfFolder(_ folderID: UUID) -> Int? {
        pages.firstIndex { page in page.items.contains { $0.folder?.id == folderID } }
    }

    /// 从布局中彻底移除某应用（直接摆放与文件夹内都清）；文件夹被清空后一并移除。
    public mutating func removeApp(id: String) {
        apps[id] = nil
        for pageIndex in pages.indices {
            pages[pageIndex].items.removeAll { $0.appID == id }
            pages[pageIndex].items = pages[pageIndex].items.compactMap { item in
                if case .folder(var folder) = item {
                    folder.appIDs.removeAll { $0 == id }
                    return folder.appIDs.isEmpty ? nil : .folder(folder)
                }
                return item
            }
        }
    }

    /// 追加应用到指定页末尾（页满顺延到下一页，必要时新建页）。
    /// 返回实际落位的页下标。
    @discardableResult
    public mutating func appendApp(id: String, toPage pageIndex: Int, capacityPerPage capacity: Int) -> Int {
        var index = min(pageIndex, pages.count)
        if index == pages.count {
            pages.append(PageRecord())
        }
        while true {
            if pages[index].slotCount < capacity {
                pages[index].items.append(.app(id: id))
                return index
            }
            index += 1
            if index == pages.count {
                pages.append(PageRecord())
            }
        }
    }

    /// 删除空页（保留至少一页）。
    public mutating func removeEmptyPages() {
        pages.removeAll { $0.items.isEmpty }
        if pages.isEmpty {
            pages.append(PageRecord())
        }
    }
}

// MARK: - GridDensity

/// 图标网格密度（原版 8 档：7–10 列 × 5–6 行）。
public struct GridDensity: Hashable, Codable, Sendable, CaseIterable, Identifiable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    public var id: String { "\(columns)x\(rows)" }
    public var label: String { "\(columns) × \(rows)" }
    /// 每页槽位容量。
    public var capacity: Int { columns * rows }

    /// 原版 8 档（顺序即设置界面展示顺序）。
    public static let allCases: [GridDensity] = [
        GridDensity(columns: 7, rows: 5),
        GridDensity(columns: 7, rows: 6),
        GridDensity(columns: 8, rows: 5),
        GridDensity(columns: 8, rows: 6),
        GridDensity(columns: 9, rows: 5),
        GridDensity(columns: 9, rows: 6),
        GridDensity(columns: 10, rows: 5),
        GridDensity(columns: 10, rows: 6),
    ]

    public static let `default` = GridDensity(columns: 7, rows: 5)
}
