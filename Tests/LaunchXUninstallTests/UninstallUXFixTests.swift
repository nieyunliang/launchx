import AppKit
import Foundation
import Testing
@testable import LaunchXCore
import LaunchXTestSupport

// MARK: - 删除结果校验（P0-2：空字典不等于成功）

@MainActor
struct TrashVerificationTests {

    private let url = URL(fileURLWithPath: "/tmp/LaunchXVerify/App.app")

    @Test func nilDictionaryIsRejected() {
        #expect(throws: FinderActionError.self) {
            try FinderActions.verifiedTrashResult(nil, requested: [url])
        }
    }

    @Test func emptyDictionaryIsRejected() {
        // NSWorkspace.recycle 用「省略字典项」表达未接收，且不保证抛错；
        // 旧实现把它当成功 → 用户看到「已卸载」但应用还在（P0-2）。
        #expect(throws: FinderActionError.self) {
            try FinderActions.verifiedTrashResult([:], requested: [url])
        }
    }

    @Test func partiallyAcceptedIsRejected() {
        #expect(throws: FinderActionError.self) {
            try FinderActions.verifiedTrashResult(
                [url: URL(fileURLWithPath: "/tmp/Trash/App.app")],
                requested: [url, URL(fileURLWithPath: "/tmp/LaunchXVerify/Other.app")]
            )
        }
    }

    @Test func fullyAcceptedReturnsDestinations() throws {
        let destination = URL(fileURLWithPath: "/tmp/Trash/App.app")
        let result = try FinderActions.verifiedTrashResult([url: destination], requested: [url])
        #expect(result[url] == destination)
    }
}

// MARK: - 前置体检（P1-8 / P2-11）

struct UninstallEligibilityTests {

    private func makeApp(
        path: String,
        bundleId: String?,
        isAlias: Bool = false
    ) -> AppRecord {
        AppRecord(
            id: bundleId ?? path,
            name: "Demo",
            bundleName: "Demo",
            bundleId: bundleId,
            version: "1.0",
            path: path,
            category: nil,
            isAlias: isAlias
        )
    }

    @Test func blocksSystemAppBehindSymlink() throws {
        // /Applications 下的系统应用是指向只读系统卷（Cryptex）的符号链接
        // （本机的 /Applications/Safari.app 就是）。只看路径前缀会漏掉这一类，
        // 于是菜单照样给「卸载」→ 缓存被清、本体 SIP 删不掉（P1-8）。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXEligibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: URL(fileURLWithPath: "/System/Applications/Mail.app")
        )
        let app = makeApp(path: link.path, bundleId: "com.apple.Safari")
        #expect(UninstallEligibility.blockReason(for: app) != nil)
    }

    @Test func allowsRemovableAppleAppStoreApps() {
        // 不该因 bundleId 前缀是 com.apple 就一刀切：Keynote/Pages/Xcode 这类
        // 用户可自行删除的 Apple 应用必须仍然能卸载。
        let keynote = makeApp(path: "/Applications/Keynote.app", bundleId: "com.apple.iWork.Keynote")
        #expect(UninstallEligibility.blockReason(for: keynote) == nil)
    }

    @Test func blocksSystemPath() {
        let app = makeApp(path: "/System/Applications/Mail.app", bundleId: "com.apple.mail")
        #expect(UninstallEligibility.blockReason(for: app) != nil)
    }

    @Test func allowsThirdPartyApp() {
        let app = makeApp(path: "/Applications/Demo.app", bundleId: "dev.example.demo")
        #expect(UninstallEligibility.blockReason(for: app) == nil)
    }

    @Test func allowsAliasEntries() {
        // 替身删的是替身文件本身，不受 SIP 影响。
        let alias = makeApp(path: "/Users/someone/Desktop/Safari.app", bundleId: "com.apple.Safari", isAlias: true)
        #expect(UninstallEligibility.blockReason(for: alias) == nil)
    }
}

// MARK: - 删除流程（P0-1 / P0-2 / P0-3 / P0-4 / 4.3 删除顺序）

