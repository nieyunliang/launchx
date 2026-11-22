import AppKit
import SwiftUI

// MARK: - 应用 Apps

struct AppsSettingsTab: View {
    @Environment(PreferencesModel.self) private var prefs

    var body: some View {
        Form {
            Section("应用来源") {
                ForEach(prefs.store.state.sources) { source in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { prefs.store.state.sources.first { $0.id == source.id }?.enabled ?? false },
                            set: { enabled in prefs.setSourceEnabled(id: source.id, enabled: enabled) }
                        ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("启用来源 \(prefs.displayName(for: source))")
                        VStack(alignment: .leading, spacing: 1) {
                            if source.kind == .defaultApps {
                                Text("应用程序")
                                    .font(.system(size: 13, weight: .medium))
                            } else {
                                Text(source.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(kindLabel(source.kind))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        // 内置「应用程序」是唯一默认来源，不提供删除入口
                        if prefs.canRemoveSource(source) {
                            Button {
                                prefs.removeSource(id: source.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除来源")
                            .accessibilityLabel("删除来源 \(prefs.displayName(for: source))")
                        }
                    }
                }
                Button("添加来源目录…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.begin { response in
                        if response == .OK, let url = panel.url {
                            prefs.addSource(url: url)
                        }
                    }
                }
            }

            Section("排序方式") {
                Picker("排序依据", selection: Binding(
                    get: { prefs.store.state.settings.activeSortKey },
                    set: { prefs.applySortKey($0) }
                )) {
                    ForEach(SortKey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if !prefs.store.state.settings.activeSortKey.hasFixedDirection,
                   prefs.store.state.settings.activeSortKey != .custom {
                    Picker("排序方向", selection: Binding(
                        get: { prefs.store.state.settings.sortAscending },
                        set: { prefs.applySortAscending($0) }
                    )) {
                        Text("升序").tag(true)
                        Text("降序").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("排序方向")
                }
            }

            Section("摆放规则") {
                Picker("Apple 应用位置", selection: Binding(
                    get: { prefs.store.state.settings.appleAppsPosition },
                    set: { prefs.setAppleAppsPosition($0) }
                )) {
                    ForEach(AppleAppsPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("文件夹位置", selection: Binding(
                    get: { prefs.store.state.settings.folderPosition },
                    set: { prefs.setFolderPosition($0) }
                )) {
                    ForEach(FolderPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section("隐藏的应用") {
                let hiddenApps = prefs.store.state.layout.apps.values
                    .filter(\.hidden)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if hiddenApps.isEmpty {
                    Text("暂无隐藏的应用")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(hiddenApps), id: \.id) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.name)
                            Spacer()
                            Button("取消隐藏") {
                                prefs.unhideApp(id: app.id)
                            }
                        }
                    }
                }
                Toggle("在搜索中显示隐藏应用", isOn: prefs.binding(\.showHiddenAppsInSearch))
            }

            Section("布局") {
                Button("恢复默认布局…", role: .destructive) {
                    prefs.restoreDefaultLayout()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func kindLabel(_ kind: SourceConfig.Kind) -> String {
        switch kind {
        case .defaultApps: "默认"
        case .systemApps: "系统应用"
        case .userApps: "用户应用"
        case .custom: "自定义"
        }
    }
}

// MARK: - 界面 Interface

struct InterfaceSettingsTab: View {
    @Environment(PreferencesModel.self) private var prefs

    var body: some View {
        Form {
            Section("浏览样式") {
                Picker("翻页方式", selection: prefs.binding(\.browsingStyle)) {
                    Text("分页").tag(BrowsingStyle.paged)
                    Text("滚动").tag(BrowsingStyle.scroll)
                }
                .pickerStyle(.radioGroup)
            }

            Section("图标网格") {
                Picker("密度（列 × 行）", selection: gridDensityBinding) {
                    ForEach(GridDensity.allCases) { density in
                        Text(density.label).tag(density)
                    }
                }
                Picker("图标颜色", selection: prefs.binding(\.iconColorMode)) {
                    ForEach(IconColorMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("隐藏应用名称", isOn: prefs.binding(\.hideAppNames))
                Picker("应用图标主题", selection: prefs.binding(\.appIconTheme)) {
                    ForEach(AppIconTheme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section("玻璃材质") {
                Toggle("模糊壁纸（全屏模式）", isOn: prefs.binding(\.blurWallpaper))
                // 有壁纸背景时材质强度不起作用：禁用控件代替文字说明。
                Picker("材质强度", selection: prefs.binding(\.glassMaterial)) {
                    ForEach(GlassMaterial.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(prefs.store.state.settings.blurWallpaper && CGPreflightScreenCaptureAccess())
            }

            Section("显示位置与收起") {
                Picker("显示位置", selection: prefs.binding(\.screenPosition)) {
                    ForEach(ScreenPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("失焦后收起", selection: prefs.binding(\.closeDelay)) {
                    ForEach(CloseDelay.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var gridDensityBinding: Binding<GridDensity> {
        Binding(
            get: { prefs.store.state.settings.gridDensity },
            set: { density in prefs.update { $0.gridDensity = density } }
        )
    }
}

// MARK: - 关于 Info

struct InfoSettingsTab: View {
    @Environment(PreferencesModel.self) private var prefs
    /// 重看引导时持有窗口控制器，避免立即释放。
    @State private var onboardingController: OnboardingWindowController?

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "rocket")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)

            Text("LaunchX")
                .font(.title.weight(.bold))
            Text("版本 \(version)（\(build)）— macOS 启动台增强替代品")
                .foregroundStyle(.secondary)

            GroupBox("更新日志") {
                VStack(alignment: .leading, spacing: 6) {
                    changelogLine("1.0", "全屏启动台网格 + 文件夹 + 拖拽整理；快捷键 / 捏合手势 / 菜单栏图标唤起；卸载器；系统启动台数据互通")
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                if let feedbackURL = URL(string: "mailto:yunliang@me.com") {
                    Link("发送反馈", destination: feedbackURL)
                }
                Button("重新查看引导") {
                    let controller = OnboardingWindowController()
                    onboardingController = controller
                    controller.show()
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changelogLine(_ version: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(version).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.accentColor)
            Text(text).font(.system(size: 12))
        }
    }
}
