import SwiftUI

// MARK: - FolderCell

/// 文件夹单元格：3×3 应用缩略图预览 + 名称；玻璃圆角；点击打开；放置合并目标。
struct FolderCell: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.gridMetrics) private var metrics
    let folder: FolderRecord
    let pageIndex: Int
    /// 是否是拖放「合入文件夹」的悬停目标（父视图按 `hoverTarget` 算好传入，
    /// 格子自己读 `hoverTarget` 会让每次换悬停目标时所有格子重算）。
    var isDropHighlighted: Bool = false

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private let previewColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        VStack(spacing: 7) {
            folderPreview
                .overlay(alignment: .topTrailing) { hoverBadge }
                .onTapGesture { openFolder() }
            if !model.settings.hideAppNames {
                Text(folder.name)
                    .font(.system(size: metrics.labelFont))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                    .lineLimit(1)
                    // 热区挂在截断 frame 之前的文本自身边界上（同 AppCell）：
                    // maxWidth 弹性 frame 会撑满格宽，手势挂在外面会让
                    // 短名称两侧空白也可点
                    .contentShape(Rectangle())
                    .frame(maxWidth: metrics.cellWidth - 4)
                    .onTapGesture { openFolder() }
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("文件夹：\(folder.name)")
        .accessibilityValue("\(folder.appIDs.count) 个应用")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openFolder() }
        // 点击热区只覆盖预览+名称可见内容（手势挂在 folderPreview 与 Text 上），
        // 格子空白落回页面背景手势；右键与悬停徽章仍覆盖整格。
        .contentShape(Rectangle())
        .contextMenu { FolderCellMenu(folder: folder, pageIndex: pageIndex) }
        .onHover { hovered = $0 }
        // 手势之后才撑满格宽：布局居中不变，热区跟随内容
        .frame(maxWidth: .infinity)
        // 文件夹暂不支持整体拖拽：若把 folder.appIDs 当载荷拖出，
        // performDrop 会把成员复制到页面/其他文件夹，导致同一应用出现在多处。
        // 拖其中应用请先打开文件夹。
        .onDrop(
            of: [DragPayload.type],
            delegate: AppDropDelegate(
                model: model,
                pageIndex: pageIndex,
                targetAppID: "",
                isFolderTarget: true,
                folderTargetID: folder.id
            )
        )
    }

    // MARK: 3×3 预览（folder.glass.cornerRadius 玻璃圆角）

    private var folderPreview: some View {
        let dark = colorScheme == .dark
        let apps = folder.appIDs.compactMap { model.layout.apps[$0] }
        let corner = metrics.iconSize * 0.25
        return LazyVGrid(columns: previewColumns, spacing: 4) {
            ForEach(apps.prefix(9)) { app in
                Image(nsImage: model.icons.icon(forPath: app.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .padding(metrics.iconSize * 0.11)
        .frame(width: metrics.iconSize + 8, height: metrics.iconSize + 8)
        .liquidGlassPanel(
            cornerRadius: corner,
            // 悬停反馈：换玻璃 tint（白 30% / 白 8%）替代原叠色层
            tint: hovered ? LXColors.folderHighlight(dark) : LXColors.folderTint(dark)
        )
        .overlay {
            if isDropHighlighted {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(LXColors.accent, lineWidth: 2)
            }
        }
        // 玻璃面板整块都是可见内容，热区=整块预览（显式声明，不依赖材质的默认命中）
        .contentShape(Rectangle())
    }

    private func openFolder() {
        withAnimation(MotionPreference.folderOpen(reduceMotion: reduceMotion)) {
            model.openFolder(page: pageIndex, folderID: folder.id)
        }
    }

    @ViewBuilder private var hoverBadge: some View {
        if folderContainsNew {
            Text("NEW")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(LXColors.newBadge(colorScheme == .dark)))
                .offset(x: 2, y: -2)
        }
    }

    private var folderContainsNew: Bool {
        folder.appIDs.contains { model.layout.apps[$0]?.isNew == true }
    }
}

/// 文件夹格右键菜单（独立视图：只在 SwiftUI 需要时求值，见 `AppCellMenu`）。
struct FolderCellMenu: View {
    @Environment(LaunchpadModel.self) private var model
    let folder: FolderRecord
    let pageIndex: Int

    var body: some View {
        Button("打开") {
            model.openFolder(page: pageIndex, folderID: folder.id)
        }
        Button("重命名…") {
            if let window = NSApp.keyWindow {
                RenameSheet.present(
                    window: window,
                    title: "重命名文件夹「\(folder.name)」",
                    initial: folder.name
                ) { newName in
                    model.renameFolder(folderID: folder.id, to: newName)
                }
            }
        }
        Divider()
        Button("解散文件夹") {
            model.ungroupFolder(folderID: folder.id)
        }
        Divider()
        Button("新建文件夹") { model.createNewFolderOnCurrentPage() }
        Button("解散全部文件夹") { model.ungroupAllFolders() }
    }
}

// MARK: - OpenedFolderView

/// 打开的文件夹：整页替换展示文件夹内容（OpenedFolderBlur 展开形态）。
struct OpenedFolderView: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.gridMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var folder: FolderRecord? { model.openedFolderRecord }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(metrics.cellWidth), spacing: metrics.columnSpacing), count: min(model.density.columns, 7))
    }

    var body: some View {
        VStack(spacing: 20) {
            if let folder {
                Text(folder.name)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2)

                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 22) {
                        ForEach(folder.appIDs.compactMap { model.layout.apps[$0] }) { app in
                            FolderMemberCell(app: app, folderID: folder.id)
                        }
                    }
                    // 成员网格范围内（含行间距）的放置不算「拖到空白处」：吞掉，不移出文件夹。
                    // 必须挂在居中 frame 之前，只覆盖网格自然尺寸。
                    .contentShape(Rectangle())
                    .onDrop(of: [DragPayload.type], delegate: FolderGridGapDropDelegate(model: model))
                    // 固定格宽：网格取自然大小居中，大屏两侧自然留白
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                }
                .frame(maxHeight: .infinity)

                Button {
                    withAnimation(MotionPreference.folderClose(reduceMotion: reduceMotion)) {
                        model.closeFolder()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭文件夹")
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 空白处放置 = 把成员移出文件夹（拖到网格外的面板空白区）
        .contentShape(Rectangle())
        .onDrop(of: [DragPayload.type], delegate: FolderBackgroundDropDelegate(model: model))
        .background {
            // OpenedFolderBlurView：中央磨砂面板（Liquid Glass，Color.clear 占位撑满内容区）
            Color.clear
                .liquidGlassPanel(cornerRadius: 38)
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
        }
        .transition(MotionPreference.folderTransition(reduceMotion: reduceMotion))
    }
}

