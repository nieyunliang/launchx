import AppKit
import Observation
import SwiftUI

/// 整理会话：执行排序 / 补空位 / 跨页重排，并保留一次可撤销的布局快照。
///
/// 快照只保留「最近一次真正改变了布局」的操作，撤销后清空；
/// 由窗口持有，窗口关闭再打开仍可撤销上一次整理。
@MainActor
@Observable
final class ReorganizeSession {

    enum Outcome: Equatable {
        case changed
        case unchanged
    }

    private let store: LayoutStore
    private let model: LaunchpadModel

    private(set) var undoSnapshot: LayoutSnapshot?
    /// 最近一次应用的操作名（撤销条文案用）。
    private(set) var lastAppliedLabel: String?

    var canUndo: Bool { undoSnapshot != nil }

    init(store: LayoutStore, model: LaunchpadModel) {
        self.store = store
        self.model = model
    }

    @discardableResult
    func apply(_ request: ReorganizeRequest) -> Outcome {
        // 先把设置与快照读成局部值：updateLayout 的闭包执行期间持有 state 的独占修改权，
        // 闭包里再读 store.state 会触发运行时独占访问 trap。
        let settings = store.state.settings
        let capacity = max(settings.gridDensity.capacity, 1)
        let before = store.state.layout
        store.updateLayout { layout in
            let options = SortOptions(
                alsoSortFolderContents: request.alsoSortFolderContents,
                folderPosition: settings.folderPosition,
                appleAppsPosition: settings.appleAppsPosition
            )
            switch request.action {
            case .sort:
                SortEngine.apply(
                    &layout,
                    key: request.sortKey,
                    ascending: request.ascending,
                    scope: request.scope,
                    options: options
                )
            case .fillEmptySlots:
                ReorganizeEngine.fillEmptySlots(
                    &layout,
                    scope: request.scope,
                    capacityPerPage: capacity
                )
            case .reorganizeAcrossPages:
                ReorganizeEngine.reorganizeAcrossPages(
                    &layout,
                    scope: request.scope,
                    capacityPerPage: capacity
                )
            }
        }
        // 排序生效后同步激活模式（Custom 之外禁拖拽）
        if case .sort = request.action {
            model.activeSortKey = request.sortKey
        }
        model.currentPage = min(model.currentPage, max(model.pageCount - 1, 0))

        let after = store.state.layout
        // 只比较槽位结构：PageRecord 每次重铺都会生成新的 id，整份快照比较会误判为「有变化」。
        guard after.pages.map(\.items) != before.pages.map(\.items) else {
            ToastManager.shared.info(request.action.unchangedMessage)
            return .unchanged
        }
        undoSnapshot = before
        lastAppliedLabel = request.action.label
        ToastManager.shared.success("布局已更新，可点「撤销」恢复")
        return .changed
    }

    /// 恢复上一次整理前的布局并落盘。仅在快照存在时可用（幂等）。
    func undo() {
        guard let snapshot = undoSnapshot else { return }
        store.updateLayout { $0 = snapshot }
        undoSnapshot = nil
        lastAppliedLabel = nil
        model.currentPage = min(model.currentPage, max(model.pageCount - 1, 0))
        ToastManager.shared.success("已撤销上次整理")
    }
}

/// 整理布局（Reorganize Layout）窗口：排序规则 + 作用域 + 补空位 / 跨页重排。
@MainActor
public final class ReorganizeWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    private let store: LayoutStore
    private let model: LaunchpadModel
    private let session: ReorganizeSession

    public init(store: LayoutStore, model: LaunchpadModel) {
        self.store = store
        self.model = model
        self.session = ReorganizeSession(store: store, model: model)
    }

    public func show() {
        let content = ReorganizeContentView(
            pageCount: max(store.state.layout.pages.count, 1),
            currentPage: model.currentPage,
            session: session
        )
        let hosting = NSHostingView(rootView: content)

        if let window {
            window.contentView = hosting
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "整理布局"
            window.contentView = hosting
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        WindowFade.fadeIn(window!)
    }

    /// 关闭按钮 → 淡出后仅移出屏幕（窗口对象保留供复用）。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowFade.fadeOut(sender)
        return false
    }
}

/// 整理请求。
struct ReorganizeRequest {
    enum Action {
        case sort
        case fillEmptySlots
        case reorganizeAcrossPages