/// 可注入的回收站桩：记录调用，并按路径策略决定「接收」或「抛错」。
final class UXTrashStub: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[URL]] = []
    private var acceptPolicy: @Sendable (URL) -> Bool = { _ in true }
    private var errorPolicy: @Sendable (URL) -> Error? = { _ in nil }

    var calls: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var calledURLs: [URL] { calls.flatMap { $0 } }

    func setAccept(_ policy: @escaping @Sendable (URL) -> Bool) {
        lock.lock()
        acceptPolicy = policy
        lock.unlock()
    }

    func setError(_ policy: @escaping @Sendable (URL) -> Error?) {
        lock.lock()
        errorPolicy = policy
        lock.unlock()
    }

    /// 同步取策略快照：NSLock 在 async 上下文里不可用（Swift 6 直接报错）。
    private func begin(_ urls: [URL]) -> (@Sendable (URL) -> Bool, @Sendable (URL) -> Error?) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(urls)
        return (acceptPolicy, errorPolicy)
    }

    func handle(_ urls: [URL]) async throws -> [URL: URL] {
        let (accept, errorFor) = begin(urls)
        var moved: [URL: URL] = [:]
        for url in urls {
            if let error = errorFor(url) { throw error }
            if accept(url) {
                moved[url] = URL(fileURLWithPath: "/tmp/LaunchXTrash/\(url.lastPathComponent)")
            }
        }
        return moved
    }
}

/// 等待扫描（含大小回填）真正结束：用模型回调代替轮询超时——
/// 全量套件并行时主 actor 可能被性能测试占用几十秒，轮询超时会把「机器忙」误判成「功能坏」。
@MainActor
private func awaitScanCompletion(_ model: UninstallModel) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        model.onScanFinished = { continuation.resume() }
        model.startScan()
    }
}

/// 等待删除流程结束。blocked / 未启动删除的路径不会回调，调用方不要用它。
@MainActor
private func awaitRemovalCompletion(
    _ model: UninstallModel,
    forceQuit: Bool = false,
    retry: Bool = false
) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        model.onRemovalFinished = { continuation.resume() }
        if retry {
            model.retryFailed()
        } else {
            model.removeChecked(forceQuitRunningApp: forceQuit)
        }
    }
}

@MainActor
struct UninstallRemovalFlowTests {

