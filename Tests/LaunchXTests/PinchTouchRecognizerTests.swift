import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 原始触点捏合识别器（合成触点帧回归）
//
// 阈值口径见 PinchTouchThresholds：minContacts=4、movementFloor=0.06、
// vetoRatio=0.40、emitFloor=0.05、fullTrip=0.30、sessionCooldown=0.25s。
// 场景几何按 2026-11-21 真机带标签实测构造：滑动 ratio 0.10~0.21、
// 捏合 ratio 0.59~1.52，判别式 spreadDelta / maxFingerMove。

@MainActor
struct PinchTouchRecognizerTests {

    // MARK: 造帧工具

    private func touch(_ id: Int32, _ state: Int32, _ x: Float, _ y: Float) -> TouchSample {
        TouchSample(id: id, state: state, x: x, y: y)
    }

    /// 十字四指位：围绕中心按系数 k 缩放（k=1 基准跨度、k>1 张开、k<1 捏拢）。
    private func crossFrame(ids: [Int32], k: Float, center: (Float, Float) = (0.5, 0.5), state: Int32 = 4) -> [TouchSample] {
        let offsets: [(Float, Float)] = [(-0.06, 0), (0.06, 0), (0, -0.06), (0, 0.06)]
        return ids.enumerated().map { i, id in
            let (dx, dy) = offsets[i]
            return touch(id, state, center.0 + dx * k, center.1 + dy * k)
        }
    }

    /// 依次喂帧并收集事件。
    private func run(_ recognizer: PinchTouchRecognizer, frames: [[TouchSample]], startAt: TimeInterval = 1000, step: TimeInterval = 0.008) -> [PinchGestureEvent] {
        var events: [PinchGestureEvent] = []
        var now = startAt
        for frame in frames {
            events.append(contentsOf: recognizer.ingest(frame, now: now).events)
            now += step
        }
        return events
    }

    /// 十字位四指从 kFrom 线性缩放到 kTo 的帧序列（含落指 st=3 与离板 st=5）。
    private func pinchFrames(ids: [Int32], kFrom: Float, kTo: Float, frames: Int) -> [[TouchSample]] {
        var result: [[TouchSample]] = [crossFrame(ids: ids, k: kFrom, state: 3)]
        for i in 1...frames {
            let k = kFrom + (kTo - kFrom) * Float(i) / Float(frames)
            result.append(crossFrame(ids: ids, k: k))
        }
        result.append(crossFrame(ids: ids, k: kTo, state: 5))
        result.append([])
        return result
    }

    // MARK: 噪声否决（「三指滑动误开面板」的根因回归）

