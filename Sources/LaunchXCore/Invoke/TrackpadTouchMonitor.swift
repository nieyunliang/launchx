import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit
import OSLog
import QuartzCore
import os

// MARK: - 原始触点手势识别（macOS 27.2 误分类问题的根治方案）
//
// 背景：macOS 27.2 会把「三指滑动 + 拇指搭板」的接触场整体分类成捏合族 CGEvent
// （type 30 + f110=23），字段签名与真四指捏合完全一致；滑动噪声流的 f124 累计幅度
// 在 ±0.2~0.7 振荡、水平滑动单调正增长收于深正值，与真捏合在帧级/会话形态级/
// 终态级全部不可区分（三轮带标签追踪实测）。CGEvent 是系统识别器**分类后**的
// 输出，逐触点运动学不经事件流——帧级判别没有出路。
//
// 本模块改走 **MultitouchSupport 私有框架的原始触点流**（LaunchOS 同款路线）：
// - dlopen 从 dyld 共享缓存解析（27.2 起磁盘二进制已删，符号链接悬空，但缓存仍在；
//   框架不可用时优雅降级为无手势，不影响其它唤起入口）；
// - 125Hz 逐触点帧：ID / 归一化坐标 / 相位（3=makeTouch 4=touching 5=breakTouch）；
// - 识别器自己做捏合判定：≥4 触点候选 + **位移否决**（滑动 = 每指大位移、跨度不变；
//   捏合 = 每指小位移、跨度大变。判别式 spreadDelta/maxFingerMove：滑动 0.10~0.21，
//   捏合 0.59~1.52，实测干净分离）+ 张开度驱动跟手进度（跟手完整保留）；
// - 系统侧双开抑制：过滤型 tap 只吞 type 30（捏合族载荷帧），吞帧条件由识别器
//   会话驱动——捏合会话（≥4 触点候选）存活期间及其尾部才吞；位移否决（判定为
//   滑动）当帧闭锁放行。macOS 27.2 把三指滑动同样分类成 type 30，Dock 切空间/
//   切窗口消费的正是这些载荷帧：若按「≥3 触点」一律吞帧，三指滑动切窗口整体
//   失效（2026-11-21 真机日志实锤，已回归）。双指缩放（2 触点）永不构成会话，
//   缩放不受影响。
// - 效率：单指空闲帧（光标移动/单指滚动）不跑识别器，125Hz 只在多触活动或
//   触点数变化时识别；识别器同步跑在 MT 回调线程（主线程拥塞不拖慢否决决策），
//   事件经邮箱合并后投递主线程；抑制 tap 跑在专用线程，吞帧决策不被主线程
//   UI 阻塞。
// - 多设备（O10）：MTDeviceCreateList 枚举内建 + 外接触控板，每设备独立
//   识别 pipeline；IOKit 热插拔通知 + 睡眠唤醒自愈触发设备重启。
// - 辅助功能权限仅抑制 tap 需要：无权限时手势照常可用，只是真捏合期间系统侧
//   启动台手势可能同时响应（UI 文案按「可选」表述）。

/// 一次识别后的捏合手势帧。`signedProgress` 绝对值范围为 0...1；
/// 正值表示张开（展开启动台），负值表示捏合（收起启动台）。
public enum PinchGestureEventPhase: Sendable {
    case began
    case changed
    case ended
    case cancelled
}

public struct PinchGestureEvent: Sendable {
    public let phase: PinchGestureEventPhase
    public let signedProgress: CGFloat

    public init(phase: PinchGestureEventPhase, signedProgress: CGFloat) {
        self.phase = phase
        self.signedProgress = signedProgress
    }
}

/// 单帧单触点的解读结果（MT 线程解析，主线程识别）。
struct TouchSample: Sendable {
    let id: Int32
    let state: Int32
    let x: Float
    let y: Float
}

/// 一次 ingest 的产出：手势事件 + 系统侧抑制决策所需的会话状态。
struct IngestOutcome {
    var events: [PinchGestureEvent] = []
    /// 识别器会话在本帧存活（含本帧新开）——抑制窗口据此逐帧续期。
    var sessionActive = false
    /// 本帧发生位移否决（判定为滑动）——抑制据此立即闭锁放行。
    var vetoed = false
    /// 本帧会话过识别门开始投递（确认真捏合）——推翻滑动闭锁。
    var pinchConfirmed = false
}

// MARK: - 识别阈值（2026-11-21 真机原始触点实测标定）

enum PinchTouchThresholds {
    /// 候选会话的最少同时接触数（四指捏合；五指同样接受）。
    static let minContacts = 4
    /// 位移否决起步值：每指位移低于此值不参与否决（落指抖动噪声）。
    static let movementFloor: Float = 0.06
    /// 张开度变化 / 每指最大位移 低于此比值判定为平移（滑动），否决会话。
    /// 实测（2026-11-21 真机带标签数据）：滑动 0.10~0.21，捏合 0.59~1.52，取中点。
    static let vetoRatio: Float = 0.40
    /// 张开度累计达到才开始投递进度（识别点，跟手从这里起步）。
    static let emitFloor: Float = 0.05
    /// 完整捏合行程对应的张开度变化（实测真捏合 0.22~0.38，取保守档）。
    static let fullTrip: Float = 0.30
    /// 会话结束后允许新候选的冷却期（防止同批触点立刻重开会话）。
    static let sessionCooldown: TimeInterval = 0.25
    /// 松手终值去尾窗口：ended 取「松手前该时长之前」最近的进度样本
    /// （≈3 帧，覆盖逐指抬起造成的张开度回落）。
    static let releaseTrim: TimeInterval = 0.024
    /// 进度历史保留窗口（松手去尾取值用；后续速度估计共用同一缓冲）。
    static let historyWindow: TimeInterval = 0.15
    /// 失触宽限：会话成员短暂失触（帧内消失且无 breakTouch）不超过此值
    /// 不结束会话（单指状态抖动一两帧不应让手势「断掉」）。
    static let dropoutGrace: TimeInterval = 0.024
    /// 抑制窗口续期步长 = 会话结束尾部：最后一段会话帧之后仍继续吞帧的时长
    /// （覆盖系统侧终帧；会话存活期间由识别器逐帧续期）。
    static let suppressTail: TimeInterval = 0.10
}

