import Foundation
import Testing
@testable import LaunchXCore

// MARK: - Dock plist 变更

struct DockPlistTests {

    private func makeDockPlist(_ apps: [(label: String, path: String)]) throws -> Data {
        let tiles: [[String: Any]] = apps.map { app in
            [
                "tile-type": "file-tile",
                "tile-data": [
                    "file-data": [
                        "_CFURLString":
                            URL(fileURLWithPath: app.path, isDirectory: true).absoluteString,
                        "_CFURLStringType": 15,
                    ] as [String: Any],
                    "file-label": app.label,
                    "file-type": 32,
                ] as [String: Any],
            ]
        }
        return try PropertyListSerialization.data(
            fromPropertyList: ["persistent-apps": tiles], format: .xml, options: 0
        )
    }

    private func labels(in data: Data) throws -> [String] {
        let root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let apps = root?["persistent-apps"] as? [[String: Any]] ?? []
        return apps.map { app in
            (app["tile-data"] as? [String: Any])?["file-label"] as? String ?? "?"
        }
    }

    @Test func moveInsertsAbsentTileAtPreferredIndex() throws {
        let data = try makeDockPlist([
            ("System", "/System/Applications/Apps.app"),
            ("Alpha", "/Applications/Alpha.app"),
            ("Gamma", "/Applications/Gamma.app"),
        ])
        let mutated = try DockPlist.moveFileTileToFront(
            dockPlist: data,
            appURL: URL(fileURLWithPath: "/Applications/Beta.app"),
            label: "Beta"
        )
        #expect(try labels(in: mutated) == ["System", "Alpha", "Beta", "Gamma"])
    }

    @Test func moveMovesExistingTileWithoutDuplicating() throws {
        let data = try makeDockPlist([
            ("System", "/System/Applications/Apps.app"),
            ("Beta", "/Applications/Beta.app"),
            ("Alpha", "/Applications/Alpha.app"),
            ("Gamma", "/Applications/Gamma.app"),
        ])
        let mutated = try DockPlist.moveFileTileToFront(
            dockPlist: data,
            appURL: URL(fileURLWithPath: "/Applications/Beta.app"),
            label: "Beta"
        )
        #expect(try labels(in: mutated) == ["System", "Alpha", "Beta", "Gamma"])
    }

    @Test func moveIsNoOpWhenAlreadyAtPreferredIndex() throws {
        let data = try makeDockPlist([
            ("System", "/System/Applications/Apps.app"),
            ("Alpha", "/Applications/Alpha.app"),
            ("Beta", "/Applications/Beta.app"),
            ("Gamma", "/Applications/Gamma.app"),
        ])
        let mutated = try DockPlist.moveFileTileToFront(
            dockPlist: data,
            appURL: URL(fileURLWithPath: "/Applications/Beta.app"),
            label: "Beta"
        )
        // 无变化：调用方据此跳过 defaults import 与 killall Dock
        #expect(mutated == data)
    }

    @Test func moveClampsToEndWhenDockIsShort() throws {
        let data = try makeDockPlist([
            ("Alpha", "/Applications/Alpha.app"),
        ])
        let mutated = try DockPlist.moveFileTileToFront(
            dockPlist: data,
            appURL: URL(fileURLWithPath: "/Applications/Beta.app"),
            label: "Beta"
        )
        #expect(try labels(in: mutated) == ["Alpha", "Beta"])
    }

    @Test func moveToFrontKeepsOtherKeys() throws {
        let source = try PropertyListSerialization.data(
            fromPropertyList: [
                "persistent-apps": [],
                "orientation": "bottom",
            ] as [String: Any],
            format: .xml,
            options: 0
        )
        let mutated = try DockPlist.moveFileTileToFront(
            dockPlist: source,
            appURL: URL(fileURLWithPath: "/Applications/Beta.app"),
            label: "Beta"
        )
        let root = try PropertyListSerialization.propertyList(
            from: mutated, options: [], format: nil
        ) as? [String: Any]
        #expect(root?["orientation"] as? String == "bottom")
        #expect(try labels(in: mutated) == ["Beta"])
    }

    @Test func removeFileTileDropsOnlyMatchingTile() throws {
        let data = try makeDockPlist([
            ("Beta", "/Applications/Beta.app"),
            ("Alpha", "/Applications/Alpha.app"),
        ])
        let mutated = try DockPlist.removeFileTile(
            dockPlist: data,
            appURL: URL(fileURLWithPath: "/Applications/Beta.app")
        )
        #expect(try labels(in: mutated) == ["Alpha"])
    }

    @Test func removeFileTileIsNoOpWhenAbsent() throws {
        let data = try makeDockPlist([
            ("Alpha", "/Applications/Alpha.app"),
        ])
        let mutated = try DockPlist.removeFileTile(
            dockPlist: data,
            appURL: URL(fileURLWithPath: "/Applications/Beta.app")
        )
        #expect(mutated == data)
    }

    @Test func malformedPlistThrows() {
        let data = Data("not a plist".utf8)
        #expect(throws: DockPlistError.self) {
            try DockPlist.moveFileTileToFront(
                dockPlist: data,
                appURL: URL(fileURLWithPath: "/Applications/Beta.app"),
                label: "Beta"
            )
        }
    }

    @Test @MainActor func dockBackupCopiesPlistsAndPrunesOldSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchX-DockBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let export = directory.appendingPathComponent("dock-export.plist")
        try Data("<plist/>".utf8).write(to: export)

        let first = try FinderActions.backupDockExport(export, into: directory)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.contents(atPath: first.path) == Data("<plist/>".utf8))

        // 同秒内多次保存也不能互相覆盖（时间戳含毫秒）。
        for _ in 0..<6 { _ = try FinderActions.backupDockExport(export, into: directory) }
        FinderActions.pruneDockBackups(in: directory, keeping: 3)

        let backups = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("dock-backup-") }
        #expect(backups.count == 3)
    }
}
