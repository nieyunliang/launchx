import Foundation
import OSLog

// MARK: - 错误

/// 布局持久化过程错误。
public enum LayoutStoreError: LocalizedError, Equatable {
    case readFailed(path: String, underlying: String)
    case decodeFailed(underlying: String)
    case encodeFailed
    case writeFailed(path: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case let .readFailed(path, underlying):
            "无法读取文件「\(path)」：\(underlying)"
        case let .decodeFailed(underlying):
            "数据解析失败，文件可能已损坏：\(underlying)"
        case .encodeFailed:
            "数据编码失败"
        case let .writeFailed(path, underlying):
            "无法写入文件「\(path)」：\(underlying)"
        }
    }
}

// MARK: - 持久化根容器

/// 落盘的完整状态（store.json）。
public struct PersistState: Codable, Hashable, Sendable {
    public var version: Int
    public var layout: LayoutSnapshot
    public var settings: AppSettings
    public var sources: [SourceConfig]

    public static let currentVersion = 2

    public init(
        version: Int = PersistState.currentVersion,
        layout: LayoutSnapshot = LayoutSnapshot(),
        settings: AppSettings = AppSettings(),
        sources: [SourceConfig] = []
    ) {
        self.version = version
        self.layout = layout
        self.settings = settings
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey { case version, layout, settings, sources }

    /// 容忍解码：顶层字段缺失 / 类型错误时用默认值补齐，避免一个字段损坏就让整份数据失效。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = c.tolerant(Int.self, forKey: .version, default: Self.currentVersion)
        self.layout = c.tolerant(LayoutSnapshot.self, forKey: .layout, default: LayoutSnapshot())
        self.settings = c.tolerant(AppSettings.self, forKey: .settings, default: AppSettings())
        self.sources = c.tolerant([SourceConfig].self, forKey: .sources, default: [])
    }
}

// MARK: - LayoutStore

/// 布局 / 设置 / 来源的唯一持久化入口（变更即原子落盘）。
///
/// - 数据文件：`<directory>/store.json`。
/// - 损坏文件改名 `store.json.corrupt-<timestamp>` 保留后从全新状态开始，不崩溃。
@MainActor
@Observable
public final class LayoutStore {

    private static let storeFileName = "store.json"
    private static let logger = Logger(subsystem: "dev.yunliang.launchx", category: "LayoutStore")

    /// 全部持久化数据。
    public private(set) var state: PersistState

    /// 读取时是否发生过「整份损坏 → 隔离重建」。UI 据此提示用户（而不是静默丢弃布局）。
    public private(set) var didRecoverFromCorruption = false

    /// 读到未来版本（version > currentVersion）时为 true：本次会话只读，绝不覆盖新版文件。
    public private(set) var isReadOnlyForFutureVersion = false

    public let storeFileURL: URL
    /// 上一次成功落盘的备份（每次 saveNow 前复制）。
    public var backupFileURL: URL { directory.appendingPathComponent("store.json.bak") }
    private let directory: URL
    private let now: () -> Date

    public init(directory: URL? = nil, now: @escaping () -> Date = { Date() }) {
        self.now = now
        let dir = directory ?? Self.defaultDirectory
        self.directory = dir

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeFileURL = dir.appendingPathComponent(Self.storeFileName)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fileExists = FileManager.default.fileExists(atPath: storeFileURL.path)
        if fileExists,
           let raw = try? Data(contentsOf: storeFileURL),
           var decoded = try? decoder.decode(PersistState.self, from: raw) {
            Self.migrateIfNeeded(&decoded)
            state = decoded
            if decoded.version > PersistState.currentVersion {
                isReadOnlyForFutureVersion = true
                Self.logger.warning("store.json 版本 \(decoded.version, privacy: .public) 高于当前支持的 \(PersistState.currentVersion, privacy: .public)，进入只读模式")
            }
        } else {
            if fileExists {
                Self.quarantineCorruptFile(at: storeFileURL, timeStamp: now())
                didRecoverFromCorruption = true
            }
            state = PersistState()
        }

        // 首次启动：初始化默认来源；存量数据：旧版多条默认来源收敛为单个内置「应用程序」
        if state.sources.isEmpty {
            state.sources = SourceConfig.defaultSources()
        } else {
            state.sources = SourceConfig.migratingLegacyDefaults(state.sources)
        }
        if state.layout.pages.isEmpty {
            state.layout.pages = [PageRecord()]
        }
    }

