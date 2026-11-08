import AppKit
import SwiftUI

/// 卸载器视图模型。
@MainActor
@Observable
public final class UninstallModel {

    public enum Phase: Equatable {
        case idle
        case scanning
        case ready
        case removing(progressDone: Int, progressTotal: Int)
        /// 全部成功（关联文件全部回收 + 应用本体已移废纸篓）。
        case done(trashed: Int)
        /// 部分失败：至少一项没能删除，需要把失败项与原因如实展示给用户。
        case partialFailure(trashed: Int, failures: [String])
    }

    /// 默认不勾选的关联文件类目（用户数据 / 系统级自启项）。
    public static let defaultExcludedCategories: Set<UninstallCategory> = [.userFiles, .launchItems]

    /// 默认勾选集合：只包含由 bundleId 精确派生的、确认属于该应用的项。
    /// 名称模糊匹配（`isSpeculative`）以及 User Files / Launch Items 一律默认不勾选，
    /// 必须由用户在清单里显式勾选。
    public static func defaultCheckedItemIDs(in items: [UninstallItem]) -> Set<String> {
        Set(items
            .filter { !$0.isSpeculative && !$0.category.isExcludedByDefault }
            .map(\.id))
    }

    public let app: AppRecord
    public private(set) var items: [UninstallItem] = []
    public var checkedItemIDs: Set<String> = []
    public var phase: Phase = .idle

    /// 当前 FDA 状态；`.denied` 时界面展示「可能漏扫」横幅，但不再阻断扫描。
    public private(set) var fullDiskAccessStatus: FullDiskAccess.Status = .unknown
    /// FDA 缺失（`.denied`）时展示横幅。保留该字段名以兼容既有调用与测试。
    public var needsFullDiskAccess: Bool = false

    /// 横幅只在「扫描前 / 扫描中 / 清单可操作」阶段显示；
    /// 删除完成页再显示「重新扫描」会把已卸载应用翻回列表，属于错误入口。
    public var showsAccessBanner: Bool {
        guard needsFullDiskAccess else { return false }
        switch phase {
        case .idle, .scanning, .ready: return true
        case .removing, .done, .partialFailure: return false
        }
    }

    private let layoutStore: LayoutStore
    /// 扫描代数：reset / 重新扫描都会自增，迟到的旧扫描结果直接丢弃。
    private var scanGeneration = 0
    /// 扫描根目录；测试可注入假 home，正常运行取真实用户目录。
    private let homeDirectory: URL
    /// FDA 探测实现；测试可注入固定状态。
    private let fullDiskAccessCheck: (URL) -> FullDiskAccess.Status

    public init(
        app: AppRecord,
        layoutStore: LayoutStore,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fullDiskAccessCheck: @escaping (URL) -> FullDiskAccess.Status = { FullDiskAccess.status(home: $0) }
    ) {
        self.app = app
        self.layoutStore = layoutStore
        self.homeDirectory = homeDirectory
        self.fullDiskAccessCheck = fullDiskAccessCheck
    }

    /// 清空上一次扫描/选择状态。窗口复用切换到另一个应用时必须先重置，
    /// 否则会残留旧应用的清单、勾选与进度态（P3-6）。
    public func reset() {
        scanGeneration &+= 1
        items = []
        checkedItemIDs = []
        phase = .idle
        fullDiskAccessStatus = .unknown
        needsFullDiskAccess = false
    }

