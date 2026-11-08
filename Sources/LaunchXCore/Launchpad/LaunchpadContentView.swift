import AppKit
import Observation
import SwiftUI

/// 壁纸图片容器。
///
/// 壁纸是唯一会随每次展开变化的内容。之前控制器在截图返回后直接替换
/// `NSHostingView.rootView`，等于销毁并重建整棵视图树：正在输入的搜索词、
/// 搜索框焦点、滚动位置与所有 @State 都会丢（P2-12）。把它抽成独立的
/// @Observable 后，刷新只改 `image`，视图树与交互状态不变。
@MainActor
@Observable
public final class LaunchpadWallpaperStore {
    public var image: NSImage?

    public init(image: NSImage? = nil) {
        self.image = image
    }
}

/// 网格键盘焦点（P3-4）。
///
/// 放在内容视图之外、由控制器持有：面板层要处理方向键/Tab/Return，
/// 视图层要据此画焦点环——两边读写同一份状态。焦点按「当前页内的格位索引」
/// 记录，翻页、搜索、打开文件夹时清空（由视图层在 currentPage 变化时清理）。
@MainActor
@Observable
public final class GridKeyboardFocus {
    /// 当前页内的格位索引（对应 `PageRecord.items` 的下标），nil = 无焦点。
    public var focusedIndex: Int?
    /// 焦点所属页；与 `model.currentPage` 不一致时视为失效。
    public var pageIndex: Int = 0

    public init() {}

    public func clear() {
        focusedIndex = nil
    }

    public func set(index: Int?, page: Int) {
        focusedIndex = index
        pageIndex = page
    }
}

/// 网格键盘导航状态机（纯逻辑，便于单测）。
///
/// 索引是当前页 `items` 的下标（LazyVGrid 按行优先排布，列数 = `density.columns`）。
/// 语义约定：
/// - 无焦点时 `next/previous`（Tab/Shift-Tab）落到首/末项，`.left/.up/.down/.right`
///   由调用方优先走翻页，不经过这里；
/// - 水平方向在行首/行尾返回 `.turnPage`，由调用方尝试翻页并在新页首尾重新落焦；
/// - 垂直方向到边界返回 `.stay`（翻页只发生在水平方向）。
enum GridFocusNavigator {
    enum Direction: Equatable {
        case left, right, up, down, next, previous
    }

    enum Move: Equatable {
        case focus(Int)
        case turnPage
        case stay
        case clear
    }

    static func move(from current: Int?, direction: Direction, count: Int, columns: Int) -> Move {
        guard count > 0, columns > 0 else { return .clear }
        guard let current, (0..<count).contains(current) else {
            switch direction {
            case .previous, .left, .up:
                return .focus(count - 1)
            case .next, .right, .down:
                return .focus(0)
            }
        }
        switch direction {
        case .left:
            return current % columns == 0 ? .turnPage : .focus(current - 1)
        case .right:
            let atRowEnd = current % columns == columns - 1
            return (atRowEnd || current == count - 1) ? .turnPage : .focus(current + 1)
        case .up:
            return current - columns >= 0 ? .focus(current - columns) : .stay
        case .down:
            let next = current + columns
            return next < count ? .focus(next) : .stay
        case .next:
            return current + 1 < count ? .focus(current + 1) : .turnPage
        case .previous:
            return current - 1 >= 0 ? .focus(current - 1) : .turnPage
        }
    }
}

/// Launchpad 主内容视图（全屏覆盖层根视图）。
public struct LaunchpadContentView: View {
    // 根视图直接持有 model；不可在此声明 @Environment(LaunchpadModel.self)——
    // .environment(model) 只注入给子视图，根视图自身取值会因环境缺失直接崩溃
    // （Fatal error: No Observable object of type LaunchpadModel found）。
    let model: LaunchpadModel
    let wallpaper: LaunchpadWallpaperStore
    /// 网格键盘焦点（P3-4）：与控制器共享，方向键/Tab/Return 由面板层驱动。
    let gridFocus: GridKeyboardFocus

