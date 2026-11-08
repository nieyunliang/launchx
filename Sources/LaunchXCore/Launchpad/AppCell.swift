import AppKit
import SwiftUI

// MARK: - 帧上报（橡皮筋选框用）

/// 单元格在页面坐标空间的 frame 上报。
struct ItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - 修饰键归一化

/// 交互修饰键归一化（P3-1）。
///
/// Caps Lock 开启时 `modifierFlags` 会带上 `.capsLock`，`.numericPad` / `.function`
/// 等也会混入；此前直接 `contains(.command)` / 判断「无修饰键」的代码在 Caps Lock
/// 打开时语义就变了（⌘ 点击失效、输入即搜索被拦）。统一先取设备无关位，再
/// 剔除这些「非意图」标志位。
enum InteractionModifiers {
    /// 指向交互语义的修饰位集合。
    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function, .help])
    }

    /// 是否按住了 ⌘（多选点击 / 框选）。⌘⇧、⌘⌥ 也算——与原行为一致。
    static func hasCommand(_ flags: NSEvent.ModifierFlags) -> Bool {
        normalized(flags).contains(.command)
    }

    /// 是否带了会阻断「输入即搜索」的修饰键（⌘⌃⌥）。
    static func blocksTypeToSearch(_ flags: NSEvent.ModifierFlags) -> Bool {
        !normalized(flags).intersection([.command, .control, .option]).isEmpty
    }
}

// MARK: - AppCell