// MARK: - 单调时钟

/// 手势时序统一单调时钟（O8）：mach 绝对时间（开机起算），不受 NTP 校时或
/// 手动改时间的跳变影响（系统时钟跳变会让吞帧窗口卡住或冷却期失效）。
/// 识别器冷却、抑制器吞帧窗口、MT 回调时序共用；trace 日志仍用系统时钟
/// （方便与系统日志对照）。
enum GestureClock {
    @inline(__always) static func now() -> TimeInterval { CACurrentMediaTime() }
}

// MARK: - MTTouch 结构（MultitouchSupport 96 字节布局，社区公认逆向结果，
// 2026-11-21 本机探针按偏移验证：state@20、normalizedPosition@32/36）

struct MTTouch {
    let frame: Int32            // 0
    private let reserved0: Int32 // 4（对齐填充）
    let timestamp: Double       // 8
    let identifier: Int32       // 16
    let state: Int32            // 20
    let fingerId: Int32         // 24
    let handId: Int32           // 28
    let normalizedPositionX: Float // 32
    let normalizedPositionY: Float // 36
    let normalizedVelocityX: Float // 40
    let normalizedVelocityY: Float // 44
    let total: Float            // 48
    let pressure: Float         // 52
    let angle: Float            // 56
    let majorAxis: Float        // 60
    let minorAxis: Float        // 64
    let absolutePositionX: Float // 68
    let absolutePositionY: Float // 72
    let absoluteVelocityX: Float // 76
    let absoluteVelocityY: Float // 80
    private let reserved1: Int32 // 84
    private let reserved2: Int32 // 88
    let density: Float          // 92
}

// MARK: - 原始触点捏合识别器（纯状态机，可注入时间做确定性测试）

/// 识别器无 UI 依赖、在 MT 回调线程同步运行（O7）：主线程拥塞时滑动否决
/// 不再滞后。线程约定：单实例内串行访问（MT 对同一设备的回调串行；测试在
/// 主线程驱动），无内部同步——因此 @unchecked Sendable。
final class PinchTouchRecognizer: @unchecked Sendable {

    private struct TrackedContact {
        var id: Int32
        var x: Float
        var y: Float
        var originX: Float
        var originY: Float
        var state: Int32
    }

    private struct ProgressSample {
        let t: TimeInterval
        let p: CGFloat
    }

    private var contacts: [Int32: TrackedContact] = [:]
    private var sessionActive = false
    private var sessionEmitting = false
    private var baselineSpread: Float = 0
    private var lastProgress: CGFloat = 0
    private var cooldownUntil: TimeInterval = 0
    // O1：会话内峰值 |spreadDelta|——过识别门后位移否决的判据分子
    private var peakAbsDelta: Float = 0
    // O2：会话成员固定；成员子集变化时把基线平移到 delta 连续的位置
    private var members: Set<Int32> = []
    private var activeKey: [Int32] = []       // 上一帧参与计算的成员 id（升序）
    private var lastSpreadDelta: Float = 0
    // O3：进度历史（松手终值去尾）与失触宽限起点
    private var history: [ProgressSample] = []
    private var belowSince: TimeInterval?

    /// 处理一帧触点采样。MT 帧只包含当前仍在传感器上的触点；消失的触点视为已离开。
    func ingest(_ samples: [TouchSample], now: TimeInterval) -> IngestOutcome {
        var outcome = IngestOutcome()

        // 1. 重建触点表：已有 id 保留落点原点，新 id 以首次接触点为原点
        var updated: [Int32: TrackedContact] = [:]
        for s in samples {
            if var existing = contacts[s.id] {
                existing.x = s.x
                existing.y = s.y
                existing.state = s.state
                updated[s.id] = existing
            } else {
                updated[s.id] = TrackedContact(
                    id: s.id, x: s.x, y: s.y, originX: s.x, originY: s.y, state: s.state
                )
            }
        }
        contacts = updated
        let touching = contacts.values.filter { $0.state == 3 || $0.state == 4 }

        // 2. 会话进行中：更新位移与张开度，执行否决/投递（否决会就地关闭会话）
        if sessionActive {
            advanceSession(touching: touching, now: now, into: &outcome)
        }

        // 3. 无会话且不在冷却期：≥minContacts 触点即开候选
        if !sessionActive, touching.count >= PinchTouchThresholds.minContacts, now >= cooldownUntil {
            sessionActive = true
            sessionEmitting = false
            // 落点原点重置为会话开启位：位移否决语义 = 本会话内的位移。
            // 触点 id 复用/上一批手势的残留原点会污染本批判定（把「落板位
            // 跳变」累计成每指位移 → 误否决），会话开启即归零。
            for var c in touching {
                c.originX = c.x
                c.originY = c.y
                contacts[c.id] = c
            }
            // 成员固定为开启时刻的全部触点（O2）：会话中新落下的手指（第 5 指
            // 落板）不参与张开度/位移计算，其起落不影响会话生死。activeKey 同步
            // 初始化，否则首帧 advanceSession 会误触发一次基线平移吞掉首帧位移。
            members = Set(touching.map(\.id))
            activeKey = touching.sorted { $0.id < $1.id }.map(\.id)
            lastSpreadDelta = 0
            peakAbsDelta = 0
            history = []
            belowSince = nil
            baselineSpread = Self.spread(of: touching) ?? 0
            lastProgress = 0
        }

        // 4. 会话收尾：按成员口径判定——成员中仍在触的数跌破候选下限才是松手
        // 意图，四指会话里第 5 指的起落不改变会话生死（O2）。
        if sessionActive {
            let memberTouching = touching.filter { members.contains($0.id) }.count
            if memberTouching < PinchTouchThresholds.minContacts {
                // 明确抬指（breakTouch 及之后）立即结束；否则先给失触宽限（O3-B）：
                // 单指状态抖动一两帧不应让手势「断掉」。宽限期内不投递、不否决
                // （advanceSession 的成员守卫已保证），抑制窗口随 sessionActive 续期。
                let explicitLift = samples.contains { members.contains($0.id) && $0.state >= 5 }
                if explicitLift {
                    endSession(now: now, into: &outcome)
                } else if let since = belowSince, now - since >= PinchTouchThresholds.dropoutGrace {
                    endSession(now: now, into: &outcome)
                } else if belowSince == nil {
                    belowSince = now
                }
            } else {
                belowSince = nil
            }
        }

        outcome.sessionActive = sessionActive
        return outcome
    }

