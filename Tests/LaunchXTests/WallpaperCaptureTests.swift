import CoreGraphics
import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 壁纸窗口匹配（WallpaperCapture.matchWallpaperWindow 纯函数）

/// 回归背景：旧实现用 `kCGDesktopWindowLevel` 比对 layer 并带
/// `.excludeDesktopElements` 枚举——macOS 26 实测壁纸窗口 layer =
/// `kCGDesktopWindowLevel - 1` 且该选项会把壁纸窗口整个排除，
/// 导致壁纸捕获永远失败（面板呈纯白毛玻璃）。
struct WallpaperCaptureTests {

    private let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))

    private func info(
        id: Int,
        layer: Int,
        owner: String,
        name: String? = nil,
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
            kCGWindowOwnerName as String: owner,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: Any],
        ]
        if let name { dict[kCGWindowName as String] = name }
        return dict
    }

    @Test func matchesModernWallpaperWindow() {
        let infos = [
            info(id: 1, layer: 0, owner: "Google Chrome", x: 0, y: 0, w: 1859, h: 1246),
            info(id: 2, layer: 24, owner: "Window Server", name: "Menubar", x: 0, y: 0, w: 1800, h: 39),
            info(id: 3, layer: desktopLevel - 1, owner: "WindowManager", name: "Wallpaper",
                 x: 0, y: 0, w: 1800, h: 1169),
        ]
        let target = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        #expect(WallpaperCapture.matchWallpaperWindow(infos: infos, targetCGFrame: target) == 3)
    }

    @Test func matchesLegacyWallpaperWindowAtDesktopLevel() {
        let infos = [
            info(id: 7, layer: desktopLevel, owner: "Window Server", x: 0, y: 0, w: 1800, h: 1169),
        ]
        let target = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        #expect(WallpaperCapture.matchWallpaperWindow(infos: infos, targetCGFrame: target) == 7)
    }

    @Test func ignoresBackstopAndDesktopIconWindows() {
        let infos = [
            // 壁纸层的黑色垫底窗口：按名字排除
            info(id: 8, layer: desktopLevel - 1, owner: "Window Server", name: "Backstop",
                 x: 0, y: 0, w: 1800, h: 1169),
            // Finder 桌面图标窗口：layer 是 desktopIconWindow 层，不匹配
            info(id: 9, layer: desktopLevel + 20, owner: "访达",
                 x: 0, y: 0, w: 1800, h: 1169),
            // 普通应用窗口
            info(id: 10, layer: 0, owner: "ZCode", x: 0, y: 0, w: 1583, h: 873),
        ]
        let target = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        #expect(WallpaperCapture.matchWallpaperWindow(infos: infos, targetCGFrame: target) == nil)
    }

    @Test func picksWindowWithBestOverlapOnMultiDisplay() {
        // 主屏壁纸 + 右侧外接屏壁纸，目标为外接屏 → 应选中 id=5
        let infos = [
            info(id: 4, layer: desktopLevel - 1, owner: "WindowManager", name: "Wallpaper",
                 x: 0, y: 0, w: 1800, h: 1169),
            info(id: 5, layer: desktopLevel - 1, owner: "WindowManager", name: "Wallpaper",
                 x: 1800, y: 0, w: 3008, h: 1692),
        ]
        let dell = CGRect(x: 1800, y: 0, width: 3008, height: 1692)
        #expect(WallpaperCapture.matchWallpaperWindow(infos: infos, targetCGFrame: dell) == 5)

        let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        #expect(WallpaperCapture.matchWallpaperWindow(infos: infos, targetCGFrame: main) == 4)
    }

    @Test func returnsNilWhenNoCandidateOverlaps() {
        let infos = [
            info(id: 6, layer: desktopLevel - 1, owner: "WindowManager", name: "Wallpaper",
                 x: 1800, y: 0, w: 3008, h: 1692),
        ]
        let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        #expect(WallpaperCapture.matchWallpaperWindow(infos: infos, targetCGFrame: main) == nil)
    }

    @Test func returnsNilForEmptyInfos() {
        #expect(WallpaperCapture.matchWallpaperWindow(infos: [], targetCGFrame: .zero) == nil)
    }
}
