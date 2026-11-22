import AppKit
import Foundation

/// 卸载关联文件分类（对应原版 14 类分组）。
public enum UninstallCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case caches = "Caches"
    case applicationSupport = "Application Support"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case applicationFiles = "Application Files"
    case userFiles = "User Files"
    case otherFiles = "Other Files"
    case webKitData = "WebKit Data"
    case httpStorage = "HTTP Storage"
    case savedState = "Saved State"
    case applicationScripts = "Application Scripts"
    case launchItems = "Launch Items"
    case aliasFile = "Alias File"
    case sandbox = "Sandbox"

    public var id: String { rawValue }

    /// 界面展示用中文名。`rawValue` 仍保留英文，作为稳定的标识与测试/日志键。
    public var displayName: String {
        switch self {
        case .caches: "缓存"
        case .applicationSupport: "应用支持文件"
        case .containers: "容器"
        case .groupContainers: "共享容器"
        case .applicationFiles: "应用文件"
        case .userFiles: "用户文件"
        case .otherFiles: "其它文件"
        case .webKitData: "网页数据"
        case .httpStorage: "HTTP 缓存"
        case .savedState: "已保存状态"
        case .applicationScripts: "应用脚本"
        case .launchItems: "自启项"
        case .aliasFile: "别名文件"
        case .sandbox: "沙盒元数据"
        }
    }

    /// 用户个人数据类目：含 ~/Documents、~/Downloads 中按名称匹配到的文件，默认不勾选。
    public var isUserData: Bool { self == .userFiles }

    /// 系统级副作用类目：删除会影响应用自启/系统状态，默认不勾选。
    public var hasSystemSideEffects: Bool { self == .launchItems }

    /// 默认不勾选的类目（必须由用户显式勾选）。
    public var isExcludedByDefault: Bool { isUserData || hasSystemSideEffects }
}

/// 扫描到的一个可清理项。
public struct UninstallItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let category: UninstallCategory
    /// 大小（字节；nil = 无法读取）。
    public let byteSize: Int64?
    /// 名称模糊匹配得到的「可能相关」项（并非由 bundleId 精确派生）。
    /// 默认不勾选，避免把同名的个人文档/自启项当作关联文件误删。
    public let isSpeculative: Bool

    public init(
        url: URL,
        category: UninstallCategory,
        byteSize: Int64?,
        isSpeculative: Bool = false
    ) {
        self.url = url
        self.category = category
        self.byteSize = byteSize
        self.isSpeculative = isSpeculative
    }

    public var id: String { "\(category.rawValue)|\(url.path)" }
}

/// 卸载扫描引擎：按应用 bundleId / 名称 / 路径全盘扫描 14 类关联文件。
public enum UninstallScanner {