/// 文件夹内成员单元格：拖到另一成员上 = 文件夹内重排；拖出（放到页面空白）= 移出文件夹。
struct FolderMemberCell: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.gridMetrics) private var metrics
    let app: AppRecord
    let folderID: UUID

    @State private var hovered = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(hovered ? LXColors.highlight : Color.clear)
                Image(nsImage: model.icons.icon(forPath: app.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: metrics.iconSize, height: metrics.iconSize)
            }
            .frame(width: metrics.iconSize + 8, height: metrics.iconSize + 8)
            if !model.settings.hideAppNames {
                Text(app.name)
                    .font(.system(size: metrics.labelFont))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: metrics.cellWidth - 4)
            }
        }
        .opacity(app.hidden ? 0.55 : 1)
        // 铺满整格：格宽约为图标宽的 2 倍，只有图标那块接收放置的话，
        // 同行图标之间的空隙会落到背景放置（= 移出文件夹），文件夹内重排松手偏一点就被移出。
        .frame(width: metrics.cellWidth)
        .contentShape(Rectangle())
        .onTapGesture { model.launch(appID: app.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(app.hidden ? "已隐藏" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.launch(appID: app.id) }
        .contextMenu { FolderMemberMenu(app: app) }
        .onHover { hovered = $0 }
        .onDrag {
            let sessionID = DragObserver.shared.beginDrag(ids: [app.id])
            return DragPayload.provider([app.id], sessionID: sessionID)
        }
        .onDrop(of: [DragPayload.type], delegate: FolderMemberDropDelegate(model: model, folderID: folderID, targetAppID: app.id))
    }
}