    /// 会话进行中的一帧。产生的手势事件与否决/确认标记写入 outcome。
    private func advanceSession(touching: [TrackedContact], now: TimeInterval, into outcome: inout IngestOutcome) {
        // 只用「仍在触的会话成员」参与计算：会话中新落下的非成员触点不污染
        // 张开度与位移口径（O2）。成员跌破候选下限：交给收尾逻辑按「松手/失触」
        // 落位，不走否决（此时 spread 不可靠，且抬手滑移是正常现象）。
        let active = touching.filter { members.contains($0.id) }.sorted { $0.id < $1.id }
        guard active.count >= PinchTouchThresholds.minContacts else { return }

        // 每指位移：当前接触成员相对各自落点的最大位移
        var maxFingerMove: Float = 0
        for c in active {
            let dx = c.x - c.originX
            let dy = c.y - c.originY
            maxFingerMove = max(maxFingerMove, (dx * dx + dy * dy).squareRoot())
        }

        // 张开度变化：当前成员平均两两间距 - 会话起点间距
        guard let raw = Self.spread(of: active) else { return }
        let key = active.map(\.id)
        if key != activeKey {
            // 成员子集变化（会话成员抬起，新落指不是成员不会走到这里）：把基线
            // 平移到能让本帧 delta 与上一帧连续的位置，进度不跳变（O2）。
            baselineSpread = raw - lastSpreadDelta
            activeKey = key
        }
        let spreadDelta = raw - baselineSpread
        lastSpreadDelta = spreadDelta

        // 位移否决：手指大幅平移而跨度几乎不变 = 滑动（LaunchOS movementThreshold 同款）。
        // 过识别门前用当帧 |delta|——阈值按该口径实测标定（滑动 0.10~0.21），不动；
        // 过门后改用会话内峰值 |delta|（O1）：不抬手反向过零、捏合后整手漂移时
        // 当帧 delta 趋近 0，按当帧判定会把进行中的手势误判成滑动取消。
        peakAbsDelta = max(peakAbsDelta, spreadDelta.magnitude)
        let evidence = sessionEmitting ? peakAbsDelta : spreadDelta.magnitude
        let ratio = evidence / max(maxFingerMove, 0.0001)
        if maxFingerMove > PinchTouchThresholds.movementFloor, ratio < PinchTouchThresholds.vetoRatio {
            outcome.vetoed = true
            if sessionEmitting {
                outcome.events.append(PinchGestureEvent(phase: .cancelled, signedProgress: lastProgress))
            }
            closeSession(now: now)
            return
        }

        // 识别门：张开度累计过识别点才开始投递（此前滑动噪声已被否决拦下）
        if !sessionEmitting, spreadDelta.magnitude >= PinchTouchThresholds.emitFloor {
            sessionEmitting = true
            outcome.pinchConfirmed = true
            outcome.events.append(PinchGestureEvent(phase: .began, signedProgress: 0))
        }

        if sessionEmitting {
            let progress = min(max(spreadDelta.magnitude / PinchTouchThresholds.fullTrip, 0), 1)
            // 方向映射与系统启动台手势同向：捏合收拢（跨度收窄）= 展开面板（正进度），
            // 张开 = 收起面板（负进度）。用户实测反馈「手势反了」即指此向。
            lastProgress = spreadDelta > 0 ? -CGFloat(progress) : CGFloat(progress)
            outcome.events.append(PinchGestureEvent(phase: .changed, signedProgress: lastProgress))
            // 进度历史：松手终值去尾（O3-A）与后续速度估计共用，只保留最近窗口。
            history.append(ProgressSample(t: now, p: lastProgress))
            let cutoff = now - PinchTouchThresholds.historyWindow
            while let first = history.first, first.t < cutoff {
                history.removeFirst()
            }
        }
    }

    private func closeSession(now: TimeInterval) {
        sessionActive = false
        sessionEmitting = false
        lastProgress = 0
        cooldownUntil = now + PinchTouchThresholds.sessionCooldown
        peakAbsDelta = 0
        members = []
        activeKey = []
        lastSpreadDelta = 0
        history = []
        belowSince = nil
    }

    /// 会话正常收尾（松手 / 失触超宽限）：投递中则补 ended，终值按松手去尾。
    private func endSession(now: TimeInterval, into outcome: inout IngestOutcome) {
        if sessionEmitting {
            outcome.events.append(PinchGestureEvent(phase: .ended, signedProgress: trimmedEndProgress(now: now)))
        }
        closeSession(now: now)
    }

    /// ended 终值：取松手前 releaseTrim 时刻之前最近的进度样本（O3-A 去尾）。
    /// 松手是逐指抬起的，最后几帧接触面缩小、张开度往回掉，直接取末帧会让
    /// 本来过半的捏合掉到提交线以下；不用峰值保持——用户最后时刻主动往回收
    /// （想取消）时峰值会把取消误判成提交，去尾取值没有这个偏差。
    /// 历史不足（样本全部落在去尾窗口内）时退回 lastProgress。
    private func trimmedEndProgress(now: TimeInterval) -> CGFloat {
        let cut = now - PinchTouchThresholds.releaseTrim
        if let sample = history.last(where: { $0.t < cut }) {
            return sample.p
        }
        return lastProgress
    }

