import AppKit
import Foundation

// MARK: - 错误

public enum FinderActionError: LocalizedError {
    /// AppleScript 执行失败（附原始错误信息）
    case appleScriptFailed(String)
    /// 读取/解析 Dock 配置失败
    case dockExportFailed(String)
    /// 写回 Dock 配置失败
    case dockImportFailed(String)
    /// 应用路径不存在
    case pathMissing(String)

    public var errorDescription: String? {
        switch self {
        case .appleScriptFailed(let message):
            return "Finder 脚本执行失败：\(message)"
        case .dockExportFailed(let message):
            return "读取 Dock 配置失败：\(message)"
        case .dockImportFailed(let message):
            return "写回 Dock 配置失败：\(message)"
        case .pathMissing(let path):
            return "未找到应用：\(path)"
        }
    }
}

// MARK: - Finder 四件套

/// 副作用壳：纯逻辑在 DockPlist，这里只做 NSWorkspace / AppleScript / Process 调用。
@MainActor
public enum FinderActions {

    /// 在 Finder 中显示该应用。
    public static func revealInFinder(_ entry: AppRecord) throws {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw FinderActionError.pathMissing(entry.path)
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    /// 显示简介（首次触发系统「控制 Finder」自动化授权弹窗，错误由调用方 UI 承接弹窗）。
    public static func showGetInfo(_ entry: AppRecord) throws {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw FinderActionError.pathMissing(entry.path)
        }
        let escapedPath = entry.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            open information window of (POSIX file "\(escapedPath)" as alias)
        end tell
        """
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        if let message = (errorInfo as? [String: Any])?[NSAppleScript.errorMessage] as? String {
            throw FinderActionError.appleScriptFailed(message)
        }
    }

    /// 添加到 Dock：defaults export → DockPlist 追加（含去重）→ defaults import → killall Dock 重载。
    /// 任何一步失败都抛错且不破坏原配置（在导出副本上操作）。
    public static func addToDock(_ entry: AppRecord) throws {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw FinderActionError.pathMissing(entry.path)
        }
        _ = try mutateDock {
            try DockPlist.addFileTile(
                toDockPlist: $0,
                appURL: URL(fileURLWithPath: entry.path),
                label: entry.name
            )
        }
    }

    /// 固定到 Dock 前部（`DockPlist.preferredInsertIndex`，默认下标 2 = 第 3 格；
    /// 设置里勾选「显示程序坞图标」时调用）。
    /// 返回调用前该图标是否已在 Dock 上：调用方据此判断是否由本应用「拥有」这个 tile，
    /// 取消勾选时才不会误删用户手动固定的图标。
    @discardableResult
    public static func pinToDockFront(_ appURL: URL, label: String) throws -> Bool {
        var alreadyPinned = false
        _ = try mutateDock { data in
            alreadyPinned = DockPlist.containsFileTile(dockPlist: data, appURL: appURL)
            return try DockPlist.moveFileTileToFront(
                dockPlist: data, appURL: appURL, label: label
            )
        }
        return alreadyPinned
    }

    /// 从 Dock 移除（仅当图标是勾选开关时由本应用固定，避免误删用户手动固定）。
    public static func unpinFromDock(_ appURL: URL) throws {
        _ = try mutateDock {
            try DockPlist.removeFileTile(dockPlist: $0, appURL: appURL)
        }
    }

    /// 在导出的 Dock 配置副本上做变更，有实际变化才写回并重载 Dock。
    /// 返回是否发生了写回（无变化时不打扰 Dock）。
    @discardableResult
    private static func mutateDock(_ transform: (Data) throws -> Data) throws -> Bool {
        let fileManager = FileManager.default
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LaunchXDock-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDir) }
        let exportFile = workDir.appendingPathComponent("dock-export.plist")
        let importFile = workDir.appendingPathComponent("dock-import.plist")

        do {
            _ = try runCommand(URL(fileURLWithPath: "/usr/bin/defaults"),
                               ["export", "com.apple.dock", exportFile.path])
        } catch {
            throw FinderActionError.dockExportFailed("\(error.localizedDescription)")
        }
        guard let exported = try? Data(contentsOf: exportFile) else {
            throw FinderActionError.dockExportFailed("导出文件读取失败")
        }

        let mutated: Data
        do {
            mutated = try transform(exported)
        } catch {
            throw FinderActionError.dockExportFailed(error.localizedDescription)
        }
        // 无实际变化（去重命中 / 已在最前 / 本就不在 Dock）：不写回，也不重载 Dock
        guard mutated != exported else {
            return false
        }

        // `defaults import` 是整体覆盖：先留一份用户 Dock 配置，导入失败可回滚。
        let backupFile = try? backupDockExport(exportFile)

        do {
            try mutated.write(to: importFile, options: .atomic)
            _ = try runCommand(URL(fileURLWithPath: "/usr/bin/defaults"),
                               ["import", "com.apple.dock", importFile.path])
        } catch {
            if let backupFile {
                _ = try? runCommand(URL(fileURLWithPath: "/usr/bin/defaults"),
                                    ["import", "com.apple.dock", backupFile.path])
            }
            throw FinderActionError.dockImportFailed("\(error.localizedDescription)（已尝试恢复原 Dock 配置）")
        }
        // 重载 Dock；失败（如 Dock 未运行）忽略
        _ = try? runCommand(URL(fileURLWithPath: "/usr/bin/killall"), ["Dock"])
        return true
    }

    /// Dock 备份目录（Application Support/LaunchX/DockBackups）。
    static func dockBackupDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LaunchX/DockBackups", isDirectory: true)
    }

    /// 把一次 `defaults export` 的 Dock 配置复制到备份目录，返回备份文件。
    @discardableResult
    static func backupDockExport(_ exportedFile: URL, into directory: URL = dockBackupDirectory()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        // 同一毫秒内多次备份也不能互相覆盖：时间戳后追加短 UUID。
        let unique = UUID().uuidString.prefix(8)
        let destination = directory.appendingPathComponent("dock-backup-\(stamp)-\(unique).plist")
        try FileManager.default.copyItem(at: exportedFile, to: destination)
        pruneDockBackups(in: directory, keeping: 5)
        return destination
    }

    /// 只保留最近 `limit` 份备份（按文件名时间戳排序，字符串比较即可）。
    static func pruneDockBackups(in directory: URL, keeping limit: Int) {
        guard limit >= 0 else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let backups = files
            .filter { $0.lastPathComponent.hasPrefix("dock-backup-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard backups.count > limit else { return }
        for url in backups.prefix(backups.count - limit) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 移到废纸篓（确认弹窗由调用方 UI 负责）。返回实际移除的 URL。
    @discardableResult
    public static func moveToTrash(_ entry: AppRecord) async throws -> [URL] {
        guard FileManager.default.fileExists(atPath: entry.path) else {
            throw FinderActionError.pathMissing(entry.path)
        }
        // SDK 各版本返回可选性不同，显式标注后取字典 values
        let trashed: [URL: URL]? = try await NSWorkspace.shared.recycle(
            [URL(fileURLWithPath: entry.path)]
        )
        return trashed.map { Array($0.values) } ?? []
    }

    // MARK: - 内部

    @discardableResult
    private static func runCommand(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "LaunchX.FinderActions",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(tool.lastPathComponent) \(arguments.joined(separator: " ")) 失败：\(output)"
                ]
            )
        }
        return output
    }
}
