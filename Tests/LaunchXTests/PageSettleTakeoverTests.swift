import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 翻页曲线 / 落位接管

/// 快启动缓出曲线的解析反演 + 横滑落位动画表现值 + 落位期间新手势接管。
@MainActor
struct PageSettleTakeoverTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let width: CGFloat = 1000

    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    // MARK: PageSlideCurve

    @Test func curveEndpointsAndMonotonic() {
        #expect(PageSlideCurve.progress(atX: 0) == 0)
        #expect(PageSlideCurve.progress(atX: 1) == 1)
        var previous = -1.0
        for step in 1...200 {
            let x = Double(step) / 200
            let y = PageSlideCurve.progress(atX: x)
            #expect(y >= previous)  // 位移进度随时间单调不减
            #expect(y >= 0 && y <= 1)  // 缓出曲线无过冲
            previous = y
        }
    }

    @Test func curveInvertsParametricBezier() {
        // 参数式正演 x(s)/y(s)，再反解：progress(atX: x(s)) 应还原 y(s)
        func bezierX(_ s: Double) -> Double {
            3 * pow(1 - s, 2) * s * Double(PageSlideCurve.x1)
                + 3 * (1 - s) * pow(s, 2) * Double(PageSlideCurve.x2)
                + pow(s, 3)
        }
        func bezierY(_ s: Double) -> Double {
            3 * pow(1 - s, 2) * s * Double(PageSlideCurve.y1)
                + 3 * (1 - s) * pow(s, 2) * Double(PageSlideCurve.y2)
                + pow(s, 3)
        }
        var s = 0.0
        while s <= 1 {
            let x = bezierX(s)
            let solved = PageSlideCurve.progress(atX: x)
            #expect(abs(solved - bezierY(s)) < 1e-4)
            s += 0.01
        }
    }

    @Test func curveIsFastStart() {
        // 快启动缓出：半程时间应走完大部分位移（easeOutCubic ≈ 0.84）
        let half = PageSlideCurve.progress(atX: 0.5)
        #expect(half > 0.7 && half < 0.95)
    }

    // MARK: PageSettleAnimation

    @Test func settleAnimationInterpolatesAlongCurve() {
        let animation = PageSettleAnimation(
            startOffset: -600, targetOffset: -1000,
            startDate: t0, duration: 0.3
        )
        #expect(animation.presentationOffset(at: t0) == -600)  // 起点
        #expect(abs(animation.presentationOffset(at: t0.addingTimeInterval(0.3)) + 1000) < 0.001)  // 终点
        let mid = animation.presentationOffset(at: t0.addingTimeInterval(0.15))
        let expected = -600 + (-400) * PageSlideCurve.progress(atX: 0.5)
        #expect(abs(mid - expected) < 0.001)
        // 越界钳制：动画结束后时间继续推进不再越靶
        #expect(abs(animation.presentationOffset(at: t0.addingTimeInterval(3)) + 1000) < 0.001)
    }

    // MARK: 手势接管续滑

    @Test func feedResumeContinuesFromPresentation() {
        var g = InteractivePageGesture()
        // 落位动画已滑至 -600：新手势接管，.began 增量 -50 计入起点
        let action = g.feed(delta: -50, isGestureStart: true, isEnded: false, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0), resumingFrom: -600)
        #expect(action == .tracking)
        #expect(g.displayOffset == -650)
        // 继续跟手 100pt 后松手：进度 0.75 ≥ 0.25 → 完成翻页
        _ = g.feed(delta: -100, isGestureStart: false, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0.2))
        let settle = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0.4))
        #expect(settle == .settle(1))
    }

    @Test func feedResumeThenReverseSnapsBack() {
        var g = InteractivePageGesture()
        // 接管后小幅反向滑动松手：未过阈值 → 回弹（不翻页）
        _ = g.feed(delta: 20, isGestureStart: true, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0), resumingFrom: -100)
        let settle = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0.3))
        #expect(settle == .settle(0))
    }

    // MARK: 模型层落位 / 接管

    private func makeModel(appCount: Int = 35) -> (LaunchpadModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXSettleTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LayoutStore(directory: dir)
        let model = LaunchpadModel(store: store)
        store.updateLayout { layout in
            var items: [SlotItem] = []
            for index in 0..<appCount {
                let id = "app\(index)"
                layout.apps[id] = makeApp(id)
                items.append(.app(id: id))
            }
            layout.pages = [PageRecord(items: items), PageRecord()]
        }
        model.pageWidth = width
        return (model, dir)
    }

    @Test func takeOverReturnsPresentationAndUnlocks() {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.pageDragOffset = -600
        model.settlePageDrag(commitDirection: 1)
        #expect(model.isSettlingPageDrag)

        let presentation = model.takeOverPageSettle()
        // 刚起滑：表现值仍贴着起点（曲线零点斜率有限，容差内）
        #expect(presentation != nil)
        #expect(abs(presentation! + 600) < 20)
        #expect(!model.isSettlingPageDrag)
        #expect(model.pageSettleAnimation == nil)
        #expect(abs(model.pageDragOffset + 600) < 20)  // 偏移无动画钉在表现值上
        #expect(model.currentPage == 0)  // 接管即取消挂起换页
    }

    @Test func settleNearTargetFinishesImmediately() {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 接管点已在目标位附近（剩余位移 < 1pt）：直接原子换页，不空转动画
        model.pageDragOffset = -999.5
        model.settlePageDrag(commitDirection: 1)
        #expect(model.currentPage == 1)
        #expect(!model.isSettlingPageDrag)
        #expect(model.pageDragOffset == 0)
    }

    @Test func hideDuringSettleCancelsPendingCommit() {
        let (model, dir) = makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        model.show()
        model.pageDragOffset = -600
        model.settlePageDrag(commitDirection: 1)
        #expect(model.isSettlingPageDrag)

        model.hide()
        #expect(!model.isSettlingPageDrag)
        #expect(model.pageSettleAnimation == nil)
        #expect(model.pageDragOffset == 0)
        #expect(model.currentPage == 0)  // 收起中断落位，不补跳页
    }
}