    /// 外部中止（设备停止 / 重置）：投递中的会话补发 cancelled，供窗口层回退
    /// 半途的跟手状态；无会话或未投递时返回空。
    /// 时钟与 ingest 一致（GestureClock 单调时钟，O8）——否则冷却期按纪元秒
    /// 写入、按开机秒比较，会话在设备重启后被永久卡死。
    func abort(now: TimeInterval = GestureClock.now()) -> [PinchGestureEvent] {
        guard sessionActive else { return [] }
        let events: [PinchGestureEvent] = sessionEmitting
            ? [PinchGestureEvent(phase: .cancelled, signedProgress: lastProgress)]
            : []
        closeSession(now: now)
        return events
    }

    /// 接触点的平均两两间距（≥3 点才有意义）。
    private static func spread(of touching: [TrackedContact]) -> Float? {
        guard touching.count >= 3 else { return nil }
        var sum: Float = 0
        var pairs = 0
        for i in 0..<touching.count {
            for j in (i + 1)..<touching.count {
                let dx = touching[i].x - touching[j].x
                let dy = touching[i].y - touching[j].y
                sum += (dx * dx + dy * dy).squareRoot()
                pairs += 1
            }
        }
        return pairs > 0 ? sum / Float(pairs) : nil
    }
}

// MARK: - 识别 pipeline 与事件邮箱（识别器下沉 MT 线程，O7）

/// 识别 pipeline：识别器 + 事件邮箱 + 空闲帧过滤状态。只在 MT 回调线程访问
/// （MT 对同一设备的回调串行），每次 startDevice 新建——天然完成状态重置，
/// 无需手工清理上一会话的残留。
final class TouchPipeline: @unchecked Sendable {
    let recognizer = PinchTouchRecognizer()
    let mailbox = PinchEventMailbox()
    /// 上次运行识别器的帧接触数（空闲帧过滤决策）。
    var lastForwardedTouching = 0
}

/// MT 线程投递、主线程取走的事件邮箱。主线程积压时连续的 changed 合并为
/// 最新一条——进度是绝对量（非增量），合并不损失信息；主线程不再对积压帧
/// 逐帧重复写 pinchTransitionProgress 产生无效渲染。
final class PinchEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [PinchGestureEvent] = []
    private var drainScheduled = false

    /// 返回 true 表示调用方需要调度一次主线程 drain。
    func post(_ events: [PinchGestureEvent]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        for event in events {
            if event.phase == .changed, let last = pending.last, last.phase == .changed {
                pending[pending.count - 1] = event
            } else {
                pending.append(event)
            }
        }
        guard !pending.isEmpty, !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    func drain() -> [PinchGestureEvent] {
        lock.lock()
        defer { lock.unlock() }
        drainScheduled = false
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}

// MARK: - 系统侧双开抑制开关（识别器会话驱动；MT 线程写触点数 / 识别器与 tap 回调读写）

/// 吞帧窗口由「识别器判定为捏合的会话」驱动，而非原始触点数：
/// - 捏合会话（≥4 触点候选）存活期间逐帧续期，会话结束后保留尾部窗口（覆盖
///   系统侧终帧）——压住真捏合期间系统启动台的开启（双开抑制）；MT 线程见
///   ≥4 触点即先临时武装，抢在主线程会话开启前压制最早帧（三指滑动只有
///   3 触点，永不触发临时武装）；
/// - 位移否决（判定为滑动）当帧立即闭锁放行：macOS 27.2 把三指滑动同样分类成
///   捏合族 type 30，Dock 切空间/切窗口消费的正是这些载荷帧——若按触点数一律
///   吞帧，三指滑动切窗口整体失效（2026-11-21 真机日志实锤后改为会话驱动）；
/// - 闭锁在触点跌破 3（基本抬手）或同批触点过识别门（确认真捏合）时解除。
final class GestureSuppressor: @unchecked Sendable {
    private let lock = NSLock()
    private var armedUntil: TimeInterval = 0
    private var swipeLatched = false

    /// 捏合会话存活：识别器逐帧续期；会话终止后靠本时间戳自然过期出尾部窗口。
    /// 滑动闭锁期间为空操作（保证闭锁后同批触点不再重新吞帧）。
    func arm(now: TimeInterval = GestureClock.now()) {
        lock.lock()
        defer { lock.unlock() }
        armLocked(now: now)
    }

    /// 已持锁的续期（note 在 MT 线程持锁调用，避免重入死锁）。
    private func armLocked(now: TimeInterval) {
        guard !swipeLatched else { return }
        armedUntil = now + PinchTouchThresholds.suppressTail
    }

    /// 位移否决：本批触点判定为滑动，闭锁吞帧直至触点撤离或转为真捏合。
    func latchSwipe() {
        lock.lock()
        defer { lock.unlock() }
        swipeLatched = true
        armedUntil = 0
    }

    /// 同批触点过识别门（确认真捏合）：推翻滑动闭锁，恢复压制。
    func confirmPinch(now: TimeInterval = GestureClock.now()) {
        lock.lock()
        defer { lock.unlock() }
        swipeLatched = false
        armedUntil = now + PinchTouchThresholds.suppressTail
    }

    /// MT 线程每帧上报接触数：
    /// - ≥4 触点：临时武装抑制（抢在主线程会话开启前压制真捏合最早帧；
    ///   三指滑动只有 3 触点，永不触发）；
    /// - <3 触点：解除滑动闭锁（触点撤离）。
    func note(touchingCount: Int, now: TimeInterval = GestureClock.now()) {
        lock.lock()
        defer { lock.unlock() }
        if touchingCount >= PinchTouchThresholds.minContacts {
            armLocked(now: now)
        } else if touchingCount < 3, swipeLatched {
            swipeLatched = false
        }
    }

    /// 是否处于吞帧窗口。
    func isActive(now: TimeInterval = GestureClock.now()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !swipeLatched && now <= armedUntil
    }

    /// 测试辅助：清空全部状态。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        armedUntil = 0
        swipeLatched = false
    }
}

// MARK: - MultitouchSupport 私有框架桥接

