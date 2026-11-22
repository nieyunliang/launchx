import Foundation
import Testing
@testable import LaunchXCore

// MARK: - 原始触点捏合识别器（合成触点帧回归）
//
// 阈值口径见 PinchTouchThresholds：minContacts=4、movementFloor=0.06、
// vetoRatio=0.40、emitFloor=0.05、fullTrip=0.30、sessionCooldown=0.25s、
// releaseTrim=24ms（松手终值去尾）、dropoutGrace=24ms（失触宽限）。
// 场景几何按 2026-11-21 真机带标签实测构造：滑动 ratio 0.10~0.21、
// 捏合 ratio 0.59~1.52，判别式 spreadDelta / maxFingerMove。

@MainActor
struct PinchTouchRecognizerTests {

    // MARK: 造帧工具

    private func touch(_ id: Int32, _ state: Int32, _ x: Float, _ y: Float) -> TouchSample {
        TouchSample(id: id, state: state, x: x, y: y)
    }

    /// 十字四指位：围绕中心按系数 k 缩放（k=1 基准跨度、k>1 张开、k<1 捏拢）。
    /// `span` 为 k=1 时的半跨度；深捏合用例用 0.12（默认 0.06 捏到底不够行程）。
    private func crossFrame(ids: [Int32], k: Float, center: (Float, Float) = (0.5, 0.5), state: Int32 = 4, span: Float = 0.06) -> [TouchSample] {
        let offsets: [(Float, Float)] = [(-span, 0), (span, 0), (0, -span), (0, span)]
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
    /// O1 语义保留：峰值判据只豁免「反向过零 / 漂移」，真正的滑动仍要取消
    /// （峰值 0.116 → 平移约 0.29 后比值跌破 0.40，依旧 cancelled）。
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

    // MARK: P0 优化回归（docs/pinch-gesture-optimization.md）
    //
    // O1：过识别门后位移否决改用会话内峰值 |delta|。原测试的十字位合成几何
    // 过零时每指恰好回到落点（maxFingerMove ≈ 0），掩盖了「中途反向 / 捏合后
    // 漂移被误取消」；以下用例加入持续质心漂移构造真实几何。

    /// 不抬手反向 + 全程质心漂移：旧逻辑在过零附近（当帧 |delta|≈0、位移已超
    /// floor）误判成滑动取消；峰值判据下应完整投递到 ended。
    @Test func reversalWithDriftIsNotVetoed() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var frames: [[TouchSample]] = []
        var drift: Float = 0
        // 捏拢 1.0 → 0.5（0.05/帧，偏移 0.12 的大跨度），质心每帧 +0.004
        for i in 0...10 {
            let k = Float(1.0) - Float(i) * 0.05
            frames.append(crossFrame(ids: ids, k: k, center: (0.5 + drift, 0.5),
                                     state: i == 0 ? 3 : 4, span: 0.12))
            drift += 0.004
        }
        // 不抬手反向：张开 0.5 → 1.4（0.05/帧），漂移继续累积
        for j in 1...18 {
            let k = Float(0.5) + Float(j) * 0.05
            frames.append(crossFrame(ids: ids, k: k, center: (0.5 + drift, 0.5), span: 0.12))
            drift += 0.004
        }
        frames.append(crossFrame(ids: ids, k: 1.4, center: (0.5 + drift, 0.5), state: 5, span: 0.12))
        frames.append([])

        let events = run(recognizer, frames: frames)
        #expect(events.contains { $0.phase == .began }, "应过识别门开始投递")
        #expect(!events.contains { $0.phase == .cancelled },
                "反向过零 + 质心漂移不得被位移否决取消（旧逻辑在此误判滑动）")
        #expect(events.last?.phase == .ended)
    }

    // MARK: O2：会话成员固定 + 成员变化时平移基线

    /// 四指捏合中途第 5 指在远角落下并保持：成员固定后不参与张开度计算，
    /// 进度连续不跳变；旧逻辑把它计入平均两两间距，进度跳变 > 0.1。
    @Test func fifthFingerLandingKeepsContinuity() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var frames: [[TouchSample]] = [crossFrame(ids: ids, k: 1.0, state: 3, span: 0.12)]
        for i in 1...10 {
            frames.append(crossFrame(ids: ids, k: Float(1.0) - Float(i) * 0.05, span: 0.12))
        }
        // 第 5 指在远角落下并保持
        frames.append(crossFrame(ids: ids, k: 0.5, span: 0.12) + [touch(5, 3, 0.9, 0.9)])
        for i in 1...5 {
            frames.append(crossFrame(ids: ids, k: Float(0.5) - Float(i) * 0.04, span: 0.12)
                + [touch(5, 4, 0.9, 0.9)])
        }
        frames.append(crossFrame(ids: ids, k: 0.3, state: 5, span: 0.12) + [touch(5, 5, 0.9, 0.9)])
        frames.append([])

        let events = run(recognizer, frames: frames)
        #expect(!events.contains { $0.phase == .cancelled }, "第 5 指起落不得影响会话")
        let changed = events.filter { $0.phase == .changed }.map(\.signedProgress)
        #expect(!changed.isEmpty)
        for (a, b) in zip(changed, changed.dropFirst()) {
            #expect(abs(b - a) < 0.1, "第 5 指落下不得造成进度跳变（\(a) → \(b)）")
        }
    }

    /// 五指会话中途一指（成员）抬起，剩余四指继续捏合：会话不结束，基线平移
    /// 使 delta 连续；旧逻辑把该指从平均间距中剔除，进度跳变 > 0.1。
    @Test func memberLiftInFiveFingerSessionRebases() {
        let recognizer = PinchTouchRecognizer()
        func fiveFrame(k: Float, state: Int32, withFifth: Bool) -> [TouchSample] {
            var samples = crossFrame(ids: [1, 2, 3, 4], k: k, state: state, span: 0.12)
            if withFifth {
                samples.append(touch(5, state, 0.5 + 0.01 * k, 0.5 + 0.01 * k))
            }
            return samples
        }
        var frames: [[TouchSample]] = [fiveFrame(k: 1.0, state: 3, withFifth: true)]
        for i in 1...5 {
            frames.append(fiveFrame(k: Float(1.0) + Float(i) * 0.1, state: 4, withFifth: true))
        }
        // 成员第五指 state 5 一帧后消失；剩余四指继续张开
        frames.append(fiveFrame(k: 1.6, state: 4, withFifth: true).map { t in
            t.id == 5 ? TouchSample(id: 5, state: 5, x: t.x, y: t.y) : t
        })
        for i in 1...5 {
            frames.append(fiveFrame(k: Float(1.6) + Float(i) * 0.08, state: 4, withFifth: false))
        }
        frames.append(fiveFrame(k: 2.0, state: 5, withFifth: false))
        frames.append([])

        let events = run(recognizer, frames: frames)
        #expect(events.filter { $0.phase == .ended }.count == 1, "成员抬起（仍剩 4 指在触）不得结束会话")
        #expect(!events.contains { $0.phase == .cancelled })
        let changed = events.filter { $0.phase == .changed }.map(\.signedProgress)
        #expect(!changed.isEmpty)
        for (a, b) in zip(changed, changed.dropFirst()) {
            #expect(abs(b - a) < 0.1, "成员抬起后基线应平移保持进度连续（\(a) → \(b)）")
        }
    }

    // MARK: O3：松手终值去尾 + 失触宽限

    /// 松手前最后 3 帧张开度回落（逐指抬起滑移）：ended 终值取松手前 24ms
    /// 之前的进度，不被回落值拖下提交线；旧逻辑直接取 lastProgress（≈0.54）。
    @Test func endedProgressTrimsLiftSlip() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var frames: [[TouchSample]] = [crossFrame(ids: ids, k: 3.0, state: 3)]
        for i in 1...20 {
            frames.append(crossFrame(ids: ids, k: Float(3.0) - Float(i) * 0.1))
        }
        // 抬指滑移：3 帧回落（k 1.11/1.22/1.33 → 进度 0.61/0.57/0.54）后离板
        for k in [Float(1.11), Float(1.22), Float(1.33)] {
            frames.append(crossFrame(ids: ids, k: k))
        }
        frames.append(crossFrame(ids: ids, k: 1.33, state: 5))
        frames.append([])

        let events = run(recognizer, frames: frames)
        guard let last = events.last, last.phase == .ended else {
            Issue.record("末事件应为 ended：\(events)")
            return
        }
        // 捏合终点 k=1.0 的进度 ≈ 0.64，终值不得被滑移段拖到提交线以下
        #expect(last.signedProgress > 0.55,
                "ended 终值应取滑移前进度（实际 \(last.signedProgress)）")
    }

    /// 成员短暂失触（帧内消失、无 breakTouch）2 帧（16ms）内恢复：宽限期内
    /// 不结束会话，恢复后继续投递；旧逻辑当即 ended + 冷却，手势「断掉」。
    @Test func briefDropoutWithinGraceContinues() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var events: [PinchGestureEvent] = []
        var now: TimeInterval = 1000
        let step: TimeInterval = 0.008

        func feed(_ frame: [TouchSample]) {
            events.append(contentsOf: recognizer.ingest(frame, now: now).events)
            now += step
        }

        // 捏拢过识别门（k 3.0 → 2.4）
        feed(crossFrame(ids: ids, k: 3.0, state: 3))
        for i in 1...6 {
            feed(crossFrame(ids: ids, k: Float(3.0) - Float(i) * 0.1))
        }
        #expect(events.contains { $0.phase == .began })

        // id=4 失触 2 帧（16ms）：宽限期内不得 ended，也不得否决
        feed([touch(1, 4, 0.36, 0.5), touch(2, 4, 0.64, 0.5), touch(3, 4, 0.5, 0.36)])
        feed([touch(1, 4, 0.35, 0.5), touch(2, 4, 0.65, 0.5), touch(3, 4, 0.5, 0.35)])
        #expect(!events.contains { $0.phase == .ended }, "失触宽限期内不得结束会话")
        #expect(!events.contains { $0.phase == .cancelled })

        // 恢复后继续捏拢并松手：changed 续传，ended 恰好一次（松手）
        for i in 1...5 {
            feed(crossFrame(ids: ids, k: Float(2.0) - Float(i) * 0.15))
        }
        #expect(events.contains { $0.phase == .changed }, "恢复后应继续投递 changed")
        feed(crossFrame(ids: ids, k: 1.25, state: 5))
        feed([])
        #expect(events.filter { $0.phase == .ended }.count == 1, "整个过程中 ended 应恰好一次")
    }

    /// 失触超过宽限期（24ms）→ 按松手收尾（ended）；宽限期内不得提前结束。
    @Test func dropoutBeyondGraceEnds() {
        let recognizer = PinchTouchRecognizer()
        let ids: [Int32] = [1, 2, 3, 4]
        var now: TimeInterval = 1000
        let step: TimeInterval = 0.008

        _ = recognizer.ingest(crossFrame(ids: ids, k: 3.0, state: 3), now: now)
        now += step
        for i in 1...6 {
            _ = recognizer.ingest(crossFrame(ids: ids, k: Float(3.0) - Float(i) * 0.1), now: now)
            now += step
        }

        // id=4 失触：宽限期内不 ended，超期后 ended
        var endedAtFrame: Int?
        for i in 0..<6 {
            let outcome = recognizer.ingest(
                [touch(1, 4, 0.36 - Float(i) * 0.005, 0.5), touch(2, 4, 0.64 + Float(i) * 0.005, 0.5),
                 touch(3, 4, 0.5, 0.36 - Float(i) * 0.005)],
                now: now)
            if outcome.events.contains(where: { $0.phase == .ended }) {
                endedAtFrame = i
                break
            }
            now += step
        }
        #expect(endedAtFrame != nil, "失触超过宽限期后应 ended")
        #expect(endedAtFrame == nil || endedAtFrame! >= 3, "宽限期内（前 3 帧 ≈24ms）不得提前 ended")
    }

    // MARK: O4：abort（设备停止时半途会话的回退出口）

    /// 投递中 abort 补发 cancelled 供窗口层回退；无会话 / 未投递返回空；
    /// abort 后冷却期内不重开候选。
    @Test func abortDeliversCancelledWhenEmitting() {
        let ids: [Int32] = [1, 2, 3, 4]

        // 无会话：空
        #expect(PinchTouchRecognizer().abort(now: 1000).isEmpty)

        // 会话开启但未过识别门：空（会话仍被关闭）
        let idle = PinchTouchRecognizer()
        _ = idle.ingest(crossFrame(ids: ids, k: 1.0, state: 3, span: 0.12), now: 1000)
        #expect(idle.abort(now: 1000.004).isEmpty)

        // 投递中：[cancelled]，且 abort 后冷却期内不重开候选
        let emitting = PinchTouchRecognizer()
        var now: TimeInterval = 1000
        var events: [PinchGestureEvent] = []
        events.append(contentsOf: emitting.ingest(crossFrame(ids: ids, k: 1.0, state: 3, span: 0.12), now: now).events)
        now += 0.008
        for i in 1...6 {
            let k = Float(1.0) - Float(i) * 0.05
            events.append(contentsOf: emitting.ingest(crossFrame(ids: ids, k: k, span: 0.12), now: now).events)
            now += 0.008
        }
        #expect(events.contains { $0.phase == .changed }, "应处于投递中")
        let aborted = emitting.abort(now: now)
        #expect(aborted.map(\.phase) == [.cancelled], "投递中 abort 应补发 cancelled：\(aborted)")

        let after = emitting.ingest(crossFrame(ids: ids, k: 0.7, span: 0.12), now: now + 0.008)
        #expect(after.events.isEmpty && !after.sessionActive, "abort 后冷却期内不得重开候选")
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
            monitor.ingestForTesting(frame, now: now)
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
        monitor.ingestForTesting([touch(1, 3, 0.44, 0.5), touch(2, 3, 0.56, 0.5), touch(3, 3, 0.5, 0.44)], now: now)
        #expect(!TrackpadTouchMonitor.suppressor.isActive(now: now))
        now += step

        // 4 指捏拢（k 3.0 → 1.0，含落板帧）：会话存活全程激活
        var lastContactFrameAt = now
        for k in stride(from: Float(3.0), through: Float(1.0), by: -0.1) {
            monitor.ingestForTesting(crossFrame(ids: ids, k: k, state: k == 3.0 ? 3 : 4), now: now)
            #expect(TrackpadTouchMonitor.suppressor.isActive(now: now),
                    "捏合会话存活期间抑制必须激活（k=\(k)）")
            lastContactFrameAt = now
            now += step
        }

        // 抬手（离板帧 + 空帧）：尾部窗口内仍激活
        monitor.ingestForTesting(crossFrame(ids: ids, k: 1.0, state: 5), now: now)
        monitor.ingestForTesting([], now: now + step)
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
            let outcome = monitor.ingestForTesting(frame, now: now)
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
            monitor.ingestForTesting(crossFrame(ids: [1, 2, 3, 4], k: k), now: now)
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

    /// 空闲帧过滤决策：仅多触活动（≥2）或触点数下降帧运行识别器。
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

    // MARK: PinchEventMailbox（O7：MT 线程投递、主线程合并取走）

    /// 连续 changed 合并为最新一条（进度是绝对量）；began/ended/cancelled 不合并、
    /// 保持顺序；已调度 drain 期间不重复调度（post 返回 false，事件仍入队）。
    @Test func mailboxMergesConsecutiveChangedKeepsTerminalOrder() {
        let mailbox = PinchEventMailbox()
        #expect(mailbox.post([PinchGestureEvent(phase: .began, signedProgress: 0)]),
                "首次 post 调度 drain")
        // 已调度 drain：后续 post 返回 false（不重复调度），事件仍入队
        #expect(!mailbox.post([PinchGestureEvent(phase: .changed, signedProgress: 0.1)]))
        #expect(!mailbox.post([PinchGestureEvent(phase: .changed, signedProgress: 0.2)]))
        #expect(!mailbox.post([PinchGestureEvent(phase: .changed, signedProgress: 0.3),
                               PinchGestureEvent(phase: .ended, signedProgress: 0.5)]))

        let drained = mailbox.drain()
        #expect(drained.map(\.phase) == [.began, .changed, .ended])
        #expect(drained[1].signedProgress == 0.3, "连续 changed 只保留最新一条")
        #expect(drained[2].signedProgress == 0.5)

        // drain 后清空；新事件重新可调度
        #expect(mailbox.drain().isEmpty)
        #expect(mailbox.post([PinchGestureEvent(phase: .cancelled, signedProgress: 0)]))
        #expect(mailbox.drain().map(\.phase) == [.cancelled])
    }

    /// 同批多事件 post：began 与连续 changed 合并后仍保序，终态事件不丢。
    @Test func mailboxBatchPostMergesWithinBatch() {
        let mailbox = PinchEventMailbox()
        let posted = mailbox.post([
            PinchGestureEvent(phase: .began, signedProgress: 0),
            PinchGestureEvent(phase: .changed, signedProgress: 0.1),
            PinchGestureEvent(phase: .changed, signedProgress: 0.2),
            PinchGestureEvent(phase: .ended, signedProgress: 0.2),
        ])
        #expect(posted)
        let drained = mailbox.drain()
        #expect(drained.map(\.phase) == [.began, .changed, .ended])
        #expect(drained[1].signedProgress == 0.2)
    }

    /// 空 post 不调度 drain；drain 后再 post 重新调度（不丢已积压事件）。
    @Test func mailboxEmptyPostAndRepostAfterDrain() {
        let mailbox = PinchEventMailbox()
        #expect(!mailbox.post([]), "空事件不调度")
        _ = mailbox.post([PinchGestureEvent(phase: .changed, signedProgress: 0.1)])
        // 主线程尚未 drain 时继续投递，再 drain：积压合并取走
        #expect(!mailbox.post([PinchGestureEvent(phase: .changed, signedProgress: 0.4)]))
        let drained = mailbox.drain()
        #expect(drained.map(\.signedProgress) == [0.4])
        // drain 后再 post 重新返回 true（调度窗口已重置）
        #expect(mailbox.post([PinchGestureEvent(phase: .changed, signedProgress: 0.6)]))
    }

    // MARK: 多设备（O10：每设备独立 pipeline）

    /// 两组触点 id 相同但来源设备不同的帧交替注入：各自识别、互不串扰
    /// （内建板 + 外接板同时出手势，识别器状态不得互相污染）。
    /// 抑制器全局共享（任一设备的会话都可武装），不在此断言。
    @Test func perDevicePipelinesDoNotInterfere() {
        let padIn = TouchPipeline()   // 板 A：捏拢（正进度）
        let padOut = TouchPipeline()  // 板 B：张开（负进度），触点 id 相同

        var now: TimeInterval = 1000
        let step: TimeInterval = 0.008
        var eventsIn: [PinchGestureEvent] = []
        var eventsOut: [PinchGestureEvent] = []

        // 交替喂 20 帧：A 捏拢 k 3.0→2.0，B 张开 k 1.0→2.0
        for i in 0...20 {
            let kA = Float(3.0) - Float(i) * 0.05
            let kB = Float(1.0) + Float(i) * 0.05
            let state: Int32 = i == 0 ? 3 : 4
            eventsIn.append(contentsOf: padIn.recognizer.ingest(
                crossFrame(ids: [1, 2, 3, 4], k: kA, state: state), now: now).events)
            eventsOut.append(contentsOf: padOut.recognizer.ingest(
                crossFrame(ids: [1, 2, 3, 4], k: kB, state: state), now: now).events)
            now += step
        }

        // 各自识别出方向相反的手势：A 捏拢（正），B 张开（负）
        #expect(eventsIn.contains { $0.phase == .began })
        #expect(eventsOut.contains { $0.phase == .began })
        #expect(eventsIn.contains { $0.phase == .changed && $0.signedProgress > 0.1 },
                "板 A 应识别出捏拢（正进度）")
        #expect(eventsOut.contains { $0.phase == .changed && $0.signedProgress < -0.1 },
                "板 B 应识别出张开（负进度）")
        #expect(eventsIn.allSatisfy { $0.signedProgress >= 0 },
                "板 A 的事件不得混入板 B 的负进度（识别器状态互不污染）")
        #expect(eventsOut.allSatisfy { $0.signedProgress <= 0 },
                "板 B 的事件不得混入板 A 的正进度")
    }
}
