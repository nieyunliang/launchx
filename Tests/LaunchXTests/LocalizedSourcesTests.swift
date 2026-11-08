import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 本地化显示名

struct LocalizedNameTests {

    /// 构造最小 .app bundle：Contents/Info.plist + Resources 附加文件。
    private func makeBundle(
        name: String,
        infoPlist: [String: Any],
        loctable: [String: [String: Any]]? = nil,
        lprojStrings: [String: [String: String]]? = nil
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXName-\(UUID().uuidString)", isDirectory: true)
        let bundle = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        if let loctable {
            let data = try PropertyListSerialization.data(fromPropertyList: loctable, format: .binary, options: 0)
            try data.write(to: resources.appendingPathComponent("InfoPlist.loctable"))
        }
        if let lprojStrings {
            for (lang, strings) in lprojStrings {
                let lproj = resources.appendingPathComponent("\(lang).lproj", isDirectory: true)
                try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
                try data.write(to: lproj.appendingPathComponent("InfoPlist.strings"))
            }
        }
        return bundle
    }

    @Test func resolvesChineseNameFromLoctable() throws {
        // 新版系统应用形式：本地化集中在 InfoPlist.loctable 单文件
        let bundleURL = try makeBundle(
            name: "Mail",
            infoPlist: ["CFBundleName": "Mail", "CFBundleIdentifier": "test.mail"],
            loctable: [
                "zh_CN": [
                    "CFBundleDisplayName": "邮件",
                    // 混入非字符串值（复数规则嵌套表）验证解析健壮性
                    "SomePluralKey": ["NSStringLocalizedFormatKey": "%#@value@"],
                ],
                "en": ["CFBundleDisplayName": "Mail"],
            ]
        )
        let bundle = try #require(Bundle(url: bundleURL))
        let name = AppIndex.localizedInfoPlistValue(
            for: ["CFBundleDisplayName", "CFBundleName"],
            in: bundle,
            preferences: ["zh-Hans-CN"]
        )
        #expect(name == "邮件")
    }

    @Test func resolvesChineseNameFromLprojStrings() throws {
        // 第三方应用形式：<lang>.lproj/InfoPlist.strings
        let bundleURL = try makeBundle(
            name: "WeChat",
            infoPlist: ["CFBundleName": "WeChat", "CFBundleIdentifier": "test.wechat"],
            lprojStrings: [
                "zh_CN": ["CFBundleDisplayName": "微信"],
                "en": ["CFBundleDisplayName": "WeChat"],
            ]
        )
        let bundle = try #require(Bundle(url: bundleURL))
        let name = AppIndex.localizedInfoPlistValue(
            for: ["CFBundleDisplayName", "CFBundleName"],
            in: bundle,
            preferences: ["zh-Hans-CN"]
        )
        #expect(name == "微信")
    }

    @Test func fallsBackToEnglishWhenPreferenceUnmatched() throws {
        let bundleURL = try makeBundle(
            name: "Only",
            infoPlist: ["CFBundleName": "Only"],
            loctable: ["fr": ["CFBundleDisplayName": "Seulement"]]
        )
        let bundle = try #require(Bundle(url: bundleURL))
        // 偏好语言在本地化集合中无命中 → 回退开发区域（en 不在表里 → nil）
        let name = AppIndex.localizedInfoPlistValue(
            for: ["CFBundleDisplayName", "CFBundleName"],
            in: bundle,
            preferences: ["zh-Hans-CN"]
        )
        #expect(name == nil)
        // resolvedName 完整链回退 Info.plist 原始值
        let resolved = AppIndex.resolvedName(
            infoPlist: ["CFBundleName": "Only"],
            bundle: bundle,
            bundlePath: bundleURL.path
        )
        #expect(resolved == "Only")
    }

    @Test func scanParseUsesResolvedLocalizedName() throws {
        // 端到端：扫描目录 → AppRecord.name 为本地化名
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXScanLoc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bundleURL = try makeBundle(
            name: "Calc",
            infoPlist: ["CFBundleName": "Calc", "CFBundleIdentifier": "test.calc"],
            loctable: ["zh_CN": ["CFBundleDisplayName": "计算器"]]
        )
        // makeBundle 放在临时根目录，这里把 bundle 移进扫描目录
        let target = dir.appendingPathComponent("Calc.app")
        try FileManager.default.moveItem(at: bundleURL, to: target)

        let records = AppIndex.scan(directories: [dir])
        #expect(records.count == 1)
        #expect(records[0].name == "计算器")
    }
}

// MARK: - 来源配置（内置应用程序 + 存量迁移）

struct SourceConfigTests {

    @Test func defaultSourcesIsSingleBuiltIn() {
        let sources = SourceConfig.defaultSources()
        #expect(sources.count == 1)
        #expect(sources[0].kind == .defaultApps)
        #expect(sources[0].enabled)
    }

    @Test func scanDirectoriesExpandsBuiltInAndSkipsDisabled() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXDirs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let custom = dir.appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)

        var sources = SourceConfig.defaultSources()
        sources.append(SourceConfig(path: custom.path, enabled: true, kind: .custom))
        sources.append(SourceConfig(path: "/nonexistent-dir", enabled: true, kind: .custom))
        sources[0].enabled = false

        let directories = SourceConfig.scanDirectories(from: sources)
        // 内置来源被禁用 → 不展开标准目录；仅含启用的自定义目录（不存在的路径保留，扫描端容错）
        #expect(directories.map(\.path) == [custom.path, "/nonexistent-dir"])
    }

    @Test func scanDirectoriesDeduplicates() {
        var sources = [SourceConfig.defaultApps()]
        sources.append(SourceConfig(path: "/Applications", enabled: true, kind: .custom))
        let directories = SourceConfig.scanDirectories(from: sources)
        let paths = directories.map(\.path)
        #expect(paths.filter { $0 == "/Applications" }.count == 1)
    }

    @Test func legacyDefaultSourcesMigrateToSingleBuiltIn() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let legacy: [SourceConfig] = [
            SourceConfig(path: "/Applications", enabled: true, kind: .userApps),
            SourceConfig(path: home.appendingPathComponent("Applications").path, enabled: true, kind: .userApps),
            SourceConfig(path: "/Applications/Utilities", enabled: true, kind: .systemApps),
            SourceConfig(path: "/System/Applications", enabled: true, kind: .systemApps),
            SourceConfig(path: "/System/Applications/Utilities", enabled: true, kind: .systemApps),
            SourceConfig(path: "/System/Cryptexes/App/System/Applications", enabled: true, kind: .systemApps),
        ]
        let migrated = SourceConfig.migratingLegacyDefaults(legacy)
        #expect(migrated.count == 1)
        #expect(migrated[0].kind == .defaultApps)
    }

    @Test func migrationKeepsUserAddedSources() {
        let legacy: [SourceConfig] = [
            SourceConfig(path: "/Applications", enabled: true, kind: .userApps),
            SourceConfig(path: "/Users/someone/MyApps", enabled: true, kind: .custom),
        ]
        let migrated = SourceConfig.migratingLegacyDefaults(legacy)
        #expect(migrated.count == 2)
        #expect(migrated[0].kind == .defaultApps)
        #expect(migrated[1].path == "/Users/someone/MyApps")
    }

    @Test func migrationLeavesCustomOnlySetupUntouched() {
        let custom = [SourceConfig(path: "/Users/someone/MyApps", enabled: true, kind: .custom)]
        let migrated = SourceConfig.migratingLegacyDefaults(custom)
        #expect(migrated == custom)
    }
}
