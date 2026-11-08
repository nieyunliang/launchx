import CoreServices
import Foundation

/// 应用索引：扫描来源目录下的 .app bundle 与替身文件，产出 AppRecord。
public enum AppIndex {

    /// 一次扫描的诊断信息：`failedDirectories` 非空表示有来源目录整体读不到
    /// （外置卷未挂载 / TCC 未授权 / 正在被安装器替换），调用方应避免据此删除布局。
    public struct ScanDiagnostics: Sendable, Equatable {
        public var records: [AppRecord]
        public var failedDirectories: [URL]

        public init(records: [AppRecord], failedDirectories: [URL]) {
            self.records = records
            self.failedDirectories = failedDirectories
        }
    }

    /// 扫描指定来源（仅 enabled 的目录，不递归；内置「应用程序」展开为标准目录集合）。
    /// 同 bundleId 去重（来源数组顺序即优先级）。
    public static func scan(sources: [SourceConfig], fileManager: FileManager = .default) -> [AppRecord] {
        scanWithDiagnostics(sources: sources, fileManager: fileManager).records
    }

    public static func scanWithDiagnostics(
        sources: [SourceConfig],
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> ScanDiagnostics {
        scanWithDiagnostics(
            directories: SourceConfig.scanDirectories(from: sources, fileManager: fileManager),
            fileManager: fileManager,
            now: now
        )
    }

    /// 扫描目录列表（不递归）：.app bundle 读 Info.plist；同 id 去重；
    /// 替身文件（非目录的 .app 文件）作为 alias 条目。
    public static func scan(directories: [URL], fileManager: FileManager = .default, now: Date = Date()) -> [AppRecord] {
        scanWithDiagnostics(directories: directories, fileManager: fileManager, now: now).records
    }

    public static func scanWithDiagnostics(
        directories: [URL],
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> ScanDiagnostics {
        var seen = Set<String>()
        var records: [AppRecord] = []
        var failedDirectories: [URL] = []
        for directory in directories {
            // 不用 .skipsHiddenFiles：/Applications/Safari.app 是系统放置的带 UF_HIDDEN
            // 标志的符号链接（Launchpad 同样展示它），跳过隐藏会把 Safari 漏掉；
            // 点开头的杂项（.DS_Store 等）由后缀与显式过滤排除
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: []
                )
            } catch {
                failedDirectories.append(directory)
                continue
            }
            for url in contents
            where url.pathExtension.lowercased() == "app" && !url.lastPathComponent.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard exists else { continue }
                let record: AppRecord?
                if isDirectory.boolValue {
                    record = parseAppBundle(at: url, fileManager: fileManager, now: now)
                } else {
                    // 替身文件：保留原名，启动交给 Finder 解析目标
                    record = parseAliasFile(at: url, now: now)
                }
                guard let record, seen.insert(record.id).inserted else { continue }
                records.append(record)
            }
        }
        return ScanDiagnostics(records: records, failedDirectories: failedDirectories)
    }

    /// 展示名回退链：本地化显示名 > Info.plist 显示名 > 文件名（去 .app）。
    public static func displayName(infoPlist: [String: Any], bundlePath: String) -> String {
        if let display = infoPlist["CFBundleDisplayName"] as? String, !display.isEmpty {
            return display
        }
        if let bundleName = infoPlist["CFBundleName"] as? String, !bundleName.isEmpty {
            return bundleName
        }
        let fileName = (bundlePath as NSString).lastPathComponent
        return fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
    }

    public static func resolvedName(infoPlist: [String: Any], bundle: Bundle?, bundlePath: String) -> String {
        if let bundle {
            if let localized = localizedInfoPlistValue(for: ["CFBundleDisplayName", "CFBundleName"], in: bundle) {
                return localized
            }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty {
                    return value
                }
            }
        }
        return displayName(infoPlist: infoPlist, bundlePath: bundlePath)
    }

    /// 读取本地化的 InfoPlist 值（Finder/Launchpad 展示的同一份名字）：
    /// 1. `InfoPlist.loctable` —— 新版系统应用把各语言键值集中在 Resources 单文件表
    ///    （Bundle.localizedString / object(forInfoDictionaryKey:) 都读不到它）；
    /// 2. `<lang>.lproj/InfoPlist.strings` —— 第三方应用的传统形式（binary/UTF-16 均可）。
    /// 语言匹配按 `preferences`（用户首选语言序）进行，不依赖进程自身语言；
    /// 都取不到返回 nil，由调用方回退 Info.plist 原始值。
    static func localizedInfoPlistValue(
        for keys: [String],
        in bundle: Bundle,
        preferences: [String] = Locale.preferredLanguages
    ) -> String? {
        // 1. .loctable：顶层 { 语言: { 键: 值 } }，值可能是 String 或嵌套表（复数规则等），逐层取 String
        if let resourceURL = bundle.resourceURL {
            let loctableURL = resourceURL.appendingPathComponent("InfoPlist.loctable")
            if let data = try? Data(contentsOf: loctableURL),
               let table = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                let best = Bundle.preferredLocalizations(from: Array(table.keys), forPreferences: preferences)
                for lang in best where localizationMatches(lang, preferences: preferences) {
                    guard let values = table[lang] as? [String: Any] else { continue }
                    for key in keys {
                        if let value = values[key] as? String, !value.isEmpty { return value }
                    }
                }
            }
        }
        // 2. 传统 .lproj/InfoPlist.strings
        let bestLproj = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: preferences)
        for lang in bestLproj where localizationMatches(lang, preferences: preferences) {
            guard let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: lang),
                  let strings = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            for key in keys {
                if let value = strings[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// 语言主子标签匹配（zh-Hans-CN ↔ zh_CN 命中；fr 与 zh 不命中）。
    /// `Bundle.preferredLocalizations(from:forPreferences:)` 对无命中的偏好也总会返回
    /// 候选（回退首个可用项），必须再用主子标签判断是否真匹配，否则会给中文用户
    /// 挑出纯法语/德语等无关本地化名（对齐系统行为：无匹配时展示 Info.plist 原始名）。
    private static func localizationMatches(_ localization: String, preferences: [String]) -> Bool {
        let languageTag = { (id: String) -> String in
            id.lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-")
                .first.map(String.init) ?? id
        }
        let localizationTag = languageTag(localization)
        return preferences.contains { languageTag($0) == localizationTag }
    }

    /// 读取系统记录的最近使用时间（Spotlight kMDItemLastUsedDate，含在 LaunchX 之外的启动）；
    /// 未被索引或从未使用时返回 nil（排序时按最早处理）。
    public static func lastUsedDate(atPath path: String) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, URL(fileURLWithPath: path) as CFURL) else {
            return nil
        }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - 内部

    private static func parseAppBundle(at url: URL, fileManager: FileManager, now: Date) -> AppRecord? {
        let infoURL = url.appendingPathComponent("Contents").appendingPathComponent("Info.plist")
        guard let data = fileManager.contents(atPath: infoURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let bundleId = plist["CFBundleIdentifier"] as? String
        let name = resolvedName(infoPlist: plist, bundle: Bundle(path: url.path), bundlePath: url.path)
        return AppRecord(
            id: bundleId ?? url.path,
            name: name,
            bundleName: plist["CFBundleName"] as? String ?? name,
            bundleId: bundleId,
            version: plist["CFBundleShortVersionString"] as? String,
            path: url.path,
            category: plist["LSApplicationCategoryType"] as? String,
            addedAt: now,
            lastOpenedAt: lastUsedDate(atPath: url.path),
            isNew: true
        )
    }

    private static func parseAliasFile(at url: URL, now: Date) -> AppRecord? {
        let fileName = url.deletingPathExtension().lastPathComponent
        return AppRecord(
            id: url.path,
            name: fileName,
            bundleName: fileName,
            bundleId: nil,
            version: nil,
            path: url.path,
            category: nil,
            isAlias: true,
            addedAt: now,
            isNew: true
        )
    }
}

// MARK: - SyncEngine

/// 把扫描结果合并进布局的纯逻辑引擎：
/// - 新应用：注册 + NEW 徽章 + 追加到指定页末尾（页满顺延）；
/// - 消失的应用（不在扫描集合且非 alias 的 bundle）：从布局与注册表移除；
/// - 已在布局的应用：刷新元数据（name/bundleName/version/category），保留用户布局位。
public enum SyncEngine {

    public struct Result: Sendable, Equatable {
        /// 新增的应用 id（含 NEW 徽章）。
        public var addedAppIDs: [String]
        /// 被移除的应用 id。
        public var removedAppIDs: [String]
        public init(addedAppIDs: [String], removedAppIDs: [String]) {
            self.addedAppIDs = addedAppIDs
            self.removedAppIDs = removedAppIDs
        }
    }

    /// 合并扫描结果。`capacityPerPage` 由当前网格密度决定。
    @discardableResult
    public static func merge(
        scanned: [AppRecord],
        into layout: inout LayoutSnapshot,
        capacityPerPage: Int,
        appendToPage pageIndex: Int? = nil,
        now: Date = Date()
    ) -> Result {
        var added: [String] = []
        var removed: [String] = []

        let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

        // 1. 移除已消失的应用（路径不存在且不在扫描集合）。
        //    宽限：安装/更新替换 bundle、外置卷瞬时不可用、TCC 抖动时，单次扫描缺失只做标记，
        //    连续两次缺失才真正移除，避免用户的排列被瞬时状态破坏。
        let placedIDs = layout.placedAppIDs
        for appID in placedIDs where !scannedByID.keys.contains(appID) {
            guard var record = layout.apps[appID], !record.isAlias else { continue }
            record.missingScans += 1
            if record.missingScans >= 2 {
                layout.removeApp(id: appID)
                removed.append(appID)
            } else {
                layout.apps[appID] = record
            }
        }

        // 2. 刷新在册应用元数据（保留用户字段：name 改名 / hidden / isNew / 使用统计）
        for (id, scannedRecord) in scannedByID {
            if var existing = layout.apps[id] {
                let oldBundleName = existing.bundleName  // 改名判定基于刷新前的原始名
                existing.bundleName = scannedRecord.bundleName
                existing.bundleId = scannedRecord.bundleId
                existing.version = scannedRecord.version
                existing.category = scannedRecord.category
                existing.path = scannedRecord.path
                // 用户未改名时跟随系统名（name == 旧 bundleName 视为未改名）
                if existing.name == oldBundleName || existing.name.isEmpty {
                    existing.name = scannedRecord.name
                }
                // 最近使用时间取较新者：站外启动由扫描刷新，站内启动的记录不被旧值覆盖
                if let scannedDate = scannedRecord.lastOpenedAt,
                   existing.lastOpenedAt == nil || scannedDate > existing.lastOpenedAt! {
                    existing.lastOpenedAt = scannedDate
                }
                existing.missingScans = 0
                layout.apps[id] = existing
            }
        }

        // 3. 新应用：注册 + 追加摆放。NEW 徽章只在增量扫描亮——
        // 首次基线扫描（注册表为空）全部视为既有应用，避免整屏 NEW。
        let isBaselineScan = layout.apps.isEmpty
        let placedSet = Set(layout.placedAppIDs)
        let startIndex = pageIndex ?? max(layout.pages.count - 1, 0)
        for scannedRecord in scanned {
            guard layout.apps[scannedRecord.id] == nil else { continue }
            var record = scannedRecord
            record.addedAt = now
            record.isNew = !isBaselineScan
            layout.apps[record.id] = record
            if !placedSet.contains(record.id) {
                layout.appendApp(id: record.id, toPage: startIndex, capacityPerPage: capacityPerPage)
            }
            added.append(record.id)
        }

        layout.removeEmptyPages()
        return Result(addedAppIDs: added, removedAppIDs: removed)
    }
}
