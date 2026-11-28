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

    /// 落点所在页。
    var page: Int {
        switch self {
        case let .slot(page, _), let .pageBackground(page), let .onApp(page, _), let .onFolder(page, _):
            return page
        }
    }
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
    /// 落位动画期间挂起的提交方向（+1/-1，回弹为 0）。视图层据此把提交目标页
    /// 提前物化，原子换页帧（finishDragCommit）不再包含新页构建开销。
    /// 收尾 / 接管 / 收起时清空。
    public private(set) var pendingCommitDirection: Int? = nil
    /// 落位动画参数（接管时解析表现值用）；无落位动画时为 nil。
    public private(set) var pageSettleAnimation: PageSettleAnimation?
    /// 落位收尾定时器（接管时取消，避免过期收尾与接管手势双写页码）。
    private var pageSettleWork: DispatchWorkItem?
    /// 当前打开的文件夹（页下标, 文件夹 ID）。
    public var openedFolder: (page: Int, folderID: UUID)?
    /// 搜索文本。变化即把键盘高亮归零：结果集变了以后旧下标可能越界
    /// （高亮环消失、回车被钳到「最后一条」）。
    public var searchQuery: String = "" {
        didSet {
            if searchQuery != oldValue { searchSelectedIndex = 0 }
            // 文本一变就不是组字中（提交 / 程序化清空）；组字期间文本不变，
            // 不会走到这里，见 searchIsComposing 注释。
            searchIsComposing = false
        }
    }
    /// 输入法组字中（field editor 有 marked text）。组字期间搜索文本不变
    /// （binding 不更新），搜索框自绘占位需据此隐藏，避免和组字文本叠字。
    /// 面板层 keyDown 监听器在事件送达 field editor 后采样 `hasMarkedText` 写入。
    public var searchIsComposing = false
    /// 搜索键盘选中下标（对外读取时用 `clampedSearchSelectedIndex`）。
    public var searchSelectedIndex: Int = 0

    /// 钳到当前命中范围的下标（命中为空时为 0）。
    public var clampedSearchSelectedIndex: Int {
        min(max(searchSelectedIndex, 0), max(searchHits.count - 1, 0))
    }
    /// 触发搜索框聚焦的令牌（面板层捕获可打印按键时 +1，视图 onChange 聚焦）。
    public var searchFocusTrigger: Int = 0
    /// 触发搜索框失焦的令牌（搜索框聚焦时按 Tab 要回到网格键盘焦点，视图 onChange 失焦）。
    public var searchBlurTrigger: Int = 0
    /// ⌘ 多选集合（应用 id）。
    public var selectedAppIDs: Set<String> = []
    /// 橡皮筋选框（页面坐标空间；nil = 无框选）。
    public var marqueeRect: CGRect?
    /// 拖拽悬停目标高亮。
    public var hoverTarget: DropTarget?
    /// 面板可见性。
    public var isVisible: Bool = false
    /// 最近一次启动失败的原因（成功或尚未回调时为 nil）。
    /// 与 Toast 并行记录，便于诊断/测试，不受 Toast 自动消失或并发清理影响。
    @ObservationIgnored public private(set) var lastLaunchError: String?
    /// 捏合手势的实时展开进度（0...1）；nil 表示由 isVisible 驱动常规过渡。
    public var pinchTransitionProgress: Double?
    /// 捏合跟手会话进行中（O9）：只在会话开始/结束翻转（beginPinchGesture /
    /// settlePinchGesture / resetPinchInteraction），不逐帧变化——根视图用
    /// 它关闭命中测试，不会像读逐帧进度那样每帧重算。
    public var isPinchInteracting = false
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
        searchSelectedIndex = 0
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
        searchSelectedIndex = 0
        selectedAppIDs = []
        openedFolder = nil
        marqueeRect = nil
        // 中断未完成的落位：清掉挂起收尾，否则定时器稍后会在收起态
        // "补跳页"（finishDragCommit 推进 currentPage）
        pageSettleWork?.cancel()
        pageSettleWork = nil
        pageSettleAnimation = nil
        pendingCommitDirection = nil
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
            let wasActive = isFolderViewActive
            closeFolder()
            // 悬空状态（文件夹已被删除/搬走）本次点击只负责清理，继续处理多选与收起，
            // 否则用户要连点两次空白才能关掉面板。
            if wasActive { return }
        }
        if !selectedAppIDs.isEmpty {
            clearSelection()
        } else {
            onDismiss?()
        }
    }

    // MARK: - 页导航

    /// 翻页入口的防重入不变量（放在模型层，新增入口不会漏掉）：
    /// 落位动画进行中或手指仍在跟手时，`finishDragCommit` 还会按方向再提交一次，
    /// 此时直接改页码会叠加成「跳两页」。
    public var allowsPageNavigation: Bool {
        PageSettleGuard.allowsNavigation(isSettlingPageDrag: isSettlingPageDrag, pageDragOffset: pageDragOffset)
    }

    /// 横滑翻页是否生效（分页浏览且不在搜索 / 文件夹态）。面板层事件过滤与
    /// 横滑处理共用这一个判定。
    public var isPagedBrowsingActive: Bool {
        settings.browsingStyle == .paged && searchQuery.isEmpty && !isFolderViewActive
    }

    public func goToPage(_ index: Int) {
        guard allowsPageNavigation else { return }
        lastPageDirection = index >= currentPage ? .forward : .backward
        currentPage = min(max(index, 0), pageCount - 1)
        openedFolder = nil
    }

    public func nextPage() {
        guard allowsPageNavigation, currentPage < pageCount - 1 else { return }
        lastPageDirection = .forward
        currentPage += 1
        openedFolder = nil
    }

    public func previousPage() {
        guard allowsPageNavigation, currentPage > 0 else { return }
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
        pendingCommitDirection = commitDirection
        // 动画时长（LXAnimations 常量）+ 余量：动画到位后执行收尾（模型层拿不到动画完成回调）。
        // 减弱动态效果时与键盘/页码点翻页保持一致：同曲线、0.12s，而不是固定 0.3s。
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let profile = MotionPreference.profile(reduceMotion: reduce)
        let slideAnimation = MotionPreference.pageSlide(reduceMotion: reduce)
        let bounceAnimation: Animation = reduce ? .easeOut(duration: profile.pageSlideDuration) : .pageBounceBack
        let duration: TimeInterval
        let targetOffset: CGFloat
        let startOffset = pageDragOffset
        if commitDirection == 0 {
            duration = reduce ? profile.pageSlideDuration : Animation.pageBounceBackSeconds
            targetOffset = 0
            withAnimation(bounceAnimation) { pageDragOffset = 0 }
        } else {
            duration = profile.pageSlideDuration
            targetOffset = -CGFloat(commitDirection) * width
            lastPageDirection = commitDirection > 0 ? .forward : .backward
            withAnimation(slideAnimation) {
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
            pendingCommitDirection = nil
        }
        isSettlingPageDrag = false
    }

    /// 落位动画期间新手势接管：取消挂起收尾，把偏移无动画地钉在当前曲线表现值上，
    /// 返回该值作为接管手势的起始偏移（调用方以此为起点继续 1:1 跟手）。
    /// 表现值与在屏画面逐帧一致，接管瞬间无跳变；无落位动画时返回 nil。
    ///
    /// 挂起的是「提交翻页」（±1）时，接管即兑现这次翻页：页码原子推进、偏移按
    /// 页宽重定基（`presentation + direction × width`），条带总偏移不变、画面无跳变。
    /// 否则接管手势仍以旧页为基准，只能把上一次翻页「滑完」，要连翻必须等落位
    /// 收尾（页码点变化）后才能开始下一页。
    public func takeOverPageSettle() -> CGFloat? {
        guard isSettlingPageDrag, let animation = pageSettleAnimation else { return nil }
        let direction = pendingCommitDirection ?? 0
        pageSettleWork?.cancel()
        pageSettleWork = nil
        pageSettleAnimation = nil
        var offset = animation.presentationOffset(at: Date())
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let target = min(max(currentPage + direction, 0), pageCount - 1)
            if direction != 0, target != currentPage {
                offset += CGFloat(target - currentPage) * max(pageWidth, 1)
                currentPage = target
            }
            pageDragOffset = offset
            pendingCommitDirection = nil
        }
        isSettlingPageDrag = false
        return offset
    }

    // MARK: - 搜索

    /// 搜索命中缓存：键为 (查询, 是否含隐藏, 存储修订号)。
    /// 视图与键盘路由在一次按键里会多次读取命中（结果网格、高亮下标、回车启动），
    /// 每次都全量过滤 + 拼音 + 排序是 O(k·n log n)。
    private struct SearchHitsCache {
        let query: String
        let includeHidden: Bool
        let revision: Int
        let hits: [SearchHit]
    }
    @ObservationIgnored private var searchHitsCache: SearchHitsCache?

    /// 搜索命中（隐藏应用默认排除）。
    /// 排序：应用名前缀 > 应用名包含 / bundleName 前缀 > bundleName 包含 / 拼音首字母 > 文件夹名命中。
    public var searchHits: [SearchHit] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        // 先读 settings（即 store.state）登记观察依赖，缓存命中时视图也会随布局变化刷新
        let includeHidden = settings.showHiddenAppsInSearch
        let revision = store.revision
        if let cache = searchHitsCache, cache.query == query,
           cache.includeHidden == includeHidden, cache.revision == revision {
            return cache.hits
        }
        let hits = computeSearchHits(query: query, includeHidden: includeHidden)
        searchHitsCache = SearchHitsCache(query: query, includeHidden: includeHidden, revision: revision, hits: hits)
        return hits
    }

    private func computeSearchHits(query: String, includeHidden: Bool) -> [SearchHit] {
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
        store.batchUpdates {
            store.recordLaunch(appID: appID)
            // 非「自定义」排序模式下保持网格与排序一致（如「最近使用」把刚启动的应用排到最前）
            store.applyActiveSort()
        }
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
        var appName = ""
        store.updateLayout { layout in
            guard layout.apps[appID] != nil else { return }
            appName = layout.apps[appID]?.name ?? ""
            layout.apps[appID]?.hidden = hidden
            // 隐藏 = 从启动台移出（只保留注册表 / 搜索）。不同时摘除摆放会让
            // 「hidden 且 placed」长期自相矛盾：图标留在页面上（仅变暗）、拖不动、
            // 且 resetLayout / unhide / 同步逻辑都以「隐藏项不在网格」为前提。
            if hidden {
                layout.detachFromGrid(appID)
            }
        }
        if hidden {
            ToastManager.shared.show(.info, "已隐藏「\(appName)」")
        }
        if hidden, selectedAppIDs.contains(appID) {
            selectedAppIDs.remove(appID)
        }
        reconcileOpenedFolder()
    }

    public func toggleHidden(appID: String) {
        setHidden(!(layout.apps[appID]?.hidden ?? false), appID: appID)
    }

    /// 取消隐藏：应用若未在网格上则追加到末页。
    public func unhide(appID: String) {
        let capacity = density.capacity  // 跟随当前密度，避免高密度下提前溢出新页
        store.batchUpdates {
            setHidden(false, appID: appID)
            store.updateLayout { layout in
                guard let app = layout.apps[appID], !app.isAlias else { return }
                if !layout.placedAppIDs.contains(appID) {
                    layout.appendApp(id: appID, toPage: max(layout.pages.count - 1, 0), capacityPerPage: capacity)
                }
            }
            store.applyActiveSort()
        }
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
        /// 系统保护 / 只读卷等前置拦截：不做任何删除，并给出原因。
        case blocked(reason: String)
        case failed(String)
    }

    /// 卸载入口前置判定：返回不能卸载的原因（nil = 可以卸载）。
    ///
    /// 系统应用（/System 路径，或指向只读系统卷的符号链接，如 /Applications/Safari.app）
    /// 不再给「卸载」入口：旧路径会先清缓存、再因为 SIP 删不掉本体，
    /// 用户数据没了应用还在（评审 P1-8 / P2-11）。
    public func uninstallBlockReason(appID: String) -> String? {
        guard let app = layout.apps[appID] else { return "未找到应用" }
        // 判定要解析符号链接、读卷属性、lstat，属于主线程同步文件 I/O；
        // 右键菜单每次构建都会问一遍，按路径缓存（重扫后清空）。
        if let cached = uninstallBlockReasonCache[app.path] { return cached }
        let reason = UninstallEligibility.blockReason(for: app)
        uninstallBlockReasonCache[app.path] = .some(reason)
        return reason
    }

    /// 卸载拦截原因缓存（key: 应用路径；值为 nil 表示可以卸载）。
    @ObservationIgnored private var uninstallBlockReasonCache: [String: String?] = [:]

    /// 移到废纸篓（系统应用拦截；alias 只删替身）。UI 弹窗由调用方承担。
    public func moveToTrash(appID: String) async -> TrashOutcome {
        guard let app = layout.apps[appID] else { return .failed("未找到应用") }
        if let reason = UninstallEligibility.blockReason(for: app) {
            return .blocked(reason: reason)
        }
        do {
            _ = try await FinderActions.moveToTrash(app)
            store.updateLayout { layout in
                layout.removeApp(id: appID)
            }
            // 被移出布局的 id 不能留在选择集里（否则工具栏计数虚高、可生成单人文件夹）。
            selectedAppIDs.remove(appID)
            reconcileOpenedFolder()
            if app.isAlias {
                ToastManager.shared.show(.info, "已删除替身「\(app.name)」（不影响原应用）")
            }
            return .trashed(name: app.name)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 右键「移到废纸篓」的统一反馈入口（AppCell / FolderViews 不再各写一份 toast）。
    public func confirmAndTrash(appID: String) async {
        let fallbackName = layout.apps[appID]?.name ?? "该应用"
        switch await moveToTrash(appID: appID) {
        case let .trashed(name):
            ToastManager.shared.success("已将「\(name)」移到废纸篓")
        case let .blocked(reason):
            ToastManager.shared.error("无法移除「\(fallbackName)」：\(reason)")
        case let .failed(message):
            ToastManager.shared.error("移到废纸篓失败：\(message)")
        }
    }

    /// 卸载器删除应用后回调：布局移除 + 选择集 / 打开态文件夹收尾（评审 P2-9）。
    ///
    /// 卸载器若只 `layoutStore.updateLayout`，被移出的 id 会留在选择集里（工具栏计数虚高、
    /// 可生成单人文件夹），打开态文件夹也可能指向已空的文件夹。
    public func appDidGetUninstalled(appID: String) {
        store.updateLayout { layout in
            layout.removeApp(id: appID)
        }
        selectedAppIDs.remove(appID)
        reconcileOpenedFolder()
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

    private func showDragRequiresCustomSortToast() {
        ToastManager.shared.show(.info, "拖拽整理仅支持「自定义」排序模式。")
    }

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
            showDragRequiresCustomSortToast()
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
            layout.ensureHasPage()

            // 1. 从原位置移除（直接摆放或文件夹内）。
            //    防御：拖拽载荷可能没有来源文件夹信息（例如历史版本的文件夹整体拖拽、
            //    或从已失效的打开文件夹状态拖出），因此这里不依赖 sourceFolderID，
            //    一律把 id 从任意文件夹中摘除，避免同一应用同时出现在文件夹和页面上。
            for appID in movableIDs {
                layout.removeAppFromAnyFolder(appID)
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

            case let .onApp(page, targetAppID):
                // 单拖到应用上 → 建夹；多拖到应用上 → 合入新文件夹。
                // 文件夹必须落在「落点」页而不是 currentPage：滚动模式下 currentPage
                // 可能未跟随可视页，用 currentPage 会让文件夹出现在别的页（用户看不到）。
                if movableIDs.count == 1, movableIDs[0] != targetAppID {
                    FolderEngine.createFolder(dragging: movableIDs[0], onto: targetAppID, layout: &layout)
                } else {
                    FolderEngine.mergeIntoNewFolder(
                        appIDs: movableIDs + [targetAppID],
                        page: page,
                        layout: &layout
                    )
                }

            case let .onFolder(_, folderID):
                FolderEngine.mergeIntoFolder(appIDs: movableIDs, folderID: folderID, layout: &layout)
            }

            // 3. 兜底：目标在放置前已失效（异步载荷回调到来前被重扫移除等）时引擎直接返回，
            //    第 1 步已摘除的拖拽项必须放回网格——否则留在注册表里却不在任何页上，
            //    merge 也不会补摆（它只追加注册表里没有的应用）。
            let fallbackPage = min(max(target.page, 0), layout.pages.count - 1)
            for appID in movableIDs
            where layout.pageIndexOfDirectApp(appID) == nil && layout.folderLocation(of: appID) == nil {
                _ = layout.appendApp(id: appID, toPage: fallbackPage, capacityPerPage: capacity)
            }

            layout.removeEmptyPages()
        }
        // 拖放收尾：只保留「仍直接摆放在网格上」的选择项。
        // 被拖走 / 被合入文件夹的 id 留在选择集里会形成陈旧选择：随后点「合并到新文件夹」
        // 会把已在文件夹里的应用再收进第二个文件夹（同一应用出现两次）。
        selectedAppIDs = selectedAppIDs.filter { layout.pageIndexOfDirectApp($0) != nil }
        // 打开态文件夹可能因这次拖放被摘空删除：面板必须一并关闭，否则只剩空白蒙层。
        reconcileOpenedFolder()
        currentPage = min(max(currentPage, 0), pageCount - 1)
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
        // 打开文件夹进入全屏子视图：网格的多选/框选不能再留在背后被工具栏操作。
        selectedAppIDs.removeAll()
        marqueeRect = nil
        openedFolder = (page, folderID)
    }

    public func closeFolder() {
        openedFolder = nil
    }

    /// 文件夹视图是否真的处于展示态（记录仍存在）。
    /// 导航、翻页、回车等入口都应以此判断，而不是 `openedFolder != nil`：
    /// 否则 `rescan`/卸载把文件夹搬走或删掉后，网格虽然回退渲染，键盘与滑动却全部被挡住。
    public var isFolderViewActive: Bool { openedFolderRecord != nil }

    /// 文件夹内重排：把拖拽项移到目标项之前。
    public func moveWithinFolder(draggingIDs: [String], folderID: UUID, beforeAppID: String) {
        guard dragAllowed else {
            showDragRequiresCustomSortToast()
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
    ///
    /// 按 `folderID` 跨页查找，而不是只看记录时的页下标：排序/重扫/整理会重建页面，
    /// 文件夹可能换页；只用旧下标会让记录「悬空」，视图回退网格但模型仍认为在文件夹里。
    public var openedFolderRecord: FolderRecord? {
        guard let opened = openedFolder else { return nil }
        for page in layout.pages {
            if let folder = page.items.compactMap(\.folder).first(where: { $0.id == opened.folderID }) {
                return folder
            }
        }
        return nil
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
        var created = false
        store.updateLayout { layout in
            layout.ensureHasPage()
            // 建文件夹：把当前页最后 1 个应用收进去（Launchpad 语义）。
            // 无应用时不建空文件夹占位——布局不变量「空文件夹不允许存在」，
            // 空夹没有任何交互入口（点开是空白、拖出成员即删除），只会困扰用户。
            let page = min(max(currentPage, 0), layout.pages.count - 1)
            guard let lastAppID = layout.pages[page].items.last(where: { $0.appID != nil })?.appID else { return }
            layout.pages[page].items.removeAll { $0.appID == lastAppID }
            let folder = FolderRecord(name: FolderEngine.defaultFolderName(layout: layout), appIDs: [lastAppID])
            layout.pages[page].items.append(.folder(folder))
            created = true
        }
        if !created {
            ToastManager.shared.show(.info, "当前页没有应用，无法新建文件夹")
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
        // 先把已不在注册表里的陈旧选择剔掉，避免提示的数量比实际隐藏的多。
        let ids = selectedAppIDs.filter { layout.apps[$0] != nil }
        guard !ids.isEmpty else {
            clearSelection()
            return
        }
        store.updateLayout { layout in
            for id in ids where layout.apps[id] != nil {
                layout.apps[id]?.hidden = true
                layout.detachFromGrid(id)
            }
        }
        ToastManager.shared.show(.info, "已隐藏 \(ids.count) 个应用")
        clearSelection()
        reconcileOpenedFolder()
    }

    /// 批量把选择合并进新文件夹。
    public func mergeSelectionIntoNewFolder() {
        let liveIDs = selectedAppIDs.filter { layout.apps[$0] != nil }
        let ids = liveIDs.sorted { a, b in
            let an = layout.apps[a]?.name ?? ""
            let bn = layout.apps[b]?.name ?? ""
            return an.localizedStandardCompare(bn) == .orderedAscending
        }
        guard ids.count >= 2 else {
            ToastManager.shared.show(.info, "至少选择 2 个应用才能创建文件夹")
            return
        }
        guard dragAllowed else {
            showDragRequiresCustomSortToast()
            return
        }
        store.updateLayout { layout in
            layout.ensureHasPage()
            let page = self.selectionAnchorPage(ids: ids, layout: layout)
            FolderEngine.mergeIntoNewFolder(appIDs: ids, page: page, layout: &layout)
        }
        clearSelection()
    }

    /// 多选合并的锚点页：当前页包含选中项时落在当前页；否则落到第一个含选中项的页。
    /// 滚动模式下 currentPage 可能滞后于可视页，直接用 currentPage 会让文件夹出现在
    /// 用户当时看不到的页（合并后「没有任何变化」）。
    private func selectionAnchorPage(ids: [String], layout: LayoutSnapshot) -> Int {
        guard !layout.pages.isEmpty else { return 0 }
        let current = min(max(currentPage, 0), layout.pages.count - 1)
        let selected = Set(ids)
        func pageContainsSelection(_ page: PageRecord) -> Bool {
            page.items.contains { item in
                if let appID = item.appID { return selected.contains(appID) }
                return item.folder?.appIDs.contains(where: selected.contains) == true
            }
        }
        if pageContainsSelection(layout.pages[current]) { return current }
        return layout.pages.firstIndex(where: pageContainsSelection) ?? current
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

    /// 上一次「来源目录读不到」提示对应的目录集合（集合变化时才再提示，避免重扫刷屏）。
    @ObservationIgnored private var lastUnreadableDirectoriesNotice: Set<String> = []

    /// 「未完成 bundle」补扫状态（见 `IncompleteBundleRetry`）。
    @ObservationIgnored private var incompleteRetry = IncompleteBundleRetry()
    @ObservationIgnored private var incompleteRetryWork: DispatchWorkItem?

    /// 扫描串行化：同一时刻只跑一次扫描，进行中的请求合并成结束后的一次补扫。
    /// 并发扫描会让两次合并看到同一个文件系统快照（如 Finder 替换安装的缺口），
    /// 「连续两次缺失才移除」的宽限一次就被耗尽，用户排列被删。
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var rescanRequestedDuringScan = false

    public func rescan() {
        isScanning = true
        guard !scanInFlight else {
            rescanRequestedDuringScan = true
            return
        }
        scanInFlight = true
        let sources = store.state.sources
        let capacity = density.capacity
        Task.detached(priority: .userInitiated) { [weak self] in
            // 扫描时保留既有 addedAt（NEW 只对真正的新应用亮）。
            // 用带诊断的版本：目录整体读不到（外置卷未挂载 / TCC 拒绝 / 安装器替换）时，
            // 该目录下的应用不能被当成「已卸载」——否则两次重扫就会永久丢掉排列。
            let diagnostics = AppIndex.scanWithDiagnostics(sources: sources)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let unreadable = diagnostics.failedDirectories.map(\.path)
                let incomplete = diagnostics.incompleteBundles.map(\.path)
                self.uninstallBlockReasonCache.removeAll()
                // 合并 + 排序合成一次落盘
                self.store.batchUpdates {
                    self.store.updateLayout { layout in
                        _ = SyncEngine.merge(
                            scanned: diagnostics.records,
                            into: &layout,
                            capacityPerPage: capacity,
                            // 覆盖更新中的 bundle（Info.plist 暂缺）同样只是「暂时读不到」，不累计缺失。
                            // 补扫用尽也继续保护：bundle 目录仍在磁盘上，删掉排列不可恢复，
                            // 而保留一个打不开的格子用户可以自行处理
                            unreadablePrefixes: unreadable + incomplete
                        )
                        // 保留既有使用统计与 NEW 状态：merge 刷新元数据已保留；
                        // 这里恢复 addedAt（merge 不覆盖在册 addedAt，无需处理）
                    }
                    // 非「自定义」排序模式下，扫描结果（含站外启动刷新的最近使用时间）落位后全局重排
                    self.store.applyActiveSort()
                }
                self.icons.invalidateCache()
                // 后台预热整仓图标：网格渲染（首展 / 滚动跨页）全部命中缓存，
                // 不再在主线程做突发性的同步重采样
                self.icons.preheat(
                    paths: diagnostics.records.map(\.path),
                    mode: self.settings.iconColorMode
                )
                self.pruneSelection()
                self.reconcileOpenedFolder()
                self.notifyUnreadableDirectories(unreadable)
                self.scheduleIncompleteBundleRetry(incomplete)
                self.scanInFlight = false
                if self.rescanRequestedDuringScan {
                    self.rescanRequestedDuringScan = false
                    self.rescan()
                } else {
                    self.isScanning = false
                }
            }
        }
    }

    /// 扫描结果里仍有未完成 bundle 时按退避间隔安排轻量探测（见 `IncompleteBundleRetry`）。
    private func scheduleIncompleteBundleRetry(_ paths: [String]) {
        switch incompleteRetry.scanCompleted(incomplete: Set(paths)) {
        case .cancel:
            incompleteRetryWork?.cancel()
            incompleteRetryWork = nil
        case .keep:
            // 同一批未完成 bundle：已有探测在排队就沿用，不让无关重扫消耗重试次数
            if incompleteRetryWork == nil { armIncompleteBundleProbe(after: incompleteRetry.currentDelay) }
        case .arm(let delay):
            armIncompleteBundleProbe(after: delay)
        }
    }

    private func armIncompleteBundleProbe(after delay: TimeInterval) {
        incompleteRetryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.probeIncompleteBundles() }
        }
        incompleteRetryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 只读待定 bundle 的 Info.plist：有变化（已可读 / bundle 已消失）才做整仓重扫，
    /// 否则推进退避——避免损坏 bundle 让整仓重扫（清图标缓存、重排、扫描态闪烁）反复空转。
    private func probeIncompleteBundles() {
        incompleteRetryWork = nil
        let fileManager = FileManager.default
        let changed = incompleteRetry.pending.contains { path in
            !fileManager.fileExists(atPath: path)
                || AppIndex.readInfoPlist(bundleAt: URL(fileURLWithPath: path), fileManager: fileManager) != nil
        }
        if changed {
            rescan()
        } else if let delay = incompleteRetry.probeFailed() {
            armIncompleteBundleProbe(after: delay)
        }
        // 用尽：只停止探测（保护仍在，见 rescan），不再空跑整仓重扫
    }

    /// 清掉已不在注册表里的选择项（卸载 / 重扫移除后调用）。
    private func pruneSelection() {
        guard !selectedAppIDs.isEmpty else { return }
        let live = selectedAppIDs.filter { layout.apps[$0] != nil }
        if live != selectedAppIDs {
            selectedAppIDs = live
        }
    }

    /// 打开态文件夹已不存在（被摘空删除 / 已移出网格）时关闭它。
    /// 否则模型仍认为在文件夹视图里：网格已回退渲染，但键盘/滑动/回车全被 `openedFolder` 挡住。
    private func reconcileOpenedFolder() {
        if openedFolder != nil, openedFolderRecord == nil {
            closeFolder()
        }
    }

    /// 来源目录整体读不到时给一次可见提示（目录集合变化才提示）：
    /// 用户需要知道「应用暂时消失」不是被删除了，并去检查磁盘 / 权限。
    private func notifyUnreadableDirectories(_ paths: [String]) {
        let current = Set(paths)
        guard current != lastUnreadableDirectoriesNotice else { return }
        lastUnreadableDirectoriesNotice = current
        guard !current.isEmpty else { return }
        ToastManager.shared.show(
            .info,
            "有 \(current.count) 个应用来源目录暂时无法读取，已保留其中应用的排列（请检查外置磁盘是否已挂载、文件访问权限）"
        )
    }
}

// MARK: - 未完成 bundle 补扫

/// 「未完成 bundle」补扫状态机：拖拽 / cp 安装时 .app 目录先出现、Info.plist 后写入，
/// 而 bundle 内部的写入不会触发来源目录的监听事件——不补扫的话新应用要等到下一次
/// 无关的目录变化才出现。按退避间隔探测，直到不再有未完成 bundle 或用尽次数；
/// 用尽的路径记为「已放弃」：不再探测（合并时仍当作暂时读不到，避免大应用的长时间
/// 覆盖更新丢失排列），直到它某次扫描恢复正常后才清出该集合。
struct IncompleteBundleRetry {
    static let delays: [TimeInterval] = [1.5, 2, 3, 5, 5, 10, 10, 15, 15, 30, 30, 60]

    enum Action: Equatable {
        case cancel
        case keep
        case arm(TimeInterval)
    }

    /// 正在等待补扫的未完成 bundle。
    private(set) var pending: Set<String> = []
    /// 补扫用尽仍未完成的 bundle。
    private(set) var exhausted: Set<String> = []
    private(set) var attempt = 0

    var currentDelay: TimeInterval { Self.delays[min(attempt, Self.delays.count - 1)] }

    /// 一次扫描完成：更新待定集合，返回对探测定时器的处理。
    mutating func scanCompleted(incomplete: Set<String>) -> Action {
        exhausted.formIntersection(incomplete)
        let newPending = incomplete.subtracting(exhausted)
        guard !newPending.isEmpty else {
            pending = []
            attempt = 0
            return .cancel
        }
        guard newPending != pending else { return .keep }
        pending = newPending
        attempt = 0
        return .arm(Self.delays[0])
    }

    /// 一次探测没发现变化：返回下一次探测的延迟；nil 表示用尽（待定集合转入已放弃）。
    mutating func probeFailed() -> TimeInterval? {
        attempt += 1
        if attempt < Self.delays.count { return Self.delays[attempt] }
        exhausted.formUnion(pending)
        pending = []
        attempt = 0
        return nil
    }
}