/// 文件夹成员右键菜单（独立视图，见 `AppCellMenu`）。
struct FolderMemberMenu: View {
    @Environment(LaunchpadModel.self) private var model
    let app: AppRecord

    var body: some View {
        Button("打开") { model.launch(appID: app.id) }
        Button("在访达中显示") { model.openInFinder(appID: app.id) }
        Button("显示简介") { model.showGetInfo(appID: app.id) }
        Divider()
        Button(app.hidden ? "取消隐藏" : "隐藏") { model.toggleHidden(appID: app.id) }
        Button("从文件夹移出") { model.moveOutOfFolder(appID: app.id) }
        Divider()
        // 替身没有关联文件（删替身即可）。系统应用直接置灰不给入口（P1-8 / P2-11）：
        // 旧文案「移除需要管理员权限，已取消操作」把 SIP 保护说成了权限问题。
        if app.isAlias {
            Button("移到废纸篓…") {
                Task { await model.confirmAndTrash(appID: app.id) }
            }
        } else if let reason = model.uninstallBlockReason(appID: app.id) {
            Button("无法卸载：\(reason)") {}
                .disabled(true)
        } else {
            Button("卸载「\(app.name)」…") {
                model.onOpenUninstall?(app.id)
            }
        }
    }
}

/// 文件夹内重排放置：把拖拽项移到目标项之前。
struct FolderMemberDropDelegate: DropDelegate {
    let model: LaunchpadModel
    let folderID: UUID
    let targetAppID: String

    func performDrop(info: DropInfo) -> Bool {
        DragPayload.load(from: info) { payload in
            guard let payload, DragObserver.shared.isCurrent(payload.sessionID) else { return }
            let dragging = payload.appIDs
            DragObserver.shared.endDrag(sessionID: payload.sessionID)
            guard !dragging.isEmpty, dragging != [targetAppID] else { return }
            model.moveWithinFolder(draggingIDs: dragging, folderID: folderID, beforeAppID: targetAppID)
        }
    }
}

/// 文件夹成员网格内、落在格子之外（行间距）的放置：不做任何移动，只结束拖拽会话。
struct FolderGridGapDropDelegate: DropDelegate {
    let model: LaunchpadModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [DragPayload.type])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.hoverTarget = nil
        return DragPayload.load(from: info) { payload in
            guard let payload else { return }
            DragObserver.shared.endDrag(sessionID: payload.sessionID)
        }
    }
}

/// 打开文件夹视图空白处的放置：把成员拖出到该文件夹所在页的页尾。
/// 只处理「当前打开文件夹的成员」——页面图标 / 搜索结果等其他来源拖进来直接忽略。
struct FolderBackgroundDropDelegate: DropDelegate {
    let model: LaunchpadModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [DragPayload.type])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.hoverTarget = nil
        return DragPayload.load(from: info) { payload in
            guard let payload, DragObserver.shared.isCurrent(payload.sessionID) else { return }
            let dragging = payload.appIDs
            DragObserver.shared.endDrag(sessionID: payload.sessionID)
            guard !dragging.isEmpty,
                  let opened = model.openedFolder,
                  let folder = model.openedFolderRecord else { return }
            let memberIDs = Set(folder.appIDs)
            guard dragging.allSatisfy({ memberIDs.contains($0) }) else { return }
            let page = model.layout.pageIndexOfFolder(folder.id) ?? opened.page
            model.performDrop(
                draggingIDs: dragging,
                sourceFolderID: folder.id,
                target: .pageBackground(page: page)
            )
        }
    }
}