    @State private var itemFrames: [String: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var gridMetrics = GridMetrics.standard
    /// 最近一次布局用的窗口尺寸（密度变化时重算网格度量）。
    @State private var contentSize: CGSize = .zero
    @FocusState private var searchFocused: Bool
    /// 系统「减弱动态效果」；开启时去掉内容缩放与弹簧（P3-3）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        model: LaunchpadModel,
        wallpaper: LaunchpadWallpaperStore,
        gridFocus: GridKeyboardFocus
    ) {
        self.model = model
        self.wallpaper = wallpaper
        self.gridFocus = gridFocus
    }

    /// 手势期间逐帧取实时进度；其他入口仍由可见性驱动完整弹簧动画。
    private var transitionProgress: Double {
        model.pinchTransitionProgress ?? (model.isVisible ? 1 : 0)
    }

    public var body: some View {
        ZStack {
            // 背景只做透明度合成；缩放仅作用于启动台内容。避免把全屏壁纸 /
            // NSVisualEffectView 与所有图标合并成一张每帧重绘的离屏纹理。
            background
                .opacity(transitionProgress)
            // 展开/收起：内容从 1.15 倍向内收缩并淡入，收起时反向放大淡出。
            // scaleEffect 是纯渲染变换不触发布局，由 GPU 合成。
            content
                // 减弱动态效果时不缩放，只淡入淡出（P3-3）
                .scaleEffect(MotionPreference.contentScale(
                    progress: transitionProgress, reduceMotion: reduceMotion
                ))
                .opacity(transitionProgress)
        }
        // 收起态与跟手期间整体关闭命中测试，避免透明全屏层误启动应用。
        .allowsHitTesting(model.isVisible && model.pinchTransitionProgress == nil)
        .animation(MotionPreference.panelTransition(reduceMotion: reduceMotion), value: model.isVisible)
        .environment(model)
        .onChange(of: model.searchFocusTrigger) { _, _ in
            searchFocused = true
        }
    }

    // MARK: 背景：壁纸（捕获侧 CoreImage 预模糊）+ GlassTint / 毛玻璃回退
    // 注意：不可在此用 SwiftUI .blur —— macOS 26 实测该修饰符（任意半径）会破坏
    // NSHostingView 内 ZStack 的合成层级（效果层盖住内容、同层图片不渲染）。

