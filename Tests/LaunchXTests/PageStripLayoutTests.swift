import Foundation
import Testing
@testable import LaunchXCore

/// 连续翻页「后一页提前跑出来叠在当前页上」回归：
/// 页在条带内的位置必须只由页码决定，翻页 / 跟手只改整条条带的单一 offset，
/// 这样动画中途增删的页不会与存量页失步。
struct PageStripLayoutTests {

    private let width: CGFloat = 1440

    @Test func pageOffsetIndependentOfSettledAndDrag() {
        // 页位置是页码的纯函数：settled / 拖拽变化都不会改它（不会被单独动画）
        for page in 0..<6 {
            #expect(PageStripLayout.pageOffset(pageIndex: page, width: width) == CGFloat(page) * width)
        }
    }

    @Test func renderOriginMatchesStripSemantics() {
        // 视口渲染原点 = (page − settled) × width + drag，与旧条带语义逐帧等价
        for settled in 0..<5 {
            for drag in [-width, -width * 0.37, 0, width * 0.5] {
                let strip = PageStripLayout.stripOffset(settledIndex: settled, width: width, dragOffset: drag)
                for page in max(settled - 1, 0)...(settled + 2) {
                    let origin = PageStripLayout.pageOffset(pageIndex: page, width: width) + strip
                    #expect(abs(origin - (CGFloat(page - settled) * width + drag)) < 0.001)
                }
            }
        }
    }

    @Test func atomicCommitKeepsEveryPageInPlace() {
        // finishDragCommit：settled+1 且 drag 从 −width 归零，条带偏移不变 → 画面无跳变
        let before = PageStripLayout.stripOffset(settledIndex: 2, width: width, dragOffset: -width)
        let after = PageStripLayout.stripOffset(settledIndex: 3, width: width, dragOffset: 0)
        #expect(before == after)
    }

    @Test func adjacentPagesNeverOverlap() {
        // 同一条带上任意两页的渲染原点恒差整数页宽，不可能叠在一起
        let strip = PageStripLayout.stripOffset(settledIndex: 1, width: width, dragOffset: -width * 0.8)
        let origins = (0..<4).map { PageStripLayout.pageOffset(pageIndex: $0, width: width) + strip }
        for i in 1..<origins.count {
            #expect(abs(origins[i] - origins[i - 1] - width) < 0.001)
        }
    }
}