/// 应用单元格：图标 + 名称 + NEW/隐藏/选中角标；点击启动；⌘ 点选；拖拽源；
/// 图标区为「建文件夹」放置目标。
struct AppCell: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.gridMetrics) private var metrics
    let app: AppRecord
    let pageIndex: Int
    /// 所在文件夹（nil = 直接摆放在页上）。
    let folderID: UUID?
    /// 是否搜索结果模式（无拖拽、单击选中回车启动）。
    let isSearchResult: Bool
    /// 键盘导航焦点（P3-4）：仅用于显示焦点环，不改变点击/启动语义。
    var isKeyboardFocused: Bool = false

    var body: some View {
        VStack(spacing: 7) {
            iconArea
                .overlay(alignment: .topTrailing) { badges }
            if !model.settings.hideAppNames {
                Text(app.name)
                    .font(.system(size: metrics.labelFont))
                    .foregroundStyle(.white.opacity(app.hidden ? 0.45 : 0.92))
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // 名称不撑满格宽：点击热区跟随内容自然宽度
                    .frame(maxWidth: metrics.cellWidth - 4)
            }
        }
        .padding(.horizontal, 2)
        .background(selectionRing)
        // 键盘焦点环：与「选中」环区分（选中是填充色块，焦点是亮色描边）。
        .overlay { keyboardFocusRing }
        // 点击热区只覆盖图标+名称的可见内容，不吃满整个格子；
        // 格子其余空白落回页面背景手势（收起选区/关文件夹）
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .contextMenu { menuItems }
        .modifier(
            DragSourceModifier(
                appID: app.id,
                // 多选时拖选中项 = 拖全部选中（按页内视觉顺序）；拖未选中项 = 单拖自身
                selectionIDs: isSearchResult || !model.selectedAppIDs.contains(app.id)
                    ? []
                    : model.orderedSelection(onPage: pageIndex)
            )
        )
        // 手势之后才撑满格宽：布局居中不变，热区/选中环跟随内容
        .frame(maxWidth: .infinity)
        .opacity(app.hidden ? 0.55 : 1)
        .onDrop(
            of: [DragPayload.type],
            delegate: AppDropDelegate(
                model: model,
                pageIndex: pageIndex,
                folderID: folderID,
                targetAppID: app.id,
                isFolderTarget: false,
                folderTargetID: nil
            )
        )
        .overlay {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ItemFramePreferenceKey.self,
                    value: [app.id: proxy.frame(in: .named("pageSpace"))]
                )
            }
        }
    }

    // MARK: 图标

    @ViewBuilder private var iconArea: some View {
        let displayIcon = model.icons.tintedIcon(
            forPath: app.path,
            mode: model.settings.iconColorMode
        ) ?? model.icons.icon(forPath: app.path)

        Image(nsImage: displayIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: metrics.iconSize, height: metrics.iconSize)
            .frame(width: metrics.iconSize + 8, height: metrics.iconSize + 8)
        .overlay {
            // 放置悬停高亮：拖到该应用上将建文件夹
            if case let .onApp(_, hoverAppID) = model.hoverTarget, hoverAppID == app.id {
                RoundedRectangle(cornerRadius: metrics.cornerRadius + 2, style: .continuous)
                    .strokeBorder(LXColors.accent, lineWidth: 2)
            }
        }
    }

    // MARK: 角标

    @ViewBuilder private var badges: some View {
        HStack(spacing: 3) {
            if app.isNew && !isSearchResult {
                Text("NEW")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule().fill(LXColors.newBadge(LXColors.isDark))
                    )
                    .shadow(color: .black.opacity(0.3), radius: 1)
            }
            if app.hidden {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
        }
        .offset(x: 2, y: -2)
    }

    @ViewBuilder private var selectionRing: some View {
        if model.selectedAppIDs.contains(app.id) {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .strokeBorder(LXColors.selection(LXColors.isDark), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                        .fill(LXColors.selection(LXColors.isDark).opacity(0.12))
                )
                .padding(-4)
        }
    }

    // MARK: 交互

    private func handleTap() {
        // Caps Lock / 数字键盘等标志位不能影响「⌘ 点击 = 多选」（P3-1）。
        if InteractionModifiers.hasCommand(NSEvent.modifierFlags), !isSearchResult {
            model.toggleSelection(appID: app.id)
        } else {
            model.launch(appID: app.id)
        }
    }

    @ViewBuilder private var keyboardFocusRing: some View {
        if isKeyboardFocused {
            RoundedRectangle(cornerRadius: metrics.cornerRadius + 3, style: .continuous)
                .strokeBorder(LXColors.accent, lineWidth: 3)
                .padding(-6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: 右键菜单（GAP §2.11 全量）

    @ViewBuilder private var menuItems: some View {
        Button("打开") { model.launch(appID: app.id) }
        Button("显示简介") { model.showGetInfo(appID: app.id) }
        Button("在访达中显示") { model.openInFinder(appID: app.id) }
        Button("重命名…") {
            if let window = NSApp.keyWindow {
                RenameSheet.present(
                    window: window,
                    title: "重命名「\(app.name)」",
                    initial: app.name
                ) { newName in
                    model.rename(appID: app.id, to: newName)
                }
            }
        }
        Divider()
        Button(app.hidden ? "取消隐藏" : "隐藏") {
            model.toggleHidden(appID: app.id)
        }
        Button("添加到程序坞") { model.addToDock(appID: app.id) }
        Divider()
        if model.isRunning(appID: app.id) {
            Button("强制退出「\(app.name)」") {
                model.forceQuit(appID: app.id)
            }
        }
        // 替身没有关联文件（删替身即可）；系统应用不可卸载，
        // 保留原「移到废纸篓」路径由模型层拦截并 toast。
        if app.isAlias || app.path.hasPrefix("/System") {
            Button("移到废纸篓…") {
                Task { await confirmAndTrash() }
            }
        } else {
            Button("卸载「\(app.name)」…") {
                model.onOpenUninstall?(app.id)
            }
        }
        if !isSearchResult, model.selectedAppIDs.count >= 2 {
            Divider()
            Button("合并到新文件夹") { model.mergeSelectionIntoNewFolder() }
            Button("隐藏所选 (\(model.selectedAppIDs.count))") { model.hideSelection() }
        }
    }

    private func confirmAndTrash() async {
        let outcome = await model.moveToTrash(appID: app.id)
        switch outcome {
        case let .needsAdmin(name):
            ToastManager.shared.show(
                .error,
                "「\(name)」是系统应用，移除需要管理员权限，已取消操作。"
            )
        case let .trashed(name):
            ToastManager.shared.success("已将「\(name)」移到废纸篓")
        case let .failed(message):
            ToastManager.shared.error("移到废纸篓失败：\(message)")
        }
    }
}

// MARK: - 拖拽源

/// 单/多选拖拽源；`selectionIDs` 为按页内视觉顺序排好的多选载荷（空 = 单拖当前项）。
struct DragSourceModifier: ViewModifier {
    let appID: String
    let selectionIDs: [String]

    func body(content: Content) -> some View {
        content.onDrag {
            let ids = selectionIDs.isEmpty ? [appID] : selectionIDs
            // 每次拖拽开启新会话：载荷里带上会话 id，drop 时校验，旧会话的载荷会被拒绝。
            let sessionID = DragObserver.shared.beginDrag(ids: ids)
            return DragPayload.provider(ids, sessionID: sessionID)
        }
    }
}

/// 进程内拖拽状态（跨页拖拽时保存拖拽 ids；SwiftUI drop 回调数据异步不可同步读）。
@MainActor
final class DragObserver: @unchecked Sendable {
    static let shared = DragObserver()

    /// 当前拖拽会话 id；无进行中的拖拽时为 nil。
    private(set) var sessionID: UUID?
    private(set) var lastDraggedIDs: [String] = []
    private var dragStartedAt = Date.distantPast

    /// 兜底 TTL：正常路径在 drop 完成 / 面板收起时立即清理；
    /// 仅「拖出面板后松手」这类没有 drop 回调的取消场景依靠它过期。
    private let fallbackTTL: TimeInterval = 15

    /// 开始一次新拖拽并返回会话 id。
    @discardableResult
    func beginDrag(ids: [String]) -> UUID {
        let session = UUID()
        sessionID = session
        lastDraggedIDs = ids
        dragStartedAt = Date()
        return session
    }

    /// 当前会话的拖拽 ids（无有效会话时为空）。
    func currentIDs() -> [String] {
        currentSession() == nil ? [] : lastDraggedIDs
    }

    /// 当前有效会话 id（超过兜底 TTL 视为已取消）。
    func currentSession() -> UUID? {
        guard let sessionID else { return nil }
        return Date().timeIntervalSince(dragStartedAt) < fallbackTTL ? sessionID : nil
    }

    func isCurrent(_ sessionID: UUID) -> Bool {
        currentSession() == sessionID
    }

    /// 结束拖拽并清空会话 id 与 ids。
    func endDrag() {
        sessionID = nil
        lastDraggedIDs = []
        dragStartedAt = .distantPast
    }

    /// 只结束指定会话（避免旧会话的迟到 drop 把新拖拽会话清掉）。
    func endDrag(sessionID: UUID) {
        guard currentSession() == sessionID else { return }
        endDrag()
    }
}

// MARK: - 放置目标

/// 应用图标上的放置：文件（合并）与应用（建夹 / 插入排序）。
struct AppDropDelegate: DropDelegate {
    let model: LaunchpadModel
    let pageIndex: Int
    let folderID: UUID?
    let targetAppID: String
    let isFolderTarget: Bool
    let folderTargetID: UUID?

    func dropEntered(info: DropInfo) {
        guard DragObserver.shared.currentIDs() != [targetAppID] else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.hoverTarget = isFolderTarget
                ? .onFolder(page: pageIndex, folderID: folderTargetID!)
                : .onApp(page: pageIndex, appID: targetAppID)
        }
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            model.hoverTarget = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.hoverTarget = nil
        return DragPayload.load(from: info) { payload in
            // 会话校验：只接受本次 onDrag 产生的载荷，旧载荷 / 外部文本一律忽略。
            guard let payload, DragObserver.shared.isCurrent(payload.sessionID) else { return }
            let dragging = payload.appIDs
            DragObserver.shared.endDrag(sessionID: payload.sessionID)
            guard !dragging.isEmpty else { return }
            handleDrop(dragging: dragging)
        }
    }

    /// 校验通过后的实际放置逻辑（会话已结束）。
    @MainActor
    private func handleDrop(dragging: [String]) {
        if isFolderTarget, let folderTargetID {
            model.performDrop(draggingIDs: dragging, sourceFolderID: nil, target: .onFolder(page: pageIndex, folderID: folderTargetID))
            return
        }
        // 拖到自己身上 no-op
        guard dragging != [targetAppID] else { return }

        // 单个非选中项拖到应用上 → 建文件夹；多选/选中项 → 插到目标之后（重排）
        if dragging.count == 1, dragging[0] != targetAppID,
           model.selectedAppIDs.contains(dragging[0]) == false {
            model.performDrop(draggingIDs: dragging, sourceFolderID: nil, target: .onApp(page: pageIndex, appID: targetAppID))
        } else {
            model.performDrop(draggingIDs: dragging, sourceFolderID: nil, target: .slot(page: pageIndex, slot: slotAfterTarget(dragging: dragging)))
        }
    }

    /// 目标应用的插入槽位（目标之后）：先按当前布局定位，再扣除因移除拖拽项产生的前移。
    @MainActor
    private func slotAfterTarget(dragging: [String]) -> Int {
        guard pageIndex < model.layout.pages.count else { return 0 }
        let items = model.layout.pages[pageIndex].items
        guard let targetSlot = items.firstIndex(where: { $0.appID == targetAppID }) else {
            return items.count
        }
        let draggingSet = Set(dragging)
        let removedBeforeTarget = items[0..<targetSlot].filter { item in
            guard let id = item.appID else { return false }
            return draggingSet.contains(id)
        }.count
        return targetSlot - removedBeforeTarget + 1
    }
}

// MARK: - 重命名弹窗（NSAlert + 输入框）

@MainActor
enum RenameSheet {
    static func present(window: NSWindow, title: String, initial: String, onOK: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "仅修改 LaunchX 内的显示名，不影响应用本身。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                onOK(field.stringValue)
            }
        }
    }
}
