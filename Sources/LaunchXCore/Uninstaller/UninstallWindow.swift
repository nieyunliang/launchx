import AppKit
import SwiftUI

/// 卸载器窗口（独立 UninstallWindow）。
@MainActor
public final class UninstallWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var currentModel: UninstallModel?
    /// 用户在删除过程中确认关闭了窗口：结束后把失败明细交还回来。
    private var closedDuringRemoval = false
    /// 应用成功移出布局后的回调（AppDelegate 注入，走 LaunchpadModel 收尾，P2-9）。
    public var onUninstalled: ((String) -> Void)?

    public override init() {
        super.init()
    }

    public func show(app: AppRecord, layoutStore: LayoutStore) {
        // 删除进行中不允许切换应用/重开：show() 会 reset 当前 model，
        // 上一个应用的失败反馈会被静默丢弃（评审 P2-8）。
        if let currentModel, currentModel.isRemoving {
            ToastManager.shared.show(.info, "正在删除「\(currentModel.app.name)」的文件，请等完成后再操作")
            return
        }
        currentModel?.reset()
        let model = UninstallModel(app: app, layoutStore: layoutStore)
        model.onAppUninstalled = { [weak self] appID in
            self?.onUninstalled?(appID)
        }
        model.onRemovalFinished = { [weak self] in
            self?.handleRemovalFinished()
        }
        currentModel = model
        closedDuringRemoval = false

        let content = UninstallContentView(model: model, onClose: { [weak self] in
            self?.requestClose()
        })
        let hosting = NSHostingView(rootView: content)

        if let window {
            window.contentView = hosting
            // 复用窗口时标题/头部必须跟着新应用刷新，否则会显示上一个应用名（P3-6）
            window.title = "卸载 \(app.name)"
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "卸载 \(app.name)"
            window.contentView = hosting
            // 可缩放（评审 P1-5：660x560 固定高度会把高风险项挤到视口之外）
            window.minSize = NSSize(width: 660, height: 560)
            window.center()
            window.delegate = self
            self.window = window
            LaunchpadWindowController.registerChildWindow(window)
        }
        window?.level = LaunchpadWindowController.childWindowLevel
        NSApp.activate(ignoringOtherApps: true)
        WindowFade.fadeIn(window!)
        // 窗口可见时由成功页承担反馈，不再重复弹 toast（P3-3）
        model.suppressCompletionToast = true
        model.startScan()
    }

    /// 视图内的关闭入口（取消按钮 / Esc / 完成按钮）统一走这里，和标题栏关闭同一条路径。
    private func requestClose() {
        guard let window else { return }
        if let model = currentModel, model.isScanning {
            // 扫描可以真正取消：中止后台枚举，不留副作用（P1-4）
            model.cancelScan(clearResults: true)
        }
        _ = windowShouldClose(window)
    }

    /// 标题栏关闭 / Esc：删除进行中必须先确认，且明确告知「关闭不停止删除」。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = currentModel else {
            WindowFade.fadeOut(sender)
            return false
        }
        if model.isRemoving {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "仍在删除文件"
            alert.informativeText = """
            关闭窗口不会停止删除，删除会继续在后台完成。
            失败项只会汇总成一条通知，本次明细将无法再查看。
            """
            alert.addButton(withTitle: "继续等待")
            alert.addButton(withTitle: "关闭窗口")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            closedDuringRemoval = true
            // 关闭后没有成功页，恢复通知反馈
            model.suppressCompletionToast = false
            WindowFade.fadeOut(sender)
            return false
        }
        closedDuringRemoval = false
        WindowFade.fadeOut(sender)
        return false
    }

    /// 删除结束：若用户当初确认关闭了窗口，失败明细不能在 3 秒通知里丢掉——
    /// 重新打开窗口把结论与逐条原因交还给用户（P0-3）。
    private func handleRemovalFinished() {
        guard closedDuringRemoval, let window, let model = currentModel else { return }
        closedDuringRemoval = false
        guard case .partialFailure = model.phase else { return }
        LaunchpadWindowController.registerChildWindow(window)
        window.level = LaunchpadWindowController.childWindowLevel
        model.suppressCompletionToast = true
        WindowFade.fadeIn(window)
    }
}

/// 卸载器内容视图：扫描 / 勾选清单 / 进度 / 完成（FDA 缺失时顶部为非阻断横幅）。
public struct UninstallContentView: View {
    // 直接持有 model（根视图不能依赖 @Environment 自注入，会崩溃）
    let model: UninstallModel
    let onClose: () -> Void