/// dlopen 加载 MultitouchSupport（磁盘二进制在 macOS 27.2 被删，dyld 共享缓存仍在）；
/// 加载失败返回 nil，调用方优雅降级为无手势。
@MainActor
final class MultitouchBridge {
    let handle: UnsafeMutableRawPointer
    let isAvailable: @convention(c) () -> Bool
    let createDefault: @convention(c) () -> UnsafeMutableRawPointer?
    /// 返回 CFArrayRef（本机全部 MT 设备）。社区逆向的可选符号：缺失时
    /// 退化为仅默认设备（O10），不影响主流程。
    let createList: (@convention(c) () -> UnsafeMutableRawPointer?)?
    let registerContactFrame: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    let stop: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    let isRunning: @convention(c) (UnsafeMutableRawPointer?) -> Bool

    static let frameworkPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    private static var cached: MultitouchBridge?

    static func load(logger: Logger) -> MultitouchBridge? {
        if let cached { return cached }
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            logger.warning("MultitouchSupport 加载失败（\(String(cString: dlerror()), privacy: .public)），手势入口停用")
            return nil
        }
        func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
        guard
            let isAvailable = sym("MTDeviceIsAvailable"),
            let createDefault = sym("MTDeviceCreateDefault"),
            let registerContactFrame = sym("MTRegisterContactFrameCallback"),
            let start = sym("MTDeviceStart"),
            let stop = sym("MTDeviceStop"),
            let isRunning = sym("MTDeviceIsRunning")
        else {
            logger.warning("MultitouchSupport 符号缺失，手势入口停用")
            return nil
        }
        if MemoryLayout<MTTouch>.stride != 96 {
            logger.error("MTTouch 布局异常 stride=\(MemoryLayout<MTTouch>.stride)，手势入口停用")
            return nil
        }
        let bridge = MultitouchBridge(
            handle: handle,
            isAvailable: unsafeBitCast(isAvailable, to: (@convention(c) () -> Bool).self),
            createDefault: unsafeBitCast(createDefault, to: (@convention(c) () -> UnsafeMutableRawPointer?).self),
            createList: sym("MTDeviceCreateList").map {
                unsafeBitCast($0, to: (@convention(c) () -> UnsafeMutableRawPointer?).self)
            },
            registerContactFrame: unsafeBitCast(registerContactFrame, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self),
            start: unsafeBitCast(start, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32).self),
            stop: unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
            isRunning: unsafeBitCast(isRunning, to: (@convention(c) (UnsafeMutableRawPointer?) -> Bool).self)
        )
        cached = bridge
        return bridge
    }

    private init(
        handle: UnsafeMutableRawPointer,
        isAvailable: @convention(c) () -> Bool,
        createDefault: @convention(c) () -> UnsafeMutableRawPointer?,
        createList: (@convention(c) () -> UnsafeMutableRawPointer?)?,
        registerContactFrame: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
        start: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32,
        stop: @convention(c) (UnsafeMutableRawPointer?) -> Int32,
        isRunning: @convention(c) (UnsafeMutableRawPointer?) -> Bool
    ) {
        self.handle = handle
        self.isAvailable = isAvailable
        self.createDefault = createDefault
        self.createList = createList
        self.registerContactFrame = registerContactFrame
        self.start = start
        self.stop = stop
        self.isRunning = isRunning
    }
}

// MARK: - 触控板手势监视器（公开入口，替代原 CGEventTap 方案）

@MainActor
public final class TrackpadTouchMonitor {

    public var onEvent: ((PinchGestureEvent) -> Void)?

    nonisolated private static let logger = Logger(subsystem: "dev.yunliang.launchx", category: "TouchMonitor")

    /// MT 回调线程在主线程 drain 时读取；startDevice 前设置、stopDevice 后置空。
    nonisolated(unsafe) private static var activeMonitor: TrackpadTouchMonitor?
    /// 识别 pipeline（识别器 + 事件邮箱 + 空闲帧过滤状态），按设备指针的
    /// 地址值索引（O10 多设备：每设备一个识别器，触点不混流；键用 Int 是
    /// 因为 UnsafeMutableRawPointer 不再隐式 Sendable，进不了锁的约束）。
    /// MT 回调线程经锁取快照使用；stopDevice 先 MTDeviceStop 再置空。运行期只读。
    nonisolated private static let pipelinesRef = OSAllocatedUnfairLock<[Int: TouchPipeline]>(initialState: [:])
    /// 捏合会话驱动的抑制窗口（MT 线程写 / tap 回调读）。
    nonisolated static let suppressor = GestureSuppressor()

    /// 空闲帧过滤决策（纯函数，供测试）：运行识别器 = 多触活动（≥2）或触点数
    /// 下降（离板/收尾帧）。单指空闲帧（光标移动、单指滚动）对识别器无意义——
    /// 会话只由 ≥4 触点开启、存活帧必然 ≥4、离板帧触点数必然下降——跳过即可，
    /// 省去 125Hz 的识别开销。
    nonisolated static func shouldForwardMTFrame(touching: Int, lastTouching: Int) -> Bool {
        touching >= 2 || touching < lastTouching
    }

    /// 测试驱动入口（ingestForTesting）专用识别器：与 MT pipeline 的识别器
    /// 互不相干（MT 回调永不触碰它）。
    private let recognizer = PinchTouchRecognizer()
    /// 当前已启动的设备引用（startDevice 填充、stopDevice 清空）。
    private var devices: [UnsafeMutableRawPointer] = []
    /// 本进程内已注册过回调的设备指针地址值：设备引用永不释放（见 startDevice），
    /// 地址恒有效，据此保证重启不叠加重复回调（O10）。
    private var registeredDevices: Set<Int> = []
    private var axChangeObserver: (any NSObjectProtocol)?
    /// 睡眠唤醒 / 会话切换观察者（O4）：MT 设备在系统睡眠、唤醒或切换用户后
    /// 经常不再回调，手势入口静默失灵只能重启 App 恢复；唤醒后延迟重启设备。
    private var wakeObservers: [any NSObjectProtocol] = []

    public private(set) var isEnabled: Bool = false

    // MARK: 实况追踪（LAUNCHX_TOUCH_TRACE=1 启用，/tmp/launchx-touch-trace.log）

