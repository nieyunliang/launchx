import Foundation
import Testing
@testable import LaunchXCore

/// GridMetrics 尺寸策略回归：对齐 LaunchOS 在两块屏上的像素实测
/// （图标固定自然尺寸，高度不足由行距压缩吸收，不缩图标）。
struct GridMetricsTests {

    /// 主内容区铬件高度（搜索 62+40+26 + 网格顶 44 + 页码 ~72），与
    /// LaunchpadContentView.updateMetrics 的扣减一致。
    private static let chromeHeight: CGFloat = 244

    @Test func bigScreenKeepsNaturalSizeAndLooseSpacing() {
        // 27" 4K（3008×1692）：图标 130、行距自然值 130（LaunchOS 实测行距 291.5pt）
        let m = GridMetrics.compute(
            areaSize: CGSize(width: 3008, height: 1692 - Self.chromeHeight),
            density: .default
        )
        #expect(m.iconSize == 130)
        #expect(m.gridSpacing == 130)
        #expect(abs(m.cellWidth - 130 / 0.51) < 0.01) // 列距 ≈ 255pt
    }

    @Test func smallScreenShrinksSpacingNotIcon() {
        // MacBook 内置屏（1800×1169）：图标几乎不缩（LaunchOS 两屏磁贴同为 103.5pt），
        // 行距压缩到 ~33pt 吸收高度差，且整页恰好放满可用高度
        let height: CGFloat = 1169 - Self.chromeHeight
        let m = GridMetrics.compute(
            areaSize: CGSize(width: 1800, height: height),
            density: .default
        )
        #expect(m.iconSize > 125)        // ≈127.6，不随高度缩到 85
        #expect(m.gridSpacing < 40)      // ≈33
        let rows: CGFloat = 5
        #expect(rows * m.cellHeight + (rows - 1) * m.gridSpacing <= height + 0.5)
    }

    @Test func veryShortAreaFallsBackToSmallerIcon() {
        // 极矮区域：连最小行距都放不下 → 兜底按高度缩图标，但不低于下限
        let m = GridMetrics.compute(areaSize: CGSize(width: 700, height: 300), density: .default)
        #expect(m.iconSize >= 56)
    }
}