    /// 默认数据目录：`~/Library/Application Support/LaunchX`。
    private static let defaultDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("LaunchX", isDirectory: true)
    }()

    private static func quarantineCorruptFile(at url: URL, timeStamp: Date) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: timeStamp)
        let parent = url.deletingLastPathComponent()
        var target = parent.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: target.path) {
            target = parent.appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)-\(n)")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            logger.warning("store.json 已损坏，改名保留为 \(target.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("损坏文件改名失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 变更入口

    /// 修改布局（快照替换），落盘。
    public func updateLayout(_ mutate: (inout LayoutSnapshot) -> Void) {
        mutate(&state.layout)
        persist()
    }

    /// 修改设置，落盘。
    public func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        updateSettingsInMemory(mutate)
        persist()
    }

    /// 仅更新内存态。供动画关键路径先提交状态，再由调用方在动画结束后 saveNow()。
    func updateSettingsInMemory(_ mutate: (inout AppSettings) -> Void) {
        mutate(&state.settings)
    }

    /// 修改来源，落盘。
    public func updateSources(_ mutate: (inout [SourceConfig]) -> Void) {
        mutate(&state.sources)
        persist()
    }

    /// 记录一次启动（lastOpenedAt / launchCount / 清除 NEW 徽章），落盘。
    public func recordLaunch(appID: String) {
        updateLayout { layout in
            guard var app = layout.apps[appID] else { return }
            app.lastOpenedAt = now()
            app.launchCount += 1
            app.isNew = false
            layout.apps[appID] = app
        }
    }

    /// 按当前排序设置（settings.activeSortKey，非 Custom）全局重排布局。
    /// 排序方式切换、应用启动后、重扫后调用，保持网格与所选排序方式一致。
    public func applyActiveSort() {
        let settings = state.settings
        let key = settings.activeSortKey
        guard key != .custom else { return }
        let capacity = settings.gridDensity.capacity
        let ascending = key.effectiveAscending(fallback: settings.sortAscending)
        let options = SortOptions(
            alsoSortFolderContents: true,
            folderPosition: settings.folderPosition,
            appleAppsPosition: settings.appleAppsPosition
        )
        updateLayout { layout in
            SortEngine.applyGlobally(&layout, key: key, ascending: ascending, capacityPerPage: capacity, options: options)
        }
    }

    /// 恢复默认布局：只重置「摆放结构」，保留应用注册表（隐藏状态 / 使用统计 / NEW 标记）、
    /// 设置与来源。可见应用按名称重新铺满页面，隐藏应用不回到网格。
    public func resetLayout() {
        let settings = state.settings
        let sources = state.sources
        let apps = state.layout.apps

        var layout = LayoutSnapshot(version: state.layout.version, apps: apps)
        let capacity = max(settings.gridDensity.capacity, 1)
        let visible = apps.values
            .filter { !$0.hidden }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var pages: [PageRecord] = []
        var current = PageRecord()
        for app in visible {
            if current.slotCount >= capacity {
                pages.append(current)
                current = PageRecord()
            }
            current.items.append(.app(id: app.id))
        }
        pages.append(current)
        layout.pages = pages
        state = PersistState(version: state.version, layout: layout, settings: settings, sources: sources)
        persist()
    }

    // MARK: - 持久化

    /// 版本迁移：v1 → v2。仅升级版本号。
    /// 不再把 `.custom` 改写成「最近使用」：旧文件里的 custom 即旧默认值，保留它可让存量用户
    /// 默认得到自由摆放（拖拽可用），也不会在升级时被强制全局重排。
    private static func migrateIfNeeded(_ state: inout PersistState) {
        guard state.version < 2 else { return }
        state.version = 2
    }


    public func saveNow() throws {
        guard !isReadOnlyForFutureVersion else {
            Self.logger.notice("只读模式（更高版本的 store.json），跳过保存以保留未知字段")
            return
        }
        let json = try encodeCurrentState()
        do {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            backupCurrentStoreFile()
            try json.write(to: storeFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw LayoutStoreError.writeFailed(path: storeFileURL.path, underlying: error.localizedDescription)
        }
    }

    /// 落盘前把上一版 store.json 留作 store.json.bak（写入失败时用户仍可手工找回上一版）。
    private func backupCurrentStoreFile() {
        guard FileManager.default.fileExists(atPath: storeFileURL.path) else { return }
        try? FileManager.default.removeItem(at: backupFileURL)
        try? FileManager.default.copyItem(at: storeFileURL, to: backupFileURL)
    }

    private func encodeCurrentState() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let raw = try encoder.encode(state)
            guard let json = String(data: raw, encoding: .utf8) else {
                throw LayoutStoreError.encodeFailed
            }
            return json
        } catch let error as LayoutStoreError {
            throw error
        } catch {
            throw LayoutStoreError.encodeFailed
        }
    }

    private func persist() {
        guard !isReadOnlyForFutureVersion else {
            Self.logger.notice("只读模式（更高版本的 store.json），跳过自动落盘")
            return
        }
        do {
            try saveNow()
        } catch {
            Self.logger.error("自动落盘失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