        var label: String {
            switch self {
            case .sort: "排序"
            case .fillEmptySlots: "补空位"
            case .reorganizeAcrossPages: "跨页整体重排"
            }
        }

        /// 布局没有任何变化时给用户的说明（尤其是空实现的「补空位」）。
        var unchangedMessage: String {
            switch self {
            case .sort: "布局没有变化（当前已是该排序结果）"
            case .fillEmptySlots: "布局已是紧凑的，没有可补的空位"
            case .reorganizeAcrossPages: "布局没有变化（已是紧凑排列）"
            }
        }
    }

    var action: Action
    var sortKey: SortKey
    var ascending: Bool
    var scope: SortScope
    var alsoSortFolderContents: Bool
}

/// 整理布局内容视图。
struct ReorganizeContentView: View {
    let pageCount: Int
    let currentPage: Int
    let session: ReorganizeSession

    @State private var selectedPageIndices: Set<Int> = []
    @State private var scopeMode: ScopeMode = .all
    @State private var sortKey: SortKey = .name
    @State private var ascending = true
    @State private var alsoSortFolderContents = true
    @State private var confirmAcrossPages = false

    enum ScopeMode: Hashable {
        case all
        case current
        case selected
    }

    private var scope: SortScope {
        switch scopeMode {
        case .all: .allPages
        case .current: .currentPage(currentPage)
        case .selected: .selectedPages(selectedPageIndices.sorted())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("整理布局")
                .font(.title2.weight(.semibold))

            // Sort By
            GroupBox("排序方式") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $sortKey) {
                        ForEach(SortKey.allCases, id: \.self) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .labelsHidden()
                    Toggle("升序（关闭为降序）", isOn: $ascending)
                    Toggle("同时排序文件夹内应用", isOn: $alsoSortFolderContents)
                }
                .padding(4)
            }

            // Apply To
            GroupBox("应用到") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $scopeMode) {
                        Text("全部页面").tag(ScopeMode.all)
                        Text("当前页面").tag(ScopeMode.current)
                        Text("选择页面").tag(ScopeMode.selected)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    if scopeMode == .selected {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 6) {
                            ForEach(0..<pageCount, id: \.self) { index in
                                Toggle("第 \(index + 1) 页", isOn: Binding(
                                    get: { selectedPageIndices.contains(index) },
                                    set: { on in
                                        if on { selectedPageIndices.insert(index) } else { selectedPageIndices.remove(index) }
                                    }
                                ))
                                    .toggleStyle(.checkbox)
                                    .font(.system(size: 11))
                            }
                        }
                        .padding(.leading, 4)
                        Text("已选 \(selectedPageIndices.count) 页")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(4)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    session.apply(ReorganizeRequest(
                        action: .sort,
                        sortKey: sortKey,
                        ascending: ascending,
                        scope: scope,
                        alsoSortFolderContents: alsoSortFolderContents
                    ))
                } label: {
                    Text("应用排序")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(scopeMode == .selected && selectedPageIndices.isEmpty)

                HStack(spacing: 12) {
                    Button("补空位") {
                        session.apply(ReorganizeRequest(
                            action: .fillEmptySlots,
                            sortKey: sortKey,
                            ascending: ascending,
                            scope: scope,
                            alsoSortFolderContents: false
                        ))
                    }
                    Button("跨页整体重排…") {
                        confirmAcrossPages = true
                    }
                }

                if session.canUndo {
                    HStack(spacing: 8) {
                        Label(
                            "已应用\(session.lastAppliedLabel.map { "：\($0)" } ?? "")，布局已保存",
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("撤销") {
                            session.undo()
                        }
                        .controlSize(.small)
                        .help("恢复本次整理前的布局")
                    }
                }

                Text("「跨页整体重排」会覆盖现有布局；应用后仍可在本窗口点「撤销」恢复。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 460, height: 520)
        .confirmationDialog(
            "跨页整体重排会覆盖现有布局，确定继续？",
            isPresented: $confirmAcrossPages,
            titleVisibility: .visible
        ) {
            Button("继续重排", role: .destructive) {
                session.apply(ReorganizeRequest(
                    action: .reorganizeAcrossPages,
                    sortKey: sortKey,
                    ascending: ascending,
                    scope: scope,
                    alsoSortFolderContents: false
                ))
            }
            Button("取消", role: .cancel) {}
        }
    }
}