    private func makeTempDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 假 home：精确归因缓存 + 个人文件（推测项）+ 可统计体积的伪 .app。
    private func makeHome() throws -> URL {
        let home = try makeTempDirectory("LaunchXRemovalHome")
        let cache = home.appendingPathComponent("Library/Caches/com.test.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: cache.appendingPathComponent("payload.bin"))

        let bundle = home.appendingPathComponent("Applications/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 900).write(to: bundle.appendingPathComponent("Demo"))

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("notes".utf8).write(to: home.appendingPathComponent("Documents/Demo 笔记.txt"))
        return home
    }

    private func makeApp(home: URL) -> AppRecord {
        AppRecord(
            id: "com.test.demo",
            name: "Demo",
            bundleName: "Demo",
            bundleId: "com.test.demo",
            version: "2.0",
            path: home.appendingPathComponent("Applications/Demo.app").path,
            category: nil
        )
    }

    private func makeStore() throws -> LayoutStore {
        LayoutStore(directory: try makeTempDirectory("LaunchXRemovalStore"))
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 直接把模型摆到「清单可操作」状态：删除流程测试只关心删除，不应再依赖扫描时序。
    private func stageReady(_ model: UninstallModel, home: URL) {
        let cache = home.appendingPathComponent("Library/Caches/com.test.demo", isDirectory: true)
        var items = [UninstallItem(url: cache, category: .caches, byteSize: 4096)]
        let notes = home.appendingPathComponent("Documents/Demo 笔记.txt")
        if FileManager.default.fileExists(atPath: notes.path) {
            items.append(UninstallItem(url: notes, category: .userFiles, byteSize: 5, isSpeculative: true))
        }
        model.items = items
        model.checkedItemIDs = Set(items.filter { $0.category == .caches }.map(\.id))
        model.appBundleSize = 900
        model.phase = .ready
    }

    private func readyModel(
        home: URL,
        store: LayoutStore,
        app: AppRecord,
        recorder: UXTrashStub,
        appTrash: @escaping UninstallModel.AppTrashHandler,
        quit: @escaping UninstallModel.RunningAppQuitHandler = { _, _ in true },
        isRunning: @escaping (String?) -> Bool = { _ in false }
    ) -> UninstallModel {
        UninstallModel(
            app: app,
            layoutStore: store,
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .granted },
            itemTrashHandler: { urls in try await recorder.handle(urls) },
            appTrashHandler: appTrash,
            runningAppQuitHandler: quit,
            isRunningCheck: isRunning
        )
    }

    @Test func appBodyFailureSkipsRelatedFilesAndKeepsLayout() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try makeStore()
        let app = makeApp(home: home)
        let recorder = UXTrashStub()
        store.updateLayout { $0.apps[app.id] = app }

        let model = readyModel(
            home: home,
            store: store,
            app: app,
            recorder: recorder,
            appTrash: { _ in throw FinderActionError.trashRejected("/Applications/Demo.app") }
        )
        stageReady(model, home: home)
        #expect(!model.selectedItems.isEmpty)

        await awaitRemovalCompletion(model)

        guard case .partialFailure = model.phase else {
            Issue.record("本体删除失败必须进入 partialFailure，实际：\(model.phase)")
            return
        }
        // 删除顺序：本体失败时不得清任何关联文件（避免「缓存没了、应用还在」）
        #expect(recorder.calls.isEmpty)
        #expect(model.report?.appMoved == false)
        #expect(model.report?.failures.isEmpty == false)
        #expect(store.state.layout.apps[app.id] != nil)
        #expect(model.canRetryFailed)
    }

    @Test func appBodySuccessRemovesLayoutAndReportsBytes() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try makeStore()
        let app = makeApp(home: home)
        let recorder = UXTrashStub()
        var uninstalledIDs: [String] = []
        store.updateLayout { $0.apps[app.id] = app }
        let model = readyModel(
            home: home,
            store: store,
            app: app,
            recorder: recorder,
            appTrash: { entry in
                // 真实模拟「本体真的离开原路径」：报告结论需要据此判断还在不在
                let source = URL(fileURLWithPath: entry.path)
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LaunchXTrash-\(UUID().uuidString)-Demo.app")
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            }
        )
        model.onAppUninstalled = { (appID: String) in
            uninstalledIDs.append(appID)
            store.updateLayout { $0.removeApp(id: appID) }
        }

        stageReady(model, home: home)
        await awaitRemovalCompletion(model)

        guard case .done = model.phase else {
            Issue.record("全部成功必须进入 done，实际：\(model.phase)")
            return
        }
        #expect(uninstalledIDs == [app.id])
        #expect(store.state.layout.apps[app.id] == nil)
        #expect(recorder.calledURLs.isEmpty == false)
        #expect((model.report?.trashedBytes ?? 0) > 0)
        #expect(model.report?.appMoved == true)
        // 完成页的「应用本体」结论必须明确
        #expect(model.report?.appConclusionText.contains("废纸篓") == true)
    }

    @Test func politeQuitTimeoutCancelsWithoutDeleting() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try makeStore()
        let app = makeApp(home: home)
        let recorder = UXTrashStub()
        var askedForce: [Bool] = []
        let model = readyModel(
            home: home,
            store: store,
            app: app,
            recorder: recorder,
            appTrash: { entry in URL(fileURLWithPath: entry.path) },
            quit: { _, force in
                askedForce.append(force)
                return false
            },
            isRunning: { _ in true }
        )

        stageReady(model, home: home)
        #expect(model.isAppRunning)
        await awaitRemovalCompletion(model)