    @ViewBuilder private var background: some View {
        ZStack {
            if model.settings.blurWallpaper, let wallpaperImage = wallpaper.image {
                Image(nsImage: wallpaperImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                // 暗化叠层：壁纸路径重暗化、不加白 tint（保住壁纸饱和度，
                // 对齐原版观感：壁纸色彩清晰可辨、白字可读）
                Color.black.opacity(0.28)
            } else {
                // 仅在无壁纸时启用全屏实时毛玻璃；壁纸已预模糊，无需叠加两套模糊。
                VisualEffectBlur(material: model.settings.glassMaterial.material)
                Color.black.opacity(0.18)
                LXColors.glassTint(LXColors.isDark)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 主体

    private var content: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                searchBar
                    .padding(.top, 62)
                    .padding(.bottom, 26)

                if !model.searchQuery.isEmpty {
                    SearchResultsGrid()
                } else if model.openedFolder != nil {
                    OpenedFolderView()
                } else if model.settings.browsingStyle == .paged {
                    PagedGridArea(
                        itemFrames: $itemFrames,
                        marqueeStart: $marqueeStart,
                        gridFocus: gridFocus
                    )
                        .transition(.opacity)
                } else {
                    ScrollGridArea(itemFrames: $itemFrames)
                }

                if model.settings.browsingStyle == .paged, model.searchQuery.isEmpty, model.openedFolder == nil {
                    PageIndicatorView()
                        .padding(.bottom, 40)
                }

                if !model.selectedAppIDs.isEmpty {
                    SelectionStatusBar()
                        .padding(.bottom, 12)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onPreferenceChange(ItemFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .onChange(of: model.marqueeRect) { _, rect in
                guard rect != nil else { return }
                // 框选矩形属于 pageViewSpace（视口坐标），cell frame 属于页内 pageSpace；
                // 两者只差当前页在视口中的渲染原点（稳态 0，跟手/落位期间 = pageDragOffset）。
                // 统一换算到视口坐标后再做相交判定，避免落位偏移期间框选错位。
                let frames = MarqueeCoordinate.viewSpaceFrames(
                    itemFrames, pageOriginX: model.pageDragOffset
                )
                model.updateMarqueeSelection(itemFrames: frames, inPage: model.currentPage)
            }
            .onChange(of: model.currentPage) { _, newPage in
                // 翻页（横滑/页码点/键盘导航之外的入口）后旧焦点已无意义；
                // 键盘翻页会先把 gridFocus.pageIndex 对齐到目标页，不会误清。
                if gridFocus.pageIndex != newPage {
                    gridFocus.clear()
                }
            }
            .onChange(of: model.pageCount) { _, newCount in
                // 页数收缩（删应用 / 导入 / 整理等，含其他窗口对 store 的变更）时
                // 钳回有效页，保持页码指示器高亮与网格一致
                if model.currentPage > newCount - 1 {
                    model.currentPage = newCount - 1
                }
            }
            .onAppear(perform: { updateMetrics(in: geo.size) })
            .onChange(of: geo.size) { _, newSize in updateMetrics(in: newSize) }
            .onChange(of: model.density) { _, _ in
                guard contentSize != .zero else { return }
                updateMetrics(in: contentSize)
            }
            .environment(\.gridMetrics, gridMetrics)
            // 空白点击兜底：子视图（图标/按钮/搜索框）未消费的点击落到这里
            // （网格区侧边距、顶部区域、搜索结果与文件夹面板空白均由此收起/关文件夹）。
            // contentShape 必须显式指定：VStack 空白处无渲染内容，默认点击会穿透到窗口层
            .contentShape(Rectangle())
            .onTapGesture { model.handleBackgroundTap() }
            // Esc 的 SwiftUI 路由：@FocusState 程序化聚焦搜索框时，Esc 由 SwiftUI 焦点系统
            // 派发（不经过面板 keyDown/cancelOperation），在此兜底。
            // 分层与面板路径一致：组字中不拦截 → 搜索词非空先清空 → 关文件夹/清选择/收起
            .onExitCommand { handleEscapeCommand() }
        }
    }

    /// 网格可用高度 = 总高 − 搜索区（62+40+26）− 网格顶 padding（44）− 底部页码区（~72）。
    /// 自然尺寸由密度决定；此处只提供可用区域供小屏收缩（只缩不放）。
    private func updateMetrics(in size: CGSize) {
        contentSize = size
        var gridArea = size
        gridArea.height -= 62 + 40 + 26 + 44 + 72
        let metrics = GridMetrics.compute(areaSize: gridArea, density: model.density)
        if metrics != gridMetrics { gridMetrics = metrics }
    }

    /// Esc 分层（SwiftUI 焦点路径）。判定与面板 `keyDown` 路径共用 `EscapeKeyRouter`：
    /// 输入法组字中不拦截 → 搜索词非空先清空 → 否则关文件夹 / 清选择 / 收起面板。
    private func handleEscapeCommand() {
        let composing = (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        switch EscapeKeyRouter.action(
            isComposingText: composing,
            searchQuery: model.searchQuery,
            // 文件夹打开时优先关文件夹（既有分层），焦点层让位
            hasGridFocus: gridFocus.focusedIndex != nil && model.openedFolder == nil
        ) {
        case .passThrough:
            return
        case .clearSearch:
            model.searchQuery = ""
            searchFocused = true  // 清空后保持焦点，便于接着输入
        case .dismissGridFocus:
            gridFocus.clear()
        case .background:
            model.handleBackgroundTap()
        }
    }

    // MARK: 搜索栏（顶部居中胶囊，比例与内容对齐原版）

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            TextField(
                "搜索应用",
                text: Bindable(model).searchQuery,
                prompt: Text("搜索应用").foregroundStyle(.white.opacity(0.85))
            )
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .onChange(of: model.searchQuery) { _, _ in
                    model.searchSelectedIndex = 0
                }
                .onSubmit { launchSelectedSearchHit() }
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(width: Self.searchCapsuleWidth, height: 40)
        .contentShape(Rectangle())
        // 消费胶囊整体点击，避免点放大镜/胶囊留白被根级手势误判为空白而收起
        .onTapGesture { }
        .liquidGlassCapsule()
        // 轻描边提升辨识度，不做过多强调
        .overlay(
            Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    /// 搜索胶囊宽度：设计稿 500px @2x Retina → 250pt。
    /// 固定值，不跟随刘海/窗口宽度。
    private static let searchCapsuleWidth: CGFloat = 250

    private func launchSelectedSearchHit() {
        let hits = model.searchHits
        guard !hits.isEmpty else { return }
        // searchSelectedIndex 可能为 -1 / 越界（方向键或结果集变化后残留），上下都钳住
        let index = min(max(model.searchSelectedIndex, 0), hits.count - 1)
        model.launch(appID: hits[index].appID)
    }
}

// MARK: - 分页网格区

/// 整条页面带 + 橡皮筋选框 + 背景放置目标。
///
/// LaunchOS 同款翻页：全部页一字排开成一条常驻条带，键盘/页码点/横滑落位
/// 都只是条带单一 offset 的变化——无逐页视图重建、无逐帧 frame 上报洪水，
/// 动画全程 GPU 合成；横滑跟手天然露出相邻页（条带本就连续）。
struct PagedGridArea: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var itemFrames: [String: CGRect]
    @Binding var marqueeStart: CGPoint?
    let gridFocus: GridKeyboardFocus

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let settledIndex = model.pageCount > 0
                ? min(model.currentPage, model.pageCount - 1)
                : 0
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<max(model.pageCount, 1), id: \.self) { pageIndex in
                        PageGridView(
                            pageIndex: pageIndex,
                            focusedSlot: pageIndex == model.currentPage ? gridFocus.focusedIndex : nil
                        )
                        .frame(width: width, height: proxy.size.height)
                    }
                }
                .offset(x: -CGFloat(settledIndex) * width + model.pageDragOffset)

                marqueeOverlay(in: proxy)
            }
            .clipped()
            .coordinateSpace(name: "pageViewSpace")
            .contentShape(Rectangle())
            .onTapGesture {
                model.handleBackgroundTap()
            }
            .contextMenu { pageMenuItems }
            .gesture(marqueeGesture(in: proxy))
            .onDrop(of: [DragPayload.type], delegate: PageBackgroundDropDelegate(model: model, pageIndex: model.currentPage))
            .onMoveCommand { direction in
                // 横滑落位动画未结束时翻页会与 finishDragCommit 叠加成「跳两页」（P2-13）
                guard PageSettleGuard.allowsNavigation(
                    isSettlingPageDrag: model.isSettlingPageDrag
                ) else { return }
                switch direction {
                case .left: model.previousPage()
                case .right: model.nextPage()
                default: break
                }
            }
            // 对齐必须显式 topLeading：frame 默认居中会把 3 页宽的条带左移一页，
            // 表现为「每页显示下一页的内容、末页空白」（首页内容永远不可见）
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear { model.pageWidth = proxy.size.width }
            .onChange(of: proxy.size.width) { _, width in model.pageWidth = width }
        }
        // 键盘/页码点翻页与横滑落位同曲线同时长（条带整段滑动）；
        // 减弱动态效果时只缩短时长，仍保留位移（避免「瞬间跳变」的观感）
        .animation(MotionPreference.pageSlide(reduceMotion: reduceMotion), value: model.currentPage)
    }

