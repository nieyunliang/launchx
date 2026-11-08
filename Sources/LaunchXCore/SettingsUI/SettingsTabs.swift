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
                        VStack(alignment: .leading, spacing: 1) {
                            if source.kind == .defaultApps {
                                Text("应用程序")
                                    .font(.system(size: 13, weight: .medium))
                                Text("默认路径（应用程序 / 系统应用）")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
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
                            .help("删除来源（会提示将移除的应用数）")
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
                Text("关闭或删除来源会移除该目录下的应用并丢失其排列，操作前会二次确认。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
                    Toggle("升序（关闭为降序，最新在前）", isOn: Binding(
                        get: { prefs.store.state.settings.sortAscending },
                        set: { prefs.applySortAscending($0) }
                    ))
                }
                Text(prefs.store.state.settings.activeSortKey == .custom
                     ? "「自定义」保留手动拖拽整理的布局。"
                     : "切换后立即重排全部页面；此模式下拖拽整理被禁用，启动应用后按所选规则自动重排。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("摆放规则") {
                Picker("Apple 应用位置", selection: prefs.binding(\.appleAppsPosition)) {
                    ForEach(AppleAppsPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("文件夹位置", selection: prefs.binding(\.folderPosition)) {
                    ForEach(FolderPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section("隐藏的应用") {
                let hiddenApps = prefs.store.state.layout.apps.values
                    .filter(\.hidden)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if hiddenApps.isEmpty {
                    Text("没有隐藏的应用。右键任意应用 → 隐藏。")
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
                                prefs.store.updateLayout { layout in
                                    layout.apps[app.id]?.hidden = false
                                }
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
        case .defaultApps: "默认路径"
        case .systemApps: "系统应用目录"
        case .userApps: "用户应用目录"
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
                Picker("材质强度", selection: prefs.binding(\.glassMaterial)) {
                    ForEach(GlassMaterial.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("模糊壁纸（全屏模式）", isOn: prefs.binding(\.blurWallpaper))
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
                .help("重新播放首次使用引导（不会修改任何设置）")
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