        // 礼貌退出失败：整单取消，不静默强杀、不删任何文件（P0-4）
        #expect(askedForce == [false])
        #expect(model.phase == .ready)
        #expect(model.lastActionError?.contains("仍在运行") == true)
        #expect(recorder.calls.isEmpty)
    }

    @Test func forcedQuitIsPassedThroughWhenUserAsks() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try makeStore()
        let app = makeApp(home: home)
        let recorder = UXTrashStub()
        var askedForce: [Bool] = []
        let model = readyModel(
            home: home,
            store: store,
            app: app,
            recorder: recorder,
            appTrash: { entry in URL(fileURLWithPath: entry.path) },
            quit: { _, force in
                askedForce.append(force)
                return true
            },
            isRunning: { _ in true }
        )

        stageReady(model, home: home)
        await awaitRemovalCompletion(model, forceQuit: true)
        #expect(askedForce == [true])
        if case .done = model.phase {} else {
            Issue.record("强制退出后应继续删除，实际：\(model.phase)")
        }
    }

    @Test func retryFailedRemovesLeftoverItems() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try makeStore()
        let app = makeApp(home: home)
        let recorder = UXTrashStub()
        // 第一次：拒绝所有关联文件（回收站返回空字典 = 未接收）
        recorder.setAccept { _ in false }
        let model = readyModel(
            home: home,
            store: store,
            app: app,
            recorder: recorder,
            appTrash: { entry in URL(fileURLWithPath: "/tmp/LaunchXTrash/\(URL(fileURLWithPath: entry.path).lastPathComponent)") }
        )

        stageReady(model, home: home)
        await awaitRemovalCompletion(model)
        guard case .partialFailure = model.phase else {
            Issue.record("关联文件被拒收必须进入 partialFailure，实际：\(model.phase)")
            return
        }
        #expect(model.canRetryFailed)

        // 第二次：回收站接收
        recorder.setAccept { _ in true }
        await awaitRemovalCompletion(model, retry: true)
        if case .done = model.phase {} else {
            Issue.record("重试应把剩余项删完，实际：\(model.phase)")
        }
        #expect(model.report?.appMoved == true)
    }

    @Test func blockedAppNeverStartsRemoval() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try makeStore()
        let recorder = UXTrashStub()
        let safari = AppRecord(
            id: "com.apple.Mail",
            name: "Mail",
            bundleName: "Mail",
            bundleId: "com.apple.mail",
            version: "18.0",
            path: "/System/Applications/Mail.app",
            category: nil
        )
        let model = readyModel(
            home: home,
            store: store,
            app: safari,
            recorder: recorder,
            appTrash: { _ in throw FinderActionError.trashRejected("/System/Applications/Mail.app") }
        )
        model.phase = .ready
        model.removeChecked()

        #expect(model.phase == .ready)
        #expect(model.lastActionError != nil)
        #expect(model.removalBlockReason != nil)
        #expect(recorder.calls.isEmpty)
    }
}
// MARK: - 扫描硬化（P2-3 / P2-4 / P2-5 / P2-7 / P1-4）

struct UninstallScannerHardeningTests {

    private func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXScanHard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeApp(
        name: String = "Demo",
        bundleName: String = "Demo",
        bundleId: String? = "com.test.demo",
        path: String = "/Applications/Demo.app"
    ) -> AppRecord {
        AppRecord(
            id: bundleId ?? path,
            name: name,
            bundleName: bundleName,
            bundleId: bundleId,
            version: "1.0",
            path: path,
            category: nil
        )
    }

    @Test func bundleNameMatchesAfterRename() throws {
        // 应用在 LaunchX 里被改名后，缓存目录仍是按原始 CFBundleName 命名的。
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/OriginalName", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let app = makeApp(name: "改过的名字", bundleName: "OriginalName", bundleId: "com.test.other")
        let items = UninstallScanner.scanPaths(app: app, home: home)
        #expect(items.contains { $0.category == .caches && $0.url.lastPathComponent == "OriginalName" })
    }

    @Test func parentDirectorySuppressesChildItems() throws {
        // Containers 容器与其内的 containermanagerd 元数据 plist 曾被同时列出，
        // 删除时子项必然跳过（P2-5）。父目录入选后子项必须被收敛掉。
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let container = home.appendingPathComponent("Library/Containers/com.test.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data("x".utf8).write(
            to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        )

        let items = UninstallScanner.scanPaths(app: makeApp(), home: home)
        #expect(items.contains { $0.category == .containers })
        #expect(!items.contains { $0.url.lastPathComponent == ".com.apple.containermanagerd.metadata.plist" })
        #expect(!items.contains { $0.category == .sandbox })
    }

