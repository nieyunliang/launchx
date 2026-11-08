import AppKit
import Foundation
import Observation
import SwiftUI

/// 拖放目标位置。
public enum DropTarget: Equatable {
    /// 插入到指定页的具体槽位（现有项后移）。
    case slot(page: Int, slot: Int)
    /// 页面空白处（追加到页尾，页满顺延）。
    case pageBackground(page: Int)
    /// 拖到应用上（建新文件夹 / 合入其所在文件夹）。
    case onApp(page: Int, appID: String)
    /// 拖到文件夹上（合并进文件夹）。
    case onFolder(page: Int, folderID: UUID)
}

/// 搜索命中（含排序分数）。
public struct SearchHit: Identifiable, Equatable, Sendable {
    public let appID: String
    public let score: Int  // 越大越靠前

    public var id: String { appID }
}

/// 翻页方向（最近一次页码变化），视图层据此选择转场的滑入/滑出边缘。
public enum PageDirection {
    /// 去往更大页码（下一页）。
    case forward
    /// 去往更小页码（上一页）。
    case backward
}

/// 进行中的横滑落位动画参数：供落位期间新手势按曲线解析表现值无缝接管。
/// SwiftUI 动画运行时模型里只有目标值，屏幕上的条带位置（表现值）由这组
/// 参数 + PageSlideCurve 反解出来，与在屏画面逐帧一致。
public struct PageSettleAnimation {
    let startOffset: CGFloat
    let targetOffset: CGFloat
    let startDate: Date
    let duration: TimeInterval

    /// 时刻 `now` 的表现偏移（pageDragOffset 坐标系）。
    func presentationOffset(at now: Date) -> CGFloat {
        let elapsed = now.timeIntervalSince(startDate)
        let x = min(max(elapsed / duration, 0), 1)
        let progress = PageSlideCurve.progress(atX: x)
        return startOffset + (targetOffset - startOffset) * progress
    }
}

/// Launchpad 主面板视图模型：布局镜像操作 + UI 状态。
@MainActor
@Observable
public final class LaunchpadModel {

    public let store: LayoutStore
    public let icons: AppIconRepository

    // MARK: UI 状态

    /// 当前页下标（分页模式）。
    public var currentPage: Int = 0
    /// 最近一次翻页方向（键盘/拖拽/页码点导航都会更新）。
    public private(set) var lastPageDirection: PageDirection = .forward
    /// 翻页跟手偏移（负 = 朝下一页露出；横滑时由窗口控制器写入，视图直接消费）。
    public var pageDragOffset: CGFloat = 0
    /// 分页网格宽度（横滑提交判定与落位动画的目标距离），由视图度量写入。
    public var pageWidth: CGFloat = 1440
    /// 横滑落位动画进行中（期间新手势可按表现值接管，离散滚轮仍等待落位）。
    public private(set) var isSettlingPageDrag = false
    /// 落位动画参数（接管时解析表现值用）；无落位动画时为 nil。
    public private(set) var pageSettleAnimation: PageSettleAnimation?
    /// 落位收尾定时器（接管时取消，避免过期收尾与接管手势双写页码）。
    private var pageSettleWork: DispatchWorkItem?
    /// 当前打开的文件夹（页下标, 文件夹 ID）。
    public var openedFolder: (page: Int, folderID: UUID)?
    /// 搜索文本。
    public var searchQuery: String = ""
    /// 搜索键盘选中下标。
    public var searchSelectedIndex: Int = 0
    /// 触发搜索框聚焦的令牌（面板层捕获可打印按键时 +1，视图 onChange 聚焦）。
    public var searchFocusTrigger: Int = 0
    /// ⌘ 多选集合（应用 id）。
    public var selectedAppIDs: Set<String> = []
    /// 橡皮筋选框（页面坐标空间；nil = 无框选）。
    public var marqueeRect: CGRect?
    /// 正在拖拽的应用 id（用于预览计数角标与目标高亮）。
    public var draggingAppIDs: [String] = []
    /// 拖拽悬停目标高亮。
    public var hoverTarget: DropTarget?
    /// 面板可见性。
    public var isVisible: Bool = false
    /// 最近一次启动失败的原因（成功或尚未回调时为 nil）。
    /// 与 Toast 并行记录，便于诊断/测试，不受 Toast 自动消失或并发清理影响。
    @ObservationIgnored public private(set) var lastLaunchError: String?
    /// 捏合手势的实时展开进度（0...1）；nil 表示由 isVisible 驱动常规过渡。
    public var pinchTransitionProgress: Double?
    /// 加载态（首扫未完成时）。
    public var isScanning: Bool = true

