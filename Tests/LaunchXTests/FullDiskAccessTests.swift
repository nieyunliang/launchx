import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 完全磁盘访问检测（审查 findings-c F-03 回归）

/// 旧探针 `~/Library/Saved Application State`、`~/Library/Containers` 未受 TCC 保护，
/// 未授权 FDA 也能列出，导致 `isGranted()` 恒为 true、权限引导成为死代码。
/// 这里锁定新契约：只认真受保护的目录，并区分「拒绝」与「目录不存在」。
struct FullDiskAccessStatusTests {

    private let home = URL(fileURLWithPath: "/Users/launchx-tester", isDirectory: true)

    private func permissionError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    }

    private func missingError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
    }

    @Test func grantedWhenAProtectedDirectoryIsListable() {
        let status = FullDiskAccess.status(home: home) { path in
            if path.hasSuffix("Library/Safari") { return ["History.db"] }
            throw self.permissionError()
        }
        #expect(status == .granted)
    }

    @Test func deniedWhenProtectedDirectoriesExistButCannotBeRead() {
        var probed: [String] = []
        let status = FullDiskAccess.status(home: home) { path in
            probed.append(path)
            throw self.permissionError()
        }
        #expect(status == .denied)
        // 探测路径必须落在真受 TCC 保护的目录上
        #expect(probed.contains { $0.hasSuffix("Library/Safari") })
        #expect(probed.contains { $0.hasSuffix("Library/Mail") })
    }

    @Test func unknownWhenNoProbePathExists() {
        // 全新用户没有 Safari/Mail/Messages 等目录：不能据此阻断卸载
        let status = FullDiskAccess.status(home: home) { _ in
            throw self.missingError()
        }
        #expect(status == .unknown)
    }

    @Test func missingDirectoryIsSkippedInsteadOfCountingAsDenied() {
        var calls = 0
        let status = FullDiskAccess.status(home: home) { _ in
            calls += 1
            // 前两个目录不存在 → 继续探测；第三个存在但读取被拒 → denied
            if calls <= 2 { throw self.missingError() }
            throw self.permissionError()
        }
        #expect(status == .denied)
        #expect(calls >= 3)
    }

    @Test func containersAndSavedStateAreNotUsedAsProbes() {
        // 这两个目录无需 FDA 即可列出，不能作为授权证据
        #expect(!FullDiskAccess.protectedRelativePaths.contains("Library/Containers"))
        #expect(!FullDiskAccess.protectedRelativePaths.contains("Library/Saved Application State"))
    }
}

// MARK: - 无 FDA 时卸载器仍可用（非阻断横幅）

@MainActor
struct UninstallLimitedAccessTests {

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXUninstallAccess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/test.app.bundle", isDirectory: true),
            withIntermediateDirectories: true
        )
        return home
    }

    private func makeStore() -> LayoutStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXAccessStore-\(UUID().uuidString)", isDirectory: true)
        return LayoutStore(directory: dir)
    }

    private func makeApp() -> AppRecord {
        AppRecord(
            id: "test.app.bundle",
            name: "TestApp",
            bundleName: "TestApp",
            bundleId: "test.app.bundle",
            version: "1.0",
            path: "/Applications/TestApp.app",
            category: nil
        )
    }

    private func waitForReady(_ model: UninstallModel) async throws {
        for _ in 0..<80 where model.phase != .ready {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test func deniedAccessStillScansAndShowsBanner() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = UninstallModel(
            app: makeApp(),
            layoutStore: makeStore(),
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .denied }
        )

        model.startScan()
        try await waitForReady(model)

        // 关键回归：缺 FDA 不再 return，扫描照常完成
        #expect(model.phase == .ready)
        #expect(model.needsFullDiskAccess)
        #expect(model.fullDiskAccessStatus == .denied)
        #expect(!model.items.isEmpty)
    }

    @Test func grantedAccessHidesBanner() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = UninstallModel(
            app: makeApp(),
            layoutStore: makeStore(),
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .granted }
        )

        model.startScan()
        try await waitForReady(model)

        #expect(model.phase == .ready)
        #expect(!model.needsFullDiskAccess)
        #expect(model.fullDiskAccessStatus == .granted)
    }

    @Test func bannerHiddenOnCompletionPages() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = UninstallModel(
            app: makeApp(),
            layoutStore: makeStore(),
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .denied }
        )
        model.needsFullDiskAccess = true

        model.phase = .ready
        #expect(model.showsAccessBanner)
        model.phase = .done(trashed: 0)
        #expect(!model.showsAccessBanner)
        model.phase = .partialFailure(trashed: 0, failures: ["x"])
        #expect(!model.showsAccessBanner)
    }

    @Test func resetCancelsInFlightScan() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = UninstallModel(
            app: makeApp(),
            layoutStore: makeStore(),
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .denied }
        )

        model.startScan()
        model.reset()
        // 给被取消的扫描足够时间；旧结果必须被代数令牌丢弃
        try await Task.sleep(for: .milliseconds(400))

        #expect(model.phase == .idle)
        #expect(model.items.isEmpty)
        #expect(!model.needsFullDiskAccess)
    }

    @Test func rescanClearsPreviousListImmediately() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = UninstallModel(
            app: makeApp(),
            layoutStore: makeStore(),
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .granted }
        )

        model.startScan()
        try await waitForReady(model)
        #expect(!model.items.isEmpty)

        model.startScan()
        // 重新扫描期间不能继续显示上一次的清单/计数
        #expect(model.items.isEmpty)
        #expect(model.checkedItemIDs.isEmpty)
        #expect(model.phase == .scanning)
        try await waitForReady(model)
    }

    @Test func resetClearsAccessStatus() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = UninstallModel(
            app: makeApp(),
            layoutStore: makeStore(),
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .denied }
        )
        model.startScan()
        try await waitForReady(model)
        #expect(model.needsFullDiskAccess)

        model.reset()
        #expect(!model.needsFullDiskAccess)
        #expect(model.fullDiskAccessStatus == .unknown)
    }
}