    /// 页面空白处右键菜单（承接原版 More 菜单入口）。
    @ViewBuilder private var pageMenuItems: some View {
        Button("整理布局…") { model.onOpenReorganize?() }
        Button("设置…") { model.onOpenSettings?() }
        Divider()
        Button("新建文件夹") { model.createNewFolderOnCurrentPage() }
        Button("解散全部文件夹") { model.ungroupAllFolders() }
    }

    // MARK: 橡皮筋

    @ViewBuilder private func marqueeOverlay(in proxy: GeometryProxy) -> some View {
        if let rect = model.marqueeRect {
            Rectangle()
                .fill(LXColors.selection(LXColors.isDark).opacity(0.12))
                .overlay(
                    Rectangle()
                        .strokeBorder(LXColors.selection(LXColors.isDark), lineWidth: 1.5)
                )
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private func marqueeGesture(in proxy: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("pageViewSpace"))
            .onChanged { value in
                // Caps Lock 等标志位不影响 ⌘ 框选判定（P3-1）
                guard InteractionModifiers.hasCommand(NSEvent.modifierFlags) else {
                    if marqueeStart == nil { marqueeStart = value.startLocation }
                    return
                }
                if marqueeStart == nil { marqueeStart = value.startLocation }
                guard let start = marqueeStart else { return }
                model.marqueeRect = CGRectFromPoints(start, value.location)
            }
            .onEnded { _ in
                marqueeStart = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    model.marqueeRect = nil
                }
            }
    }
}

