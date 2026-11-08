import AppKit
import Observation
import SwiftUI

/// Toast 渲染视图。
public struct ToastsView: View {
    @Environment(ToastManager.self) private var manager

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(manager.items) { item in
                HStack(spacing: 8) {
                    switch item.kind {
                    case .info:
                        Image(systemName: "info.circle")
                    case .success:
                        Image(systemName: "checkmark.circle.fill")
                    case .error:
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    Text(item.message)
                        .font(.system(size: 13))
                        .lineLimit(2)
                }
                .foregroundStyle(item.kind == .error ? Color(red: 1, green: 0.76, blue: 0.4) : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // Toast 需要强对比保证可读：深色 scrim 的 Liquid Glass
                .liquidGlassCapsule(tint: .black.opacity(0.55))
                .shadow(color: .black.opacity(0.28), radius: 5, y: 1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { manager.dismiss(id: item.id) }
                // VoiceOver：仅有点击手势的提示无法被辅助技术关闭
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("点按关闭提示")
                .accessibilityAction(named: "关闭提示") { manager.dismiss(id: item.id) }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: manager.items)
    }
}

/// Toast 面板几何：按当前队列内容计算窗口尺寸。
///
/// 旧实现把面板固定成 460×160，即使只有一条一行提示，也会在屏幕底部中央
/// 留下一块 460×160 的透明热区，短暂吞掉下方窗口的点击（审查遗留问题）。
/// 尺寸改为「气泡尺寸 + 6pt 阴影留白」，底部 24pt 留白移到窗口原点，
/// 不再落在窗口内部形成透明热区。
///
/// 这里用 AppKit 字体度量复算 SwiftUI `ToastsView` 的布局常量。纯函数，
/// 便于单测锁定「面板不大于提示气泡多少」的契约。
enum ToastPanelLayout {
    /// 面板内容最大宽度（超长文案换行）。
    static let maxWidth: CGFloat = 460
    /// 单条气泡内部水平内边距（左右各 14）。
    static let horizontalPadding: CGFloat = 28
    /// 单条气泡内部垂直内边距（上下各 9）。
    static let verticalPadding: CGFloat = 18
    /// SF Symbol 图标宽度（按常见符号取略保守的值）。
    static let iconWidth: CGFloat = 18
    /// 图标与文字间距。
    static let iconSpacing: CGFloat = 8
    /// 多条 Toast 之间的间距。
    static let itemSpacing: CGFloat = 8
    /// 阴影（radius 5, y 1）需要的外扩留白；也是窗口内唯一的透明边。
    static let shadowMargin: CGFloat = 6
    /// 气泡距屏幕可视区底部的额外偏移（原 VStack 底部 padding 的位置）。
    static let bottomOffset: CGFloat = 24
    /// 面板底边距屏幕可视区底部的基础间距。
    static let screenBottomMargin: CGFloat = 8

    /// 计算承载 `items` 所需的窗口尺寸（含阴影留白）。空队列返回 `.zero`。
    ///
    /// - Parameter maxPanelWidth: 目标屏可容纳的最大窗口宽度；窄屏时同步收窄文本
    ///   预算并重算高度，避免只 clamp 宽度导致换行后最后一行被裁。
    static func panelSize(
        for items: [ToastItem],
        maxPanelWidth: CGFloat = maxWidth + shadowMargin * 2,
        font: NSFont = .systemFont(ofSize: 13)
    ) -> NSSize {
        guard !items.isEmpty else { return .zero }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        // ToastsView 用 `.lineLimit(2)`：超过两行的文案会截断，高度也必须按两行封顶，
        // 否则长文案会把面板撑高、重新制造大片透明热区。
        let maxTextHeight = lineHeight * 2
        let contentMaxWidth = min(maxWidth, max(maxPanelWidth - shadowMargin * 2, 1))
        let maxTextWidth = max(contentMaxWidth - horizontalPadding - iconWidth - iconSpacing, 1)

        var widestText: CGFloat = 0
        var contentHeight: CGFloat = 0
        for (index, item) in items.enumerated() {
            let singleLineWidth = ceil((item.message as NSString).size(withAttributes: attributes).width)
            // 宽度留 2pt 余量：不同 SF Symbol 宽度略有差异，略宽一点可避免
            // SwiftUI 实际换行后被裁掉。
            let textWidth = min(max(singleLineWidth + 2, 1), maxTextWidth)
            let measured = (item.message as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes
            ).height
            let textHeight = min(ceil(measured), maxTextHeight)
            widestText = max(widestText, textWidth)
            contentHeight += textHeight + verticalPadding
            if index < items.count - 1 {
                contentHeight += itemSpacing
            }
        }

        let contentWidth = min(
            contentMaxWidth,
            widestText + horizontalPadding + iconWidth + iconSpacing
        )
        return NSSize(
            width: contentWidth + shadowMargin * 2,
            height: contentHeight + shadowMargin * 2
        )
    }
}

/// 独立 Toast 浮层窗口（屏幕底部居中，不抢焦点）。
@MainActor
public final class ToastWindowController {

    private var panel: NSPanel?
    private let manager: ToastManager

    public init(manager: ToastManager = .shared) {
        self.manager = manager
    }

    /// 测试可见：当前面板 frame / 可见性（正常代码不应依赖）。
    var panelFrame: NSRect? { panel?.frame }
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    public func install() {
        guard panel == nil else { return }
        // 初始尺寸只占位：每次显示前 position() 会按内容重算，避免固定大面板
        // 在屏幕底部留下透明点击热区。
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 必须高于启动台全屏覆盖层（.statusBar）：否则启动台展开期间的提示
        // （排序模式限制、权限提醒等）整层被盖住，表现为"操作无反馈"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        // 点击胶囊可关闭 Toast：需要接收鼠标事件（窗口仍为 nonactivatingPanel，点击不会抢焦点）。
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = NSHostingView(
            rootView: ToastsView().environment(manager)
        )
        // macOS 26+ 的 NSHostingView 默认 sizingOptions 会反向驱动窗口尺寸：
        // toast 首帧出现时中文文本测量未就绪，fittingSize 偏小（仅图标宽），
        // 面板被永久缩成 icon 大小、文字被裁掉。禁掉反向驱动，面板尺寸只由
        // position() 决定。
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        observeQueue()

        // Toast 增删时自适应位置/尺寸
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.position()
            }
        }
    }

