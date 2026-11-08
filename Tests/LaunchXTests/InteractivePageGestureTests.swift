import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 交互式横滑翻页手势

/// 跟手偏移 / 边界橡皮筋 / 松手按进度与速度落位 / 离散滚轮 / 超时兜底。
struct InteractivePageGestureTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let width: CGFloat = 1000

    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    /// 慢速滑动事件（速度远低于 commitVelocity，便于单测进度分支）。
    private func slow(_ g: inout InteractivePageGesture, deltas: [CGFloat], started: Bool, endAt: TimeInterval? = nil) {
        var time: TimeInterval = 0
        for (index, delta) in deltas.enumerated() {
            time += 0.25
            _ = g.feed(
                delta: delta,
                isGestureStart: started && index == 0,
                isEnded: endAt == time,
                isMomentum: false,
                isDiscrete: false,
                canGoBackward: true,
                canGoForward: true,
                pageWidth: width,
                at: at(time)
            )
        }
    }

    @Test func dragFollowsFingerAndCommitsByProgress() {
        var g = InteractivePageGesture()
        slow(&g, deltas: [-150, -150], started: true)
        #expect(g.displayOffset == -300)  // 跟手累计
        // 松手：进度 0.3 ≥ 0.25（速度 420pt/s < 600）→ 完成向前翻页
        let action = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0.75))
        #expect(action == .settle(1))
    }

    @Test func smallSlowDragSnapsBack() {
        var g = InteractivePageGesture()
        slow(&g, deltas: [-50, -50], started: true)  // 进度 0.1，速度 200pt/s
        let action = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0.5))
        #expect(action == .settle(0))
    }

    @Test func quickFlickCommitsByVelocity() {
        var g = InteractivePageGesture()
        // 轻快甩动：0.05s 内滑 -120pt（速度 2400pt/s ≥ 600），进度仅 0.12 也应完成
        // 事件序列贴近真实触控板：began ≈0 增量 → 若干 changed → ended
        _ = g.feed(delta: 0, isGestureStart: true, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0))
        _ = g.feed(delta: -60, isGestureStart: false, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0.02))
        _ = g.feed(delta: -60, isGestureStart: false, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0.04))
        let action = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0.05))
        #expect(action == .settle(1))
    }

    @Test func rubberBandAtLastPageAndSnapBack() {
        var g = InteractivePageGesture()
        // 已在末页：向前无路，偏移被橡皮筋压在渐近线内
        _ = g.feed(delta: -5000, isGestureStart: true, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: false,
                   pageWidth: width, at: at(0))
        #expect(g.displayOffset > -110)  // 渐近于 -100 附近，绝不显示整页
        let action = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: false,
                            pageWidth: width, at: at(0.25))
        #expect(action == .settle(0))  // 无路可翻 → 回弹
    }

    @Test func momentumAfterEndIsIgnored() {
        var g = InteractivePageGesture()
        slow(&g, deltas: [-50], started: true)
        _ = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0.25))
        // 落位已决定，惯性尾巴不改变结果（且不回写残留偏移）
        let action = g.feed(delta: -800, isGestureStart: false, isEnded: false, isMomentum: true,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0.3))
        #expect(action == .ignored)
    }

    @Test func trackingEventsUpdateOffset() {
        var g = InteractivePageGesture()
        let a1 = g.feed(delta: 0, isGestureStart: true, isEnded: false, isMomentum: false,
                        isDiscrete: false, canGoBackward: true, canGoForward: true,
                        pageWidth: width, at: at(0))
        #expect(a1 == .tracking)
        let a2 = g.feed(delta: -100, isGestureStart: false, isEnded: false, isMomentum: false,
                        isDiscrete: false, canGoBackward: true, canGoForward: true,
                        pageWidth: width, at: at(0.1))
        #expect(a2 == .tracking)
        #expect(g.displayOffset == -100)
    }

    @Test func discreteWheelTicksPageWithCooldown() {
        var g = InteractivePageGesture()
        let action1 = g.feed(delta: -10, isGestureStart: false, isEnded: false, isMomentum: false,
                             isDiscrete: true, canGoBackward: true, canGoForward: true,
                             pageWidth: width, at: at(0))
        #expect(action1 == .settle(1))  // 离散滚轮：单事件直接翻页
        let action2 = g.feed(delta: -10, isGestureStart: false, isEnded: false, isMomentum: false,
                             isDiscrete: true, canGoBackward: true, canGoForward: true,
                             pageWidth: width, at: at(0.1))
        #expect(action2 == .ignored)  // 冷却期内忽略
        let action3 = g.feed(delta: 10, isGestureStart: false, isEnded: false, isMomentum: false,
                             isDiscrete: true, canGoBackward: true, canGoForward: true,
                             pageWidth: width, at: at(0.5))
        #expect(action3 == .settle(-1))  // 冷却结束，反向滚动翻回
    }

    @Test func timeoutSettleWithoutEndEvent() {
        var g = InteractivePageGesture()
        slow(&g, deltas: [-300], started: true)  // 无 .ended
        let action = g.timeoutSettle(pageWidth: width, at: at(1.5))
        #expect(action == .settle(1))  // 兜底按进度落位
    }

    @Test func endedEventWithZeroDeltaIsForwarded() {
        // 回归：.ended 的滚动增量恒近 0，按幅度过滤会丢失"松手"信号导致无法落位翻页
        #expect(InteractivePageGesture.shouldForward(deltaX: 0, deltaY: 0, isGestureBoundary: true))
        #expect(InteractivePageGesture.shouldForward(deltaX: 0.5, deltaY: 3, isGestureBoundary: true))
        // 非边界事件按幅度与方向过滤
        #expect(!InteractivePageGesture.shouldForward(deltaX: 0, deltaY: 0, isGestureBoundary: false))
        #expect(!InteractivePageGesture.shouldForward(deltaX: 5, deltaY: 20, isGestureBoundary: false))  // 纵向为主
        #expect(InteractivePageGesture.shouldForward(deltaX: 10, deltaY: 3, isGestureBoundary: false))  // 正常横滑
    }

    @Test func endedEventDoesNotDiluteVelocity() {
        var g = InteractivePageGesture()
        // 高速甩动后接零增量 .ended：速度不应被冲淡
        _ = g.feed(delta: 0, isGestureStart: true, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0))
        _ = g.feed(delta: -80, isGestureStart: false, isEnded: false, isMomentum: false,
                   isDiscrete: false, canGoBackward: true, canGoForward: true,
                   pageWidth: width, at: at(0.04))  // 2000pt/s
        let action = g.feed(delta: 0, isGestureStart: false, isEnded: true, isMomentum: false,
                            isDiscrete: false, canGoBackward: true, canGoForward: true,
                            pageWidth: width, at: at(0.05))
        #expect(action == .settle(1))  // 速度判定仍成立（进度仅 0.08）
    }
}
