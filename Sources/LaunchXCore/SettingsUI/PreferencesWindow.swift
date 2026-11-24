import AppKit
import ServiceManagement
import SwiftUI

/// 开机自启动（SMAppService 封装）。
public enum LoginItemService {
    /// 当前是否已注册登录项（仅打包 .app 可用）。
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 注册生效或等待用户在系统设置中批准（沙盒/审批场景下 register 后为 .requiresApproval）。
    public static var isEffectivelyEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// 已发起注册但还需用户到系统设置 → 通用 → 登录项 中批准。
    public static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// 设置窗根模型：设置读写 + 应用回调（AppDelegate 注入）。
@MainActor
@Observable
public final class PreferencesModel {

    public let store: LayoutStore

    /// 设置变更后应用副作用（快捷键 / 手势 / 图标开关）。
    public var onApplySettings: (() -> Void)?
    /// 触发重扫。
    public var onRescan: (() -> Void)?
    /// 取消隐藏应用（AppDelegate 接到 `LaunchpadModel.unhide`：会把未摆放的应用补摆回网格）。
    public var onUnhideApp: ((String) -> Void)?

    public init(store: LayoutStore) {
        self.store = store
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        store.updateSettings(mutate)
        onApplySettings?()
    }

    public func updateSources(_ mutate: (inout [SourceConfig]) -> Void) {
        store.updateSources(mutate)
        onRescan?()
    }