    // MARK: UI 钩子（由 AppCoordinator 注入）

    public var onOpenUninstall: ((String) -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onOpenReorganize: (() -> Void)?
    /// 收起面板（由窗口控制器注入 hide()）。
    public var onDismiss: (() -> Void)?

    public init(store: LayoutStore, icons: AppIconRepository = .shared) {
        self.store = store
        self.icons = icons
    }

    // MARK: - 便捷访问

    public var settings: AppSettings { store.state.settings }
    public var layout: LayoutSnapshot { store.state.layout }
    public var density: GridDensity { settings.gridDensity }

    public var pageCount: Int { max(layout.pages.count, 1) }

    public var activeSortKey: SortKey {
        get { store.state.settings.activeSortKey }
        set { store.updateSettings { $0.activeSortKey = newValue } }
    }

    // MARK: - 显示 / 隐藏

    public func show() {
        let target = min(max(settings.lastViewedPage, 0), max(pageCount - 1, 0))
        lastPageDirection = target >= currentPage ? .forward : .backward
        currentPage = target
        searchQuery = ""
        selectedAppIDs = []
        openedFolder = nil
        marqueeRect = nil
        isVisible = true
    }

    public func hide() {
        guard isVisible else { return }
        isVisible = false
        // 立即更新内存态，保证快速重新展开仍恢复本页；完整 JSON 编码与原子写盘
        // 由窗口控制器延后到淡出结束，避免阻塞收起动画的首帧。
        store.updateSettingsInMemory { $0.lastViewedPage = self.currentPage }
        searchQuery = ""
        selectedAppIDs = []
        openedFolder = nil
        marqueeRect = nil
        // 中断未完成的落位：清掉挂起收尾，否则定时器稍后会在收起态
        // "补跳页"（finishDragCommit 推进 currentPage）
        pageSettleWork?.cancel()
        pageSettleWork = nil
        pageSettleAnimation = nil
        isSettlingPageDrag = false
        pageDragOffset = 0
        // 面板收起即视为拖拽取消（Esc / 点空白 / 失焦），立即清掉拖拽会话，
        // 避免旧会话在 TTL 内被后续外部文本 drop 命中。
        DragObserver.shared.endDrag()
    }

    public func toggle() {
        isVisible ? hide() : show()
    }

    /// 面板空白处点击：先关文件夹 → 清多选 → 都没有则收起面板（对齐原版 Launchpad）。
    public func handleBackgroundTap() {
        if openedFolder != nil {
            closeFolder()
        } else if !selectedAppIDs.isEmpty {
            clearSelection()
        } else {
            onDismiss?()
        }
    }

    // MARK: - 页导航

    public func goToPage(_ index: Int) {
        lastPageDirection = index >= currentPage ? .forward : .backward
        currentPage = min(max(index, 0), pageCount - 1)
        openedFolder = nil
    }

    public func nextPage() {
        guard currentPage < pageCount - 1 else { return }
        lastPageDirection = .forward
        currentPage += 1
        openedFolder = nil
    }

    public func previousPage() {
        guard currentPage > 0 else { return }
        lastPageDirection = .backward
        currentPage -= 1
        openedFolder = nil
    }

    /// 横滑松手落位：+1 = 完成向前翻页，-1 = 完成向后翻页，0 = 回弹。
    /// 提交时先把偏移动画到整页宽，动画到位后原子换页并归零偏移；
    /// 期间新手势经 takeOverPageSettle 按曲线表现值接管，不产生输入死窗。
    public func settlePageDrag(commitDirection: Int) {
        guard !isSettlingPageDrag else { return }
        // 已在原位（如 .began 后立即松手）：无动画无锁定，避免空转吞掉新手势
        if commitDirection == 0, abs(pageDragOffset) < 1 { return }
        let width = max(pageWidth, 1)
        if commitDirection != 0 {
            // 接管手势已在目标位附近（如落位动画尾部接管后再次提交）：
            // 剩余位移不足 1pt，直接原子换页，免空转一轮动画时长
            let target = -CGFloat(commitDirection) * width
            if abs(pageDragOffset - target) < 1 {
                finishDragCommit(direction: commitDirection)
                return
            }
        }
        isSettlingPageDrag = true
        // 动画时长（LXAnimations 常量）+ 余量：动画到位后执行收尾（模型层拿不到动画完成回调）
        let duration: TimeInterval
        let targetOffset: CGFloat
        let startOffset = pageDragOffset
        if commitDirection == 0 {
            duration = Animation.pageBounceBackSeconds
            targetOffset = 0
            withAnimation(Animation.pageBounceBack) { pageDragOffset = 0 }
        } else {
            duration = Animation.pageSlideSeconds
            targetOffset = -CGFloat(commitDirection) * width
            lastPageDirection = commitDirection > 0 ? .forward : .backward
            withAnimation(Animation.pageSlide) {
                pageDragOffset = targetOffset
            }
        }
        pageSettleAnimation = PageSettleAnimation(
            startOffset: startOffset,
            targetOffset: targetOffset,
            startDate: Date(),
            duration: duration
        )
        let deadline = DispatchTime.now() + duration + 0.05
        let work = DispatchWorkItem { [weak self] in
            self?.finishDragCommit(direction: commitDirection)
        }
        pageSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
    }

    // 落位曲线与键盘/页码点翻页动画同曲线（见 LXAnimations.swift：easeOutCubic 快启动缓出）。

    /// 落位动画到位后的原子换页：无动画地同时改页码与归零偏移，画面无跳变
    /// （条带机制下换页前后的条带 offset 值相同，天然无缝）。
    private func finishDragCommit(direction: Int) {
        pageSettleWork?.cancel()
        pageSettleWork = nil
        pageSettleAnimation = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            currentPage = min(max(currentPage + direction, 0), pageCount - 1)
            pageDragOffset = 0
        }
        isSettlingPageDrag = false
    }