    /// 扫描某应用的关联文件。主线程调用（内部读大量小目录，建议后台线程）。
    public static func scan(
        app: AppRecord,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [UninstallItem] {
        var items: [UninstallItem] = []
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let bundleID = app.bundleId ?? ""
        let name = app.name

        /// 允许清理的根目录。删除路径必须落在这些根之下（目录边界匹配），
        /// 否则一个畸形 bundle（如 `CFBundleIdentifier = "../.."`）会让清单指向家目录本身。
        let allowedRoots = [
            home,
            URL(fileURLWithPath: "/Library", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
        ]

        func existing(_ path: String) -> URL? {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue)
            // 防御：`..` 越界（或指向允许根之外的绝对路径）的条目一律不收集。
            guard Self.isContainedInAllowedRoots(url, roots: allowedRoots) else { return nil }
            return url
        }

        /// 记录一个命中项。`speculative` = 由名称模糊匹配得到、不保证属于该应用。
        func add(_ url: URL?, _ category: UninstallCategory, speculative: Bool = false) {
            guard let url else { return }
            items.append(UninstallItem(
                url: url,
                category: category,
                byteSize: Self.size(of: url, fileManager: fileManager),
                isSpeculative: speculative || category.isExcludedByDefault
            ))
        }

        // 路径拼接用的分量必须是单个安全文件名：bundleId / 显示名来自 bundle 的 Info.plist，
        // 出现 `/`、`..` 等分量时会构造出越界路径（兜底在 existing()，这里先挡一层）。
        let bundleComponent = Self.safePathComponent(bundleID)
        let nameComponent = Self.safePathComponent(name)

        // Caches（bundleId 精确路径可直接归因；按应用名命名的缓存目录属于模糊匹配）
        if let bundleComponent {
            add(existing(library.appendingPathComponent("Caches/\(bundleComponent)").path), .caches)
        }
        if let nameComponent {
            add(existing(library.appendingPathComponent("Caches/\(nameComponent)").path), .caches, speculative: true)
        }

        // Application Support
        if let bundleComponent {
            add(existing(library.appendingPathComponent("Application Support/\(bundleComponent)").path), .applicationSupport)
        }
        if let nameComponent {
            add(
                existing(library.appendingPathComponent("Application Support/\(nameComponent)").path),
                .applicationSupport,
                speculative: true
            )
        }

        // Containers
        if let bundleComponent {
            add(existing(library.appendingPathComponent("Containers/\(bundleComponent)").path), .containers)
        }

        // Group Containers（group.<team>.<id>，按 bundleId 尾缀匹配）
        let groupContainers = library.appendingPathComponent("Group Containers", isDirectory: true)
        let groupNames = (try? fileManager.contentsOfDirectory(atPath: groupContainers.path)) ?? []
        for groupName in groupNames where !bundleID.isEmpty && groupName.contains(bundleID) {
            add(existing(groupContainers.appendingPathComponent(groupName).path), .groupContainers, speculative: true)
        }

        // Application Files：~/Library/<name>、Logs（按名称匹配，可能同名误伤）
        if let nameComponent {
            add(existing(library.appendingPathComponent("\(nameComponent)").path), .applicationFiles, speculative: true)
            add(existing(library.appendingPathComponent("Logs/\(nameComponent)").path), .applicationFiles, speculative: true)
        }
        if let bundleComponent {
            add(existing(library.appendingPathComponent("Logs/\(bundleComponent)").path), .applicationFiles)
        }

        // User Files：~/Documents、~/Downloads 浅层名称匹配。
        // 结果标记为「可能相关」并强制默认不勾选——同名子串很容易命中无关的个人文档/工程目录。
        for folderName in ["Documents", "Downloads"] {
            let folder = home.appendingPathComponent(folderName, isDirectory: true)
            let children = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for child in children where child.localizedCaseInsensitiveContains(name) && name.count >= 3 {
                add(existing(folder.appendingPathComponent(child).path), .userFiles, speculative: true)
            }
        }

        // Other Files：Preferences plist。
        // 必须按目录边界匹配：`hasPrefix(bundleID)` 会把 `com.foo` 的卸载连带勾选
        // `com.foobar.plist`（另一个应用的偏好设置）。只有 `bundleID.plist` 直接归因，
        // `bundleID.` 前缀（helper/子模块）降级为「可能相关」默认不勾选。
        if !bundleID.isEmpty {
            let prefs = library.appendingPathComponent("Preferences", isDirectory: true)
            let plists = (try? fileManager.contentsOfDirectory(atPath: prefs.path)) ?? []
            for plist in plists where Self.preferenceBelongsTo(plist, bundleID: bundleID) {
                let exact = plist == "\(bundleID).plist"
                add(existing(prefs.appendingPathComponent(plist).path), .otherFiles, speculative: !exact)
            }
        }

        // WebKit Data / HTTP Storage / Saved State / Application Scripts
        if let bundleComponent {
            add(existing(library.appendingPathComponent("WebKit/\(bundleComponent)").path), .webKitData)
            add(existing(library.appendingPathComponent("HTTPStorages/\(bundleComponent)").path), .httpStorage)
            add(existing(library.appendingPathComponent("Saved Application State/\(bundleComponent).savedState").path), .savedState)
            add(existing(library.appendingPathComponent("Application Scripts/\(bundleComponent)").path), .applicationScripts)
        }

        // Launch Items
        for launchDir in [
            library.appendingPathComponent("LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
        ] {
            let agents = (try? fileManager.contentsOfDirectory(atPath: launchDir.path)) ?? []
            for agent in agents
            where agent.localizedCaseInsensitiveContains(name) || (!bundleID.isEmpty && agent.localizedCaseInsensitiveContains(bundleID)) {
                add(existing(launchDir.appendingPathComponent(agent).path), .launchItems, speculative: true)
            }
        }

        // Alias File：常用目录中指向该应用的替身
        let aliasDirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true),
        ]
        for dir in aliasDirs {
            let children = (try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]
            )) ?? []
            for child in children
            where child.pathExtension.lowercased() == "app" || child.pathExtension.lowercased() == "alias" {
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    let fileName = child.deletingPathExtension().lastPathComponent
                    if fileName.localizedCaseInsensitiveContains(name) || child.lastPathComponent.localizedCaseInsensitiveContains(bundleID) {
                        add(existing(child.path), .aliasFile)
                    }
                }
            }
        }

        // Sandbox：容器元数据（独立于 Containers 主体，作为最后防线类目）
        if let bundleComponent {
            add(
                existing(library.appendingPathComponent("Containers/\(bundleComponent)/.com.apple.containermanagerd.metadata.plist").path),
                .sandbox
            )
        }

        // 去重（同名不同类目保留首项）
        var seen = Set<String>()
        items.removeAll { !seen.insert($0.url.path).inserted }

        return items
    }

    // MARK: - 路径安全

    /// 允许清理的根目录（删除/收集都必须落在这些目录之下）。`home` 之外的系统级根
    /// 只包含 `/Library` 与 `/Applications`：扫描器本身只会产出这两处的自启项与替身。
    static func allowedRoots(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            home.standardizedFileURL,
            URL(fileURLWithPath: "/Library", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
        ]
    }

    /// URL 是否落在给定根目录之内（目录边界匹配，根目录本身视为「不允许」）。
    ///
    /// 用 `standardizedFileURL` 先把 `..` 分子消掉；不解析符号链接（回收站删除的是链接本身）。
    public static func isContainedInAllowedRoots(_ url: URL, roots: [URL]) -> Bool {
        let target = url.standardizedFileURL.path
        guard !target.isEmpty, target != "/" else { return false }
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard !rootPath.isEmpty, rootPath != "/" else { continue }
            if target == rootPath { return false }
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if target.hasPrefix(prefix) { return true }
        }
        return false
    }

    /// 单个路径分量是否安全：非空、不含 `/`、`\0`、`: ` 与 `.` / `..`。
    static func safePathComponent(_ raw: String) -> String? {
        guard !raw.isEmpty,
              raw != ".", raw != "..",
              !raw.contains("/"),
              !raw.contains("\0"),
              !raw.contains(":") else { return nil }
        return raw
    }

    /// Preferences 目录里的 plist 是否属于该 bundleId（目录边界匹配）。
    /// `com.foo` 只直接归因 `com.foo.plist`；`com.foo.bar.plist`（helper/子模块）允许命中但调用方降级为「可能相关」。
    static func preferenceBelongsTo(_ plist: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return plist == "\(bundleID).plist" || plist.hasPrefix("\(bundleID).")
    }

    /// 目录/文件大小（目录递归；失败 nil）。
    public static func size(of url: URL, fileManager: FileManager = .default) -> Int64? {        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                return Int64(size)
            }
            return nil
        }
        // TCC/权限拒绝时 `enumerator(at:)` 可能返回空迭代而不是 nil，把不可读目录
        // 统计成 0 字节，用户会在删除清单里看到「0 字节」误以为没有数据。
        // 先确认目录本身可列（权限不足会抛错），把「不可读」与「空目录」区分开。
        guard (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        guard let enumerator = fileManager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return nil }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            if let size = try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