    /// 抑制 tap 引用（回调闭包无上下文，经 static 存取以支持超时自恢复）。
    nonisolated(unsafe) private static var suppressorTapRef: CFMachPort?
    /// 抑制 tap 专用线程与其 runloop（stop 时在 tap 线程自身执行清理退出）。
    nonisolated(unsafe) private static var suppressorThreadRef: Thread?
    nonisolated(unsafe) private static var suppressorRunLoopRef: CFRunLoop?

    nonisolated static let traceEnabled = ProcessInfo.processInfo.environment["LAUNCHX_TOUCH_TRACE"] == "1"
    nonisolated private static let traceLogPath = "/tmp/launchx-touch-trace.log"
    nonisolated private static let traceFileHandle: FileHandle? = {
        FileManager.default.createFile(atPath: traceLogPath, contents: nil)
        return FileHandle(forWritingAtPath: traceLogPath)
    }()
    /// MT / tap / 主线程三处并发写同一日志文件：整行加锁保证原子。
    nonisolated private static let traceLock = NSLock()

    nonisolated static func trace(_ line: String) {
        guard traceEnabled else { return }
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        traceLock.lock()
        defer { traceLock.unlock() }
        traceFileHandle?.seekToEndOfFile()
        traceFileHandle?.write(Data("ts=\(ts) \(line)\n".utf8))
    }

    public init() {}