    /// 落位动画期间新手势接管：取消挂起收尾，把偏移无动画地钉在当前曲线表现值上，
    /// 返回该值作为接管手势的起始偏移（调用方以此为起点继续 1:1 跟手）。
    /// 表现值与在屏画面逐帧一致，接管瞬间无跳变；无落位动画时返回 nil。
    public func takeOverPageSettle() -> CGFloat? {
        guard isSettlingPageDrag, let animation = pageSettleAnimation else { return nil }
        pageSettleWork?.cancel()
        pageSettleWork = nil
        pageSettleAnimation = nil
        let presentation = animation.presentationOffset(at: Date())
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { pageDragOffset = presentation }
        isSettlingPageDrag = false
        return presentation
    }

    // MARK: - 搜索

    /// 搜索命中（隐藏应用默认排除）。
    /// 排序：应用名前缀 > 应用名包含 / bundleName 前缀 > bundleName 包含 / 拼音首字母 > 文件夹名命中。
    public var searchHits: [SearchHit] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let includeHidden = settings.showHiddenAppsInSearch
        let lowerQuery = query.lowercased()
        let compactQuery = lowerQuery.replacingOccurrences(of: " ", with: "")

        // 文件夹名命中：文件夹内成员以较低分数参与排序（低于应用自身名称匹配）。
        var folderScores: [String: Int] = [:]
        for page in layout.pages {
            for item in page.items {
                guard let folder = item.folder else { continue }
                let folderName = folder.name.lowercased()
                let score: Int
                if folderName.hasPrefix(lowerQuery) {
                    score = 2
                } else if folderName.contains(lowerQuery) {
                    score = 1
                } else {
                    continue
                }
                for appID in folder.appIDs {
                    folderScores[appID] = max(folderScores[appID] ?? 0, score)
                }
            }
        }

        return layout.apps.values
            .filter { includeHidden || !$0.hidden }
            .compactMap { app -> SearchHit? in
                var score = 0
                let name = app.name.lowercased()
                if name.hasPrefix(lowerQuery) {
                    score = max(score, 4)
                } else if name.contains(lowerQuery) {
                    score = max(score, 3)
                }
                // 原始 CFBundleName（重命名前的英文/本地化名）单独参与匹配
                let bundleName = app.bundleName.lowercased()
                if bundleName.hasPrefix(lowerQuery) {
                    score = max(score, 3)
                } else if bundleName.contains(lowerQuery) {
                    score = max(score, 2)
                }
                // 拼音首字母：输入「wx」命中「微信」
                if !compactQuery.isEmpty, let initials = pinyinInitials(for: app),
                   initials.hasPrefix(compactQuery) {
                    score = max(score, 2)
                }
                score = max(score, folderScores[app.id] ?? 0)
                guard score > 0 else { return nil }
                return SearchHit(appID: app.id, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let ln = layout.apps[lhs.appID]?.name ?? ""
                let rn = layout.apps[rhs.appID]?.name ?? ""
                return ln.localizedStandardCompare(rn) == .orderedAscending
            }
    }

