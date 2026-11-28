import CoreServices
import Foundation

/// 应用索引：扫描来源目录下的 .app bundle 与替身文件，产出 AppRecord。
public enum AppIndex {

    /// 递归下钻的深度上限（根目录第一层不计，子目录最多再往下 3 层）：
    /// 自定义目录常见「根/分类/App.app」「根/分类/子分类/App.app」，更深几乎不放应用，
    /// 不封顶则超大目录树（如把整个家目录设为来源）会拖慢扫描。
    /// 内置来源对 ~/Applications 也递归（浏览器快捷方式子文件夹），同样受此上限约束。
    static let maxRecursionDepth = 3

    /// 一次扫描的诊断信息：`failedDirectories` 非空表示有来源目录整体读不到
    /// （外置卷未挂载 / TCC 未授权 / 正在被安装器替换），调用方应避免据此删除布局。
    public struct ScanDiagnostics: Sendable, Equatable {
        public var records: [AppRecord]
        public var failedDirectories: [URL]
        /// 存在但读不到 / 解析不了 `Contents/Info.plist` 的 .app 目录——典型是拖拽 / cp
        /// 安装或覆盖更新仍在拷贝中。这类 bundle 内部的后续写入不会触发来源目录的
        /// kqueue 事件，调用方需要自行稍后重扫；同时它们不应被判为「已卸载」。
        public var incompleteBundles: [URL]

        public init(records: [AppRecord], failedDirectories: [URL], incompleteBundles: [URL] = []) {
            self.records = records
            self.failedDirectories = failedDirectories
            self.incompleteBundles = incompleteBundles
        }
    }

