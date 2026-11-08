import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 卸载扫描大小统计（审查 P2-2 回归）

/// 不可读目录（TCC/权限拒绝）曾被 `fileManager.enumerator` 静默跳过并统计成
/// 0 字节，删除清单里显示「0 字节」会误导用户。这里锁定：不可读 = nil，空目录 = 0。
struct UninstallSizeTests {

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXSizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func emptyDirectoryIsZeroBytes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        #expect(UninstallScanner.size(of: empty) == 0)
    }

    @Test func unreadableDirectoryIsNilNotZero() throws {
        let root = try makeTempDirectory()
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: root)
        }

        #expect(UninstallScanner.size(of: locked) == nil)
    }

    @Test func regularFileReportsByteCount() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 1_234).write(to: file)

        #expect(UninstallScanner.size(of: file) == 1_234)
    }

    @Test func missingPathIsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXMissing-\(UUID().uuidString)")
        #expect(UninstallScanner.size(of: missing) == nil)
    }
}