/// 两点 → 矩形。
func CGRectFromPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(
        x: min(a.x, b.x), y: min(a.y, b.y),
        width: abs(a.x - b.x), height: abs(a.y - b.y)
    )
}

/// 框选相关的坐标换算（纯逻辑，便于单测）。
///
/// 两套坐标系：
/// - `pageViewSpace`：`PagedGridArea` 在条带视图上声明的空间（原点 = 网格区左上角）。
///   `DragGesture` 上报的 `startLocation`/`location`、以及 `model.marqueeRect` 都属于它；
/// - `pageSpace`：`PageGridView` 声明的单页内部空间，`AppCell` 上报的 cell frame 属于它。
///
/// 两者只差「当前页在视口中的渲染原点」：稳态为 0（页带 offset 与 settled 页正好抵消，
/// 实测已用合成鼠标事件验证），跟手/落位期间 x = `pageDragOffset`。
/// 换算把页内 frame 平移到视口坐标后再与框选矩形求交，落位偏移期间也不会错位。
enum MarqueeCoordinate {
    /// 页内坐标 → 视口坐标：两者仅 x 相差当前页渲染原点。
    static func viewSpaceFrames(_ frames: [String: CGRect], pageOriginX: CGFloat) -> [String: CGRect] {
        guard pageOriginX != 0 else { return frames }
        return frames.mapValues { $0.offsetBy(dx: pageOriginX, dy: 0) }
    }
}

// MARK: - 单页网格