    /// 通用设置页的 keyPath → Binding 辅助。
    public func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { self.store.state.settings[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    /// 开机启动开关与 SMAppService 对账（面板打开时调用；服务是唯一真相，此字段仅为 UI 镜像）。
    public func syncLoginItemMirror() {
        store.updateSettings { $0.launchAtLogin = LoginItemService.isEffectivelyEnabled }
    }

    // MARK: 隐藏应用

    /// 取消隐藏。优先走 `LaunchpadModel.unhide`（会按当前密度把未摆放的应用补摆到末页）；
    /// 未接线时用等价后备实现——直接改 hidden 会让「恢复默认布局」后只存在注册表的
    /// 隐藏项既不回网格、默认搜索也搜不到，等于彻底失联。
    public func unhideApp(id: String) {
        if let onUnhideApp {
            onUnhideApp(id)
            return
        }
        let capacity = store.state.settings.gridDensity.capacity
        store.updateLayout { layout in
            guard let app = layout.apps[id] else { return }
            layout.apps[id]?.hidden = false
            if !app.isAlias, !layout.placedAppIDs.contains(id) {
                layout.appendApp(id: id, toPage: max(layout.pages.count - 1, 0), capacityPerPage: capacity)
            }
        }
        store.applyActiveSort()
    }

    // MARK: 排序方式

    /// 切换排序方式并立即全局重排（Custom 保持现有布局不重排）。
    public func applySortKey(_ key: SortKey) {
        update { $0.activeSortKey = key }
        store.applyActiveSort()
    }

    /// 切换升序 / 降序并立即全局重排（固定方向键无此开关，调用方负责隐藏）。
    public func applySortAscending(_ ascending: Bool) {
        update { $0.sortAscending = ascending }
        store.applyActiveSort()
    }

    /// 摆放规则（文件夹位置）只在 `applyActiveSort` 里被读取：改完必须立即重排，
    /// 否则设置与网格不一致，要等下次重扫/启动才生效。
    public func setFolderPosition(_ position: FolderPosition) {
        update { $0.folderPosition = position }
        store.applyActiveSort()
    }

    /// 摆放规则（Apple 应用位置），同上。
    public func setAppleAppsPosition(_ position: AppleAppsPosition) {
        update { $0.appleAppsPosition = position }
        store.applyActiveSort()
    }

    // MARK: 快捷键录制结果处理

    /// 尝试注册新快捷键；成功返回 nil，失败返回错误文案（由录制器展示并回滚）。
    public func tryApplyHotKey(_ spec: HotKeySpec) -> String? {
        do {
            try HotKeyCenter.shared.register(spec)
            update { $0.hotKey = spec }
            return nil
        } catch {
            // 冲突检测：保留当前生效键
            if let active = HotKeyCenter.shared.currentSpec {
                update { $0.hotKey = active }
            }
            return "快捷键注册失败，可能与其它应用冲突：\(error.localizedDescription)"
        }
    }

    /// 清除快捷键；若它已经是最后一个唤起入口则拒绝（否则应用会失联）。
    public func clearHotKey() {
        guard hasAlternativeEntry(excluding: .hotKey) else {
            blockLastEntry()
            return
        }
        HotKeyCenter.shared.unregister()
        update { $0.hotKey = .none }
    }

    // MARK: 唤起入口保底（P1-11）

    /// 应用的全部唤起入口。
    public enum EntryKind: Hashable, Sendable {
        case menuBarIcon
        case dockIcon
        case hotKey
        case pinchGesture
    }

    /// 除指定入口外是否还存在其它可用入口。
    public func hasAlternativeEntry(excluding kind: EntryKind, in settings: AppSettings? = nil) -> Bool {
        let s = settings ?? store.state.settings
        // 原始触点手势通道无需任何权限，开关即有效入口。
        let gestureEntry = TrackpadTouchMonitor.isEntryAvailable(enabled: s.pinchGestureEnabled)
        switch kind {
        case .menuBarIcon:
            return s.hotKey != .none || gestureEntry || s.showDockIcon
        case .dockIcon:
            return s.hotKey != .none || gestureEntry || s.showMenuBarIcon
        case .hotKey:
            return gestureEntry || s.showMenuBarIcon || s.showDockIcon
        case .pinchGesture:
            return s.hotKey != .none || s.showMenuBarIcon || s.showDockIcon
        }
    }

    /// 当前是否至少有一个唤起入口（AppDelegate 兜底判定同一逻辑）。
    public var hasAnyEntry: Bool {
        let s = store.state.settings
        return s.showMenuBarIcon || s.showDockIcon || s.hotKey != .none
            || TrackpadTouchMonitor.isEntryAvailable(enabled: s.pinchGestureEnabled)
    }

    private func blockLastEntry() {
        ToastManager.shared.error("无法关闭：至少保留一个唤起入口（快捷键、手势或图标）。")
    }

    public func setMenuBarIconVisible(_ visible: Bool) {
        guard visible || hasAlternativeEntry(excluding: .menuBarIcon) else {
            blockLastEntry()
            return
        }
        update { $0.showMenuBarIcon = visible }
    }

    public func setDockIconVisible(_ visible: Bool) {
        guard visible || hasAlternativeEntry(excluding: .dockIcon) else {
            blockLastEntry()
            return
        }
        update { $0.showDockIcon = visible }
    }

    public func setPinchGestureEnabled(_ enabled: Bool) {
        guard enabled || hasAlternativeEntry(excluding: .pinchGesture) else {
            blockLastEntry()
            return
        }
        update { $0.pinchGestureEnabled = enabled }
    }

    // MARK: 来源管理

    public func addSource(url: URL) {
        let path = url.path
        guard !store.state.sources.contains(where: { $0.path == path }) else { return }
        updateSources { $0.append(SourceConfig(path: path, enabled: true, kind: .custom)) }
        ToastManager.shared.success("已添加应用来源：\(url.lastPathComponent)")
    }

    public func removeSource(id: UUID) {
        guard let source = store.state.sources.first(where: { $0.id == id }) else { return }
        guard canRemoveSource(source) else {
            ToastManager.shared.error("内置「应用程序」来源不能删除")
            return
        }
        let affected = affectedAppCount(for: source)
        guard confirmSourceChange(title: "删除来源「\(displayName(for: source))」？", affected: affected) else { return }
        updateSources { $0.removeAll { $0.id == id } }
    }

    public func setSourceEnabled(id: UUID, enabled: Bool) {
        guard let source = store.state.sources.first(where: { $0.id == id }) else { return }
        if !enabled {
            let affected = affectedAppCount(for: source)
            // 关闭来源会让已摆放应用被 rescan 从布局移除：有应用或内置来源时必须确认
            if affected > 0 || source.kind == .defaultApps {
                guard confirmSourceChange(
                    title: "关闭来源「\(displayName(for: source))」？",
                    affected: affected,
                    extra: "重新启用后，这些应用会作为「新应用」出现在最后一页，原排列与文件夹归类不会恢复。"
                ) else { return }
            }
        }
        updateSources { sources in
            if let index = sources.firstIndex(where: { $0.id == id }) {
                sources[index].enabled = enabled
            }
        }
    }

    /// 内置「应用程序」来源是唯一默认来源，不允许删除。
    public func canRemoveSource(_ source: SourceConfig) -> Bool {
        source.kind != .defaultApps
    }

    /// 来源展示名（内置来源显示中文，自定义来源显示目录名）。
    public func displayName(for source: SourceConfig) -> String {
        if source.kind == .defaultApps { return "应用程序（默认路径）" }
        return URL(fileURLWithPath: source.path).lastPathComponent
    }

    /// 该来源当前布局中有多少应用（用于「将移除 N 个应用」提示）。
    public func affectedAppCount(for source: SourceConfig) -> Int {
        let directories = sourceDirectories(for: source)
        guard !directories.isEmpty else { return 0 }
        return store.state.layout.apps.values.filter { app in
            directories.contains { app.path.hasPrefix($0 + "/") }
        }.count
    }

    private func sourceDirectories(for source: SourceConfig) -> [String] {
        source.kind == .defaultApps ? SourceConfig.defaultAppsDirectories() : [source.path]
    }

    /// 来源变更确认弹窗：明确列出受影响的已摆放应用数量；后果不显然时用 extra 补一句。
    private func confirmSourceChange(title: String, affected: Int, extra: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        let consequence = affected > 0
            ? "将从启动台移除该来源下的 \(affected) 个应用，其排序位置、文件夹归类与隐藏状态会被清除。"
            : "该来源下没有已摆放的应用，不会影响当前布局。"
        alert.informativeText = extra.map { "\(consequence)\n\($0)" } ?? consequence
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: 高级操作

    public func restoreDefaultLayout() {
        let alert = NSAlert()
        alert.messageText = "恢复默认布局？"
        alert.informativeText = "将清除页面与文件夹排列，并重新按扫描结果排列；隐藏状态与使用记录会保留。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.resetLayout()
        onRescan?()
        ToastManager.shared.success("已恢复默认布局")
    }
}

/// 设置窗控制器（4 标签页：通用 / 应用 / 界面 / 关于）。
@MainActor
public final class PreferencesWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?

    private let model: PreferencesModel

    public init(model: PreferencesModel) {
        self.model = model
    }

    public func show() {
        if window == nil {
            let content = PreferencesRootView()
                .environment(model)
            let hosting = NSHostingView(rootView: content.frame(minWidth: 680, minHeight: 520))
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "LaunchX 设置"
            newWindow.contentView = hosting
            newWindow.center()
            newWindow.delegate = self
            window = newWindow
        }
        guard let window else { return }
        // 面板是全屏 statusBar 层级：面板可见时子窗口必须抬到它之上，否则会被完全遮住。
        window.level = LaunchpadWindowController.childWindowLevel
        LaunchpadWindowController.registerChildWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        WindowFade.fadeIn(window)
    }

    /// 关闭按钮 → 淡出后仅移出屏幕（窗口对象保留供复用）。
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowFade.fadeOut(sender)
        return false
    }
}

/// 设置根视图：4 标签页（通用/应用/界面/关于）。
struct PreferencesRootView: View {
    @Environment(PreferencesModel.self) private var prefs
    /// 用户去系统设置授权后切回来：重算一次 body，让「需要权限 / 待批准」提示即时消失。
    /// 这两个状态来自 AXIsProcessTrusted / SMAppService，都不是可观察对象。
    @State private var permissionRefreshTick = 0

