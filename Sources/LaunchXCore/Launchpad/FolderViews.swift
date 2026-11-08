import SwiftUI

// MARK: - FolderCell

/// 文件夹单元格：3×3 应用缩略图预览 + 名称；玻璃圆角；点击打开；放置合并目标。
struct FolderCell: View {
    @Environment(LaunchpadModel.self) private var model
    @Environment(\.gridMetrics) private var metrics
    let folder: FolderRecord
    let pageIndex: Int

    @State private var hovered = false

    private let previewColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        VStack(spacing: 7) {
            folderPreview
                .overlay(alignment: .topTrailing) { hoverBadge }
            if !model.settings.hideAppNames {
                Text(folder.name)
                    .font(.system(size: metrics.labelFont))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                    .lineLimit(1)
                    // 名称不撑满格宽：点击热区跟随内容自然宽度
                    .frame(maxWidth: metrics.cellWidth - 4)
            }
        }
        .padding(.horizontal, 2)
        // 点击热区只覆盖预览+名称的可见内容，不吃满整个格子；
        // 格子其余空白落回页面背景手势
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.openFolder(page: pageIndex, folderID: folder.id)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu { folderMenu }
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
                folderID: nil,
                targetAppID: "",
                isFolderTarget: true,
                folderTargetID: folder.id
            )
        )
    }

    // MARK: 3×3 预览（folder.glass.cornerRadius 玻璃圆角）

    private var folderPreview: some View {
        let dark = LXColors.isDark
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
            if case let .onFolder(_, hoverFolderID) = model.hoverTarget, hoverFolderID == folder.id {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(LXColors.accent, lineWidth: 2)
            }
        }
    }

    @ViewBuilder private var hoverBadge: some View {
        if model.layout.apps.values.first(where: { $0.isNew })?.isNew == true, folderContainsNew {
            Text("NEW")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(LXColors.newBadge(LXColors.isDark)))
                .offset(x: 2, y: -2)
        }
    }

    private var folderContainsNew: Bool {
        folder.appIDs.contains { model.layout.apps[$0]?.isNew == true }
    }

    // MARK: 文件夹右键菜单

    @ViewBuilder private var folderMenu: some View {
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
                    // 固定格宽：网格取自然大小居中，大屏两侧自然留白
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                }
                .frame(maxHeight: .infinity)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        model.closeFolder()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
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
        .transition(.scale(scale: 0.92).combined(with: .opacity))
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
            }
        }
        .opacity(app.hidden ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.launch(appID: app.id) }
        .contextMenu { memberMenu }
        .onHover { hovered = $0 }
        .onDrag {
            let sessionID = DragObserver.shared.beginDrag(ids: [app.id])
            return DragPayload.provider([app.id], sessionID: sessionID)
        }
        .onDrop(of: [DragPayload.type], delegate: FolderMemberDropDelegate(model: model, folderID: folderID, targetAppID: app.id))
    }

    // MARK: 右键菜单

    @ViewBuilder private var memberMenu: some View {
        Button("打开") { model.launch(appID: app.id) }
        Button("在访达中显示") { model.openInFinder(appID: app.id) }
        Button("显示简介") { model.showGetInfo(appID: app.id) }
        Divider()
        Button(app.hidden ? "取消隐藏" : "隐藏") { model.toggleHidden(appID: app.id) }
        Button("从文件夹移出") { model.moveOutOfFolder(appID: app.id) }
        Divider()
        // 替身没有关联文件（删替身即可）；系统应用不可卸载，保留「移到废纸篓」由模型层拦截并 toast。
        if app.isAlias || app.path.hasPrefix("/System") {
            Button("移到废纸篓…") {
                Task { await confirmAndTrash() }
            }
        } else {
            Button("卸载「\(app.name)」…") {
                model.onOpenUninstall?(app.id)
            }
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