    /// 扫描指定来源（仅 enabled 的目录；内置「应用程序」展开为标准目录集合，对齐 Launchpad
    /// 只扫第一层、~/Applications 例外递归下钻子目录；自定义目录递归下钻，见 `maxRecursionDepth`）。
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
            specs: SourceConfig.scanSpecs(from: sources, fileManager: fileManager),
            fileManager: fileManager,
            now: now
        )
    }

    /// 扫描「目录 + 递归标记」列表：.app bundle 读 Info.plist；同 id 去重；
    /// 替身文件（非目录的 .app 文件）作为 alias 条目。
    public static func scanWithDiagnostics(
        specs: [SourceConfig.ScanSpec],
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> ScanDiagnostics {
        var seen = Set<String>()
        var records: [AppRecord] = []
        var failedDirectories: [URL] = []
        var incompleteBundles: [URL] = []
        for spec in specs {
            scanDirectory(
                spec.url,
                depth: 0,
                recursive: spec.recursive,
                fileManager: fileManager,
                now: now,
                seen: &seen,
                records: &records,
                failedDirectories: &failedDirectories,
                incompleteBundles: &incompleteBundles
            )
        }
        return ScanDiagnostics(
            records: records,
            failedDirectories: failedDirectories,
            incompleteBundles: incompleteBundles
        )
    }

    /// 兼容入口：目录列表全部按非递归扫描。
    public static func scan(directories: [URL], fileManager: FileManager = .default, now: Date = Date()) -> [AppRecord] {
        scanWithDiagnostics(directories: directories, fileManager: fileManager, now: now).records
    }

    public static func scanWithDiagnostics(
        directories: [URL],
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> ScanDiagnostics {
        scanWithDiagnostics(
            specs: directories.map { SourceConfig.ScanSpec(url: $0) },
            fileManager: fileManager,
            now: now
        )
    }

    /// 扫描单个目录：第一层收集 .app（bundle 或替身文件）；`recursive` 且未达深度上限时，
    /// 普通子目录（非 .app、非隐藏、非目录符号链接——防环）继续下钻。
    private static func scanDirectory(
        _ directory: URL,
        depth: Int,
        recursive: Bool,
        fileManager: FileManager,
        now: Date,
        seen: inout Set<String>,
        records: inout [AppRecord],
        failedDirectories: inout [URL],
        incompleteBundles: inout [URL]
    ) {
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
            return
        }
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            if url.pathExtension.lowercased() == "app" {
                var isDirectory: ObjCBool = false
                let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                guard exists else { continue }
                let record: AppRecord?
                if isDirectory.boolValue {
                    record = parseAppBundle(at: url, fileManager: fileManager, now: now)
                    if record == nil, !isWrappediOSApp(at: url, fileManager: fileManager) {
                        incompleteBundles.append(url)
                    }
                } else {
                    // 替身文件：保留原名，启动交给 Finder 解析目标
                    record = parseAliasFile(at: url, now: now)
                }
                guard let record, seen.insert(record.id).inserted else { continue }
                records.append(record)
            } else {
                // 非应用条目：真实子目录（不跟符号链接，防环）且未超深度上限才下钻
                guard recursive, depth < maxRecursionDepth else { continue }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else { continue }
                scanDirectory(
                    url,
                    depth: depth + 1,
                    recursive: true,
                    fileManager: fileManager,
                    now: now,
                    seen: &seen,
                    records: &records,
                    failedDirectories: &failedDirectories,
                    incompleteBundles: &incompleteBundles
                )
            }
        }
    }

    /// 递归下钻会覆盖的子目录集合（与扫描同一套规则，供目录监听展开用，不含根目录本身）。
    static func subdirectories(under root: URL, fileManager: FileManager = .default) -> [URL] {
        var result: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (directory, depth) = queue.removeFirst()
            guard depth < maxRecursionDepth else { continue }
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )) ?? []
            for url in contents {
                guard !url.lastPathComponent.hasPrefix("."),
                      url.pathExtension.lowercased() != "app",
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true else { continue }
                result.append(url)
                queue.append((url, depth + 1))
            }
        }
        return result
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

    /// 读取 bundle 的 `Contents/Info.plist`；缺失或解析不了返回 nil（安装 / 覆盖中或已损坏）。
    static func readInfoPlist(bundleAt url: URL, fileManager: FileManager = .default) -> [String: Any]? {
        let infoURL = url.appendingPathComponent("Contents").appendingPathComponent("Info.plist")
        guard let data = fileManager.contents(atPath: infoURL.path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    /// Apple Silicon 上安装的 iOS 应用：外层 `Foo.app` 只有 `Wrapper/` 与 `WrappedBundle`，
    /// 没有 `Contents/Info.plist`。这是稳定结构而不是安装中的半成品，不能记作未完成 bundle，
    /// 否则每次启动都会白跑一轮补扫探测，最后还要整仓重扫一次。
    static func isWrappediOSApp(at url: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url.appendingPathComponent("WrappedBundle").path)
            || fileManager.fileExists(atPath: url.appendingPathComponent("Wrapper").path)
    }

    private static func parseAppBundle(at url: URL, fileManager: FileManager, now: Date) -> AppRecord? {
        guard let plist = readInfoPlist(bundleAt: url, fileManager: fileManager) else { return nil }
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
    ///
    /// - Parameter unreadablePrefixes: 本次扫描中**整体读取失败**的来源目录路径
    ///   （外置卷未挂载 / TCC 拒绝 / 安装器正在替换 bundle），以及 Info.plist 暂缺、
    ///   仍在补扫期内的单个 .app 路径（覆盖更新中）。落在这些路径下的应用
    ///   只是「暂时扫不到」，不参与消失判定，也不累加缺失次数，避免用户的排列被误删。
    @discardableResult
    public static func merge(
        scanned: [AppRecord],
        into layout: inout LayoutSnapshot,
        capacityPerPage: Int,
        appendToPage pageIndex: Int? = nil,
        unreadablePrefixes: [String] = [],
        now: Date = Date()
    ) -> Result {
        var added: [String] = []
        var removed: [String] = []

        let scannedByID = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })
        let scannedIDs = Set(scannedByID.keys)
        let unreadable = unreadablePrefixes.filter { !$0.isEmpty }

        // 1. 移除已消失的应用（路径不存在且不在扫描集合）。
        //    宽限：安装/更新替换 bundle、外置卷瞬时不可用、TCC 抖动时，单次扫描缺失只做标记，
        //    连续两次缺失才真正移除，避免用户的排列被瞬时状态破坏。
        //    候选 = 网格上的应用 + 只在注册表里的应用（如「恢复默认布局」后的隐藏项）；
        //    只遍历前者会让后者被卸载后永远清不掉。
        let placedIDs = layout.placedAppIDs
        let placedSet = Set(placedIDs)
        var candidates = placedIDs.filter { !scannedIDs.contains($0) }
        candidates.append(contentsOf: layout.apps.keys
            .filter { !scannedIDs.contains($0) && !placedSet.contains($0) }
            .sorted())
        for appID in candidates {
            guard let existing = layout.apps[appID], !existing.isAlias else { continue }
            // 1a. 来源目录整体读不到：不是「应用被卸载」，跳过且保留已有缺失计数
            //     （该目录恢复可读后再按正常路径判定）。
            if Self.isUnderUnreadableDirectory(existing.path, prefixes: unreadable) { continue }
            // 1b. 未摆放项（隐藏/恢复默认布局后仅存注册表）：只有文件真的不存在才算消失，
            //     避免把「来源被临时关闭 / 目录未挂载」这类扫描不到但文件仍在的情况误删。
            if !placedSet.contains(appID),
               !existing.path.isEmpty,
               FileManager.default.fileExists(atPath: existing.path) {
                continue
            }
            var record = existing
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
        let placedForAppending = Set(layout.placedAppIDs)
        let startIndex = pageIndex ?? max(layout.pages.count - 1, 0)
        for scannedRecord in scanned {
            guard layout.apps[scannedRecord.id] == nil else { continue }
            var record = scannedRecord
            record.addedAt = now
            record.isNew = !isBaselineScan
            layout.apps[record.id] = record
            if !placedForAppending.contains(record.id) {
                layout.appendApp(id: record.id, toPage: startIndex, capacityPerPage: capacityPerPage)
            }
            added.append(record.id)
        }

        layout.removeEmptyPages()
        return Result(addedAppIDs: added, removedAppIDs: removed)
    }

    /// 应用路径是否落在本次扫描失败的目录下（前缀按目录边界匹配：
    /// `/Volumes/Extern` 命中 `/Volumes/Extern/App.app`，不命中 `/Volumes/Extern2/App.app`）。
    static func isUnderUnreadableDirectory(_ path: String, prefixes: [String]) -> Bool {
        guard !path.isEmpty, !prefixes.isEmpty else { return false }
        return prefixes.contains { prefix in
            let root = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
            guard !root.isEmpty else { return false }
            return path == root || path.hasPrefix(root + "/")
        }
    }
}