/// 删除引擎：勾选项移到废纸篓（安全），逐项回报进度与失败原因。
public enum UninstallEngine {

    public enum Outcome: Sendable {
        case progress(done: Int, total: Int)
        case finished(trashed: Int, failed: [(path: String, error: String)])
    }

    /// 移到废纸篓的实现：返回「原 URL → 废纸篓内新 URL」。
    /// 未能移动的项不会出现在返回字典中（NSWorkspace 的约定），调用方据此判定失败。
    /// 抽成可注入类型，便于单测覆盖失败收集逻辑。
    public typealias TrashHandler = @Sendable ([URL]) async throws -> [URL: URL]

    /// 真实实现：交给系统回收站。
    public static func systemTrash(_ urls: [URL]) async throws -> [URL: URL] {
        try await NSWorkspace.shared.recycle(urls)
    }

    /// 删除侧安全校验：路径必须落在 `home` / `/Library` / `/Applications` 之内。
    public static func isSafeToTrash(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        UninstallScanner.isContainedInAllowedRoots(url, roots: UninstallScanner.allowedRoots(home: home))
    }

    /// 删除选中项（移到废纸篓）。
    ///
    /// 失败逐条收集（含单项抛错与「未出现在回收站返回字典中」两种情形）；
    /// 只有真正被回收站接收的项才计入 `trashed`，不会因为 `fileExists` 就虚报成功。
    @discardableResult
    public static func remove(
        items: [UninstallItem],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        trash: TrashHandler = UninstallEngine.systemTrash,
        onEvent: @MainActor @escaping (Outcome) -> Void
    ) async -> (trashed: Int, failed: [(path: String, error: String)]) {
        var trashed = 0
        var failed: [(path: String, error: String)] = []
        let fileManager = FileManager.default

        for (index, item) in items.enumerated() {
            // 最后一道闸：任何不在允许根目录内的路径都不交给回收站。
            // 扫描侧已做同样校验，这里防的是调用方传入的手工条目 / 扫描后路径被替换。
            guard isSafeToTrash(item.url, home: home) else {
                failed.append((item.url.path, "路径不在允许的清理范围内，已跳过"))
                let done = index + 1
                await MainActor.run {
                    onEvent(.progress(done: done, total: items.count))
                }
                continue
            }
            if !fileManager.fileExists(atPath: item.url.path) {
                // 扫描之后已被其它途径移除：无可删内容，既不算成功也不算失败
            } else {
                do {
                    let moved = try await trash([item.url])
                    if moved[item.url] != nil {
                        trashed += 1
                    } else {
                        failed.append((item.url.path, "未能移到废纸篓（可能没有权限或文件正被占用）"))
                    }
                } catch {
                    failed.append((item.url.path, error.localizedDescription))
                }
            }
            let done = index + 1
            await MainActor.run {
                onEvent(.progress(done: done, total: items.count))
            }
        }
        let result = (trashed, failed)
        await MainActor.run {
            onEvent(.finished(trashed: result.0, failed: result.1))
        }
        return result
    }
}

