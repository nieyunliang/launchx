import AppKit
import Foundation
import Observation

/// 卸载入口前置体检：哪些应用根本不该给「卸载」入口。
///
/// 入口（右键菜单）与卸载器内部共用同一判定，避免两处规则漂移：
/// 评审 P1-8 指出 /Applications 下的 Apple 应用（如 Safari，com.apple.Safari）
/// 不走 /System 分支，菜单照样给「卸载」，结果缓存被清干净、本体却因 SIP 删不掉。
public enum UninstallEligibility {

    /// 不能卸载的原因；nil = 可以卸载。
    ///
    /// 只拦「注定失败且会先造成数据损失」的情形。应用路径已不存在不算拦截：
    /// 本体没了仍然可以清理关联文件（那是卸载器的主要用途之一）。
    public static func blockReason(for app: AppRecord) -> String? {
        if app.isAlias { return nil }
        let url = URL(fileURLWithPath: app.path)
        // 系统应用有两种存在形式：直接位于 /System/... ；或 /Applications 下指向
        // 只读系统卷（Cryptex）的符号链接（本例机上的 /Applications/Safari.app 就是）。
        // 只看路径前缀会把后者漏掉——那正是「缓存被清、本体删不掉」的来源（P1-8）。
        let resolved = url.resolvingSymlinksInPath()
        if app.path.hasPrefix("/System/") || resolved.path.hasPrefix("/System/") {
            return "系统应用受系统完整性保护（SIP），无法卸载"
        }
        if let values = try? resolved.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return "应用位于只读磁盘，无法卸载"
        }
        if isRestricted(path: app.path) || isRestricted(path: resolved.path) {
            return "应用受系统保护（restricted），无法卸载"
        }
        return nil
    }

    /// 系统标记位（sys/stat.h）：SF_RESTRICTED | SF_IMMUTABLE | UF_IMMUTABLE。
    /// SIP 保护的应用/文件即使不在 /System 下也会带这些标记，禁止移出。
    private static let protectedStatFlags: UInt32 = 0x0008_0000 | 0x0002_0000 | 0x0000_0002

    private static func isRestricted(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & protectedStatFlags != 0
    }
}

/// 卸载器视图模型。
@MainActor
@Observable
public final class UninstallModel {

