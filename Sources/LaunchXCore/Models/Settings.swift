import Foundation

// MARK: - 设置枚举

/// 浏览样式：分页（左右翻页）或连续纵向滚动。
public enum BrowsingStyle: String, Codable, CaseIterable, Sendable {
    case paged
    case scroll

    public var label: String { self == .paged ? "分页" : "滚动" }
}

/// 在哪个屏幕显示全屏面板。
public enum ScreenPosition: String, Codable, CaseIterable, Sendable {
    case main      // Main Screen
    case active    // Active Screen
    case cursor    // Cursor Screen
    case dock      // Dock Screen

    public var label: String {
        switch self {
        case .main: "主屏幕"
        case .active: "当前激活屏幕"
        case .cursor: "鼠标所在屏幕"
        case .dock: "Dock 所在屏幕"
        }
    }
}

/// 失焦后延时收起。
public enum CloseDelay: String, Codable, CaseIterable, Sendable {
    case never   // 不自动收起
    case always  // 立即收起
    case s1      // 1 秒宽限（默认：给「点开子菜单 / 弹出系统窗口」留一点反应时间）
    case s5
    case s15
    case s30
    case m1
    case m5

    public var label: String {
        switch self {
        case .never: "永不"
        case .always: "立即"
        case .s1: "1 秒后"
        case .s5: "5 秒后"
        case .s15: "15 秒后"
        case .s30: "30 秒后"
        case .m1: "1 分钟后"
        case .m5: "5 分钟后"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .never: nil
        case .always: 0
        case .s1: 1
        case .s5: 5
        case .s15: 15
        case .s30: 30
        case .m1: 60
        case .m5: 300
        }
    }
}

/// 网格图标染色模式（原色 / 白色→红 / 红→白 单色轮廓）。
public enum IconColorMode: String, Codable, CaseIterable, Sendable {
    case original
    case whiteToRed
    case redToWhite

    public var label: String {
        switch self {
        case .original: "原色"
        case .whiteToRed: "白色→红"
        case .redToWhite: "红→白"
        }
    }

    /// 单色轮廓的目标色（`.original` 不染色）。
    /// 必须与 `label` 的语义一致：「白色→红」把图标渲染成主题红，「红→白」渲染成白色。
    public var tintTarget: IconTintTarget? {
        switch self {
        case .original: nil
        case .whiteToRed: .themeRed
        case .redToWhite: .white
        }
    }
}

/// 单色染色目标（与 `NSColor` 解耦，便于纯逻辑测试）。
public enum IconTintTarget: Equatable, Sendable {
    case white
    case themeRed

    /// 主题红 #F1383D。
    public static let themeRedComponents: (red: Double, green: Double, blue: Double) =
        (0xF1 / 255.0, 0x38 / 255.0, 0x3D / 255.0)
}

/// 应用自身图标主题（4 套 × 明暗自动切换）。
public enum AppIconTheme: String, Codable, CaseIterable, Sendable {
    case brand
    case classic
    case launchx
    case rocket

    public var label: String {
        switch self {
        case .brand: "Brand"
        case .classic: "Classic"
        case .launchx: "LaunchX"
        case .rocket: "Rocket"
        }
    }
}

/// 玻璃材质强度。
public enum GlassMaterial: String, Codable, CaseIterable, Sendable {
    case off
    case thin
    case regular
    case thick

    public var label: String {
        switch self {
        case .off: "关闭"
        case .thin: "薄"
        case .regular: "适中"
        case .thick: "厚"
        }
    }
}

/// Apple 应用的摆放位置规则。
public enum AppleAppsPosition: String, Codable, CaseIterable, Sendable {
    case beforeApps  // 应用之前
    case afterApps   // 应用之后
    case mixed       // 混排（不特殊处理）

    public var label: String {
        switch self {
        case .beforeApps: "应用之前"
        case .afterApps: "应用之后"
        case .mixed: "混排"
        }
    }
}

