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

/// 触控板捏合手势档位（原版三档 + 四指精确档）。
/// 触发为双向：张开手指打开窗口、捏合手指收起窗口（与系统 Launchpad 习惯一致）。
public enum PinchGesture: String, Codable, CaseIterable, Sendable {
    case off
    case threeFinger   // 三指捏合
    case fourFinger    // 四指捏合
    case fourFiveFinger // 四或五指捏合
    case fiveFinger    // 五指捏合

    public var label: String {
        switch self {
        case .off: "关闭"
        case .threeFinger: "三指捏合"
        case .fourFinger: "四指捏合"
        case .fourFiveFinger: "四或五指捏合"
        case .fiveFinger: "五指捏合"
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
    /// 触控板捏合手势。
    public var pinchGesture: PinchGesture
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

    /// 容错解码：缺失键回退默认值（兼容旧版备份）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = AppSettings()
        hotKey = try c.decodeIfPresent(HotKeySpec.self, forKey: .hotKey) ?? .none
        pinchGesture = try c.decodeIfPresent(PinchGesture.self, forKey: .pinchGesture) ?? .off
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        dockIconPinnedByApp = try c.decodeIfPresent(Bool.self, forKey: .dockIconPinnedByApp) ?? false
        appleAppsPosition = try c.decodeIfPresent(AppleAppsPosition.self, forKey: .appleAppsPosition) ?? .mixed
        folderPosition = try c.decodeIfPresent(FolderPosition.self, forKey: .folderPosition) ?? .afterApps
        showHiddenAppsInSearch = try c.decodeIfPresent(Bool.self, forKey: .showHiddenAppsInSearch) ?? false
        browsingStyle = try c.decodeIfPresent(BrowsingStyle.self, forKey: .browsingStyle) ?? .paged
        gridDensity = try c.decodeIfPresent(GridDensity.self, forKey: .gridDensity) ?? .default
        glassMaterial = try c.decodeIfPresent(GlassMaterial.self, forKey: .glassMaterial) ?? .regular
        blurWallpaper = try c.decodeIfPresent(Bool.self, forKey: .blurWallpaper) ?? true
        iconColorMode = try c.decodeIfPresent(IconColorMode.self, forKey: .iconColorMode) ?? .original
        hideAppNames = try c.decodeIfPresent(Bool.self, forKey: .hideAppNames) ?? false
        closeDelay = try c.decodeIfPresent(CloseDelay.self, forKey: .closeDelay) ?? .s1
        screenPosition = try c.decodeIfPresent(ScreenPosition.self, forKey: .screenPosition) ?? .active
        appIconTheme = try c.decodeIfPresent(AppIconTheme.self, forKey: .appIconTheme) ?? .brand
        // 默认自由摆放：与拖拽整理（dragAllowed 要求 .custom）保持一致，首次安装即可直接拖动。
        activeSortKey = try c.decodeIfPresent(SortKey.self, forKey: .activeSortKey) ?? .custom
        sortAscending = try c.decodeIfPresent(Bool.self, forKey: .sortAscending) ?? false
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        lastViewedPage = try c.decodeIfPresent(Int.self, forKey: .lastViewedPage) ?? 0
    }

    public init(
        hotKey: HotKeySpec = .none,
        pinchGesture: PinchGesture = .off,
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
        self.pinchGesture = pinchGesture
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

    /// 内置「应用程序」来源（path 仅作展示占位，实际扫描 defaultAppsDirectories）。
    public static func defaultApps() -> SourceConfig {
        SourceConfig(path: "/Applications", enabled: true, kind: .defaultApps)
    }

    /// 默认来源：单个内置「应用程序」。
    public static func defaultSources(fileManager: FileManager = .default) -> [SourceConfig] {
        [defaultApps()]
    }

    /// 存量数据迁移：旧版把 6 个标准目录逐条列为默认来源，收敛为单个内置「应用程序」；
    /// 用户自添加的目录保持原样。
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
        guard sources.contains(where: { legacyDefaults.contains($0.path) }) else { return sources }
        var migrated = sources.filter { !legacyDefaults.contains($0.path) }
        if !migrated.contains(where: { $0.kind == .defaultApps }) {
            migrated.insert(defaultApps(), at: 0)
        }
        return migrated
    }

    /// 把来源列表展开为实际扫描目录（内置项展开为标准目录集合，其余按路径）。
    public static func scanDirectories(from sources: [SourceConfig], fileManager: FileManager = .default) -> [URL] {
        var directories: [URL] = []
        for source in sources where source.enabled {
            let paths: [String]
            if source.kind == .defaultApps {
                paths = defaultAppsDirectories(fileManager: fileManager)
            } else {
                paths = [source.path]
            }
            for path in paths {
                let url = URL(fileURLWithPath: path, isDirectory: true)
                if !directories.contains(url) { directories.append(url) }
            }
        }
        return directories
    }
}