    public enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case removing(progressDone: Int, progressTotal: Int)
        /// 全部成功（应用本体已移废纸篓 + 关联文件全部回收）。
        case done(trashed: Int)
        /// 部分失败：至少一项没能删除，需要把失败项与原因如实展示给用户。
        case partialFailure(trashed: Int, failures: [String])
    }

    /// 单项失败的结构化信息（失败页按原因分组，评审 P0-3）。
    public struct RemovalFailure: Hashable, Sendable {
        public enum Reason: String, CaseIterable, Equatable, Sendable {
            case noPermission = "没有权限"
            case inUse = "文件正被占用"
            case protectedPath = "受系统保护"
            case trashRejected = "系统未接收"
            case other = "其它原因"
        }

        public let path: String
        public let message: String
        public let reason: Reason

        public init(path: String, message: String) {
            self.path = path
            self.message = message
            self.reason = Self.classify(message)
        }

        /// 按错误文案归类。系统错误本地化文案不稳定，只做粗分类：
        /// 目的是让失败页能回答「为什么失败、还能不能补救」，不做精确 errno 判断。
        static func classify(_ message: String) -> Reason {
            let text = message.lowercased()
            if text.contains("没有权限")
                || text.contains("permission")
                || text.contains("denied")
                || text.contains("operation not permitted") {
                return .noPermission
            }
            if text.contains("占用") || text.contains("busy") || text.contains("in use") {
                return .inUse
            }
            if text.contains("受保护") || text.contains("protected") || text.contains("sip") {
                return .protectedPath
            }
            if text.contains("未能移到废纸篓") || text.contains("未接收") {
                return .trashRejected
            }
            return .other
        }

        public var summary: String { "\(path)：\(message)" }
    }

    public struct FailureGroup: Identifiable, Equatable, Sendable {
        public let reason: RemovalFailure.Reason
        public let failures: [RemovalFailure]
        public var id: String { reason.rawValue }
    }

    /// 一次删除的完整结果。完成页 / 失败页 / 「复制详情」都从这里取数，
    /// 保证「应用本体到底还在不在」有唯一事实来源（评审 P0-3）。
    public struct RemovalReport: Equatable, Sendable {
        public let appName: String
        public let appPath: String
        /// 应用本体是否已移入废纸篓（原本就不存在也视同已移除）。
        public let appMoved: Bool
        /// 生成报告时应用本体是否仍在原路径。
        public let appStillPresent: Bool
        /// 应用在废纸篓内的新位置（可一步跳转查看）。
        public let appTrashURL: URL?
        public let trashedCount: Int
        /// 已移入废纸篓的字节数（含应用本体；大小未知时按 0 计）。
        public let trashedBytes: Int64
        public let failures: [RemovalFailure]
        /// 本次真正移入废纸篓的位置（应用 + 关联文件），供「在废纸篓中显示」。
        public let trashLocations: [URL]

        public var appConclusionText: String {
            if appMoved {
                return appStillPresent ? "应用本体：报告为已移除，但原路径仍存在" : "应用本体：已移到废纸篓"
            }
            return "应用本体：仍在 \(appPath)"
        }
    }

    public struct RemovalSummary: Equatable, Sendable {
        public let appName: String
        public let appPath: String
        public let itemCount: Int
        public let userFilePaths: [String]
        /// 名称模糊匹配（可能不属于该应用）的勾选项路径。
        public let speculativePaths: [String]
        /// 位于 /Library、需要管理员权限的勾选项数量。
        public let requiresAdminCount: Int
        public let estimatedBytes: Int64?
        public let isAppRunning: Bool
    }

    /// 勾选状态的分组视图数据（「全选」语义按推测项拆开，评审 P1-6）。
    public struct GroupSelection: Equatable, Sendable {
        public let totalCount: Int
        public let selectedCount: Int
        public let exactCount: Int
        public let selectedExactCount: Int
        public let speculativeCount: Int
        public let selectedSpeculativeCount: Int

        public var allSelected: Bool { totalCount > 0 && selectedCount == totalCount }
        public var exactAllSelected: Bool { exactCount > 0 && selectedExactCount == exactCount }
        public var hasUnselectedExact: Bool { selectedExactCount < exactCount }
        public var hasUnselectedSpeculative: Bool { selectedSpeculativeCount < speculativeCount }
    }

    /// footer 常驻的「高风险未选项」摘要（评审 P1-5：风险项不能藏在视口之外）。
    public struct RiskSummary: Equatable, Sendable {
        public let userFiles: Int
        public let launchItems: Int
        public let otherSpeculative: Int
        public var total: Int { userFiles + launchItems + otherSpeculative }
        public var isEmpty: Bool { total == 0 }

        public var text: String {
            var parts: [String] = []
            if userFiles > 0 { parts.append("\(userFiles) 项个人文件") }
            if launchItems > 0 { parts.append("\(launchItems) 项自启项") }
            if otherSpeculative > 0 { parts.append("\(otherSpeculative) 项可能相关") }
            return "另有 \(total) 项高风险未选：\(parts.joined(separator: " · "))"
        }
    }
    // MARK: 依赖注入类型

    public typealias ItemTrashHandler = UninstallEngine.TrashHandler
    public typealias AppTrashHandler = @MainActor @Sendable (AppRecord) async throws -> URL
    public typealias RunningAppQuitHandler = @MainActor @Sendable (String?, Bool) async -> Bool

    /// 默认不勾选的关联文件类目（用户数据 / 系统级自启项）。
    public static let defaultExcludedCategories: Set<UninstallCategory> = [.userFiles, .launchItems]

    /// 默认勾选集合：只包含由 bundleId 精确派生的、确认属于该应用的项。
    /// 名称模糊匹配（isSpeculative）以及 User Files / Launch Items 一律默认不勾选，
    /// 必须由用户在清单里显式勾选。
    public static func defaultCheckedItemIDs(in items: [UninstallItem]) -> Set<String> {
        Set(items
            .filter { !$0.isSpeculative && !$0.category.isExcludedByDefault }
            .map(\.id))
    }

    // MARK: 状态

    public let app: AppRecord
    public internal(set) var items: [UninstallItem] = []
    public var checkedItemIDs: Set<String> = []
    /// 状态机。外部只读；测试（@testable）可直接摆置阶段。
    public internal(set) var phase: Phase = .idle

    /// 当前 FDA 状态；.denied 时界面展示「可能漏扫」横幅，但不再阻断扫描。
    public private(set) var fullDiskAccessStatus: FullDiskAccess.Status = .unknown
    /// FDA 缺失（.denied）时展示横幅。保留该字段名以兼容既有调用与测试。
    public var needsFullDiskAccess: Bool = false

    /// 应用 bundle 本身体积（nil = 未知/尚未算完）。
    public internal(set) var appBundleSize: Int64?
    /// 清单已可操作、大小仍在后台填充。
    public internal(set) var isComputingSizes = false
    /// 扫描阶段文案（正在扫描缓存 / 容器 / 自启项…）。
    public private(set) var scanDetail = ""
    /// 应用是否正在运行（P0-4：头部徽标 + 确认弹窗提示）。
    public private(set) var isAppRunning = false
    /// 删除结束后回填的完整结果。
    public internal(set) var report: RemovalReport?
    /// 删除中的当前条目名（进度里展示「正在删除 X」）。
    public private(set) var currentRemovalItem: String?
    /// 被前置检查拦下或运行中取消时的说明（footer 上方展示）。
    public private(set) var lastActionError: String?
    /// 清单分组滚动定位目标（风险摘要点击跳转）。
    public var scrollTarget: UninstallCategory?
    /// 窗口可见时不再重复弹「已卸载」toast（成功页已经给了反馈）。
    public var suppressCompletionToast = false

    /// 应用被成功移除后回调（AppDelegate 注入，走 LaunchpadModel 做模型层收尾，P2-9）。
    public var onAppUninstalled: ((String) -> Void)?
    /// 删除流程结束（成功或失败）后回调，窗口控制器据此把失败明细交还给用户。
    public var onRemovalFinished: (() -> Void)?
    /// 扫描（含后台大小回填）结束时回调。界面不需要它，供测试等待扫描完成，
    /// 避免用轮询超时把「机器忙」误判成「功能坏」。
    public var onScanFinished: (() -> Void)?

    private let layoutStore: LayoutStore
    /// 扫描代数：reset / 重新扫描都会自增，迟到的旧扫描结果直接丢弃。
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?
    private var scanCancellation: ScanCancellation?
    /// 失败页「重试失败项」的目标（上次没删掉的关联文件）。
    private var failedTargets: [UninstallItem] = []
    /// 扫描根目录；测试可注入假 home，正常运行取真实用户目录。
    private let homeDirectory: URL
    /// FDA 探测实现；测试可注入固定状态。
    private let fullDiskAccessCheck: (URL) -> FullDiskAccess.Status
    private let itemTrashHandler: ItemTrashHandler
    private let appTrashHandler: AppTrashHandler
    private let runningAppQuitHandler: RunningAppQuitHandler
    /// 应用运行状态探测（测试可注入；生产走 NSRunningApplication）。
    private let isRunningCheck: (String?) -> Bool

    public init(
        app: AppRecord,
        layoutStore: LayoutStore,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fullDiskAccessCheck: @escaping (URL) -> FullDiskAccess.Status = { FullDiskAccess.status(home: $0) },
        itemTrashHandler: ItemTrashHandler? = nil,
        appTrashHandler: AppTrashHandler? = nil,
        runningAppQuitHandler: RunningAppQuitHandler? = nil,
        isRunningCheck: ((String?) -> Bool)? = nil
    ) {
        self.app = app
        self.layoutStore = layoutStore
        self.homeDirectory = homeDirectory
        self.fullDiskAccessCheck = fullDiskAccessCheck
        self.itemTrashHandler = itemTrashHandler ?? { urls in try await UninstallEngine.systemTrash(urls) }
        self.appTrashHandler = appTrashHandler ?? { entry in try await FinderActions.recycleApp(entry) }
        self.runningAppQuitHandler = runningAppQuitHandler
            ?? { bundleId, force in await Self.waitForTermination(bundleId: bundleId, force: force) }
        self.isRunningCheck = isRunningCheck ?? { Self.isRunning(bundleId: $0) }
        self.isAppRunning = self.isRunningCheck(app.bundleId)
    }

    // MARK: - 派生状态

    public var isRemoving: Bool {
        if case .removing = phase { return true }
        return false
    }

    public var isScanning: Bool { phase == .scanning }

    /// 是否已经走完一次删除流程（成功或部分失败）。
    public var hasFinished: Bool {
        switch phase {
        case .done, .partialFailure: return true
        case .idle, .scanning, .ready, .removing: return false
        }
    }

    /// 前置体检：系统/SIP 应用与只读卷直接拦截，不给「移除」按钮。
    public var removalBlockReason: String? {
        UninstallEligibility.blockReason(for: app)
    }

    public var canStartRemoval: Bool {
        phase == .ready && removalBlockReason == nil && !isRemoving
    }

    public var appPathMissing: Bool {
        !FileManager.default.fileExists(atPath: app.path)
    }

    /// 横幅只在「扫描前 / 扫描中 / 清单可操作」阶段显示；
    /// 删除完成页再显示「重新扫描」会把已卸载应用翻回列表，属于错误入口。
    public var showsAccessBanner: Bool {
        guard needsFullDiskAccess else { return false }
        switch phase {
        case .idle, .scanning, .ready: return true
        case .removing, .done, .partialFailure: return false
        }
    }

    public var selectedItems: [UninstallItem] {
        items.filter { checkedItemIDs.contains($0.id) }
    }

    public var selectedBytes: Int64 {
        selectedItems.compactMap(\.byteSize).reduce(0, +)
    }

    public var selectedUnknownSizeCount: Int {
        selectedItems.filter { $0.byteSize == nil }.count
    }

    /// 空间账本：应用本体 + 已选关联文件（评审 P1-1）。
    /// 任一来源未知时按已知部分给下限，界面上标注「至少」。
    public var plannedTrashBytes: Int64? {
        var total: Int64 = 0
        var known = false
        if let appBundleSize {
            total += appBundleSize
            known = true
        }
        if selectedBytes > 0 {
            total += selectedBytes
            known = true
        }
        return known ? total : nil
    }

    /// 有大小未知的已选项时，账本只能算下限。
    public var plannedTrashBytesIsLowerBound: Bool {
        selectedUnknownSizeCount > 0 || appBundleSize == nil
    }

    /// 分组视图（按类目，保持 14 类固定顺序）。
    public var groupedItems: [(category: UninstallCategory, items: [UninstallItem])] {
        UninstallCategory.allCases.compactMap { category in
            let group = items.filter { $0.category == category }
            return group.isEmpty ? nil : (category, group)
        }
    }

    /// 未勾选的高风险项摘要（个人文件 / 自启项 / 其它可能相关项）。
    public var riskSummary: RiskSummary {
        var userFiles = 0
        var launchItems = 0
        var otherSpeculative = 0
        for item in items where !checkedItemIDs.contains(item.id) {
            if item.category == .userFiles {
                userFiles += 1
            } else if item.category == .launchItems {
                launchItems += 1
            } else if item.isSpeculative {
                otherSpeculative += 1
            }
        }
        return RiskSummary(userFiles: userFiles, launchItems: launchItems, otherSpeculative: otherSpeculative)
    }

    /// 风险摘要点击后跳转的类目（个人文件 → 自启项 → 其它推测项）。
    public var riskSummaryJumpCategory: UninstallCategory? {
        let summary = riskSummary
        if summary.userFiles > 0 { return .userFiles }
        if summary.launchItems > 0 { return .launchItems }
        if summary.otherSpeculative > 0 {
            return items.first {
                $0.isSpeculative
                    && !$0.category.isExcludedByDefault
                    && !checkedItemIDs.contains($0.id)
            }?.category
        }
        return nil
    }

    /// 失败页的按原因分组明细（固定原因顺序，方便扫读）。
    public var failureGroups: [FailureGroup] {
        guard let report else { return [] }
        let grouped = Dictionary(grouping: report.failures, by: \.reason)
        return RemovalFailure.Reason.allCases.compactMap { reason in
            guard let failures = grouped[reason], !failures.isEmpty else { return nil }
            return FailureGroup(reason: reason, failures: failures)
        }
    }

    /// 「复制详情」用的纯文本。
    public var reportText: String {
        guard let report else { return "" }
        var lines = ["卸载「\(report.appName)」结果"]
        lines.append(report.appConclusionText)
        lines.append("已清理关联文件：\(report.trashedCount) 项")
        if report.trashedBytes > 0 {
            lines.append("已移入废纸篓：\(Self.formattedBytes(report.trashedBytes) ?? "")")
        }
        if !report.failures.isEmpty {
            lines.append("失败 \(report.failures.count) 项：")
            lines.append(contentsOf: report.failures.map { "· [\($0.reason.rawValue)] \($0.path)：\($0.message)" })
        }
        return lines.joined(separator: "\n")
    }

    /// 删除确认弹窗所需的信息（路径清单供用户在确认前逐一核对）。
    public var removalSummary: RemovalSummary {
        let selected = selectedItems
        return RemovalSummary(
            appName: app.name,
            appPath: app.path,
            itemCount: selected.count,
            userFilePaths: selected.filter { $0.category.isUserData }.map(\.url.path),
            speculativePaths: selected.filter { $0.isSpeculative }.map(\.url.path),
            requiresAdminCount: selected.filter(\.requiresAdmin).count,
            estimatedBytes: plannedTrashBytes,
            isAppRunning: isAppRunning
        )
    }
    // MARK: - 扫描

    /// 清空上一次扫描/选择状态。窗口复用切换到另一个应用时必须先重置，
    /// 否则会残留旧应用的清单、勾选与进度态（P3-6）。
    public func reset() {
        cancelScan(clearResults: true)
        phase = .idle
        fullDiskAccessStatus = .unknown
        needsFullDiskAccess = false
        report = nil
        lastActionError = nil
        currentRemovalItem = nil
        failedTargets = []
        suppressCompletionToast = false
        scrollTarget = nil
        isAppRunning = isRunningCheck(app.bundleId)
    }

    /// 开始扫描。两段式（P1-4）：先快速拿到路径清单立即可操作，
    /// 再把应用体积与逐项大小在后台渐进填上。
    public func startScan() {
        scanGeneration &+= 1
        let generation = scanGeneration
        scanCancellation?.cancel()
        let cancellation = ScanCancellation()
        scanCancellation = cancellation
        // 未授权 FDA 时不再整页阻断：应用本体与缓存等目录无需 FDA 即可清理，
        // 容器等受保护目录只是可能漏扫，应如实提示而不是让卸载器不可用。
        fullDiskAccessStatus = fullDiskAccessCheck(homeDirectory)
        needsFullDiskAccess = (fullDiskAccessStatus == .denied)
        // 重扫期间先清空旧清单/勾选，避免 footer 与列表还显示上一次应用的计数。
        items = []
        checkedItemIDs = []
        appBundleSize = nil
        isComputingSizes = false
        report = nil
        lastActionError = nil
        scanDetail = "正在扫描关联文件…"
        phase = .scanning
        isAppRunning = isRunningCheck(app.bundleId)

        let app = self.app
        let home = homeDirectory
        scanTask = Task { [weak self] in
            let paths = await Task.detached(priority: .userInitiated) {
                UninstallScanner.scanPaths(
                    app: app,
                    home: home,
                    shouldContinue: { !cancellation.isCancelled },
                    onPhase: { phaseText in
                        // 扫描在后台线程推进阶段文案；经主 actor 更新 UI 状态。
                        Task { @MainActor [weak self] in
                            guard let self, self.scanGeneration == generation else { return }
                            self.scanDetail = phaseText
                        }
                    }
                )
            }.value
            guard let self else { return }
            guard !cancellation.isCancelled, self.scanGeneration == generation else {
                // 扫描在出清单前被取消：也要通知等待方，避免测试/调用方永远挂起
                self.onScanFinished?()
                return
            }
            self.items = paths
            // 默认只勾选明确归属于该应用的项；User Files / Launch Items / 名称模糊匹配默认关闭
            self.checkedItemIDs = Self.defaultCheckedItemIDs(in: paths)
            self.scanDetail = ""
            // 清单立即可操作：大小稍后渐进填充，不再让「扫描」卡住首屏
            self.phase = .ready
            self.isComputingSizes = true
            await self.fillSizes(generation: generation, cancellation: cancellation)
        }
    }

    /// 取消扫描（真正的取消：中止后台枚举并丢弃结果）。
    public func cancelScan(clearResults: Bool = false) {
        scanGeneration &+= 1
        scanCancellation?.cancel()
        scanCancellation = nil
        scanTask?.cancel()
        scanTask = nil
        isComputingSizes = false
        scanDetail = ""
        if clearResults {
            items = []
            checkedItemIDs = []
            appBundleSize = nil
        }
    }

    /// 后台补大小：先算应用本身体积（账本第一栏），再逐项回填。
    private func fillSizes(generation: Int, cancellation: ScanCancellation) async {
        defer { onScanFinished?() }
        let appURL = URL(fileURLWithPath: app.path)
        let appSize = await Task.detached(priority: .utility) {
            UninstallScanner.size(of: appURL)
        }.value
        guard !cancellation.isCancelled, scanGeneration == generation else { return }
        appBundleSize = appSize

        while true {
            guard !cancellation.isCancelled, scanGeneration == generation else { return }
            guard let index = items.indices.first(where: { items[$0].byteSize == nil }) else { break }
            let url = items[index].url
            let size = await Task.detached(priority: .utility) {
                UninstallScanner.size(of: url)
            }.value
            guard !cancellation.isCancelled, scanGeneration == generation else { return }
            guard items.indices.contains(index), items[index].url == url else { continue }
            items[index].byteSize = size
        }
        isComputingSizes = false
    }

    /// 重新探测应用是否在运行（打开窗口 / 打开菜单时刷新）。
    public func refreshRunningState() {
        isAppRunning = isRunningCheck(app.bundleId)
    }

    // MARK: - 勾选

    public func toggle(_ item: UninstallItem) {
        if checkedItemIDs.contains(item.id) {
            checkedItemIDs.remove(item.id)
        } else {
            checkedItemIDs.insert(item.id)
        }
    }

    public func setChecked(_ checked: Bool, for item: UninstallItem) {
        if checked {
            checkedItemIDs.insert(item.id)
        } else {
            checkedItemIDs.remove(item.id)
        }
    }

    public func groupSelection(_ category: UninstallCategory) -> GroupSelection {
        let group = items.filter { $0.category == category }
        let exact = group.filter { !$0.isSpeculative }
        let speculative = group.filter(\.isSpeculative)
        return GroupSelection(
            totalCount: group.count,
            selectedCount: group.filter { checkedItemIDs.contains($0.id) }.count,
            exactCount: exact.count,
            selectedExactCount: exact.filter { checkedItemIDs.contains($0.id) }.count,
            speculativeCount: speculative.count,
            selectedSpeculativeCount: speculative.filter { checkedItemIDs.contains($0.id) }.count
        )
    }

    /// 分组「全选」。默认只选非推测项；推测项必须显式 includeSpeculative 才会被勾上
    /// （评审 P1-6：默认策略的安全收益不能被一个高频按钮绕过）。
    public func selectAll(in category: UninstallCategory, includeSpeculative: Bool = false) {
        for item in items where item.category == category {
            if item.isSpeculative && !includeSpeculative { continue }
            checkedItemIDs.insert(item.id)
        }
    }

    public func deselectAll(in category: UninstallCategory) {
        for item in items where item.category == category {
            checkedItemIDs.remove(item.id)
        }
    }
    // MARK: - 删除

    /// 执行删除：先移应用本体，成功后才清关联文件（评审 4.3 删除顺序）。
    /// 顺序反了会出现「缓存没了、应用还在」，是用户投诉最多的路径。
    public func removeChecked(forceQuitRunningApp: Bool = false) {
        guard phase == .ready else { return }
        if let reason = removalBlockReason {
            lastActionError = reason
            ToastManager.shared.error(reason)
            return
        }
        performRemoval(
            targets: selectedItems,
            forceQuitRunningApp: forceQuitRunningApp,
            appBodyAlreadyMoved: false
        )
    }

    /// 失败页是否还能「重试失败项」。
    public var canRetryFailed: Bool {
        guard case .partialFailure = phase, let report else { return false }
        return !report.appMoved || !failedTargets.isEmpty
    }

    /// 重试失败项：只重跑上次失败的关联文件，以及上次没移走的应用本体。
    public func retryFailed() {
        guard case .partialFailure = phase, let report else { return }
        let needsAppBody = !report.appMoved
        guard needsAppBody || !failedTargets.isEmpty else { return }
        performRemoval(
            targets: failedTargets,
            forceQuitRunningApp: false,
            appBodyAlreadyMoved: report.appMoved
        )
    }

    private func performRemoval(
        targets: [UninstallItem],
        forceQuitRunningApp: Bool,
        appBodyAlreadyMoved: Bool
    ) {
        report = nil
        lastActionError = nil
        currentRemovalItem = nil
        failedTargets = []
        let bodyStep = appBodyAlreadyMoved ? 0 : 1
        phase = .removing(progressDone: 0, progressTotal: targets.count + bodyStep)

        let app = self.app
        let home = homeDirectory
        let itemTrashHandler = self.itemTrashHandler
        let appTrashHandler = self.appTrashHandler
        let quitHandler = self.runningAppQuitHandler

        Task { [weak self] in
            guard let self else { return }

            // 0) 应用体积若还没算完，删除前补上（完成页要展示实际释放量）
            if self.appBundleSize == nil {
                let appURL = URL(fileURLWithPath: app.path)
                let size = await Task.detached(priority: .utility) {
                    UninstallScanner.size(of: appURL)
                }.value
                self.appBundleSize = size
            }

            // 1) 应用仍在运行？按用户在确认弹窗里的选择先退出（P0-4）。
            //    「请求退出」未在 2s 内退出则整单取消，不做静默强杀、也不删任何文件。
            if !appBodyAlreadyMoved, self.isRunningCheck(app.bundleId) {
                let quit = await quitHandler(app.bundleId, forceQuitRunningApp)
                guard quit else {
                    self.phase = .ready
                    self.refreshRunningState()
                    let message = "「\(app.name)」仍在运行，已取消卸载。请先退出应用后再试。"
                    self.lastActionError = message
                    ToastManager.shared.error(message)
                    self.onRemovalFinished?()
                    return
                }
            }

            var appMoved = appBodyAlreadyMoved
            var appTrashURL: URL?
            var trashLocations: [URL] = []
            var trashedCount = 0
            var trashedBytes: Int64 = 0
            var failures: [RemovalFailure] = []

            // 2) 先移应用本体。只有系统真正接收（recycle 返回字典包含该 URL）才算成功；
            //    空字典/未抛错不再当成卸载成功（P0-2）。
            if !appBodyAlreadyMoved {
                do {
                    let destination = try await appTrashHandler(app)
                    appMoved = true
                    appTrashURL = destination
                    trashLocations.append(destination)
                    trashedBytes += self.appBundleSize ?? 0
                } catch let error as FinderActionError where error.isPathMissing {
                    // 本体已不存在 == 已卸载（无需再移）
                    appMoved = true
                } catch {
                    failures.append(RemovalFailure(path: app.path, message: error.localizedDescription))
                }
                if appMoved {
                    self.removeFromLayout(appID: app.id)
                }
                if bodyStep > 0 {
                    self.phase = .removing(progressDone: 1, progressTotal: targets.count + bodyStep)
                }
            }

            // 3) 本体失败则中止：不清任何关联文件（避免「缓存没了、应用还在」）。
            if appMoved, !targets.isEmpty {
                let result = await UninstallEngine.remove(
                    items: targets,
                    home: home,
                    trash: itemTrashHandler
                ) { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case let .progress(done, _, current):
                        self.currentRemovalItem = current.map { URL(fileURLWithPath: $0).lastPathComponent }
                        self.phase = .removing(
                            progressDone: done + bodyStep,
                            progressTotal: targets.count + bodyStep
                        )
                    case .finished:
                        break
                    }
                }
                trashedCount = result.trashed
                trashedBytes += targets
                    .filter { result.trashedPaths.contains($0.url.path) }
                    .compactMap(\.byteSize)
                    .reduce(0, +)
                failures.append(contentsOf: result.failed.map {
                    RemovalFailure(path: $0.path, message: $0.error)
                })
                let failedPaths = Set(result.failed.map(\.path))
                self.failedTargets = targets.filter { failedPaths.contains($0.url.path) }
            } else {
                self.failedTargets = []
            }

            // 4) 结果如实上报：应用本体失败也算失败（即使关联文件没动）。
            self.currentRemovalItem = nil
            self.refreshRunningState()
            let stillPresent = FileManager.default.fileExists(atPath: app.path)
            let report = RemovalReport(
                appName: app.name,
                appPath: app.path,
                appMoved: appMoved,
                appStillPresent: stillPresent,
                appTrashURL: appTrashURL,
                trashedCount: trashedCount,
                trashedBytes: trashedBytes,
                failures: failures,
                trashLocations: trashLocations
            )
            self.report = report
            if failures.isEmpty {
                self.phase = .done(trashed: trashedCount)
                if !self.suppressCompletionToast {
                    let sizeText = report.trashedBytes > 0
                        ? "，已移入废纸篓 \(Self.formattedBytes(report.trashedBytes) ?? "")"
                        : ""
                    ToastManager.shared.success("已卸载「\(app.name)」\(sizeText)")
                }
            } else {
                self.phase = .partialFailure(trashed: trashedCount, failures: failures.map(\.summary))
                ToastManager.shared.error("「\(app.name)」未完全卸载：\(failures.count) 项失败")
            }
            self.onRemovalFinished?()
        }
    }

    /// 卸载成功后从布局移除应用；优先走 LaunchpadModel（顺带收尾选择集/打开文件夹，P2-9），
    /// 没有注入回调时退回直接改布局。
    private func removeFromLayout(appID: String) {
        if let onAppUninstalled {
            onAppUninstalled(appID)
        } else {
            layoutStore.updateLayout { layout in
                layout.removeApp(id: appID)
            }
        }
    }

    // MARK: - 运行中的应用

    public static func isRunning(bundleId: String?) -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { !$0.isTerminated }
            .isEmpty
    }

    /// 优雅退出应用：先 terminate 等待最多 timeout；force 为 true 时才强杀。
    ///
    /// 旧实现无条件 2 秒后 forceTerminate，用户正在编辑的文档会被静默强杀（P0-4）。
    /// 现在是否强杀由用户在确认弹窗里决定；force 完成后不再判定成败（强杀已尽力）。
    @MainActor
    public static func waitForTermination(
        bundleId: String?,
        timeout: TimeInterval = 2,
        force: Bool
    ) async -> Bool {
        guard let bundleId, !bundleId.isEmpty else { return true }
        func running() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
                .filter { !$0.isTerminated }
        }
        guard !running().isEmpty else { return true }
        for app in running() { app.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // 礼貌退出超时：不擅自强杀，交回用户决定（调用方取消本次卸载）。
        guard force else { return false }
        for app in running() { app.forceTerminate() }
        try? await Task.sleep(for: .milliseconds(300))
        for app in running() { app.forceTerminate() }
        // 给系统一点时间回收文件句柄，避免紧接着的删除被判为「文件正被占用」
        try? await Task.sleep(for: .milliseconds(200))
        return true
    }

    // MARK: - 格式化

    public static func formattedBytes(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 扫描取消标记：跨线程读取（后台枚举线程 + 主线程取消）。
final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}