/// 文件夹的摆放位置规则。
public enum FolderPosition: String, Codable, CaseIterable, Sendable {
    case beforeApps // 其他应用前
    case afterApps  // 其他应用后

    public var label: String { self == .beforeApps ? "其他应用前" : "其他应用后" }
}

// MARK: - HotKeySpec

/// 全局快捷键描述（Carbon 虚拟键码 + Carbon 修饰键位掩码）。
public struct HotKeySpec: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 未注册哨兵（modifiers 0xFFFF 且 keyCode 0 表示「无快捷键」）。
    public static let none = HotKeySpec(keyCode: 0, modifiers: 0xFFFF)
}

// MARK: - AppSettings

/// 应用设置（对应设置窗 4 个标签页的全部选项）。
public struct AppSettings: Codable, Hashable, Sendable {

    // MARK: 通用 General

    /// 全局快捷键（默认未注册，与原版一致）。
    public var hotKey: HotKeySpec
    /// 触控板捏合手势开关：开 = 四指捏合识别。识别阈值固定为四指档
    ///（识别器基于原始触点数据自建，见 TrackpadTouchMonitor 说明。）
    public var pinchGestureEnabled: Bool
    /// 开机自启动的 UI 镜像（真实来源是 SMAppService；设置面板 onAppear 时对账）。
    public var launchAtLogin: Bool
    /// 显示菜单栏图标。
    public var showMenuBarIcon: Bool
    /// 显示程序坞图标。
    public var showDockIcon: Bool
    /// 程序坞里的 LaunchX 图标是否由本应用固定（用于取消勾选时只移除自己添加的那一个，
    /// 不误删用户手动固定的图标）。
    public var dockIconPinnedByApp: Bool

    // MARK: 应用 Apps

    /// Apple 应用位置。
    public var appleAppsPosition: AppleAppsPosition
    /// 文件夹位置。
    public var folderPosition: FolderPosition
    /// 在搜索中显示隐藏应用。
    public var showHiddenAppsInSearch: Bool

    // MARK: 界面 Interface

    /// 浏览样式。
    public var browsingStyle: BrowsingStyle
    /// 网格密度。
    public var gridDensity: GridDensity
    /// 玻璃材质。
    public var glassMaterial: GlassMaterial
    /// 模糊壁纸（全屏模式）。
    public var blurWallpaper: Bool
    /// 图标染色。
    public var iconColorMode: IconColorMode
    /// 隐藏应用名称。
    public var hideAppNames: Bool
    /// 失焦延时收起。
    public var closeDelay: CloseDelay
    /// 显示位置。
    public var screenPosition: ScreenPosition
    /// 应用自身图标主题。
    public var appIconTheme: AppIconTheme

    // MARK: 其他

    /// 当前生效的排序模式（Custom 为唯一可拖拽模式；默认「最近使用」）。
    public var activeSortKey: SortKey
    /// 可反向排序键（名称/添加日期/最近打开日期/使用次数）的升序开关（关闭 = 降序，最新在前）。
    public var sortAscending: Bool
    /// 是否已完成首次引导。
    public var onboardingCompleted: Bool
    /// 上次浏览到的页（唤起面板时恢复到该页）。
    public var lastViewedPage: Int