    /// 更新开关并重启监听。
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        restart()
        // 唤醒观察者与热插拔通知只在关闭手势时移除（stop/restart 不移除，
        // 否则下次唤醒/插拔就监听不到了）
        if !enabled {
            removeWakeObservers()
            removeHotPlugWatch()
        }
    }

    public func restart() {
        stop()
        guard isEnabled else { return }
        startDevice()
        startSuppressorTap()
        observePermissionChange()
        observeSystemWake()
        observeDeviceHotPlug()
    }

    public func stop() {
        stopDevice()
        stopSuppressorTap()
        Self.activeMonitor = nil
        if let observer = axChangeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            axChangeObserver = nil
        }
    }

    // MARK: 睡眠唤醒自愈（O4）

    /// 唤醒后设备未必立即就绪：延迟 1s 再重启。观察者常驻（restart 幂等注册），
    /// 仅 setEnabled(false) 时移除。
    private func observeSystemWake() {
        guard wakeObservers.isEmpty else { return }
        let nc = NSWorkspace.shared.notificationCenter  // 必须用 NSWorkspace 的通知中心
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wakeObservers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, self.isEnabled else { return }
                        self.restart()
                    }
                }
            })
        }
    }

    private func removeWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for observer in wakeObservers {
            nc.removeObserver(observer)
        }
        wakeObservers = []
    }

    // MARK: 设备热插拔（O10）

    /// 热插拔通知（IOKit 首配 / 终止）：外接 Magic Trackpad 插入、拔出（或系统
    /// 重新枚举设备）后防抖 1s 重启，重新走 MTDeviceCreateList 拿最新设备集。
    /// 服务类名 AppleMultitouchDevice 经本机 ioreg 确认（2026-11-22）。
    private var hotPlugWatch: (port: IONotificationPortRef, iterators: [io_iterator_t])?
    private var hotPlugRestartWork: DispatchWorkItem?

    private func observeDeviceHotPlug() {
        guard hotPlugWatch == nil else { return }
        // 通知端口挂主 runloop：回调即主线程，可直接做防抖重启。
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            Self.logger.warning("IONotificationPortCreate 失败，热插拔监听不可用")
            return
        }
        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        var iterators: [io_iterator_t] = []
        for interest in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            guard let matching = IOServiceMatching("AppleMultitouchDevice") else { continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, interest, matching, Self.deviceSetChangedCallback, nil, &iterator
            )
            guard result == KERN_SUCCESS else {
                Self.logger.error("IOServiceAddMatchingNotification 失败 kr=\(result)")
                continue
            }
            // 初始 drain 才会武装通知：现存设备（内建板）在此次 drain 中静默跳过，
            // 之后插拔才触发回调。
            Self.drainDeviceIterator(iterator)
            iterators.append(iterator)
        }
        guard !iterators.isEmpty else {
            IONotificationPortDestroy(port)
            return
        }
        hotPlugWatch = (port, iterators)
    }

    private func removeHotPlugWatch() {
        hotPlugRestartWork?.cancel()
        hotPlugRestartWork = nil
        guard let watch = hotPlugWatch else { return }
        for iterator in watch.iterators {
            IOObjectRelease(iterator)
        }
        if let source = IONotificationPortGetRunLoopSource(watch.port)?.takeUnretainedValue() {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        IONotificationPortDestroy(watch.port)
        hotPlugWatch = nil
    }

    /// IOKit 通知回调类型（SDK 未导出 IOServiceNotificationCallback 别名，内联声明）。
    private typealias DeviceSetChangedCallbackC = @convention(c) (UnsafeMutableRawPointer?, io_iterator_t) -> Void

    /// IOKit 通知回调（主 runloop）：drain 本次通知的 service 引用（保持通知
    /// 武装）并防抖 1s 重启设备。
    nonisolated private static let deviceSetChangedCallback: DeviceSetChangedCallbackC = { _, iterator in
        MainActor.assumeIsolated {
            drainDeviceIterator(iterator)
            guard let monitor = TrackpadTouchMonitor.activeMonitor else { return }
            monitor.debounceHotPlugRestart()
        }
    }

    /// 取走并释放迭代器里的 service 引用（IOServiceAddMatchingNotification 的
    /// 武装要求；引用不释放会漏拿后续通知）。
    nonisolated private static func drainDeviceIterator(_ iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            IOObjectRelease(service)
        }
    }

    private func debounceHotPlugRestart() {
        hotPlugRestartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isEnabled else { return }
            Self.logger.info("触控板设备集变化，重启识别器")
            self.restart()
        }
        hotPlugRestartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// 是否已具备「辅助功能」权限（仅抑制系统双开需要，手势本体不需要）。
    nonisolated public static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 手势开关打开时是否为有效唤起入口：原始触点通道无需任何权限。
    nonisolated public static func isEntryAvailable(enabled: Bool) -> Bool {
        enabled
    }

    private func startDevice() {
        guard let bridge = MultitouchBridge.load(logger: Self.logger) else { return }
        // 多设备（O10）：MTDeviceCreateList 枚举全部触控板（内建 + 外接 Magic
        // Trackpad / 合盖外显只用外接板的场景），每设备独立 pipeline；符号缺失
        // 时退化为仅默认设备（原行为，不影响启用）。
        // 所有权约定：设备引用一律不 MTDeviceRelease（社区对 CreateList 的引用
        // 语义无共识，过度释放会野指针；少量常驻泄漏换来指针恒有效——这是
        // registeredDevices 去重可靠的前提），CFRelease 数组同理不执行。
        var devices: [UnsafeMutableRawPointer] = []
        if let createList = bridge.createList {
            if let array = createList() {
                let cfArray = Unmanaged<CFArray>.fromOpaque(array).takeUnretainedValue()
                for i in 0..<CFArrayGetCount(cfArray) {
                    if let device = unsafeBitCast(CFArrayGetValueAtIndex(cfArray, i), to: UnsafeMutableRawPointer?.self) {
                        devices.append(device)
                    }
                }
            }
            if devices.isEmpty {
                Self.logger.info("MTDeviceCreateList 为空：本机无触控板，手势入口不可用")
                return
            }
        } else {
            guard bridge.isAvailable() else {
                Self.logger.warning("本机无内置触控板（MTDeviceIsAvailable=false），手势入口不可用")
                return
            }
            guard let device = bridge.createDefault() else {
                Self.logger.warning("MTDeviceCreateDefault 失败，手势入口不可用")
                return
            }
            devices = [device]
        }

        Self.activeMonitor = self
        // 每次 startDevice 新建 pipeline：识别器/邮箱/空闲帧过滤状态天然重置。
        var pipelines: [Int: TouchPipeline] = [:]
        for device in devices {
            pipelines[Int(bitPattern: device)] = TouchPipeline()
        }
        // 先发布字典再启动设备：启动瞬间的早期帧也能被正确路由。
        Self.publishPipelines(pipelines)
        for device in devices {
            // 注册按设备指针地址去重：设备引用恒有效，重启不会叠加重复回调。
            let deviceKey = Int(bitPattern: device)
            if !registeredDevices.contains(deviceKey) {
                bridge.registerContactFrame(device, unsafeBitCast(Self.contactFrameCallback, to: UnsafeMutableRawPointer.self))
                registeredDevices.insert(deviceKey)
            }
            let status = bridge.start(device, 0)
            if status != 0 {
                Self.logger.error("MTDeviceStart 失败 status=\(status)")
                pipelines.removeValue(forKey: deviceKey)
                Self.publishPipelines(pipelines)
            }
        }
        guard !pipelines.isEmpty else {
            Self.activeMonitor = nil
            Self.pipelinesRef.withLock { $0 = [:] }
            return
        }
        self.devices = devices
        Self.logger.info("原始触点识别器已启动（\(devices.count) 台触控板，CreateList/CreateDefault）")
        Self.trace("DEVICE-STARTED n=\(devices.count)")
    }

    /// 发布 pipeline 字典（@Sendable 锁闭包不能捕获可变局部变量，经 let 参数中转）。
    nonisolated private static func publishPipelines(_ pipelines: [Int: TouchPipeline]) {
        pipelinesRef.withLock { $0 = pipelines }
    }

    private func stopDevice() {
        guard let bridge = MultitouchBridge.load(logger: Self.logger), !devices.isEmpty else { return }
        let pipelines = Self.pipelinesRef.withLock { $0 }
        for device in devices {
            // 先停设备（MTDeviceStop 返回后不再有新回调）；在途回调持有
            // pipeline 快照强引用，不受置空影响（O7 生命周期保护）。
            if bridge.isRunning(device) {
                _ = bridge.stop(device)
            }
            // 半途会话补发 cancelled（O4）：避免窗口层卡在跟手状态。此时主线程
            // 独占 pipeline，abort 与 MT 回调不会并发。
            if let pipeline = pipelines[Int(bitPattern: device)] {
                for event in pipeline.recognizer.abort() {
                    onEvent?(event)
                }
            }
        }
        // registeredDevices 保留：设备引用不释放（指针恒有效），重启后复用注册。
        self.devices = []
        Self.activeMonitor = nil
        Self.pipelinesRef.withLock { $0 = [:] }
        Self.trace("DEVICE-STOPPED")
    }

    // MARK: MT 回调 → MT 线程识别（O7）→ 邮箱合并投递主线程

    /// MT 接触帧回调（MT 内部线程；无上下文参数，经 static 转交）。
    /// MTTouch 是 Swift 声明的布局结构，无法出现在 @convention(c) 签名里，
    /// 因此以 UnsafeRawPointer 按偏移解读（布局经本机探针验证）。
    private static let contactFrameCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void = { device, touches, count, _, _ in
        guard let device, let touches, count > 0 else { return }
        // 第一遍只数接触数：单指空闲帧在此短路（不构建样本、不跑识别器）
        var touching = 0
        for i in 0..<Int(count) {
            let state = touches.advanced(by: i * MemoryLayout<MTTouch>.stride).load(fromByteOffset: 20, as: Int32.self)
            if state == 3 || state == 4 { touching += 1 }
        }
        suppressor.note(touchingCount: touching)
        // 按设备指针取 pipeline（O10 多设备路由）；锁内取一次快照后使用：
        // stopDevice 先 MTDeviceStop 再置空引用，且 pipeline 是 class——快照
        // 持有的强引用保证回调期间不会被释放。
        let deviceKey = Int(bitPattern: device)  // 键在锁外换算（指针不进 @Sendable 闭包）
        guard let pipeline = pipelinesRef.withLock({ $0[deviceKey] }) else { return }
        let forward = shouldForwardMTFrame(touching: touching, lastTouching: pipeline.lastForwardedTouching)
        pipeline.lastForwardedTouching = touching
        guard forward || traceEnabled else { return }
        var samples: [TouchSample] = []
        samples.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let base = touches.advanced(by: i * MemoryLayout<MTTouch>.stride)
            samples.append(TouchSample(
                id: base.load(fromByteOffset: 16, as: Int32.self),
                state: base.load(fromByteOffset: 20, as: Int32.self),
                x: base.load(fromByteOffset: 32, as: Float.self),
                y: base.load(fromByteOffset: 36, as: Float.self)
            ))
        }
        if traceEnabled {
            let summary = samples.map { "\($0.id):st\($0.state):(\(String(format: "%.2f", $0.x)),\(String(format: "%.2f", $0.y)))" }.joined(separator: " ")
            let sup = suppressor.isActive() ? 1 : 0
            trace("FRAME n=\(count) touching=\(touching) sup=\(sup) fwd=\(forward ? 1 : 0) \(summary)")
        }
        guard forward else { return }

        // 识别器在 MT 回调线程同步运行：吞帧决策链（滑动否决 → 放行）不再等
        // 主线程处理完这一帧——主线程拥塞（翻页动画、首次展开渲染、壁纸捕获
        // 回调）时，积压窗口内的 type 30 帧不再被误吞，四指滑动切空间不迟钝。
        // 事件经邮箱合并后异步投递：主线程积压时连续 changed 只保留最新一条
        // （进度是绝对量，合并不损失信息），不逐帧重复写进度产生无效渲染。
        let now = GestureClock.now()
        let outcome = pipeline.recognizer.ingest(samples, now: now)
        applySuppression(outcome, now: now)
        if pipeline.mailbox.post(outcome.events) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let monitor = TrackpadTouchMonitor.activeMonitor else { return }
                    for event in pipeline.mailbox.drain() {
                        monitor.onEvent?(event)
                    }
                }
            }
        }
    }

    /// 抑制决策与 trace（识别器会话驱动，MT 回调线程与测试入口共用）：
    /// 判定为滑动当帧闭锁放行（切窗口载荷帧不许吞），确认真捏合后恢复压制
    /// （压系统启动台），会话存活期间逐帧续期。
    nonisolated private static func applySuppression(_ outcome: IngestOutcome, now: TimeInterval) {
        if outcome.vetoed {
            suppressor.latchSwipe()
            trace("LATCH-SWIPE")
        } else if outcome.pinchConfirmed {
            suppressor.confirmPinch(now: now)
            trace("CONFIRM-PINCH")
        }
        if outcome.sessionActive {
            suppressor.arm(now: now)
        }
        if traceEnabled, !outcome.events.isEmpty {
            trace(outcome.events.map { "EV \($0.phase) p=\(String(format: "%.2f", $0.signedProgress))" }.joined(separator: " | "))
        }
    }

    /// 测试直接驱动的同步入口（主线程调用）：与 MT 回调执行完全相同的识别 +
    /// 抑制路径，事件直接交给 onEvent（不经邮箱合并与线程跳转，便于断言）。
    @discardableResult
    func ingestForTesting(_ samples: [TouchSample], now: TimeInterval) -> IngestOutcome {
        let outcome = recognizer.ingest(samples, now: now)
        Self.applySuppression(outcome, now: now)
        for event in outcome.events {
            onEvent?(event)
        }
        return outcome
    }

    // MARK: 系统侧双开抑制 tap（可选：需辅助功能权限）

    private func startSuppressorTap() {
        guard Self.hasPermission else {
            Self.logger.info("无辅助功能权限：手势可用，但不抑制系统启动台手势（可能双开）")
            return
        }
        guard Self.suppressorThreadRef == nil else { return }
        // 只监听 type 30（捏合族载荷帧）：吞帧条件由识别器会话驱动（捏合会话存活
        // +尾部吞帧；位移否决判定的滑动当帧闭锁放行，三指滑动切窗口不受影响）；
        // 双指缩放（2 触点）永不构成会话、永不吞帧；平移类（type 29/kind 32）不经此 tap。
        //
        // tap 创建与运行全部在专用线程完成：吞帧决策不被主线程 UI 阻塞
        // （翻页动画期间主 runloop 拥塞会让 type 30 帧的吞/放排队滞后）。
        // 回调只读线程安全的 GestureSuppressor，无主线程依赖。
        let thread = Thread {
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: 1 << 30,
                callback: Self.suppressTapCallback,
                userInfo: nil
            ) else {
                Self.suppressorThreadRef = nil  // 创建失败：允许授权变化后重试
                Self.logger.warning("抑制 tap 创建失败（缺辅助功能权限）")
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            let runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            Self.suppressorTapRef = tap
            Self.suppressorRunLoopRef = runLoop
            Self.logger.info("双开抑制 tap 已创建（type 30，捏合会话窗口内吞帧，专用线程）")
            Self.trace("SUPPRESSOR-TAP-CREATED")
            CFRunLoopRun()  // 常驻；stop 经 performBlock + CFRunLoopStop 退出
        }
        thread.name = "dev.yunliang.launchx.suppressor-tap"
        Self.suppressorThreadRef = thread
        thread.start()
    }

    private func stopSuppressorTap() {
        guard let runLoop = Self.suppressorRunLoopRef else { return }
        Self.suppressorRunLoopRef = nil
        Self.suppressorThreadRef = nil
        // 清理在 tap 线程自身执行（失效 tap → 停 runloop → 线程退出）
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            if let tap = Self.suppressorTapRef {
                CFMachPortInvalidate(tap)
                Self.suppressorTapRef = nil
            }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    nonisolated private static let suppressTapCallback: CGEventTapCallBack = { _, type, event, _ in
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue
            || type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            // 系统因超时/用户输入停用 tap 后就地恢复（与旧方案同款自愈）。
            if let tap = suppressorTapRef {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if type.rawValue == 30, suppressor.isActive() {
            trace("SUPPRESS type=30")
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: 辅助功能授权变化（授权后重建抑制 tap）

    private func observePermissionChange() {
        guard axChangeObserver == nil else { return }
        axChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.stopSuppressorTap()
                self.startSuppressorTap()
            }
        }
    }
}