    public init(model: UninstallModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if model.showsAccessBanner {
                LimitedAccessBanner(
                    onOpenSettings: {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
                        )
                    },
                    onRescan: { model.startScan() }
                )
            }
            if let reason = model.removalBlockReason {
                blockedBanner(reason)
            }
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 660, minHeight: 560)
        .environment(model)
        // Esc 关闭（评审 P2-2：此前全流程没有键盘退路）
        .onExitCommand(perform: onClose)
    }

    // MARK: 头部（图标 + 名称/版本/运行状态 + 应用体积）

    private var header: some View {
        HStack(spacing: 16) {
            JiggleIconView(iconPath: model.app.path, isActive: jiggleActive)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.app.name).font(.title2.weight(.semibold))
                    if let version = model.app.version, !version.isEmpty {
                        Text(version)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if model.isAppRunning {
                        runningBadge
                    }
                }
                Text(model.app.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.appPathMissing, !model.hasFinished {
                    Text("应用本体已不在磁盘上，本次只清理关联文件")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            appSizeLabel
        }
        .padding(20)
    }

    /// 只在可操作清单里抖动（iOS 抖动语义是「进入编辑」）；完成/进度页不再抖。
    private var jiggleActive: Bool {
        if case .ready = model.phase { return true }
        return false
    }

    private var runningBadge: some View {
        Text("正在运行")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .accessibilityLabel("应用正在运行")
    }

    @ViewBuilder private var appSizeLabel: some View {
        // 卸载已经完成后「应用 X MB / 移到废纸篓」不再有意义（它已经在废纸篓里了）
        if !model.hasFinished {
            appSizeLabelContent
        }
    }

    @ViewBuilder private var appSizeLabelContent: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let size = UninstallModel.formattedBytes(model.appBundleSize) {
                Text("应用 \(size)")
                    .font(.system(size: 12, weight: .medium))
                Text("移到废纸篓")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if model.isComputingSizes {
                Text("正在计算体积…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func blockedBanner(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("该应用无法卸载")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(reason)。为避免「缓存被清、应用还在」，这里不提供任何删除操作。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }
    // MARK: 主体内容

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .scanning:
            scanningContent
        case let .removing(done, total):
            removingContent(done: done, total: total)
        case .done:
            doneContent
        case .partialFailure:
            partialFailureContent
        case .ready:
            readyContent
        }
    }

    private var scanningContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(model.scanDetail.isEmpty ? "正在扫描关联文件…" : model.scanDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("清单会先出现、大小随后补全；扫描也可以取消。\n应用本体与所有勾选项都只会移到废纸篓。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func removingContent(done: Int, total: Int) -> some View {
        VStack(spacing: 10) {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .frame(width: 320)
            } else {
                ProgressView()
            }
            Text("正在移除…（\(done)/\(max(total, 1))）")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            if let current = model.currentRemovalItem {
                Text(current)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Text("删除进行中无法取消；关闭窗口不会停止删除。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groupedItems, id: \.category) { group in
                        UninstallCategoryGroupView(
                            category: group.category,
                            items: group.items,
                            selection: model.groupSelection(group.category),
                            checkedIDs: model.checkedItemIDs,
                            isComputingSizes: model.isComputingSizes,
                            onToggle: { model.toggle($0) },
                            onSelectAll: { includeSpeculative in
                                model.selectAll(in: group.category, includeSpeculative: includeSpeculative)
                            },
                            onDeselectAll: { model.deselectAll(in: group.category) }
                        )
                        // 系统应用整页只读：勾选/全选没有意义，避免用户以为能操作（P1-8）
                        .allowsHitTesting(model.removalBlockReason == nil)
                        .id(categoryAnchor(group.category))
                    }
                    if model.groupedItems.isEmpty {
                        emptyState
                    }
                }
                .padding(20)
            }
            // 内容溢出时滚动条保持可见（P1-5：默认隐藏让用户以为只有这些项）
            .scrollIndicators(.visible)
            .onChange(of: model.scrollTarget) { _, target in
                guard let target else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(categoryAnchor(target), anchor: .top)
                }
                model.scrollTarget = nil
            }
        }
    }

    private func categoryAnchor(_ category: UninstallCategory) -> String {
        "category-\(category.rawValue)"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("未发现关联文件")
                .font(.headline)
            Text(emptyStateDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .padding(.horizontal, 30)
    }

    private var emptyStateDetail: String {
        if let size = UninstallModel.formattedBytes(model.appBundleSize) {
            return "没有由 Bundle ID 派生的缓存 / 容器 / 偏好设置。\n仍可把应用本体（\(size)）移到废纸篓。"
        }
        return "没有由 Bundle ID 派生的缓存 / 容器 / 偏好设置。\n仍可只把应用本体移到废纸篓。"
    }

    private var doneContent: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.green)
            Text(doneTitle)
                .font(.headline)
            if let report = model.report {
                if report.trashedBytes > 0, let size = UninstallModel.formattedBytes(report.trashedBytes) {
                    Text("已移入废纸篓：\(size)")
                        .font(.system(size: 12, weight: .medium))
                }
                Text(report.appConclusionText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            // 项目最大的安全优势（走废纸篓、可恢复）必须在成功页可见（P1-3）
            Text("应用与关联文件都在废纸篓里，可以随时恢复。\n清倒废纸篓后才会真正释放空间。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    /// 失败摘要：本体没移走时明确说明「含应用本体」，避免用户以为失败的都是关联文件。
    private func partialSummaryText(_ report: UninstallModel.RemovalReport) -> String {
        let base = "已清理 \(report.trashedCount) 项关联文件"
        if report.appMoved {
            return "\(base)；以下 \(report.failures.count) 项没有删掉。"
        }
        return "\(base)；另有 \(report.failures.count) 项没有删掉（含应用本体）。"
    }

    private var doneTitle: String {
        guard let report = model.report else { return "已卸载" }
        return report.trashedCount > 0
            ? "已卸载，并清理 \(report.trashedCount) 项关联文件"
            : "已卸载"
    }

    private var partialFailureContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.orange)
                    Text("未完全卸载")
                        .font(.headline)
                }
                if let report = model.report {
                    // 首行固定回答「应用本体到底还在不在」（P0-3）
                    Label(report.appConclusionText, systemImage: report.appMoved ? "checkmark.circle" : "xmark.octagon.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(report.appMoved ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                    Text(partialSummaryText(report))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ForEach(model.failureGroups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(group.reason.rawValue)（\(group.failures.count) 项）")
                                .font(.system(size: 12, weight: .semibold))
                            ForEach(group.failures, id: \.self) { failure in
                                Text("· \(failure.path)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("  \(failure.message)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .scrollIndicators(.visible)
    }
    // MARK: 底部操作（按阶段整体切换，P1-2）

    private var footer: some View {
        VStack(spacing: 8) {
            if case .ready = model.phase {
                if !model.riskSummary.isEmpty {
                    riskSummaryRow
                }
                if let error = model.lastActionError {
                    errorRow(error)
                }
            }
            HStack(spacing: 10) {
                leadingFooterText
                Spacer()
                footerButtons
            }
        }
        .padding(16)
    }

    @ViewBuilder private var leadingFooterText: some View {
        switch model.phase {
        case .idle, .scanning:
            Text("正在扫描…")
                .foregroundStyle(.secondary)
        case .ready:
            HStack(spacing: 6) {
                Text("已选 \(model.selectedItems.count) 项")
                if let bytes = model.plannedTrashBytes {
                    Text("· \(model.plannedTrashBytesIsLowerBound ? "至少 " : "")\(UninstallModel.formattedBytes(bytes) ?? "") 将移入废纸篓")
                        .foregroundStyle(.secondary)
                }
                if model.isComputingSizes {
                    Text("· 大小计算中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        case .removing:
            Text("正在删除，无法取消")
                .foregroundStyle(.secondary)
        case .done:
            if let bytes = model.report?.trashedBytes,
               bytes > 0,
               let text = UninstallModel.formattedBytes(bytes) {
                Text("已卸载 · \(text) 已移入废纸篓")
                    .foregroundStyle(.secondary)
            } else {
                Text("已卸载")
                    .foregroundStyle(.secondary)
            }
        case .partialFailure:
            // 结论行已经在正文首行完整给出，footer 只留短摘要，避免长路径把底栏撑成多行
            Text(model.report.map { "未完全卸载 · \($0.failures.count) 项待处理" } ?? "未完全卸载")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footerButtons: some View {
        switch model.phase {
        case .idle, .scanning:
            Button("取消扫描", action: onClose)
        case .ready:
            Button("取消", action: onClose)
            Button(removeButtonTitle) {
                confirmAndRemove()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canStartRemoval)
        case .removing:
            EmptyView()
        case .done:
            if let locations = model.report?.trashLocations, !locations.isEmpty {
                Button("在废纸篓中显示") { revealTrash(locations) }
            }
            Button("完成", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .partialFailure:
            if let report = model.report, !report.failures.isEmpty {
                Button("在访达中显示") { revealFailures(report.failures) }
            }
            Button("复制详情") { copyReport() }
            if model.canRetryFailed {
                Button("重试失败项") { model.retryFailed() }
            }
            Button("完成", action: onClose)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var riskSummaryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(model.riskSummary.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let target = model.riskSummaryJumpCategory {
                Button("查看") {
                    model.scrollTarget = target
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Spacer()
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Spacer()
        }
    }

    private func revealTrash(_ locations: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(locations)
    }

    /// 在访达中定位失败项（仍然存在的那些）；都不可见时退回应用本体位置。
    private func revealFailures(_ failures: [UninstallModel.RemovalFailure]) {
        let urls = failures
            .map { URL(fileURLWithPath: $0.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let targets = urls.isEmpty ? [URL(fileURLWithPath: model.app.path)] : urls
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.reportText, forType: .string)
        ToastManager.shared.success("详情已复制")
    }

    private var removeButtonTitle: String {
        if model.removalBlockReason != nil { return "无法卸载" }
        let count = model.selectedItems.count
        if count == 0 {
            return model.appPathMissing ? "清理并完成" : "仅卸载应用"
        }
        return "移除 \(count) 项并卸载"
    }

    /// 危险操作二次确认：回答「移多少 / 移到哪 / 能不能恢复 / 有什么风险」。
    /// 含个人文件或推测项时默认按钮为「取消」，必须明确点按才继续（保留原有防误触设计）。
    private func confirmAndRemove() {
        model.refreshRunningState()
        let summary = model.removalSummary
        let hasCritical = !summary.userFilePaths.isEmpty || !summary.speculativePaths.isEmpty

        let alert = NSAlert()
        alert.alertStyle = summary.userFilePaths.isEmpty ? .warning : .critical
        alert.messageText = "确认卸载「\(summary.appName)」？"

        var lines: [String] = []
        if let bytes = summary.estimatedBytes {
            let lower = model.plannedTrashBytesIsLowerBound ? "至少 " : ""
            lines.append("将移到废纸篓：\(lower)\(UninstallModel.formattedBytes(bytes) ?? "")（应用本体 + \(summary.itemCount) 项关联文件）")
        } else if summary.itemCount > 0 {
            lines.append("将把 \(summary.itemCount) 项关联文件移到废纸篓，并卸载应用本体。")
        } else {
            lines.append("未勾选关联文件，仅把应用本体移到废纸篓。")
        }
        lines.append("应用本体：\(summary.appPath)")
        lines.append("全部内容进入废纸篓，可随时恢复；清倒废纸篓后才会释放空间。")
        if summary.isAppRunning {
            lines.append("")
            lines.append("⚠️ 该应用正在运行：卸载前会先请求它退出，未保存的内容可能丢失。")
        }
        if !summary.userFilePaths.isEmpty {
            lines.append("")
            lines.append("⚠️ 勾选项含 \(summary.userFilePaths.count) 项个人文件（文档/下载中按名称匹配）：")
            lines.append(contentsOf: summary.userFilePaths.prefix(6).map { "· \($0)" })
            if summary.userFilePaths.count > 6 {
                lines.append("· …等共 \(summary.userFilePaths.count) 项")
            }
        }
        if !summary.speculativePaths.isEmpty {
            lines.append("")
            lines.append("其中 \(summary.speculativePaths.count) 项按名称模糊匹配，可能属于其它应用：")
            lines.append(contentsOf: summary.speculativePaths.prefix(5).map { "· \($0)" })
            if summary.speculativePaths.count > 5 {
                lines.append("· …等共 \(summary.speculativePaths.count) 项")
            }
        }
        if summary.requiresAdminCount > 0 {
            lines.append("")
            lines.append("\(summary.requiresAdminCount) 项位于 /Library，需要管理员权限，可能删除失败。")
        }
        alert.informativeText = lines.joined(separator: "\n")

        let removeTitle = summary.itemCount > 0 ? "移到废纸篓并卸载" : "仅卸载应用"
        if summary.isAppRunning {
            // 运行中：是否强杀交给用户决定（P0-4），默认按钮是取消
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "请求退出后卸载")
            alert.addButton(withTitle: "强制退出并卸载")
        } else if hasCritical {
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "仍要卸载（含风险项）")
        } else {
            alert.addButton(withTitle: removeTitle)
            alert.addButton(withTitle: "取消")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            guard !summary.isAppRunning, !hasCritical else { return }
            beginRemoval(forceQuit: false)
        case .alertSecondButtonReturn:
            guard summary.isAppRunning || hasCritical else { return }
            beginRemoval(forceQuit: false)
        case .alertThirdButtonReturn:
            guard summary.isAppRunning else { return }
            beginRemoval(forceQuit: true)
        default:
            return
        }
    }

    private func beginRemoval(forceQuit: Bool) {
        // 窗口可见时成功页已经给了反馈，避免「成功页 + toast」重复（P3-3）
        model.suppressCompletionToast = true
        model.removeChecked(forceQuitRunningApp: forceQuit)
    }
}