    @Test func scanPathsLeavesSizesUnsetAndScanFillsThem() throws {
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/com.test.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 12).write(to: cache.appendingPathComponent("payload.bin"))

        let paths = UninstallScanner.scanPaths(app: makeApp(), home: home)
        let cachePath = paths.first { $0.category == .caches }
        #expect(cachePath?.byteSize == nil)

        let sized = UninstallScanner.scan(app: makeApp(), home: home)
        let sizedCache = sized.first { $0.category == .caches }
        #expect(sizedCache?.byteSize == 12)
    }

    @Test func userFilesSkipApplicationBundles() throws {
        // 文档里同名的 .app 是另一个完整应用副本，删掉它远超「清理关联文件」预期（P2-7）。
        let home = try makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents/Demo.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: home.appendingPathComponent("Documents/Demo 笔记.txt"))

        let items = UninstallScanner.scanPaths(app: makeApp(), home: home)
        let userFiles = items.filter { $0.category == .userFiles }
        #expect(userFiles.contains { $0.url.lastPathComponent == "Demo 笔记.txt" })
        #expect(!userFiles.contains { $0.url.lastPathComponent == "Demo.app" })
    }

    @Test func categoryDisplayNamesMatchActualContent() {
        // P2-4：「其它文件」实际是 Preferences plist，「应用文件」是日志与数据。
        #expect(UninstallCategory.otherFiles.displayName == "偏好设置")
        #expect(UninstallCategory.applicationFiles.displayName == "日志与数据")
    }
}

// MARK: - 勾选语义与空间账本（P1-1 / P1-6）

@MainActor
struct UninstallSelectionAndLedgerTests {

