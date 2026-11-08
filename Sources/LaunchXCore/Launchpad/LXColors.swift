import AppKit
import SwiftUI

/// 原版色值 Token（Assets.car 提取的精确值，见 GAP_ANALYSIS §3.1）。
public enum LXColors {

    /// 强调色：systemBlue (0, 0.533, 1)。
    public static let accent = Color(red: 0, green: 0.533, blue: 1)

    /// Main：亮色白 / 暗色 (0.067, 0.067, 0.067)。
    public static func main(_ dark: Bool) -> Color {
        dark ? Color(white: 0.067) : .white
    }

    /// GlassTint：全屏模式毛玻璃叠色（白 10% / 白 2%）。
    public static func glassTint(_ dark: Bool) -> Color {
        Color.white.opacity(dark ? 0.02 : 0.10)
    }

    /// SearchGlassTint：搜索框底（白 15%）。
    public static var searchGlassTint: Color {
        Color(white: 0.067, opacity: 0.15)
    }

    /// Highlight：图标按压/悬停高亮（黑 32%）。
    public static var highlight: Color {
        Color.black.opacity(0.32)
    }

    /// Selection：选中遮罩（亮白 / 暗灰 0.467）。
    public static func selection(_ dark: Bool) -> Color {
        dark ? Color(white: 0.467) : .white
    }

    /// FolderTint：文件夹底（亮黑 5% / 暗透明）。
    public static func folderTint(_ dark: Bool) -> Color {
        dark ? Color.clear : Color.black.opacity(0.05)
    }

    /// FolderHighlight：文件夹悬停（白 30% / 白 8%）。
    public static func folderHighlight(_ dark: Bool) -> Color {
        Color.white.opacity(dark ? 0.08 : 0.30)
    }

    /// NEW 徽章：#F1383D（暗色 #FF615C）。
    public static func newBadge(_ dark: Bool) -> Color {
        dark
            ? Color(red: 0xFF / 255.0, green: 0x61 / 255.0, blue: 0x5C / 255.0)
            : Color(red: 0xF1 / 255.0, green: 0x1F / 255.0, blue: 0x14 / 255.0)
    }

    /// 当前是否暗色外观。
    @MainActor
    public static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - 液态玻璃（Liquid Glass）

public extension View {

    /// 胶囊形 Liquid Glass 底（控件级：搜索框 / 选中状态栏 / Toast）。
    ///
    /// interactive 提供悬停镜面响应；默认暗色 scrim（暗 0.22 / 亮 0.10）
    /// 保证白字在亮壁纸上可读，Toast 等强对比场景可传更深的 tint。
    func liquidGlassCapsule(tint: Color? = nil) -> some View {
        let scrim = tint ?? Color.black.opacity(LXColors.isDark ? 0.22 : 0.10)
        return self.glassEffect(.regular.tint(scrim).interactive(), in: Capsule())
    }

    /// 圆角矩形 Liquid Glass 底（容器级：文件夹预览 / 打开态磨砂面板）。
    ///
    /// 容器不参与悬停交互（悬停反馈由调用方换 tint 实现）；tint 传 nil 为纯 regular 玻璃。
    func liquidGlassPanel(cornerRadius: CGFloat, tint: Color? = nil) -> some View {
        self.glassEffect(
            .regular.tint(tint),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

// MARK: - 玻璃材质

/// GlassMaterial → NSVisualEffectView.Material。
public extension GlassMaterial {
    var material: NSVisualEffectView.Material {
        switch self {
        case .off: .underWindowBackground
        case .thin: .underWindowBackground
        case .regular: .sidebar
        case .thick: .fullScreenUI
        }
    }
}
