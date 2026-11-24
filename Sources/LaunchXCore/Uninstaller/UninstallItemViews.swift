import AppKit
import SwiftUI

// MARK: - 类目分组

struct UninstallCategoryGroupView: View {
    let category: UninstallCategory
    let items: [UninstallItem]
    let selection: UninstallModel.GroupSelection
    let checkedIDs: Set<String>
    let isComputingSizes: Bool
    let onToggle: (UninstallItem) -> Void
    /// includeSpeculative = true 时连「可能相关」项一起选中（需用户显式点按）。
    let onSelectAll: (Bool) -> Void
    let onDeselectAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(category.displayName)
                    .font(.headline)
                Text("(\(items.count))")
                    .foregroundStyle(.secondary)
                groupSizeLabel
                Spacer()
                selectionControls
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
                    isComputingSizes: isComputingSizes,
                    onToggle: { onToggle(item) }
                )
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }

    /// 类目合计体积（只统计已知大小；计算中时提示）。
    @ViewBuilder private var groupSizeLabel: some View {
        let known = items.compactMap(\.byteSize)
        if !known.isEmpty {
            Text(UninstallModel.formattedBytes(known.reduce(0, +)) ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if isComputingSizes, items.contains(where: { $0.byteSize == nil }) {
            Text("计算中…")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// 分组选择控件。「全选」默认只选非推测项；推测项必须显式点按才会被选中（P1-6）。
    @ViewBuilder private var selectionControls: some View {
        if selection.allSelected {
            Button("取消全选", action: onDeselectAll)
                .buttonStyle(.link)
                .font(.system(size: 12))
                .accessibilityLabel("取消全选\(category.displayName)")
        } else if selection.exactCount == 0 {
            Button("全选（\(selection.totalCount) 项可能相关）") { onSelectAll(true) }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .accessibilityLabel("全选\(category.displayName)\(selection.totalCount) 项可能相关项")
        } else {
            if selection.hasUnselectedExact {
                Button("全选") { onSelectAll(false) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .accessibilityLabel("全选\(category.displayName)")
            }
            if selection.hasUnselectedSpeculative {
                let remaining = selection.speculativeCount - selection.selectedSpeculativeCount
                Button("全选（含 \(remaining) 项可能相关）") { onSelectAll(true) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .accessibilityLabel("全选\(category.displayName)并包含\(remaining) 项可能相关项")
            }
        }
    }

    /// 高风险类目提示（默认不勾选的原因）。
    private var riskHint: String? {
        if category.isUserData {
            return "按应用名匹配到的个人文件，可能与该应用无关；默认不勾选，请逐项确认"
        }
        if category.hasSystemSideEffects {
            return "系统/用户级自启项，删除后应用可能无法自动启动；默认不勾选"
        }
        if items.contains(where: \.requiresAdmin) {
            return "含位于 /Library 的条目，移入废纸篓需要管理员权限，可能删除失败"
        }
        return nil
    }
}

// MARK: - 单行条目

struct UninstallItemRowView: View {
    let item: UninstallItem
    let checked: Bool
    let isComputingSizes: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { checked },
                set: { newValue in
                    // 只有值真的变化才切换：避免行手势与 Toggle 同时触发时互相抵消（P2-12）
                    if newValue != checked { onToggle() }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel("选择 \(item.displayName)")
            .accessibilityValue(accessibilityValue)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if item.isSpeculative {
                        badge("可能相关", color: .orange)
                    }
                    if item.requiresAdmin {
                        badge("需要管理员权限", color: .secondary)
                    }
                }
                // 路径可选中复制（P1-7：用户被要求逐项确认，却无法核对内容）
                Text(item.parentPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            // 只有文本区承担「点整行切换」；复选框自己处理点击，避免双重触发
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            Spacer()
            sizeText
            rowMenu
        }
        .contextMenu { rowMenuItems }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var sizeText: some View {
        if let bytes = item.byteSize {
            Text(UninstallModel.formattedBytes(bytes) ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if isComputingSizes {
            Text("计算中…")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            Text("大小未知")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .help("无法读取大小（可能没有权限或路径不可达）")
        }
    }

    /// 行尾菜单：在访达中显示 / 复制路径（P1-7）。
    private var rowMenu: some View {
        Menu {
            rowMenuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
        .accessibilityLabel("\(item.displayName) 的更多操作")
    }

    @ViewBuilder private var rowMenuItems: some View {
        Button("在访达中显示") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Button("复制路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private var accessibilityValue: String {
        var parts = [item.category.displayName]
        if let bytes = item.byteSize, let text = UninstallModel.formattedBytes(bytes) {
            parts.append(text)
        }
        if item.isSpeculative { parts.append("可能相关") }
        if item.requiresAdmin { parts.append("需要管理员权限") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 抖动图标（iOS 删除式抖动）

/// 抖动图标：只在可操作清单里抖动，并尊重「减弱动态效果」（P2-1）。
struct JiggleIconView: View {
    let iconPath: String
    /// 当前阶段是否需要抖动（完成/进度页不抖）。
    var isActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var jiggle = false

    var body: some View {
        let animating = isActive && !reduceMotion
        Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .rotationEffect(.degrees(animating && jiggle ? 2.4 : 0))
            .offset(x: animating && jiggle ? 1.5 : 0)
            .animation(
                animating ? .easeInOut(duration: 0.11).repeatForever(autoreverses: true) : nil,
                value: jiggle
            )
            .onAppear {
                if animating { jiggle = true }
            }
            .onChange(of: animating) { _, active in
                jiggle = active
            }
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