    /// 容错解码：**逐字段**回退默认值（旧版备份 / 手工编辑 / 同步工具写坏一个字段时，
    /// 只丢那一个设置，而不是整段设置被重置）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = AppSettings()
        hotKey = c.tolerant(HotKeySpec.self, forKey: .hotKey, default: .none)
        // JSON 键沿用旧名「pinchGesture」：旧档位存的是字符串（off/threeFinger/…/fiveFinger），
        // 简化为开关后 off → 关、其余档位 → 开（统一按四指识别）；新版直接存 Bool。
        if let enabled = c.tolerantOptional(Bool.self, forKey: .pinchGestureEnabled) {
            pinchGestureEnabled = enabled
        } else if let legacyMode = c.tolerantOptional(String.self, forKey: .pinchGestureEnabled) {
            pinchGestureEnabled = legacyMode != "off"
        } else {
            pinchGestureEnabled = true
        }
        launchAtLogin = c.tolerant(Bool.self, forKey: .launchAtLogin, default: false)
        showMenuBarIcon = c.tolerant(Bool.self, forKey: .showMenuBarIcon, default: true)
        showDockIcon = c.tolerant(Bool.self, forKey: .showDockIcon, default: false)
        dockIconPinnedByApp = c.tolerant(Bool.self, forKey: .dockIconPinnedByApp, default: false)
        appleAppsPosition = c.tolerant(AppleAppsPosition.self, forKey: .appleAppsPosition, default: .mixed)
        folderPosition = c.tolerant(FolderPosition.self, forKey: .folderPosition, default: .afterApps)
        showHiddenAppsInSearch = c.tolerant(Bool.self, forKey: .showHiddenAppsInSearch, default: false)
        browsingStyle = c.tolerant(BrowsingStyle.self, forKey: .browsingStyle, default: .paged)
        gridDensity = c.tolerant(GridDensity.self, forKey: .gridDensity, default: .default)
        glassMaterial = c.tolerant(GlassMaterial.self, forKey: .glassMaterial, default: .regular)
        blurWallpaper = c.tolerant(Bool.self, forKey: .blurWallpaper, default: true)
        iconColorMode = c.tolerant(IconColorMode.self, forKey: .iconColorMode, default: .original)
        hideAppNames = c.tolerant(Bool.self, forKey: .hideAppNames, default: false)
        closeDelay = c.tolerant(CloseDelay.self, forKey: .closeDelay, default: .s1)
        screenPosition = c.tolerant(ScreenPosition.self, forKey: .screenPosition, default: .active)
        appIconTheme = c.tolerant(AppIconTheme.self, forKey: .appIconTheme, default: .brand)
        // 默认自由摆放：与拖拽整理（dragAllowed 要求 .custom）保持一致，首次安装即可直接拖动。
        activeSortKey = c.tolerant(SortKey.self, forKey: .activeSortKey, default: .custom)
        sortAscending = c.tolerant(Bool.self, forKey: .sortAscending, default: false)
        onboardingCompleted = c.tolerant(Bool.self, forKey: .onboardingCompleted, default: false)
        lastViewedPage = c.tolerant(Int.self, forKey: .lastViewedPage, default: 0)
    }

    public init(
        hotKey: HotKeySpec = .none,
        pinchGestureEnabled: Bool = true,
        launchAtLogin: Bool = false,
        showMenuBarIcon: Bool = true,
        showDockIcon: Bool = false,
        dockIconPinnedByApp: Bool = false,
        appleAppsPosition: AppleAppsPosition = .mixed,
        folderPosition: FolderPosition = .afterApps,
        showHiddenAppsInSearch: Bool = false,
        browsingStyle: BrowsingStyle = .paged,
        gridDensity: GridDensity = .default,
        glassMaterial: GlassMaterial = .regular,
        blurWallpaper: Bool = true,
        iconColorMode: IconColorMode = .original,
        hideAppNames: Bool = false,
        closeDelay: CloseDelay = .s1,
        screenPosition: ScreenPosition = .active,
        appIconTheme: AppIconTheme = .brand,
        activeSortKey: SortKey = .custom,
        sortAscending: Bool = false,
        onboardingCompleted: Bool = false,
        lastViewedPage: Int = 0
    ) {
        self.hotKey = hotKey
        self.pinchGestureEnabled = pinchGestureEnabled
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
        self.showDockIcon = showDockIcon
        self.dockIconPinnedByApp = dockIconPinnedByApp
        self.appleAppsPosition = appleAppsPosition
        self.folderPosition = folderPosition
        self.showHiddenAppsInSearch = showHiddenAppsInSearch
        self.browsingStyle = browsingStyle
        self.gridDensity = gridDensity
        self.glassMaterial = glassMaterial
        self.blurWallpaper = blurWallpaper
        self.iconColorMode = iconColorMode
        self.hideAppNames = hideAppNames
        self.closeDelay = closeDelay
        self.screenPosition = screenPosition
        self.appIconTheme = appIconTheme
        self.activeSortKey = activeSortKey
        self.sortAscending = sortAscending
        self.onboardingCompleted = onboardingCompleted
        self.lastViewedPage = lastViewedPage
    }

    /// 显式键名表：仅为了让开关沿用旧档位的 JSON 键「pinchGesture」，
    /// 其余键与属性名一致（枚举一开就不能再依赖合成键名）。
    private enum CodingKeys: String, CodingKey {
        case hotKey
        case pinchGestureEnabled = "pinchGesture"
        case launchAtLogin
        case showMenuBarIcon
        case showDockIcon
        case dockIconPinnedByApp
        case appleAppsPosition
        case folderPosition
        case showHiddenAppsInSearch
        case browsingStyle
        case gridDensity
        case glassMaterial
        case blurWallpaper
        case iconColorMode
        case hideAppNames
        case closeDelay
        case screenPosition
        case appIconTheme
        case activeSortKey
        case sortAscending
        case onboardingCompleted
        case lastViewedPage
    }
}

