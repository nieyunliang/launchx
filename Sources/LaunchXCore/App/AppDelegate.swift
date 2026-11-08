import AppKit
import os
import SwiftUI

/// 应用装配中枢：菜单栏/Dock 图标开关、唤起方式（快捷键/手势/菜单栏）、窗口装配、新应用监听。
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "dev.yunliang.launchx", category: "AppDelegate")

    // MARK: 模块

    public let store = LayoutStore()
    public let launchpadModel: LaunchpadModel
    public let launchpadController: LaunchpadWindowController

    private lazy var preferencesModel = PreferencesModel(store: store)
    private lazy var preferencesController = PreferencesWindowController(model: preferencesModel)
    private lazy var reorganizeController = ReorganizeWindowController(store: store, model: launchpadModel)
    private lazy var uninstallController = UninstallWindowController()
    private lazy var onboardingController = OnboardingWindowController()
    private lazy var toastController = ToastWindowController()

    private let hotKeyCenter = HotKeyCenter.shared
    private let gestureMonitor = TrackpadGestureMonitor()
    private let newAppWatcher = NewAppWatcher()

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    /// 上一次生效的「显示程序坞图标」值：nil 表示启动后的首次装配。
    private var lastDockIconSetting: Bool?

    /// 上一次生效的网格密度：变更时需重排布局，避免物品按新容量溢出页框。
    private var lastAppliedDensity: GridDensity?

    // MARK: 生命周期

    public override init() {
        launchpadModel = LaunchpadModel(store: store)
        launchpadController = LaunchpadWindowController(model: launchpadModel)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        wireCallbacks()
        applySettings(interactive: false)
        toastController.install()
        if store.didRecoverFromCorruption {
            ToastManager.shared.error("布局文件已损坏，原文件已保留为 .corrupt 备份，本次从默认布局启动")
        }
        launchpadModel.rescan()
        watchAppDirectories()
        setupStatusItem()
        refreshDockIconVisibility()
        observeAppearanceChanges()
        launchpadController.preheatWallpaper()

        // 诊断：观察状态栏图标窗口是否在创建后被系统回收（0 高 → 正常，消失 → 被回收）
        for delay in [2.5, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                Self.logger.info("status item check t+\(delay)s: item=\(self.statusItem != nil, privacy: .public), buttonWindow=\(String(describing: self.statusItem?.button?.window?.frame), privacy: .public)")
            }
        }

        if !store.state.settings.onboardingCompleted {
            onboardingController.onFinished = { [weak self] in
                self?.store.updateSettings { $0.onboardingCompleted = true }
            }
            onboardingController.show()
        }

        #if DEBUG
        // 开发/调试触发：外部 post 分布式通知即可显示/隐藏启动台
        // （swift -e 'DistributedNotificationCenter...' 或脚本），无需辅助功能权限。
        // 仅 DEBUG 编译存在：Release 包不暴露任何外部可触发的控制入口。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("LaunchXDevToggle"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.launchpadController.toggle()
            }
        }

        // 开发/调试触发：post 该分布式通知可直接打开设置面板（无需 UI 点击）。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("LaunchXDevSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.preferencesController.show()
            }
        }
        #endif

        // 冒烟模式：`LaunchX -launchx-smoke` 启动 1s 后自动打开 Launchpad，
        // 3s 后校验可见状态并退出（exit 0 = 通过；窗口装配崩溃则进程直接 SIGTRAP）。
        if ProcessInfo.processInfo.arguments.contains("-launchx-smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.launchpadController.show()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let visible = self?.launchpadModel.isVisible == true
                    print("SMOKE: launchpad visible = \(visible)")
                    exit(visible ? 0 : 1)
                }
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // 收起时的持久化会延后到动画结束；退出前兜底保存尚未落盘的内存状态。
        try? store.saveNow()
        gestureMonitor.stop()
        hotKeyCenter.unregister()
    }

    // MARK: 回调装配

    private func wireCallbacks() {
        launchpadModel.onOpenSettings = { [weak self] in
            self?.preferencesController.show()
        }
        launchpadModel.onOpenReorganize = { [weak self] in
            self?.reorganizeController.show()
        }
        launchpadModel.onOpenUninstall = { [weak self] appID in
            guard let self, let app = self.store.state.layout.apps[appID] else { return }
            self.uninstallController.show(app: app, layoutStore: self.store)
        }
        launchpadModel.onDismiss = { [weak self] in
            self?.launchpadController.hide()
        }
        preferencesModel.onApplySettings = { [weak self] in
            self?.applySettings(interactive: false)
            self?.refreshDockIconVisibility()
            self?.setupStatusItem()
        }
        preferencesModel.onRescan = { [weak self] in
            self?.launchpadModel.rescan()
            // 来源目录可能已增删，同步重挂监听，否则新目录里后续放入的 app 不会自动重扫
            self?.watchAppDirectories()
        }

        hotKeyCenter.onTrigger = { [weak self] in self?.launchpadController.toggle() }
        gestureMonitor.onEvent = { [weak self] event in
            self?.launchpadController.handlePinchGesture(event)
        }
        newAppWatcher.onDirectoriesChanged = { [weak self] in
            self?.launchpadModel.rescan()
            self?.watchAppDirectories()
        }
    }

    /// 应用设置（快捷键 / 手势）。
    private func applySettings(interactive: Bool) {
        let settings = store.state.settings

        // 全局快捷键
        if settings.hotKey == .none {
            hotKeyCenter.unregister()
        } else {
            do {
                try hotKeyCenter.register(settings.hotKey)
            } catch {
                if interactive {
                    ToastManager.shared.error("全局快捷键注册失败：\(error.localizedDescription)")
                }
            }
        }

        // 触控板手势
        gestureMonitor.setMode(settings.pinchGesture)

        // 网格密度变化：按新容量重排（启动首次装配只记录，不动用户现有排列）。
        let density = settings.gridDensity
        if let previous = lastAppliedDensity, previous != density {
            launchpadModel.reflowAfterDensityChange()
        }
        lastAppliedDensity = density
    }

    // MARK: 菜单栏

    /// 菜单栏图标：左键展开/收起启动台，右键（含 ⌃左键）弹功能菜单。
    /// `statusItem.button` 偶发返回 nil（系统侧创建竞态）会导致图标静默消失且无法唤起，
    /// 因此失败时摘除重建，最多重试 3 次。
    private var didWarnAboutLastEntryPoint = false

    private func setupStatusItem(retryAttempt: Int = 0) {
        // 入口保底：菜单栏图标、全局快捷键、手势、程序坞图标全关时，用户将无法再次唤起面板；
        // 此时强制保留菜单栏图标并提示（设置界面同时会阻止关闭最后一个入口）。
        var showMenuBar = store.state.settings.showMenuBarIcon
        if !showMenuBar {
            let settings = store.state.settings
            let hasAlternativeEntry = settings.hotKey != .none
                || settings.pinchGesture != .off
                || settings.showDockIcon
            if !hasAlternativeEntry {
                showMenuBar = true
                if !didWarnAboutLastEntryPoint {
                    didWarnAboutLastEntryPoint = true
                    ToastManager.shared.error("已保留菜单栏图标：否则将没有任何方式重新打开 LaunchX")
                }
            }
        }
        if !showMenuBar {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            statusMenu = nil
            return
        }
        // 图标已存在（如设置里换了主题）时仅刷新图标
        if let item = statusItem {
            item.button?.image = Self.menuBarIcon(for: store.state.settings.appIconTheme)
            item.button?.image?.isTemplate = true
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuBarIcon(for: store.state.settings.appIconTheme)
            button.image?.isTemplate = true
            // 不设 item.menu（那会让左键也弹菜单），改为 action 按键位分流
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        } else {
            NSStatusBar.system.removeStatusItem(item)
            Self.logger.error("status item button is NIL at creation (attempt \(retryAttempt + 1))")
            if retryAttempt < 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.setupStatusItem(retryAttempt: retryAttempt + 1)
                }
                return
            }
            Self.logger.fault("status item creation failed after retries; launchpad unreachable until relaunch or settings change")
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettingsMenuItem), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 LaunchX", action: #selector(quitMenuItem), keyEquivalent: "q").target = self

        statusMenu = menu
        statusItem = item
        Self.logger.info("status item created: theme=\(self.store.state.settings.appIconTheme.rawValue, privacy: .public), buttonWindow=\(String(describing: item.button?.window?.frame), privacy: .public)")
    }

    /// 图标点击分流：左键 toggle 启动台；右键 / ⌃左键临时挂载菜单并弹出。
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseDown
            || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
        guard wantsMenu, let menu = statusMenu else {
            launchpadController.toggle()
            return
        }
        // 挂回 item.menu 后模拟点击，走系统原生状态项菜单（高亮 + 正确锚定）；
        // menuDidClose 中摘除，保证左键仍是展开行为。
        statusItem?.menu = menu
        sender.performClick(nil)
    }

    /// 菜单栏模板图标（与新 Dock 图标同语言的瓦片网格，见 AppIconRenderer）。
    private static func menuBarIcon(for theme: AppIconTheme) -> NSImage {
        AppIconRenderer.menuBarIcon(for: theme)
    }

    // MARK: Dock 图标开关与图标主题

    private func refreshDockIconVisibility() {
        let showDock = store.state.settings.showDockIcon

        // 先调整 Dock 配置（写回后 Dock 会重载），再切激活策略，
        // 避免「先变成运行中应用、图标先出现在末尾、随后才跳到最前」的闪动。
        if lastDockIconSetting != showDock {
            let previous = lastDockIconSetting
            lastDockIconSetting = showDock

            if showDock {
                // 仅运行中由关→开时才前移：启动时不再搬动，避免和用户手动拖拽的图标位置打架
                if previous == false {
                    pinDockIconAtFront()
                }
            } else if store.state.settings.dockIconPinnedByApp {
                // 启动时也做一次对账：上次异常退出没来得及移除时补上
                unpinDockIcon()
            }
        }

        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        refreshAppIcon()
    }

    /// 勾选「显示程序坞图标」→ 把 LaunchX 固定到程序坞前部（默认下标 2 = 第 3 格）。
    /// macOS 没有 Dock 排序 API，只能改写 `com.apple.dock` 的 `persistent-apps`
    ///（与「添加到程序坞」共用同一套 defaults 导出/写回 + killall Dock 逻辑）。
    private func pinDockIconAtFront() {
        guard let bundleURL = appBundleURL else { return }
        let label = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "LaunchX"
        do {
            let alreadyPinned = try FinderActions.pinToDockFront(bundleURL, label: label)
            // 图标本来就在 Dock 上（用户手动固定）：不算本应用所有，取消勾选时保留
            if !alreadyPinned {
                store.updateSettings { $0.dockIconPinnedByApp = true }
            }
        } catch {
            Self.logger.error("固定程序坞图标失败: \(error.localizedDescription, privacy: .public)")
            ToastManager.shared.error("无法把图标放到程序坞指定位置：\(error.localizedDescription)")
        }
    }

    /// 取消勾选「显示程序坞图标」→ 移除本应用自己固定的那个 tile。
    private func unpinDockIcon() {
        guard let bundleURL = appBundleURL else { return }
        do {
            try FinderActions.unpinFromDock(bundleURL)
        } catch {
            Self.logger.error("移除程序坞图标失败: \(error.localizedDescription, privacy: .public)")
        }
        store.updateSettings { $0.dockIconPinnedByApp = false }
    }

    /// 只有以 .app 形式运行时才改写 Dock（`swift run` 的裸二进制没有可固定的 bundle）。
    private var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            Self.logger.info("非 .app 运行（\(url.path, privacy: .public)），跳过程序坞位置同步")
            return nil
        }
        return url
    }

    /// 应用图标主题（4 套 × 明暗）：程序自绘（技术方案约定不使用原版素材），
    /// 与 resources/AppIcon.icns 同一套「深空底 + 瓦片网格」视觉语言（AppIconRenderer）。
    private func refreshAppIcon() {
        let theme = store.state.settings.appIconTheme
        let dark = LXColors.isDark
        NSApp.applicationIconImage = AppIconRenderer.appIcon(for: theme, dark: dark)
    }

    /// 监听系统外观切换（亮暗主题跟随刷新图标）。
    private func observeAppearanceChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAppIcon()
            }
        }
    }

    // MARK: 新应用监听

    private func watchAppDirectories() {
        newAppWatcher.watch(directories: SourceConfig.scanDirectories(from: store.state.sources))
    }

    // MARK: 菜单动作

    @objc private func openSettingsMenuItem() {
        preferencesController.show()
    }

    @objc private func quitMenuItem() {
        NSApp.terminate(nil)
    }
}

// MARK: - 菜单状态刷新

extension AppDelegate: NSMenuDelegate {
    public func menuDidClose(_ menu: NSMenu) {
        // 菜单仅在右键时临时挂载（见 statusItemClicked），关闭后摘除以恢复左键展开
        statusItem?.menu = nil
    }
}