    /// 三指滑动：接触数永远到不了 4，静默忽略（一个事件都不产生）。
    @Test func threeFingerSwipeProducesNoEvents() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3]
        var frames: [[TouchSample]] = [
            [touch(1, 3, 0.30, 0.5), touch(2, 3, 0.40, 0.5), touch(3, 3, 0.50, 0.5)]
        ]
        for i in 1...15 {
            let dx = Float(i) * 0.03
            frames.append([touch(1, 4, 0.30 + dx, 0.5), touch(2, 4, 0.40 + dx, 0.5), touch(3, 4, 0.50 + dx, 0.5)])
        }
        frames.append([touch(1, 5, 0.75, 0.5), touch(2, 5, 0.85, 0.5), touch(3, 5, 0.95, 0.5)])
        frames.append([])

        let events = run(recognizer, frames: frames)
        #expect(events.isEmpty)
    }

    /// 拇指搭板的四指滑动（整手平移、跨度不变）：位移否决拦下，静默无声。
    /// 回归：macOS 27.2 把这种接触场分类成捏合族事件流，旧方案在此误开面板。
    @Test func thumbContaminatedSwipeIsVetoedSilently() {
        let recognizer = PinchTouchRecognizer()
        var frames: [[TouchSample]] = [
            [touch(1, 3, 0.30, 0.5), touch(2, 3, 0.40, 0.5), touch(3, 3, 0.50, 0.5), touch(4, 3, 0.35, 0.62)]
        ]
        for i in 1...13 {
            let dx = Float(i) * 0.03
            frames.append([
                touch(1, 4, 0.30 + dx, 0.5), touch(2, 4, 0.40 + dx, 0.5),
                touch(3, 4, 0.50 + dx, 0.5), touch(4, 4, 0.35 + dx, 0.62)
            ])
        }
        frames.append([touch(1, 5, 0.69, 0.5), touch(2, 5, 0.79, 0.5), touch(3, 5, 0.89, 0.5), touch(4, 5, 0.74, 0.62)])
        frames.append([])

        let events = run(recognizer, frames: frames)
        #expect(events.isEmpty)
    }

    /// 双指缩放：2 触点永不构成候选（抑制 tap 同口径放行，系统缩放不受影响）。
    @Test func twoFingerZoomIsNeverACandidate() {
        let recognizer = PinchTouchRecognizer()
        var frames: [[TouchSample]] = [
            [touch(1, 3, 0.4, 0.5), touch(2, 3, 0.6, 0.5)]
        ]
        for i in 1...10 {
            let dx = Float(i) * 0.03
            frames.append([touch(1, 4, 0.4 - dx, 0.5), touch(2, 4, 0.6 + dx, 0.5)])
        }
        frames.append([touch(1, 5, 0.1, 0.5), touch(2, 5, 0.9, 0.5)])
        frames.append([])

        let events = run(recognizer, frames: frames)
        #expect(events.isEmpty)
    }

    /// 悬停态（st=2）不计入接触数，不构成候选。
    @Test func hoverContactsDoNotStartCandidate() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var frames: [[TouchSample]] = []
        for i in 0..<5 {
            let dx = Float(i) * 0.02
            frames.append([touch(1, 2, 0.44 + dx, 0.5), touch(2, 2, 0.56 + dx, 0.5), touch(3, 2, 0.5 + dx, 0.44), touch(4, 2, 0.5 + dx, 0.56)])
        }
        frames.append(contentsOf: pinchFrames(ids: ids, kFrom: 1.0, kTo: 2.6, frames: 16))
        let events = run(recognizer, frames: frames)
        // 悬停阶段无事件；触指后正常识别
        #expect(events.first?.phase == .began)
        #expect(events.contains { $0.phase == .changed && $0.signedProgress < 0 })
        #expect(events.last?.phase == .ended)
    }

    // MARK: 真捏合识别与跟手

    /// 四指捏拢（跨度收窄）：began → 逐帧正进度 → ended 过提交深度（跟手展开）。
    /// 方向与系统启动台手势同向：捏合收拢 = 打开。
    @Test func fourFingerPinchInTracksLiveAndCommits() {
        let recognizer = PinchTouchRecognizer()
        let events = run(recognizer, frames: pinchFrames(ids: [1, 2, 3, 4], kFrom: 3.0, kTo: 1.0, frames: 20))
        guard case .began = events.first?.phase else {
            Issue.record("首事件应为 began：\(events)")
            return
        }
        let changed = events.filter { $0.phase == .changed }
        #expect(changed.count >= 10)
        #expect(changed.allSatisfy { $0.signedProgress > 0 })
        // 进度单调不回退
        for (a, b) in zip(changed, changed.dropFirst()) {
            #expect(b.signedProgress >= a.signedProgress)
        }
        guard let last = events.last, last.phase == .ended else {
            Issue.record("末事件应为 ended：\(events)")
            return
        }
        let final = last.signedProgress
        #expect(final >= 0.5)
    }

    /// 四指张开：负进度（收起方向），ended 为负。
    @Test func fourFingerSpreadProducesNegativeProgress() {
        let recognizer = PinchTouchRecognizer()
        let events = run(recognizer, frames: pinchFrames(ids: [1, 2, 3, 4], kFrom: 1.0, kTo: 3.0, frames: 20))
        let changed = events.filter { $0.phase == .changed }
        #expect(!changed.isEmpty)
        #expect(changed.allSatisfy { $0.signedProgress < 0 })
        guard let last = events.last, last.phase == .ended else {
            Issue.record("末事件应为 ended：\(events)")
            return
        }
        let final = last.signedProgress
        #expect(final <= -0.5)
    }

    /// 不抬手反向：张开到 2.0 再捏回 0.5，有符号进度过零连续，终帧为负。
    @Test func midSessionReversalCrossesZero() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var frames: [[TouchSample]] = [crossFrame(ids: ids, k: 1.0, state: 3)]
        for k in stride(from: Float(1.1), through: Float(2.0), by: 0.1) {
            frames.append(crossFrame(ids: ids, k: k))
        }
        for k in stride(from: Float(1.9), through: Float(0.5), by: -0.1) {
            frames.append(crossFrame(ids: ids, k: k))
        }
        frames.append(crossFrame(ids: ids, k: 0.5, state: 5))
        frames.append([])

        let events = run(recognizer, frames: frames)
        let changed = events.filter { $0.phase == .changed }.map(\.signedProgress)
        #expect(changed.contains { $0 < -0.1 })   // 张开段 = 收起方向（负）
        #expect(changed.contains { $0 > 0.05 })   // 捏拢段 = 展开方向（正）
        // 过零连续：无跳变（相邻帧差 < 0.2）
        for (a, b) in zip(changed, changed.dropFirst()) {
            #expect(abs(b - a) < 0.2)
        }
        guard let last = events.last, last.phase == .ended else {
            Issue.record("末事件应为 ended：\(events)")
            return
        }
        let final = last.signedProgress
        #expect(final > 0)
    }

    /// 五指捏合同样接受（≥4 触点）。
    @Test func fiveFingerPinchAccepted() {
        let recognizer = PinchTouchRecognizer()
        let offsets: [(Float, Float)] = [(-0.06, 0), (0.06, 0), (0, -0.06), (0, 0.06), (0.045, 0.045)]
        func frame(k: Float, state: Int32) -> [TouchSample] {
            offsets.enumerated().map { i, off in
                touch(Int32(i + 1), state, 0.5 + off.0 * k, 0.5 + off.1 * k)
            }
        }
        var frames: [[TouchSample]] = [frame(k: 1.0, state: 3)]
        for i in 1...22 {
            frames.append(frame(k: 1.0 + Float(i) * 0.1, state: 4))
        }
        frames.append(frame(k: 3.2, state: 5))
        frames.append([])

        let events = run(recognizer, frames: frames)
        #expect(events.first?.phase == .began)
        #expect(events.contains { $0.phase == .changed && $0.signedProgress < -0.3 })
        guard let last = events.last, last.phase == .ended else {
            Issue.record("末事件应为 ended：\(events)")
            return
        }
        let final = last.signedProgress
        #expect(final <= -0.5)
    }

    // MARK: 会话生命周期

    /// 投递中接触数跌破 4 → ended 落位；冷却期内重合指不重开候选；冷却过后可新会话。
    @Test func contactDropEndsSessionAndCooldownBlocksImmediateRestart() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var events: [PinchGestureEvent] = []
        var now: TimeInterval = 1000
        let step: TimeInterval = 0.008

        func feed(_ frame: [TouchSample]) {
            events.append(contentsOf: recognizer.ingest(frame, now: now).events)
            now += step
        }

        // 展开到识别点以上
        feed(crossFrame(ids: ids, k: 1.0, state: 3))
        for k in stride(from: Float(1.1), through: Float(1.8), by: 0.1) {
            feed(crossFrame(ids: ids, k: k))
        }
        #expect(events.contains { $0.phase == .began })
        // 一指离板 → ended
        feed([touch(1, 4, 0.44, 0.5), touch(2, 4, 0.56, 0.5), touch(3, 4, 0.5, 0.44), touch(4, 5, 0.5, 0.62)])
        guard case .ended? = events.last?.phase else {
            Issue.record("一指离板应触发 ended：\(events)")
            return
        }
        let endedCount = events.filter { $0.phase == .ended }.count

        // 冷却期内第 4 指重新落板并继续张开：不得重开候选
        feed([touch(1, 4, 0.44, 0.5), touch(2, 4, 0.56, 0.5), touch(3, 4, 0.5, 0.44), touch(4, 3, 0.5, 0.66)])
        for k in stride(from: Float(1.9), through: Float(2.4), by: 0.1) {
            feed(crossFrame(ids: ids, k: k))
        }
        #expect(events.filter { $0.phase == .began }.count == 1)
        #expect(events.filter { $0.phase == .ended }.count == endedCount)

        // 冷却结束（0.25s ≈ 32 帧）后再次张开 → 新候选
        for _ in 0..<33 { feed([]) }
        feed(crossFrame(ids: ids, k: 1.0, state: 3))
        for k in stride(from: Float(1.1), through: Float(2.2), by: 0.1) {
            feed(crossFrame(ids: ids, k: k))
        }
        #expect(events.filter { $0.phase == .began }.count == 2)
        #expect(events.contains { $0.phase == .changed && $0.signedProgress < -0.2 })
    }

    /// 张开不足识别点就抬手：全程静默（无 began、无 ended）。
    @Test func subThresholdGestureIsSilent() {
        let recognizer = PinchTouchRecognizer()
        var frames: [[TouchSample]] = [crossFrame(ids: [1, 2, 3, 4], k: 1.0, state: 3)]
        for k in stride(from: Float(1.02), through: Float(1.40), by: 0.02) {
            frames.append(crossFrame(ids: [1, 2, 3, 4], k: k))
        }
        frames.append(crossFrame(ids: [1, 2, 3, 4], k: 1.4, state: 5))
        frames.append([])
        let events = run(recognizer, frames: frames)
        #expect(events.isEmpty)
    }

    /// 投递中转为平移（跨度冻结、位移猛增）→ cancelled，供窗口层回退。
    @Test func translationMidSessionDeliversCancelled() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var frames: [[TouchSample]] = [crossFrame(ids: ids, k: 1.0, state: 3)]
        // 先张开到 k=2.2（delta ≈ 0.116，已投递）
        for k in stride(from: Float(1.1), through: Float(2.2), by: 0.1) {
            frames.append(crossFrame(ids: ids, k: k))
        }
        // 再整手平移（跨度冻结在 k=2.2）：每帧 +0.03
        for i in 1...13 {
            let dx = Float(i) * 0.03
            frames.append(crossFrame(ids: ids, k: 2.2).map { t in
                TouchSample(id: t.id, state: t.state, x: t.x + dx, y: t.y)
            })
        }
        frames.append([])
        let events = run(recognizer, frames: frames)
        #expect(events.contains { $0.phase == .began })
        guard case .cancelled? = events.last?.phase else {
            Issue.record("末事件应为 cancelled：\(events)")
            return
        }
    }

    // MARK: 系统侧吞帧抑制（识别器会话驱动）
    //
    // 回归：2026-11-21 真机日志实锤——macOS 27.2 把三指滑动同样分类成捏合族
    // type 30，Dock 切空间/切窗口消费的正是这些载荷帧。旧抑制按「≥3 触点」
    // 一律吞帧，把整个滑动的载荷帧吞光导致三指滑动切窗口失效。现在抑制由
    // 识别器会话驱动：捏合会话存活+尾部才吞，滑动（位移否决）当帧闭锁放行。

    /// 三指滑动：会话永不开启 → 抑制全程不激活（切窗口载荷帧全部放行）。
    @Test func threeFingerSwipeNeverActivatesSuppression() {
        let monitor = TrackpadTouchMonitor()
        TrackpadTouchMonitor.suppressor.reset()
        var frames: [[TouchSample]] = [
            [touch(1, 3, 0.30, 0.5), touch(2, 3, 0.40, 0.5), touch(3, 3, 0.50, 0.5)]
        ]
        for i in 1...15 {
            let dx = Float(i) * 0.03
            frames.append([touch(1, 4, 0.30 + dx, 0.5), touch(2, 4, 0.40 + dx, 0.5), touch(3, 4, 0.50 + dx, 0.5)])
        }
        frames.append([touch(1, 5, 0.75, 0.5), touch(2, 5, 0.85, 0.5), touch(3, 5, 0.95, 0.5)])
        frames.append([])

        var now: TimeInterval = 1000
        for frame in frames {
            monitor.ingest(frame, now: now)
            #expect(!TrackpadTouchMonitor.suppressor.isActive(now: now),
                    "三指滑动期间抑制必须全程关闭（t=\(now)）")
            now += 0.008
        }
    }

    /// 真捏合：会话开启即抑制（含识别门前），抬手后保留尾部再过期。
    @Test func pinchSessionArmsSuppressionWithTail() {
        let monitor = TrackpadTouchMonitor()
        TrackpadTouchMonitor.suppressor.reset()
        var now: TimeInterval = 1000
        let step: TimeInterval = 0.008
        let ids: [Int32] = [1, 2, 3, 4]

        // 3 指落板阶段（未达候选数）：抑制不激活。
        // 触点 id 与后续捏合批共享：会话开启时落点原点重置，前置批次的紧缩位
        // 不会污染本批位移否决。
        monitor.ingest([touch(1, 3, 0.44, 0.5), touch(2, 3, 0.56, 0.5), touch(3, 3, 0.5, 0.44)], now: now)
        #expect(!TrackpadTouchMonitor.suppressor.isActive(now: now))
        now += step

        // 4 指捏拢（k 3.0 → 1.0，含落板帧）：会话存活全程激活
        var lastContactFrameAt = now
        for k in stride(from: Float(3.0), through: Float(1.0), by: -0.1) {
            monitor.ingest(crossFrame(ids: ids, k: k, state: k == 3.0 ? 3 : 4), now: now)
            #expect(TrackpadTouchMonitor.suppressor.isActive(now: now),
                    "捏合会话存活期间抑制必须激活（k=\(k)）")
            lastContactFrameAt = now
            now += step
        }

        // 抬手（离板帧 + 空帧）：尾部窗口内仍激活
        monitor.ingest(crossFrame(ids: ids, k: 1.0, state: 5), now: now)
        monitor.ingest([], now: now + step)
        #expect(TrackpadTouchMonitor.suppressor.isActive(now: lastContactFrameAt + 0.05),
                "会话结束后 0.05s 应处于尾部抑制窗口")
        #expect(!TrackpadTouchMonitor.suppressor.isActive(now: lastContactFrameAt + 0.15),
                "尾部窗口（0.10s）过后应放行")
    }

    /// 拇指搭板的四指滑动：候选期短暂抑制，位移否决当帧立即闭锁放行，
    /// 后续帧（触点仍 ≥3）不再回吞；触点撤离解除闭锁后新捏合恢复压制。
    @Test func thumbSwipeLatchesSuppressionOffOnVeto() {
        let monitor = TrackpadTouchMonitor()
        TrackpadTouchMonitor.suppressor.reset()
        var frames: [[TouchSample]] = [
            [touch(1, 3, 0.30, 0.5), touch(2, 3, 0.40, 0.5), touch(3, 3, 0.50, 0.5), touch(4, 3, 0.35, 0.62)]
        ]
        for i in 1...13 {
            let dx = Float(i) * 0.03
            frames.append([
                touch(1, 4, 0.30 + dx, 0.5), touch(2, 4, 0.40 + dx, 0.5),
                touch(3, 4, 0.50 + dx, 0.5), touch(4, 4, 0.35 + dx, 0.62)
            ])
        }
        frames.append([touch(1, 5, 0.69, 0.5), touch(2, 5, 0.79, 0.5), touch(3, 5, 0.89, 0.5), touch(4, 5, 0.74, 0.62)])
        frames.append([])

        var now: TimeInterval = 1000
        var vetoed = false
        var activeBeforeVeto = 0
        for frame in frames {
            let outcome = monitor.ingest(frame, now: now)
            let active = TrackpadTouchMonitor.suppressor.isActive(now: now)
            if outcome.vetoed {
                vetoed = true
                #expect(!active, "否决当帧必须立即闭锁放行")
            } else if vetoed {
                #expect(!active, "闭锁后同批触点不得重新吞帧（t=\(now)）")
            } else if active {
                activeBeforeVeto += 1
            }
            now += 0.008
        }
        #expect(vetoed, "拇指搭板滑动必须触发位移否决")
        #expect(activeBeforeVeto > 0, "否决前的候选期应有短暂抑制（吞掉误分类早期帧）")

        // 触点撤离（MT 线程上报 0）解除闭锁；冷却过后新捏合会话恢复压制
        TrackpadTouchMonitor.suppressor.note(touchingCount: 0)
        now += 0.3
        for k in stride(from: Float(3.0), through: Float(1.6), by: -0.1) {
            monitor.ingest(crossFrame(ids: [1, 2, 3, 4], k: k), now: now)
            #expect(TrackpadTouchMonitor.suppressor.isActive(now: now),
                    "闭锁解除后的新捏合会话必须恢复抑制（k=\(k)）")
            now += 0.008
        }
    }

    /// 跨批触点 id 复用：上一批的落点原点不污染本批位移否决
    /// （会话开启时原点重置为会话开启位；旧实现会把「落板位跳变」累计成
    /// 每指位移 → 误触发滑动否决，正常捏合被拦下）。
    @Test func staleOriginFromPreviousBatchDoesNotVeto() {
        let recognizer = PinchTouchRecognizer()
        var now: TimeInterval = 1000
        // 上一批：单指落在别处（触点保留在表中，无空帧间隔——真实管线里
        // 「双指收拢到单指 → 再落第四指」就会走到这个形态）
        _ = recognizer.ingest([touch(1, 4, 0.20, 0.20)], now: now)
        now += 0.008

        // 本批：四指捏合，id 1 落板位与上批差距很大（0.20,0.20 → 0.32,0.5）
        var beganSeen = false
        for k in stride(from: Float(3.0), through: Float(1.0), by: -0.1) {
            let outcome = recognizer.ingest(
                crossFrame(ids: [1, 2, 3, 4], k: k, state: k == 3.0 ? 3 : 4), now: now)
            #expect(!outcome.vetoed, "跨批残留原点不得触发位移否决（k=\(k)）")
            beganSeen = beganSeen || outcome.pinchConfirmed
            now += 0.008
        }
        #expect(beganSeen, "正常四指捏合应过识别门")
    }

    // MARK: GestureSuppressor 状态机（纯逻辑）

    @Test func suppressorStateMachine() {
        let suppressor = GestureSuppressor()
        suppressor.reset()
        let step = PinchTouchThresholds.suppressTail

        // 未武装：不吞
        #expect(!suppressor.isActive(now: 100))

        // 会话存活续期，尾部过期
        suppressor.arm(now: 100)
        #expect(suppressor.isActive(now: 100 + step / 2))
        #expect(!suppressor.isActive(now: 100 + step * 1.5))

        // 滑动闭锁：立即失效，且闭锁期间 arm 为空操作
        suppressor.arm(now: 200)
        suppressor.latchSwipe()
        #expect(!suppressor.isActive(now: 200))
        suppressor.arm(now: 200.05)
        #expect(!suppressor.isActive(now: 200.05))

        // ≥3 触点不解锁，触点撤离（<3）解锁
        suppressor.note(touchingCount: 3)
        #expect(!suppressor.isActive(now: 201))
        suppressor.note(touchingCount: 0)
        suppressor.arm(now: 300)
        #expect(suppressor.isActive(now: 300))

        // 确认真捏合推翻闭锁
        suppressor.latchSwipe()
        #expect(!suppressor.isActive(now: 400))
        suppressor.confirmPinch(now: 400)
        #expect(suppressor.isActive(now: 400 + step / 2))

        // reset 清空
        suppressor.reset()
        #expect(!suppressor.isActive(now: 500))
    }

    /// MT 线程临时武装：≥4 触点帧立即激活抑制（不等主线程会话开启），
    /// 滑动闭锁期间临时武装失效，触点撤离解除闭锁后恢复。
    @Test func provisionalArmFromMTThread() {
        let suppressor = GestureSuppressor()
        suppressor.reset()

        // 3 触点：不武装（三指滑动安全边界）
        suppressor.note(touchingCount: 3)
        #expect(!suppressor.isActive())

        // 4 触点：立即武装
        suppressor.note(touchingCount: 4)
        #expect(suppressor.isActive())

        // 滑动闭锁：临时武装失效（arm 空操作）
        suppressor.latchSwipe()
        suppressor.note(touchingCount: 4)
        #expect(!suppressor.isActive())

        // 触点撤离解除闭锁后，新 ≥4 帧恢复武装
        suppressor.note(touchingCount: 0)
        suppressor.note(touchingCount: 4)
        #expect(suppressor.isActive())
    }

    /// 空闲帧过滤决策：仅多触活动（≥2）或触点数下降帧转发主线程。
    @Test func idleSingleTouchFramesAreFiltered() {
        // 单指空闲（光标移动/单指滚动）与无触帧：跳过
        #expect(!TrackpadTouchMonitor.shouldForwardMTFrame(touching: 1, lastTouching: 1))
        #expect(!TrackpadTouchMonitor.shouldForwardMTFrame(touching: 0, lastTouching: 0))
        // 多触活动：转发
        #expect(TrackpadTouchMonitor.shouldForwardMTFrame(touching: 2, lastTouching: 1))
        #expect(TrackpadTouchMonitor.shouldForwardMTFrame(touching: 4, lastTouching: 4))
        #expect(TrackpadTouchMonitor.shouldForwardMTFrame(touching: 3, lastTouching: 4))
        // 触点数下降（离板/会话收尾）：转发
        #expect(TrackpadTouchMonitor.shouldForwardMTFrame(touching: 1, lastTouching: 2))
        #expect(TrackpadTouchMonitor.shouldForwardMTFrame(touching: 0, lastTouching: 4))
    }
}