    /// 搜索模式下要展示的扁平应用列表。
    public var searchResultAppIDs: [String] {
        searchHits.map(\.appID)
    }

    /// 拼音首字母缓存（key: appID + 分隔符 + 当前名称；改名后自动失效）。
    @ObservationIgnored private var pinyinInitialsCache: [String: String] = [:]

    /// 应用名的拼音首字母（「微信」→ "wx"）；非中文名也能给出可匹配的首字母串。
    private func pinyinInitials(for app: AppRecord) -> String? {
        let key = app.id + "\u{1F}" + app.name
        if let cached = pinyinInitialsCache[key] {
            return cached.isEmpty ? nil : cached
        }
        let latin = app.name.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? app.name
        let initials = latin
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .compactMap { $0.first.map(String.init) }
            .joined()
            .lowercased()
        pinyinInitialsCache[key] = initials
        return initials.isEmpty ? nil : initials
    }

    // MARK: - 启动

    /// 启动应用（记录使用 + 清 NEW 徽章 + 收起面板）。
    /// 启动失败时保留面板并提示，不记录使用、不重排、不收起。
    public func launch(appID: String) {
        guard let app = layout.apps[appID] else { return }
        lastLaunchError = nil
        let url = URL(fileURLWithPath: app.path)
        let appName = app.name
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] runningApp, error in
            // completion 可能在非主线程回调：只在此处算出结果，状态更新统一切回主线程
            let failure: String? = (error != nil || runningApp == nil)
                ? "无法打开「\(appName)」：\(error?.localizedDescription ?? "应用不可用")"
                : nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure {
                    self.lastLaunchError = failure
                    ToastManager.shared.error(failure)
                    return
                }
                self.finishLaunch(appID: appID)
            }
        }
    }

    /// 启动成功后的收尾：记录使用、按排序重排、收起面板。
    private func finishLaunch(appID: String) {
        store.recordLaunch(appID: appID)
        // 非「自定义」排序模式下保持网格与排序一致（如「最近使用」把刚启动的应用排到最前）
        store.applyActiveSort()
        // 收起必须经 onDismiss 走窗口控制器（真正执行 orderOut）；
        // 模型层 hide() 只复位 UI 状态不关窗口，会让面板残留全屏，
        // 且此后 Esc/空白点击等收起路径被 controller.hide() 的 guard 拦死。
        if let onDismiss {
            onDismiss()
        } else {
            hide()
        }
    }

    /// 运行状态查询的短 TTL 缓存：右键菜单批量求值时逐格全局查询
    /// （NSRunningApplication 线性扫描）开销放大明显，缓存后每 2s 至多查一次全局清单。
    @ObservationIgnored private var runningBundleIDsCache: Set<String> = []
    @ObservationIgnored private var runningCacheDate = Date.distantPast

    public func isRunning(appID: String) -> Bool {
        guard let bundleId = layout.apps[appID]?.bundleId else { return false }
        if Date().timeIntervalSince(runningCacheDate) > 2 {
            runningBundleIDsCache = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            runningCacheDate = Date()
        }
        return runningBundleIDsCache.contains(bundleId)
    }

    /// 强制退出：用 forceTerminate（挂起/无响应的应用也能杀掉）；失败时重试一次，仍失败给错误提示。
    public func forceQuit(appID: String) {
        guard let app = layout.apps[appID] else { return }
        guard let bundleId = app.bundleId else {
            ToastManager.shared.show(.info, "无法强制退出「\(app.name)」：缺少 Bundle ID")
            return
        }
        let name = app.name
        let running = Self.runningApplications(bundleId: bundleId)
        guard !running.isEmpty else {
            ToastManager.shared.show(.info, "「\(name)」未在运行")
            return
        }
        for process in running {
            process.forceTerminate()
        }
        Task { @MainActor in
            if await Self.waitUntilTerminated(bundleId: bundleId, timeout: 0.8) {
                ToastManager.shared.success("已强制退出「\(name)」")
                return
            }
            // 部分应用第一次 forceTerminate 不生效：再强杀一次
            for process in Self.runningApplications(bundleId: bundleId) {
                process.forceTerminate()
            }
            if await Self.waitUntilTerminated(bundleId: bundleId, timeout: 1.2) {
                ToastManager.shared.success("已强制退出「\(name)」")
            } else {
                ToastManager.shared.error("无法强制退出「\(name)」，请稍后重试")
            }
        }
    }

    private nonisolated static func runningApplications(bundleId: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).filter { !$0.isTerminated }
    }

    private nonisolated static func waitUntilTerminated(bundleId: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningApplications(bundleId: bundleId).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return runningApplications(bundleId: bundleId).isEmpty
    }

    // MARK: - 隐藏 / 重命名

    public func setHidden(_ hidden: Bool, appID: String) {
        store.updateLayout { layout in
            guard layout.apps[appID] != nil else { return }
            layout.apps[appID]?.hidden = hidden
        }
        if hidden {
            ToastManager.shared.show(.info, "已隐藏「\(layout.apps[appID]?.name ?? "")」")
        }
    }

    public func toggleHidden(appID: String) {
        setHidden(!(layout.apps[appID]?.hidden ?? false), appID: appID)
    }

    /// 取消隐藏：应用若未在网格上则追加到末页。
    public func unhide(appID: String) {
        setHidden(false, appID: appID)
        let capacity = density.capacity  // 跟随当前密度，避免高密度下提前溢出新页
        store.updateLayout { layout in
            guard let app = layout.apps[appID], !app.isAlias else { return }
            if !layout.placedAppIDs.contains(appID) {
                layout.appendApp(id: appID, toPage: max(layout.pages.count - 1, 0), capacityPerPage: capacity)
            }
        }
        store.applyActiveSort()
    }

    public func rename(appID: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.updateLayout { layout in
            layout.apps[appID]?.name = trimmed
        }
    }

    public func renameFolder(folderID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        store.updateLayout { layout in
            FolderEngine.renameFolder(folderID: folderID, to: trimmed, layout: &layout)
        }
    }

    // MARK: - 废纸篓

    public enum TrashOutcome {
        case trashed(name: String)
        case needsAdmin(name: String)
        case failed(String)
    }

    /// 移到废纸篓（系统应用拦截；alias 只删替身）。UI 弹窗由调用方承担。
    public func moveToTrash(appID: String) async -> TrashOutcome {
        guard let app = layout.apps[appID] else { return .failed("未找到应用") }
        if app.path.hasPrefix("/System") {
            return .needsAdmin(name: app.name)
        }
        do {
            _ = try await FinderActions.moveToTrash(app)
            store.updateLayout { layout in
                layout.removeApp(id: appID)
            }
            if app.isAlias {
                ToastManager.shared.show(.info, "已删除替身「\(app.name)」（不影响原应用）")
            }
            return .trashed(name: app.name)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - 右键动作透传

    public func openInFinder(appID: String) {
        if let app = layout.apps[appID] {
            try? FinderActions.revealInFinder(app)
        }
    }

    public func showGetInfo(appID: String) {
        if let app = layout.apps[appID] {
            do {
                try FinderActions.showGetInfo(app)
            } catch {
                ToastManager.shared.error(error.localizedDescription)
            }
        }
    }

    public func addToDock(appID: String) {
        guard let app = layout.apps[appID] else { return }
        do {
            try FinderActions.addToDock(app)
            ToastManager.shared.success("已添加到程序坞")
        } catch {
            ToastManager.shared.error(error.localizedDescription)
        }
    }

    // MARK: - 拖放

    /// 是否允许拖拽整理（仅 Custom 模式）。
    public var dragAllowed: Bool { activeSortKey == .custom }

    /// 多选拖拽载荷顺序：按源页视觉顺序（左→右、上→下）排列；
    /// 不在本页的选中项（理论上不应出现）按字母序追加，避免拖拽块内部顺序反转。
    public func orderedSelection(onPage page: Int) -> [String] {
        guard !selectedAppIDs.isEmpty else { return [] }
        guard layout.pages.indices.contains(page) else { return selectedAppIDs.sorted() }
        let inPage = layout.pages[page].items.compactMap(\.appID).filter { selectedAppIDs.contains($0) }
        let inPageSet = Set(inPage)
        var ordered = inPage
        ordered.append(contentsOf: selectedAppIDs.subtracting(inPageSet).sorted())
        return ordered
    }

    /// 执行拖放。`sourceFolderID` 为拖拽源所在文件夹（从文件夹内拖出时提供）。
    public func performDrop(draggingIDs: [String], sourceFolderID: UUID?, target: DropTarget) {
        guard dragAllowed else {
            ToastManager.shared.show(.info, "拖拽整理仅支持「自定义」排序模式。")
            return
        }
        let movableIDs = draggingIDs.filter { id in
            layout.apps[id] != nil && layout.apps[id]?.hidden != true
        }
        guard !movableIDs.isEmpty else { return }
        // 拖到隐藏应用上 / 隐藏应用本身拖入文件夹：提示先取消隐藏
        if case let .onApp(_, targetAppID) = target, layout.apps[targetAppID]?.hidden == true {
            ToastManager.shared.show(.info, "请先取消隐藏「\(layout.apps[targetAppID]?.name ?? "")」再移入文件夹。")
            return
        }

        let capacity = density.capacity  // 先取值：闭包内再读 store.state 会触发独占访问冲突
        store.updateLayout { layout in
            // resetLayout 等路径可能让布局没有任何页面：先补一页，避免后续 pages[-1] 崩溃
            if layout.pages.isEmpty {
                layout.pages = [PageRecord()]
            }

            // 1. 从原位置移除（直接摆放或文件夹内）。
            //    防御：拖拽载荷可能没有来源文件夹信息（例如历史版本的文件夹整体拖拽、
            //    或从已失效的打开文件夹状态拖出），因此这里不依赖 sourceFolderID，
            //    一律把 id 从任意文件夹中摘除，避免同一应用同时出现在文件夹和页面上。
            for appID in movableIDs {
                Self.removeAppFromAnyFolder(appID: appID, layout: &layout)
                for pageIndex in layout.pages.indices {
                    layout.pages[pageIndex].items.removeAll { $0.appID == appID }
                }
            }

            // 2. 放置
            switch target {
            case let .slot(page, slot):
                let pageIndex = min(max(page, 0), layout.pages.count - 1)
                // movableIDs 已按源页视觉顺序排好：倒序插入同一位置即可保持拖拽块内顺序
                let insertAt = min(max(slot, 0), layout.pages[pageIndex].items.count)
                for appID in movableIDs.reversed() {
                    layout.pages[pageIndex].items.insert(.app(id: appID), at: insertAt)
                }
                // 页超容：末尾溢出项顺延到后续页
                spillOverflow(fromPage: pageIndex, capacity: capacity, layout: &layout)

            case let .pageBackground(page):
                let pageIndex = min(max(page, 0), layout.pages.count - 1)
                for appID in movableIDs {
                    layout.appendApp(id: appID, toPage: pageIndex, capacityPerPage: capacity)
                }

            case let .onApp(_, targetAppID):
                // 单拖到应用上 → 建夹；多拖到应用上 → 每个合入
                if movableIDs.count == 1, movableIDs[0] != targetAppID {
                    FolderEngine.createFolder(dragging: movableIDs[0], onto: targetAppID, layout: &layout)
                } else {
                    FolderEngine.mergeIntoNewFolder(
                        appIDs: movableIDs + [targetAppID],
                        page: currentPage,
                        layout: &layout
                    )
                }

            case let .onFolder(_, folderID):
                FolderEngine.mergeIntoFolder(appIDs: movableIDs, folderID: folderID, layout: &layout)
            }

            layout.removeEmptyPages()
        }
        selectedAppIDs.subtract(movableIDs)
        currentPage = min(max(currentPage, 0), pageCount - 1)
    }

    /// 把应用从任意文件夹中摘除；文件夹被摘空后一并移除。
    /// 用于拖放前清理旧位置，防止成员被复制到多处。
    private static func removeAppFromAnyFolder(appID: String, layout: inout LayoutSnapshot) {
        for pageIndex in layout.pages.indices {
            guard let slotIndex = layout.pages[pageIndex].items.firstIndex(where: { $0.folder?.appIDs.contains(appID) == true }),
                  var folder = layout.pages[pageIndex].items[slotIndex].folder
            else { continue }
            folder.appIDs.removeAll { $0 == appID }
            if folder.appIDs.isEmpty {
                layout.pages[pageIndex].items.remove(at: slotIndex)
            } else {
                layout.pages[pageIndex].items[slotIndex] = .folder(folder)
            }
        }
    }

    /// 页超容量时把末尾项顺延到后续页。
    private func spillOverflow(fromPage pageIndex: Int, capacity: Int, layout: inout LayoutSnapshot) {
        var index = pageIndex
        while layout.pages[index].items.count > capacity {
            let overflow = layout.pages[index].items.removeLast()
            index += 1
            if index == layout.pages.count {
                layout.pages.append(PageRecord())
            }
            layout.pages[index].items.insert(overflow, at: 0)
        }
    }

    // MARK: - 文件夹

    public func openFolder(page: Int, folderID: UUID) {
        openedFolder = (page, folderID)
    }

    public func closeFolder() {
        openedFolder = nil
    }

    /// 文件夹内重排：把拖拽项移到目标项之前。
    public func moveWithinFolder(draggingIDs: [String], folderID: UUID, beforeAppID: String) {
        guard dragAllowed else {
            ToastManager.shared.show(.info, "拖拽整理仅支持「自定义」排序模式。")
            return
        }
        store.updateLayout { layout in
            guard let page = layout.pageIndexOfFolder(folderID),
                  let slot = layout.pages[page].items.firstIndex(where: { $0.folder?.id == folderID }) else { return }
            var folder = layout.pages[page].items[slot].folder!
            for id in draggingIDs {
                folder.appIDs.removeAll { $0 == id }
            }
            if let targetIndex = folder.appIDs.firstIndex(of: beforeAppID) {
                folder.appIDs.insert(contentsOf: draggingIDs, at: targetIndex)
            } else {
                folder.appIDs.append(contentsOf: draggingIDs)
            }
            layout.pages[page].items[slot] = .folder(folder)
        }
    }

    /// 把文件夹成员移出到文件夹所在页的页尾（右键「移出文件夹」入口）。
    /// 走 performDrop 同一条路径：先摘除成员，文件夹被摘空即删除，再追加到页尾。
    public func moveOutOfFolder(appID: String) {
        guard let (page, folder) = layout.folderLocation(of: appID) else { return }
        performDrop(
            draggingIDs: [appID],
            sourceFolderID: folder.id,
            target: .pageBackground(page: page)
        )
    }

    /// 当前打开文件夹的记录。
    public var openedFolderRecord: FolderRecord? {
        guard let opened = openedFolder else { return nil }
        guard opened.page < layout.pages.count else { return nil }
        return layout.pages[opened.page].items.compactMap(\.folder).first { $0.id == opened.folderID }
    }

    public func ungroupFolder(folderID: UUID) {
        let capacity = density.capacity
        store.updateLayout { layout in
            FolderEngine.ungroup(folderID: folderID, layout: &layout, capacityPerPage: capacity)
        }
        if openedFolder?.folderID == folderID {
            closeFolder()
        }
    }

    public func ungroupAllFolders() {
        let capacity = density.capacity
        store.updateLayout { layout in
            FolderEngine.ungroupAll(layout: &layout, capacityPerPage: capacity)
        }
        closeFolder()
        ToastManager.shared.show(.info, "已解散全部文件夹（应用追加到页尾）")
    }

    public func createNewFolderOnCurrentPage() {
        store.updateLayout { layout in
            // resetLayout 后布局可能没有任何页面；补一页，避免 pages[-1] 崩溃
            if layout.pages.isEmpty {
                layout.pages = [PageRecord()]
            }
            // 建空文件夹：把当前页最后 1 个应用收进去（Launchpad 语义），
            // 无应用时建一个空文件夹占位
            let page = min(max(currentPage, 0), layout.pages.count - 1)
            if let lastAppID = layout.pages[page].items.last(where: { $0.appID != nil })?.appID {
                layout.pages[page].items.removeAll { $0.appID == lastAppID }
                let folder = FolderRecord(name: FolderEngine.defaultFolderName(layout: layout), appIDs: [lastAppID])
                layout.pages[page].items.append(.folder(folder))
            } else {
                let folder = FolderRecord(name: FolderEngine.defaultFolderName(layout: layout), appIDs: [])
                layout.pages[page].items.append(.folder(folder))
            }
        }
    }

    // MARK: - 多选

    public func toggleSelection(appID: String) {
        if selectedAppIDs.contains(appID) {
            selectedAppIDs.remove(appID)
        } else {
            selectedAppIDs.insert(appID)
        }
    }

    public func clearSelection() {
        selectedAppIDs = []
        marqueeRect = nil
    }

    /// 橡皮筋选框更新时选中相交项（itemFrames 由视图层上报：id → 页面空间 frame）。
    public func updateMarqueeSelection(itemFrames: [String: CGRect], inPage page: Int) {
        guard let marquee = marqueeRect else { return }
        // 框选拖动逐帧调用：页内直接摆放应用索引一次成型，
        // 避免对每个相交候选做整布局线性扫描（O(页×项) → O(页+项)）
        var directAppPages: [String: Int] = [:]
        for (pageIndex, pageRecord) in layout.pages.enumerated() {
            for item in pageRecord.items {
                if let id = item.appID { directAppPages[id] = pageIndex }
            }
        }
        var intersected: Set<String> = []
        for (appID, frame) in itemFrames where frame.intersects(marquee) {
            if directAppPages[appID] == page {
                intersected.insert(appID)
            }
        }
        selectedAppIDs = intersected
    }

    /// 批量隐藏当前选择。单次 updateLayout 落盘（逐项调用会触发 N 次同步 JSON 写盘）。
    public func hideSelection() {
        let ids = Array(selectedAppIDs)
        guard !ids.isEmpty else { return }
        store.updateLayout { layout in
            for id in ids where layout.apps[id] != nil {
                layout.apps[id]?.hidden = true
            }
        }
        ToastManager.shared.show(.info, "已隐藏 \(ids.count) 个应用")
        clearSelection()
    }

    /// 批量把选择合并进新文件夹。
    public func mergeSelectionIntoNewFolder() {
        let ids = Array(selectedAppIDs).sorted { a, b in
            let an = layout.apps[a]?.name ?? ""
            let bn = layout.apps[b]?.name ?? ""
            return an.localizedStandardCompare(bn) == .orderedAscending
        }
        guard ids.count >= 2 else {
            ToastManager.shared.show(.info, "至少选择 2 个应用才能创建文件夹")
            return
        }
        guard dragAllowed else {
            ToastManager.shared.show(.info, "拖拽整理仅支持「自定义」排序模式。")
            return
        }
        store.updateLayout { layout in
            // resetLayout 后布局可能没有任何页面：补一页并钳位，避免 pages[-1] 崩溃
            if layout.pages.isEmpty {
                layout.pages = [PageRecord()]
            }
            let page = min(max(self.currentPage, 0), layout.pages.count - 1)
            FolderEngine.mergeIntoNewFolder(appIDs: ids, page: page, layout: &layout)
        }
        clearSelection()
    }

    // MARK: - 密度

    /// 网格密度变更后按新容量重排所有页（跨页前压、保序、去空页）。
    /// 由设置 / 捏合手势的接线方在密度变化后调用。
    public func reflowAfterDensityChange() {
        let capacity = density.capacity
        guard capacity > 0 else { return }
        store.updateLayout { layout in
            _ = ReorganizeEngine.fillEmptySlots(&layout, scope: .allPages, capacityPerPage: capacity)
        }
        currentPage = min(max(currentPage, 0), pageCount - 1)
        // 打开文件夹的页下标可能已变化：跟随到新页；文件夹不存在则关闭
        if let opened = openedFolder {
            if let newPage = layout.pageIndexOfFolder(opened.folderID) {
                openedFolder = (newPage, opened.folderID)
            } else {
                closeFolder()
            }
        }
    }

    // MARK: - 重扫

    public func rescan() {
        isScanning = true
        let sources = store.state.sources
        let capacity = density.capacity
        Task.detached(priority: .userInitiated) { [weak self] in
            // 扫描时保留既有 addedAt（NEW 只对真正的新应用亮）
            let scanned = AppIndex.scan(sources: sources)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.store.updateLayout { layout in
                    _ = SyncEngine.merge(
                        scanned: scanned,
                        into: &layout,
                        capacityPerPage: capacity
                    )
                    // 保留既有使用统计与 NEW 状态：merge 刷新元数据已保留；
                    // 这里恢复 addedAt（merge 不覆盖在册 addedAt，无需处理）
                }
                self.isScanning = false
                self.icons.invalidateCache()
                // 非「自定义」排序模式下，扫描结果（含站外启动刷新的最近使用时间）落位后全局重排
                self.store.applyActiveSort()
            }
        }
    }
}