struct PageGridView: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.gridMetrics) private var metrics
    let pageIndex: Int
    /// 键盘焦点格位（P3-4）：仅当前页会传入非 nil。
    var focusedSlot: Int? = nil

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cellWidth), spacing: metrics.columnSpacing), count: model.density.columns)
    }

    var body: some View {
        Group {
            if pageIndex < model.layout.pages.count {
                let items = model.layout.pages[pageIndex].items
                LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                    ForEach(Array(items.enumerated()), id: \.element) { slotIndex, item in
                        switch item {
                        case let .app(appID):
                            if let app = model.layout.apps[appID] {
                                AppCell(
                                    app: app,
                                    pageIndex: pageIndex,
                                    folderID: nil,
                                    isSearchResult: false,
                                    isKeyboardFocused: focusedSlot == slotIndex
                                )
                                .id(slotIndex)
                            }
                        case let .folder(folder):
                            // FolderCell 由 panel 组维护，焦点环在容器侧叠加（P3-4）
                            FolderCell(folder: folder, pageIndex: pageIndex)
                                .overlay { folderFocusRing(slotIndex: slotIndex) }
                                .id(slotIndex)
                        }
                    }
                }
                // 先把内容锚定在整页网格虚拟尺寸的左上角，再在可用区域内顶部居中：
                // 末页剩余项保持与满页相同的格位（不随条数收缩漂移到页面中央）；
                // 顶部对齐 + 顶 padding 对齐 LaunchOS 首行位置（首行紧贴搜索栏下方）
                .frame(
                    width: CGFloat(model.density.columns) * metrics.cellWidth,
                    height: CGFloat(model.density.rows) * metrics.cellHeight
                        + CGFloat(model.density.rows - 1) * metrics.gridSpacing,
                    alignment: .topLeading
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 44)
            } else {
                EmptyStateView(systemImage: model.isScanning ? "hourglass" : "square.grid.3x3",
                               title: model.isScanning ? "正在扫描应用…" : "这一页是空的")
            }
        }
        // 页内坐标空间：cell 的 frame 上报（橡皮筋选框用）以此为准。
        // 相对坐标不受条带 offset 影响，翻页动画期间不再逐帧刷新上报。
        .coordinateSpace(name: "pageSpace")
    }

    @ViewBuilder private func folderFocusRing(slotIndex: Int) -> some View {
        if focusedSlot == slotIndex {
            RoundedRectangle(cornerRadius: metrics.cornerRadius + 3, style: .continuous)
                .strokeBorder(LXColors.accent, lineWidth: 3)
                .padding(-6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 滚动模式

/// Scroll 模式：全部页面纵向连续滚动（仅纵向锁定）。
struct ScrollGridArea: View {
    @Environment(LaunchpadModel.self) private var model
    @Binding var itemFrames: [String: CGRect]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 44) {
                ForEach(Array(model.layout.pages.enumerated()), id: \.element.id) { pageIndex, _ in
                    PageGridView(pageIndex: pageIndex)
                        .frame(minHeight: 360)
                        // 每个页面各自接收投放：滚动模式下空白处拖入应用应落到「那一页」，
                        // 之前统一按第 0 页处理，用户在第 N 页拖放后看不到落点（P2-1）。
                        .onDrop(
                            of: [DragPayload.type],
                            delegate: PageBackgroundDropDelegate(model: model, pageIndex: pageIndex)
                        )
                }
            }
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .coordinateSpace(name: "pageSpace")
        .onTapGesture { model.handleBackgroundTap() }
    }
}

// MARK: - 页码指示器

struct PageIndicatorView: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<model.pageCount, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == model.currentPage ? 0.95 : 0.35))
                    .frame(width: index == model.currentPage ? 9 : 7,
                           height: index == model.currentPage ? 9 : 7)
                    // 视觉圆点保持 7/9pt，命中区扩到 24×24：7pt 圆几乎点不中，
                    // 点偏一点就落到根级 onTapGesture 把面板收起（P2-20）。
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // 落位动画未结束时翻页会让 finishDragCommit 再提交一次（P2-13）
                        guard PageSettleGuard.allowsNavigation(
                            isSettlingPageDrag: model.isSettlingPageDrag
                        ) else { return }
                        model.goToPage(index)
                    }
            }
        }
        .padding(8)
        .contentShape(Rectangle())
        // 点圆点之间的留白落在容器上：显式消费，避免冒泡到根级手势收起面板。
        .onTapGesture { }
        // 页码点大小/透明度随翻页用同一贝塞尔缓出平滑过渡（减弱动态效果时缩短）
        .animation(MotionPreference.pageSlide(reduceMotion: reduceMotion), value: model.currentPage)
    }
}