    /// 观察 Toast 队列：只在有条目时显示面板，队列清空立即 orderOut，
    /// 避免一个透明的顶层面板长期驻留并挡住下方窗口的点击。
    private func observeQueue() {
        withObservationTracking {
            // 必须观察整个数组：只看 isEmpty 的话，「已有一条时再新增/移除一条」
            // 不会触发回调，面板尺寸会停在旧内容的尺寸上（动态尺寸后必须跟着更新）。
            _ = manager.items
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncVisibility()
                self.observeQueue()
            }
        }
        syncVisibility()
    }

    private func syncVisibility() {
        guard let panel else { return }
        if manager.items.isEmpty {
            panel.orderOut(nil)
        } else {
            position()
            // orderFrontRegardless 不会激活 App / 抢焦点（nonactivatingPanel）
            panel.orderFrontRegardless()
        }
    }

    /// 底部居中的目标屏幕：优先当前键盘窗口所在屏（启动台所在屏），
    /// 其次鼠标所在屏，最后回退主屏。
    private func preferredScreen() -> NSScreen? {
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        let mouse = NSEvent.mouseLocation
        if let hovered = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hovered
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// 底部居中于目标屏可视区（避开 Dock），尺寸按当前队列内容收缩。
    private func position() {
        guard let panel,
              let screen = preferredScreen() else { return }
        let visible = screen.visibleFrame
        // 窄屏：把可用宽度传给布局函数，同步重算换行后的高度（不能只 clamp 宽度）。
        let size = ToastPanelLayout.panelSize(
            for: manager.items,
            maxPanelWidth: max(visible.width - 16, ToastPanelLayout.shadowMargin * 2 + 20)
        )
        guard size.width > 0, size.height > 0 else { return }
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + ToastPanelLayout.screenBottomMargin + ToastPanelLayout.bottomOffset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// 新应用检测：监听来源目录变化（删除/新增 .app）触发重扫 + NEW 徽章。
@MainActor
public final class NewAppWatcher {

    public var onDirectoriesChanged: (() -> Void)?

    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedDirectories: [URL] = []

    public init() {}

    /// 开始监听（对现有来源目录建立 file system object 源）。
    public func watch(directories: [URL]) {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        watchedDirectories = directories

        for directory in directories {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleChange()
                }
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            sources.append(source)
        }
    }

    private var debounceTask: Task<Void, Never>?

    private func handleChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))  // 等安装过程落定
            guard !Task.isCancelled else { return }
            self?.onDirectoriesChanged?()
        }
    }
}