    private func makeTempDirectory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHome() throws -> URL {
        let home = try makeTempDirectory("LaunchXLedgerHome")
        let exactCache = home.appendingPathComponent("Library/Caches/com.test.demo", isDirectory: true)
        try FileManager.default.createDirectory(at: exactCache, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 1000).write(to: exactCache.appendingPathComponent("payload.bin"))
        // 按显示名命名的缓存 → 推测项
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/Demo", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bundle = home.appendingPathComponent("Applications/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 512).write(to: bundle.appendingPathComponent("Demo"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("notes".utf8).write(to: home.appendingPathComponent("Documents/Demo 笔记.txt"))
        return home
    }

    private func makeApp(home: URL) -> AppRecord {
        AppRecord(
            id: "com.test.demo",
            name: "Demo",
            bundleName: "Demo",
            bundleId: "com.test.demo",
            version: "2.0",
            path: home.appendingPathComponent("Applications/Demo.app").path,
            category: nil
        )
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func preparedModel() async throws -> (UninstallModel, AppRecord, URL) {
        let home = try makeHome()
        let store = LayoutStore(directory: try makeTempDirectory("LaunchXLedgerStore"))
        let app = makeApp(home: home)
        let model = UninstallModel(
            app: app,
            layoutStore: store,
            homeDirectory: home,
            fullDiskAccessCheck: { _ in .granted },
            isRunningCheck: { _ in false }
        )
        await awaitScanCompletion(model)
        return (model, app, home)
    }

    @Test func groupSelectionSeparatesSpeculativeItems() async throws {
        let (model, _, home) = try await preparedModel()
        defer { try? FileManager.default.removeItem(at: home) }

        let selection = model.groupSelection(.caches)
        #expect(selection.exactCount == 1)
        #expect(selection.speculativeCount == 1)
        #expect(selection.selectedCount == 1)  // 默认只勾精确项

        model.selectAll(in: .caches)
        #expect(model.groupSelection(.caches).allSelected == false)
        #expect(model.groupSelection(.caches).hasUnselectedSpeculative)

        model.selectAll(in: .caches, includeSpeculative: true)
        #expect(model.groupSelection(.caches).allSelected)

        model.deselectAll(in: .caches)
        #expect(model.groupSelection(.caches).selectedCount == 0)
    }

    @Test func ledgerSumsAppBundleAndSelectedItems() async throws {
        let (model, app, home) = try await preparedModel()
        defer { try? FileManager.default.removeItem(at: home) }

        let appSize = try #require(UninstallScanner.size(of: URL(fileURLWithPath: app.path)))
        #expect(model.appBundleSize == appSize)

        model.selectAll(in: .caches)
        let expectedSelected = model.selectedItems.compactMap(\.byteSize).reduce(0, +)
        #expect(model.selectedBytes == expectedSelected)
        // 账本 = 应用本体 + 已选关联文件（P1-1）
        #expect(model.plannedTrashBytes == appSize + expectedSelected)
    }

    @Test func riskSummaryCountsUnselectedRiskItems() async throws {
        let (model, _, home) = try await preparedModel()
        defer { try? FileManager.default.removeItem(at: home) }

        // 默认勾选不含个人文件与名称推测项
        let summary = model.riskSummary
        #expect(summary.userFiles == 1)
        #expect(summary.otherSpeculative >= 1)
        #expect(summary.total >= 2)
        #expect(summary.text.contains("高风险未选"))
        #expect(model.riskSummaryJumpCategory == .userFiles)
    }
}

// MARK: - 入口判定与模型层收尾（P1-8 / P2-9 / P2-11）

@MainActor
struct UninstallEntryGuardTests {

    private func makeModel() -> (LayoutStore, LaunchpadModel) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXEntryGuard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LayoutStore(directory: dir)
        return (store, LaunchpadModel(store: store))
    }

    private func app(id: String, bundleId: String, path: String) -> AppRecord {
        AppRecord(
            id: id,
            name: id,
            bundleName: id,
            bundleId: bundleId,
            version: "1.0",
            path: path,
            category: nil
        )
    }

    @Test func systemAppHasNoUninstallEntry() {
        let (store, model) = makeModel()
        let mail = app(id: "com.apple.mail", bundleId: "com.apple.mail", path: "/System/Applications/Mail.app")
        store.updateLayout { $0.apps[mail.id] = mail }
        #expect(model.uninstallBlockReason(appID: mail.id) != nil)
    }

    @Test func thirdPartyAppCanBeUninstalled() {
        let (store, model) = makeModel()
        let demo = app(id: "dev.example.demo", bundleId: "dev.example.demo", path: "/Applications/Demo.app")
        store.updateLayout { $0.apps[demo.id] = demo }
        #expect(model.uninstallBlockReason(appID: demo.id) == nil)
    }

    @Test func moveToTrashBlocksSystemApp() async {
        let (store, model) = makeModel()
        let mail = app(id: "com.apple.mail", bundleId: "com.apple.mail", path: "/System/Applications/Mail.app")
        store.updateLayout { $0.apps[mail.id] = mail }
        let outcome = await model.moveToTrash(appID: mail.id)
        guard case let .blocked(reason) = outcome else {
            Issue.record("系统应用必须被前置拦截，实际：\(outcome)")
            return
        }
        #expect(reason.contains("SIP") || reason.contains("系统"))
        ToastManager.shared.dismissAll()
    }

    @Test func appDidGetUninstalledPrunesSelection() {
        let (store, model) = makeModel()
        let a = app(id: "dev.a", bundleId: "dev.a", path: "/Applications/A.app")
        let b = app(id: "dev.b", bundleId: "dev.b", path: "/Applications/B.app")
        store.updateLayout { layout in
            layout.apps[a.id] = a
            layout.apps[b.id] = b
            layout.pages = [PageRecord(items: [.app(id: a.id), .app(id: b.id)])]
        }
        model.toggleSelection(appID: a.id)
        model.toggleSelection(appID: b.id)

        model.appDidGetUninstalled(appID: a.id)

        #expect(store.state.layout.apps[a.id] == nil)
        #expect(!model.selectedAppIDs.contains(a.id))
        #expect(model.selectedAppIDs.contains(b.id))
        ToastManager.shared.dismissAll()
    }
}