    var body: some View {
        let _ = permissionRefreshTick
        VStack(spacing: 8) {
            // 只读模式横幅：更高版本写入的配置无法保存，必须让用户看见
            if let notice = prefs.store.futureVersionReadOnlyNotice {
                Label(notice, systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            TabView {
                GeneralSettingsTab().tabItem { Label("通用", systemImage: "gearshape") }
                AppsSettingsTab().tabItem { Label("应用", systemImage: "square.grid.2x2") }
                InterfaceSettingsTab().tabItem { Label("界面", systemImage: "paintbrush") }
                InfoSettingsTab().tabItem { Label("关于", systemImage: "info.circle") }
            }
        }
        .padding(16)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRefreshTick &+= 1
        }
    }
}

// MARK: - 通用 General

/// 需要用户到系统设置操作时的行内替代文案：一句状态 + 直达对应面板的按钮。
struct SystemSettingsActionRow: View {
    let icon: String
    let status: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(status, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Spacer()
            Button("打开系统设置", action: action)
                .controlSize(.small)
        }
    }
}

/// 系统设置面板跳转。
enum SystemSettingsPane {
    /// 隐私与安全性 → 辅助功能（捏合手势需要）。
    static func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    /// 通用 → 登录项（开机启动审批）。
    static func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}

struct GeneralSettingsTab: View {
    @Environment(PreferencesModel.self) private var prefs
    private var settings: AppSettings { prefs.store.state.settings }