    public func startScan() {
        scanGeneration &+= 1
        let generation = scanGeneration
        // 未授权 FDA 时不再整页阻断：应用本体与缓存等目录无需 FDA 即可清理，
        // 容器等受保护目录只是可能漏扫，应如实提示而不是让卸载器不可用。
        fullDiskAccessStatus = fullDiskAccessCheck(homeDirectory)
        needsFullDiskAccess = (fullDiskAccessStatus == .denied)
        // 重扫期间先清空旧清单/勾选，避免 footer 与列表还显示上一次应用的计数。
        items = []
        checkedItemIDs = []
        phase = .scanning
        let app = self.app
        let home = homeDirectory
        Task.detached(priority: .userInitiated) { [weak self] in
            let scanned = UninstallScanner.scan(app: app, home: home)
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.items = scanned
                // 默认只勾选明确归属于该应用的项；User Files / Launch Items / 名称模糊匹配默认关闭
                self.checkedItemIDs = Self.defaultCheckedItemIDs(in: scanned)
                self.phase = .ready
            }
        }
    }

    public func toggle(_ item: UninstallItem) {
        if checkedItemIDs.contains(item.id) {
            checkedItemIDs.remove(item.id)
        } else {
            checkedItemIDs.insert(item.id)
        }
    }

    public var selectedItems: [UninstallItem] {
        items.filter { checkedItemIDs.contains($0.id) }
    }

    /// 分组视图（按类目，保持 14 类固定顺序）。
    public var groupedItems: [(category: UninstallCategory, items: [UninstallItem])] {
        UninstallCategory.allCases.compactMap { category in
            let group = items.filter { $0.category == category }
            return group.isEmpty ? nil : (category, group)
        }
    }

    /// 删除确认弹窗所需的信息（路径清单供用户在确认前逐一核对）。
    public struct RemovalSummary: Equatable, Sendable {
        public let appName: String
        public let appPath: String
        public let itemCount: Int
        public let userFilePaths: [String]
    }

    public var removalSummary: RemovalSummary {
        let selected = selectedItems
        return RemovalSummary(
            appName: app.name,
            appPath: app.path,
            itemCount: selected.count,
            userFilePaths: selected.filter { $0.category.isUserData }.map(\.url.path)
        )
    }

    /// 执行删除：勾选项移废纸篓；应用本体移废纸篓并从布局移除。
    /// 只有全部成功才进入 `.done`，否则进入 `.partialFailure` 展示失败项与原因。
    public func removeChecked() {
        let targets = selectedItems
        phase = .removing(progressDone: 0, progressTotal: targets.count)
        let app = self.app
        Task { [weak self] in
            // 1) 先等待应用退出，避免边删边写导致删除失败/文件复活
            await Self.waitForTermination(bundleId: app.bundleId)
            guard let self else { return }

            // 2) 逐项移到废纸篓，失败逐条收集
            var trashed = 0
            var failures: [String] = []
            if !targets.isEmpty {
                let result = await UninstallEngine.remove(items: targets) { [weak self] event in
                    guard let self else { return }
                    if case let .progress(done, total) = event {
                        self.phase = .removing(progressDone: done, progressTotal: total)
                    }
                }
                trashed = result.trashed
                failures = result.failed.map { "\($0.path)：\($0.error)" }
            }

            // 3) 应用本体移废纸篓：错误不得吞掉；本体已不存在等同于已卸载
            var removedFromLayout = false
            do {
                _ = try await FinderActions.moveToTrash(app)
                removedFromLayout = true
            } catch {
                if case FinderActionError.pathMissing = error {
                    removedFromLayout = true
                } else {
                    failures.append("\(app.path)：\(error.localizedDescription)")
                }
            }
            if removedFromLayout {
                self.layoutStore.updateLayout { layout in
                    layout.removeApp(id: app.id)
                }
            }

            // 4) 结果如实上报：全部成功才显示成功态
            if failures.isEmpty {
                self.phase = .done(trashed: trashed)
                ToastManager.shared.success("已卸载「\(app.name)」")
            } else {
                self.phase = .partialFailure(trashed: trashed, failures: failures)
                ToastManager.shared.error("「\(app.name)」未完全卸载：\(failures.count) 项失败")
            }
        }
    }

    /// 优雅退出应用：等待最多 2s，超时后强制退出并短暂等待文件句柄释放。
    @MainActor
    private static func waitForTermination(bundleId: String?, timeout: TimeInterval = 2) async {
        guard let bundleId, !bundleId.isEmpty else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !running.isEmpty else { return }
        for app in running {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy({ $0.isTerminated }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for app in running where !app.isTerminated {
            app.forceTerminate()
        }
        // 给系统一点时间回收文件句柄，避免紧接着的删除被判为「文件正被占用」
        try? await Task.sleep(for: .milliseconds(200))
    }
}

/// 卸载器窗口（独立 UninstallWindow）。
@MainActor
public final class UninstallWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var currentModel: UninstallModel?

    public override init() {
        super.init()
    }

    public func show(app: AppRecord, layoutStore: LayoutStore) {
        currentModel?.reset()
        let model = UninstallModel(app: app, layoutStore: layoutStore)
        currentModel = model

        let content = UninstallContentView(model: model, onClose: { [weak self] in
            if let window = self?.window {
                WindowFade.fadeOut(window)
            }
        })
        let hosting = NSHostingView(rootView: content)

        if let window {
            window.contentView = hosting
            // 复用窗口时标题/头部必须跟着新应用刷新，否则会显示上一个应用名（P3-6）
            window.title = "卸载 \(app.name)"
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "卸载 \(app.name)"
            window.contentView = hosting
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        WindowFade.fadeIn(window!)
        model.startScan()
    }

    /// 关闭按钮 → 淡出后仅移出屏幕（窗口对象保留供复用）。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowFade.fadeOut(sender)
        return false
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
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .environment(model)
    }

    // MARK: 头部（图标 + 抖动动画）

    private var header: some View {
        HStack(spacing: 16) {
            JiggleIconView(iconPath: model.app.path)
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.app.name).font(.title2.weight(.semibold))
                Text(model.app.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(20)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .scanning:
            ProgressView("正在扫描关联文件…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .removing(done, total):
            VStack(spacing: 12) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .frame(width: 320)
                    Text("正在移除…（\(done)/\(total)）")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("正在退出应用并移到废纸篓…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .done(trashed):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.green)
                Text(trashed > 0 ? "已卸载，并清理 \(trashed) 项关联文件" : "已卸载")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .partialFailure(trashed, failures):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.orange)
                    Text("未完全卸载")
                        .font(.headline)
                }
                Text("已清理 \(trashed) 项；以下 \(failures.count) 项失败（可能没有权限、文件正被占用或位于受保护目录）：")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(failures, id: \.self) { failure in
                            Text("· \(failure)")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        case .ready:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                    ForEach(model.groupedItems, id: \.category) { group in
                        UninstallCategoryGroupView(
                            category: group.category,
                            items: group.items,
                            checkedIDs: Bindable(model).checkedItemIDs,
                            onToggle: { model.toggle($0) }
                        )
                    }
                    if model.groupedItems.isEmpty {
                        Text("未发现关联文件")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack {
            Text("共 \(model.items.count) 项，已选 \(model.selectedItems.count) 项")
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消", action: onClose)
            if case .ready = model.phase {
                Button(removeButtonTitle) {
                    confirmAndRemove()
                }
                .buttonStyle(.borderedProminent)
            }
            if case .done = model.phase {
                Button("完成", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
            if case .partialFailure = model.phase {
                Button("完成", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var removeButtonTitle: String {
        let count = model.selectedItems.count
        return count > 0 ? "移除 \(count) 项并卸载" : "仅卸载应用"
    }

    /// 危险操作二次确认：列出项数与关键路径；含个人文件时默认按钮改为「取消」，
    /// 需要用户明确点按「仍要移除个人文件并卸载」才会继续。
    private func confirmAndRemove() {
        let summary = model.removalSummary
        let alert = NSAlert()
        alert.alertStyle = summary.userFilePaths.isEmpty ? .warning : .critical
        alert.messageText = "确认卸载「\(summary.appName)」？"

        var lines: [String] = []
        if summary.itemCount > 0 {
            lines.append("将把 \(summary.itemCount) 项关联文件移到废纸篓，并卸载应用本体。")
        } else {
            lines.append("未勾选关联文件，仅把应用本体移到废纸篓。")
        }
        lines.append("应用本体：\(summary.appPath)")
        if !summary.userFilePaths.isEmpty {
            lines.append("")
            lines.append("⚠️ 勾选项含 \(summary.userFilePaths.count) 项个人文件（「文档」「下载」文件夹中按名称匹配到）：")
            lines.append(contentsOf: summary.userFilePaths.prefix(8).map { "· \($0)" })
            if summary.userFilePaths.count > 8 {
                lines.append("· …等共 \(summary.userFilePaths.count) 项")
            }
            lines.append("这些文件可能与该应用无关，删除后会进入废纸篓。")
        }
        alert.informativeText = lines.joined(separator: "\n")

        if summary.userFilePaths.isEmpty {
            alert.addButton(withTitle: "移到废纸篓并卸载")
            alert.addButton(withTitle: "取消")
        } else {
            // 默认按钮（回车）为取消，避免误触
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "仍要移除个人文件并卸载")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let confirmed = summary.userFilePaths.isEmpty
            ? response == .alertFirstButtonReturn
            : response == .alertSecondButtonReturn
        guard confirmed else { return }
        model.removeChecked()
    }
}

// MARK: - 类目分组

struct UninstallCategoryGroupView: View {
    let category: UninstallCategory
    let items: [UninstallItem]
    @Binding var checkedIDs: Set<String>
    let onToggle: (UninstallItem) -> Void

    private var allChecked: Bool {
        items.allSatisfy { checkedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(category.displayName)
                    .font(.headline)
                Text("(\(items.count))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(allChecked ? "取消全选" : "全选") {
                    if allChecked {
                        items.forEach { checkedIDs.remove($0.id) }
                    } else {
                        items.forEach { checkedIDs.insert($0.id) }
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            if let hint = riskHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
            }
            ForEach(items) { item in
                UninstallItemRowView(
                    item: item,
                    checked: checkedIDs.contains(item.id),
                    onToggle: { onToggle(item) }
                )
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }

    /// 高风险类目提示（默认不勾选的原因）。
    private var riskHint: String? {
        if category.isUserData {
            return "按应用名匹配到的个人文件，可能与该应用无关；默认不勾选，请逐项确认"
        }
        if category.hasSystemSideEffects {
            return "系统/用户级自启项，删除后应用可能无法自动启动；默认不勾选"
        }
        return nil
    }
}

struct UninstallItemRowView: View {
    let item: UninstallItem
    let checked: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { checked },
                set: { _ in onToggle() }
            ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if item.isSpeculative {
                        Text("可能相关")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                }
                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text(item.byteSize.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "大小未知")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }
}

// MARK: - 抖动图标（iOS 删除式抖动）

struct JiggleIconView: View {
    let iconPath: String
    @State private var jiggle = false

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .rotationEffect(.degrees(jiggle ? 2.4 : -2.4))
            .offset(x: jiggle ? 1.5 : -1.5)
            .animation(
                .easeInOut(duration: 0.11).repeatForever(autoreverses: true),
                value: jiggle
            )
            .onAppear { jiggle = true }
    }
}

// MARK: - 权限提示（完全磁盘访问）

/// 未授权「完全磁盘访问」时的非阻断横幅。
///
/// 旧版在缺权限时用整页引导替代扫描界面，导致卸载器在未授权机器上完全不可用；
/// 而应用本体、缓存、偏好等目录其实无需 FDA 就能清理。这里改为扫描照常进行，
/// 顶部横幅说明「容器等受保护目录可能漏扫」，并提供授权入口与重新扫描。
struct LimitedAccessBanner: View {
    let onOpenSettings: () -> Void
    let onRescan: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("未授予「完全磁盘访问」")
                    .font(.system(size: 12, weight: .semibold))
                Text("共享容器、其他应用的容器内容等受保护目录可能漏扫；个别受保护项删除时可能失败。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("前往授权", action: onOpenSettings)
                .controlSize(.small)
                .buttonStyle(.bordered)
            Button("重新扫描", action: onRescan)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.10))
    }
}