/// 完全磁盘访问（FDA）检测。
///
/// 旧探针用的是 `~/Library/Saved Application State` 与 `~/Library/Containers`：
/// 这两个目录在未授权 FDA 时也能被普通进程 `contentsOfDirectory`，而
/// `fileExists` 对缺失/不可见目录返回 false 后又被直接跳过——`isGranted()` 因此
/// 恒为 true，权限引导成了死代码，同时容器内容等受保护目录被静默漏扫
/// （审查 findings-c F-03）。
///
/// 现在改为探测真正由 TCC 保护的用户目录（Safari / Mail / Messages / Accounts），
/// 并且区分三种状态：
/// - `.granted`：至少一个受保护目录可以列出；
/// - `.denied`：受保护目录存在但读取被拒；
/// - `.unknown`：机器上没有这些目录（全新用户/精简系统），不阻断卸载流程。
public enum FullDiskAccess {

    public enum Status: Equatable, Sendable {
        case granted
        case denied
        case unknown
    }

    /// 真正受 TCC 保护的用户目录（相对 home）。缺失的目录会被跳过，
    /// 避免把「没装邮件」误判成「没有权限」。
    /// 只收「目录列举一定受 TCC 保护」的路径：TCC 数据库用的是文件级保护，
    /// 列目录未必被拒，不能作为授权证据。
    static let protectedRelativePaths: [String] = [
        "Library/Safari",
        "Library/Mail",
        "Library/Messages",
        "Library/Accounts",
    ]

    /// 判断 FDA 状态。目录列举行为可注入，便于单测覆盖授权/拒绝/缺失三种分支。
    public static func status(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        listDirectory: (String) throws -> [String] = { try FileManager.default.contentsOfDirectory(atPath: $0) }
    ) -> Status {
        var sawProtectedPath = false
        for relativePath in protectedRelativePaths {
            let path = home.appendingPathComponent(relativePath).path
            do {
                _ = try listDirectory(path)
                // 任一受保护目录可列出，说明已有 FDA
                return .granted
            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                    // 目录不存在 ≠ 没有权限（例如从未使用过 Safari）
                    continue
                }
                sawProtectedPath = true
            }
        }
        return sawProtectedPath ? .denied : .unknown
    }
}