    var body: some View {
        Form {
            Section("唤起") {
                HotKeyRecorderRow()
                Toggle("捏合唤起（四指）", isOn: Binding(
                    get: { settings.pinchGestureEnabled },
                    set: { prefs.setPinchGestureEnabled($0) }
                ))
                if settings.pinchGestureEnabled && !TrackpadTouchMonitor.hasPermission {
                    SystemSettingsActionRow(
                        icon: "lock.open.fill",
                        status: "可选：授予「辅助功能」权限后，捏合唤起时会同时抑制系统启动台手势（避免双开）",
                        action: SystemSettingsPane.openAccessibility
                    )
                }
            }

            Section("启动与图标") {
                Toggle("开机自动启动", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { on in
                        do {
                            try LoginItemService.setEnabled(on)
                        } catch {
                            ToastManager.shared.error("开机启动设置失败（需以打包后的 .app 运行）：\(error.localizedDescription)")
                        }
                        prefs.update { $0.launchAtLogin = LoginItemService.isEffectivelyEnabled }
                    }
                ))
                if LoginItemService.needsApproval {
                    SystemSettingsActionRow(
                        icon: "hourglass",
                        status: "待系统批准开机启动",
                        action: SystemSettingsPane.openLoginItems
                    )
                }
                Toggle("显示菜单栏图标", isOn: Binding(
                    get: { settings.showMenuBarIcon },
                    set: { prefs.setMenuBarIconVisible($0) }
                ))
                Toggle("显示程序坞图标", isOn: Binding(
                    get: { settings.showDockIcon },
                    set: { prefs.setDockIconVisible($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .onAppear { prefs.syncLoginItemMirror() }
    }
}

/// 快捷键单项配置行：标签 + 录制框 + × 清除。
struct HotKeyRecorderRow: View {
    @Environment(PreferencesModel.self) private var prefs
    @State private var recording = false
    @State private var errorMessage: String?

    private var spec: HotKeySpec { prefs.store.state.settings.hotKey }

    var body: some View {
        HStack {
            Text("快捷键")
            Spacer()
            HotKeyRecorderControl(
                recording: $recording,
                displayText: spec == .none ? "未设置" : KeyCodes.displayString(for: spec),
                onRecorded: { recorded in
                    guard let recorded else { return }
                    if let validationIssue = KeyCodes.validate(recorded) {
                        errorMessage = validationIssue
                        return
                    }
                    errorMessage = prefs.tryApplyHotKey(recorded)
                }
            )
            Button {
                prefs.clearHotKey()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .disabled(spec == .none)
            .accessibilityLabel("清除快捷键")
        }
        .alert("快捷键无效", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

/// 快捷键录制控件（NSView 捕获 keyDown）。
struct HotKeyRecorderControl: NSViewRepresentable {
    @Binding var recording: Bool
    let displayText: String
    let onRecorded: (HotKeySpec?) -> Void

    func makeNSView(context: Context) -> RecorderControlView {
        let view = RecorderControlView()
        view.onRecorded = { recorded in
            recording = false
            onRecorded(recorded)
        }
        view.onRecordingChanged = { recording = $0 }
        return view
    }

    func updateNSView(_ nsView: RecorderControlView, context: Context) {
        nsView.displayText = displayText
        nsView.recording = recording
    }

    final class RecorderControlView: NSView {
        var displayText: String = "" {
            didSet { needsDisplay = true; updateLabel() }
        }
        var recording = false {
            didSet {
                guard oldValue != recording else { return }
                needsDisplay = true
                updateLabel()
                // VoiceOver 需要感知「录制中 / 已录到键位」的状态变化
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
        var onRecorded: ((HotKeySpec?) -> Void)?
        var onRecordingChanged: ((Bool) -> Void)?

        private let label = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            addSubview(label)
            label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            label.alignment = .center
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            updateLabel()
        }

        required init?(coder: NSCoder) { fatalError() }

        private func updateLabel() {
            label.stringValue = recording ? "按下新的快捷键…" : displayText
            layer?.borderColor = recording
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
        }

        override var intrinsicContentSize: NSSize { NSSize(width: 140, height: 28) }

        override func layout() {
            super.layout()
            label.frame = bounds.insetBy(dx: 6, dy: 6)
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            recording = true
            onRecordingChanged?(true)
        }

        override var acceptsFirstResponder: Bool { true }

        // VoiceOver：以按钮角色暴露标签与当前键位
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { "全局快捷键" }
        override func accessibilityValue() -> Any? { recording ? "录制中" : displayText }

        /// 仅暴露为 .button 而没有 press 动作时，VoiceOver 用户无法开始录制（P3-5）。
        override func accessibilityPerformPress() -> Bool {
            if recording {
                recording = false
                onRecordingChanged?(false)
                return true
            }
            guard window != nil else { return false }
            window?.makeFirstResponder(self)
            recording = true
            onRecordingChanged?(true)
            return true
        }

        override func accessibilityHelp() -> String? {
            "按下后可录制新的快捷键；按 Esc 取消录制。"
        }

        /// 失去焦点即取消录制，避免界面卡在「按下新的快捷键…」。
        override func resignFirstResponder() -> Bool {
            if recording {
                recording = false
                onRecordingChanged?(false)
            }
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            // 录制结束后控件仍是 first responder：不设这道闸，之后在设置窗里敲的任意键
            //（Tab/方向键/字母）都会被当成一次新录制——要么弹「快捷键无效」，要么静默换绑热键。
            guard recording else {
                super.keyDown(with: event)
                return
            }
            defer {
                recording = false
                onRecordingChanged?(false)
                // 录完主动交还第一响应者，让后续按键回到正常控件导航。
                window?.makeFirstResponder(nil)
            }
            // Esc 取消
            if event.keyCode == KeyCodes.kVK_Escape {
                onRecorded?(nil)
                return
            }
            let modifiers = KeyCodes.carbonFlags(from: event.modifierFlags)
            let spec = HotKeySpec(keyCode: UInt32(event.keyCode), modifiers: modifiers)
            onRecorded?(spec)
        }
    }
}