// MARK: - SourceConfig

/// 应用来源目录（对应原版 SourceEntity：path + enabled + type）。
public struct SourceConfig: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// 内置「应用程序」来源：扫描系统标准应用目录（默认唯一来源，对齐 Launchpad 习惯）
        case defaultApps
        case systemApps   // 系统应用目录（旧版默认来源，仅存量数据兼容）
        case userApps     // 用户应用目录（旧版默认来源，仅存量数据兼容）
        case custom       // 自定义
    }

    public var id: UUID
    public var path: String
    public var enabled: Bool
    public var kind: Kind

    public init(id: UUID = UUID(), path: String, enabled: Bool = true, kind: Kind = .custom) {
        self.id = id
        self.path = path
        self.enabled = enabled
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case id, path, enabled, kind }

    /// 容错解码：单个来源的字段写坏（未知 kind / 类型不符）只回退该字段；
    /// 完全没有 path 的来源无法扫描，抛错交由 `Lossy` 按条丢弃（不影响其它来源）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tolerant(UUID.self, forKey: .id, default: UUID())
        path = c.tolerant(String.self, forKey: .path, default: "")
        enabled = c.tolerant(Bool.self, forKey: .enabled, default: true)
        kind = c.tolerant(Kind.self, forKey: .kind, default: .custom)
        guard !path.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .path, in: c, debugDescription: "来源缺少 path"
            )
        }
    }

    /// 内置「应用程序」来源覆盖的系统标准目录（顺序即同 bundleId 去重优先级）。
    public static func defaultAppsDirectories(fileManager: FileManager = .default) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            "/Applications",
            home.appendingPathComponent("Applications").path,
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
        ].filter { fileManager.fileExists(atPath: $0) }
    }

    /// ~/Applications：Chrome/浏览器等工具会把应用快捷方式放进其子文件夹
    /// （如「Chrome Apps.localized」），内置来源对该目录递归下钻子目录。
    public static func userApplicationsPath(fileManager: FileManager = .default) -> String {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
    }

    /// 内置「应用程序」来源（path 仅作展示占位，实际扫描 defaultAppsDirectories）。
    public static func defaultApps() -> SourceConfig {
        SourceConfig(path: "/Applications", enabled: true, kind: .defaultApps)
    }

    /// 默认来源：单个内置「应用程序」。
    public static func defaultSources(fileManager: FileManager = .default) -> [SourceConfig] {
        [defaultApps()]
    }

    /// 存量数据迁移：旧版把 6 个标准目录逐条列为默认来源，收敛为单个内置「应用程序」；
    /// 只有旧版默认条目（systemApps / userApps）参与收敛，用户自添加的目录保持原样。
    public static func migratingLegacyDefaults(_ sources: [SourceConfig]) -> [SourceConfig] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacyDefaults: Set<String> = [
            "/Applications",
            home.appendingPathComponent("Applications").path,
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Cryptexes/App/System/Applications",
        ]
        // 按 kind 判定，不能只看路径：用户可能把 ~/Applications 这类旧默认路径显式添加为
        // 自定义来源（含子目录递归），按路径过滤会在每次启动时把该来源静默吞掉
        let isLegacyDefault: (SourceConfig) -> Bool = { source in
            (source.kind == .systemApps || source.kind == .userApps)
                && legacyDefaults.contains(source.path)
        }
        guard sources.contains(where: isLegacyDefault) else { return sources }
        var migrated = sources.filter { !isLegacyDefault($0) }
        if !migrated.contains(where: { $0.kind == .defaultApps }) {
            migrated.insert(defaultApps(), at: 0)
        }
        return migrated
    }

    /// 扫描规格：目录 + 是否递归下钻子目录。
    /// 内置「应用程序」对齐 Launchpad 只扫各标准目录第一层，但 ~/Applications 例外——
    /// 其子文件夹常由浏览器等工具放置应用快捷方式，递归下钻（深度上限 AppIndex.maxRecursionDepth）；
    /// 自定义目录按「含子目录」递归。
    public struct ScanSpec: Sendable, Hashable {
        public let url: URL
        public let recursive: Bool

        public init(url: URL, recursive: Bool = false) {
            self.url = url
            self.recursive = recursive
        }
    }

    /// 把来源列表展开为扫描规格（内置项展开为标准目录集合、~/Applications 递归，自定义目录递归）。
    public static func scanSpecs(from sources: [SourceConfig], fileManager: FileManager = .default) -> [ScanSpec] {
        var specs: [ScanSpec] = []
        var pathToIndex: [String: Int] = [:]
        func append(_ path: String, recursive: Bool) {
            if let index = pathToIndex[path] {
                // 同一路径重复出现（如内置「应用程序」已覆盖 ~/Applications，用户又把它添加为
                // 自定义来源）：递归标记取并集——显式添加的自定义来源应让该目录含子目录
                if recursive, !specs[index].recursive {
                    specs[index] = ScanSpec(url: specs[index].url, recursive: true)
                }
                return
            }
            pathToIndex[path] = specs.count
            specs.append(ScanSpec(url: URL(fileURLWithPath: path, isDirectory: true), recursive: recursive))
        }
        let userApps = userApplicationsPath(fileManager: fileManager)
        for source in sources where source.enabled {
            if source.kind == .defaultApps {
                for path in defaultAppsDirectories(fileManager: fileManager) {
                    append(path, recursive: path == userApps)
                }
            } else {
                // 旧版默认来源（systemApps / userApps）对应 Launchpad 标准目录，保持只扫第一层
                append(source.path, recursive: source.kind == .custom)
            }
        }
        return specs
    }

    /// 把来源列表展开为实际扫描目录（内置项展开为标准目录集合，其余按路径）。
    public static func scanDirectories(from sources: [SourceConfig], fileManager: FileManager = .default) -> [URL] {
        scanSpecs(from: sources, fileManager: fileManager).map(\.url)
    }

    /// 目录监听集合：扫描覆盖到的所有目录（递归来源展开其子目录，深度与扫描一致），
    /// 保证子目录里新增 / 删除应用也能触发重扫。
    public static func watchDirectories(from sources: [SourceConfig], fileManager: FileManager = .default) -> [URL] {
        var directories: [URL] = []
        for spec in scanSpecs(from: sources, fileManager: fileManager) {
            guard !directories.contains(spec.url) else { continue }
            directories.append(spec.url)
            guard spec.recursive else { continue }
            for sub in AppIndex.subdirectories(under: spec.url, fileManager: fileManager)
            where !directories.contains(sub) {
                directories.append(sub)
            }
        }
        return directories
    }
}