// MARK: - 搜索结果网格

struct SearchResultsGrid: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.gridMetrics) private var metrics

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cellWidth), spacing: metrics.columnSpacing), count: model.density.columns)
    }

    var body: some View {
        ScrollView {
            if model.searchHits.isEmpty {
                EmptyStateView(systemImage: "sparkle.magnifyingglass",
                               title: "没有找到匹配的应用",
                               subtitle: "只搜索应用名称")
                    .frame(minHeight: 320)
            } else {
                LazyVGrid(columns: columns, spacing: metrics.gridSpacing) {
                    ForEach(Array(model.searchResultAppIDs.enumerated()), id: \.element) { index, appID in
                        if let app = model.layout.apps[appID] {
                            AppCell(app: app, pageIndex: 0, folderID: nil, isSearchResult: true)
                                .overlay(alignment: .topLeading) {
                                    if index == model.searchSelectedIndex {
                                        RoundedRectangle(cornerRadius: 12)
                                            .strokeBorder(LXColors.accent, lineWidth: 2)
                                            .padding(-4)
                                    }
                                }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - 选中状态栏（Selected %d items）

struct SelectionStatusBar: View {
    @Environment(LaunchpadModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Text("已选择 \(model.selectedAppIDs.count) 项")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            Divider().frame(height: 12)
            Button("合并到新文件夹") { model.mergeSelectionIntoNewFolder() }
            Button("隐藏") { model.hideSelection() }
            Button("取消") { model.clearSelection() }
        }
        .buttonStyle(.link)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .liquidGlassCapsule()
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 页面空白处放置（追加到页尾 / 从文件夹移出）

struct PageBackgroundDropDelegate: DropDelegate {
    let model: LaunchpadModel
    let pageIndex: Int

    func performDrop(info: DropInfo) -> Bool {
        // 载荷自带会话 id：外部纯文本、旧格式、上一次拖拽的陈旧载荷都会被拒绝。
        // `load` 是异步回调（主线程），因此这里只用返回值表示「是否接受了拖放」。
        let accepted = DragPayload.load(from: info) { payload in
            guard let payload, DragObserver.shared.isCurrent(payload.sessionID) else { return }
            let dragging = payload.appIDs
            DragObserver.shared.endDrag(sessionID: payload.sessionID)
            guard !dragging.isEmpty else { return }
            // 源文件夹：拖出语义
            let sourceFolderID = model.openedFolder?.folderID
            model.performDrop(
                draggingIDs: dragging,
                sourceFolderID: sourceFolderID,
                target: .pageBackground(page: max(pageIndex, 0))
            )
        }
        return accepted
    }
}

// MARK: - 网格度量（自然尺寸由密度决定、不随屏幕拉伸，比例实测对齐原版 LaunchOS）

/// 由行列密度推导的一组尺寸 Token（自然尺寸，不随屏幕拉伸）。
struct GridMetrics: Equatable {
    var iconSize: CGFloat
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var gridSpacing: CGFloat
    var columnSpacing: CGFloat
    var labelFont: CGFloat
    var cornerRadius: CGFloat

    /// 图标占格子跨度的比例（＝图标/列距，调大＝列间距更紧凑）。
    /// 0.51 = LaunchOS 实测：磁贴/列距 ≈ 103/251.5pt（3008×1692、7×5）。
    private static let iconWidthRatio: CGFloat = 0.51
    /// 基准图标：140pt 减 10pt = 130pt（260px@2x）。
    private static let baseIconSize: CGFloat = 130
    /// 图标下限（极小窗口兜底）。
    private static let minIconSize: CGFloat = 56
    /// 行距自然值系数（相对图标）与下限：大屏取自然值
    /// （1.0 = LaunchOS 实测：行距 291.5pt − 格高 161pt ≈ 130pt 净空隙）。
    private static let rowSpacingRatio: CGFloat = 1.0
    private static let rowSpacingMin: CGFloat = 20
    /// 横向最小侧边距：列宽收缩只在扣除它之后的空间里推导（只缩不放）。
    private static let minSideMargin: CGFloat = 24
    /// 单元内容高的常数部分：图标框 +8、VStack 间距 7、标签行 16（fittingSize 实测）。
    private static let cellExtraHeight: CGFloat = 31

    /// LaunchOS 同款策略：图标用固定自然尺寸（按密度按平方根缩放），
    /// 屏幕变小/高度不足时由行距向下压缩吸收（间距缩、图标不缩）；
    /// 只有横向放不下、或连最小行距都放不下时才缩图标。
    /// 网格按自然尺寸排布，在可用区域内顶部对齐、左右居中留白。
    static func compute(areaSize: CGSize, density: GridDensity) -> GridMetrics {
        let scale = sqrt(CGFloat(GridDensity.default.capacity) / CGFloat(density.capacity))
        let natural = baseIconSize * scale
        // 横向：扣掉最小侧边距后按列宽收缩（只缩不放）
        let fitWidth = ((areaSize.width - 2 * minSideMargin) / CGFloat(density.columns)) * iconWidthRatio
        var iconSize = max(min(natural, fitWidth), minIconSize)
        let rows = CGFloat(density.rows)
        // 纵向：先按图标自然高度排，余量摊进行距（自然值封顶、下限保底）
        let cellHeight = iconSize + cellExtraHeight
        var gridSpacing = min(
            max((areaSize.height - rows * cellHeight) / max(rows - 1, 1), rowSpacingMin),
            iconSize * rowSpacingRatio
        )
        // 兜底：连最小行距都放不下 → 回到按高度缩图标路径（极矮窗口）
        if rows * cellHeight + (rows - 1) * gridSpacing > areaSize.height {
            iconSize = max(min(iconSize, verticalFit(areaSize.height, rows: density.rows)), minIconSize)
            gridSpacing = max(
                rowSpacingMin,
                min(
                    iconSize * rowSpacingRatio,
                    (areaSize.height - rows * (iconSize + cellExtraHeight)) / max(rows - 1, 1)
                )
            )
        }
        return GridMetrics(
            iconSize: iconSize,
            // 格宽即列距（130/0.51 ≈ 255pt），列间距为 0，格与格贴合
            cellWidth: iconSize / iconWidthRatio,
            cellHeight: iconSize + cellExtraHeight,
            gridSpacing: gridSpacing,
            columnSpacing: 0,
            labelFont: iconSize >= 80 ? 13 : 12,
            cornerRadius: iconSize * 0.22
        )
    }

    /// 垂直可容纳的最大图标（兜底路径）：rows×(s+31) + (rows−1)×行间距 ≤ 可用高度
    /// （行间距 = max(20, ratio·s)；分段求解保证任何窗口高度都不溢出）。
    private static func verticalFit(_ areaHeight: CGFloat, rows: Int) -> CGFloat {
        let r = CGFloat(rows)
        let proportional = (areaHeight - r * cellExtraHeight) / (r + (r - 1) * rowSpacingRatio)
        if proportional * rowSpacingRatio >= rowSpacingMin { return proportional }
        // 行间距触底后按固定下限求解
        return (areaHeight - r * cellExtraHeight - (r - 1) * rowSpacingMin) / r
    }

    static let standard = GridMetrics(
        iconSize: 64, cellWidth: 64 / 0.51, cellHeight: 95,
        gridSpacing: 64, columnSpacing: 0, labelFont: 12, cornerRadius: 14
    )
}

private struct GridMetricsKey: EnvironmentKey {
    static let defaultValue = GridMetrics.standard
}

extension EnvironmentValues {
    var gridMetrics: GridMetrics {
        get { self[GridMetricsKey.self] }
        set { self[GridMetricsKey.self] = newValue }
    }
}

// MARK: - NSVisualEffectView 封装

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
