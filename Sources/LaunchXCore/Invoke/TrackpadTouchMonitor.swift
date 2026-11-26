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
// - 多设备（O10）：MTDeviceCreateList 枚举内建 + 外接触控板（Magic Mouse 按
//   族 ID / 表面朝向排除），每设备独立识别 pipeline；IOKit 热插拔通知 + 睡眠
//   唤醒自愈触发设备重启，设备引用每次停止时配平释放。
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
    /// 有符号进度的变化速度（进度/秒），只在 ended 上有意义（截止到终值所取
    /// 样本、PinchTouchThresholds.velocityWindow 窗口内的最小二乘斜率）；其余为 0。
    public let velocity: CGFloat

    public init(phase: PinchGestureEventPhase, signedProgress: CGFloat, velocity: CGFloat = 0) {
        self.phase = phase
        self.signedProgress = signedProgress
        self.velocity = velocity
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
    /// 实测（2026-11-21 真机带标签数据）：滑动 0.10~0.21，捏合 0.59~1.52。
    /// 2026-11-24 由 0.40 下调：那批捏合样本是「四指对称收拢」，漏掉了系统
    /// 推荐的「拇指 + 三指」手法里最常见的**拇指主导**捏合（三指基本不动、
    /// 拇指向上收）——平均两两间距里三条指-指间距不变，把拇指的位移稀释一半：
    /// 几何推算 ratio 仅 0.43~0.49，且在过识别门前（拇指要走约 0.10 才攒够
    /// emitFloor）全程暴露在否决下，拇指走弧线 / 手腕轻转的一点横向分量就跌破
    /// 0.40 → 会话被静默否决，用户感知为「偶尔捏了没反应」。取滑动上沿 0.21
    /// 与拇指主导捏合下沿 0.43 的中点。
    static let vetoRatio: Float = 0.32
    /// 张开度累计达到才开始投递进度（识别点，跟手从这里起步）。
    static let emitFloor: Float = 0.05
    /// 完整捏合行程对应的张开度变化（实测真捏合 0.22~0.38，取保守档）。
    static let fullTrip: Float = 0.30
    /// 会话结束后允许新候选的冷却期（防止同批触点立刻重开会话）。
    static let sessionCooldown: TimeInterval = 0.25
    /// 松手终值去尾窗口（≈3 帧，从最后一个进度样本倒推）：只用来**剔除回落**——
    /// 末样本比窗口前的锚点更小（逐指抬起的张开度回落）就取锚点；仍在增长就取
    /// 末样本（窗口中间的冲高不参与，不做峰值保持）。
    /// 2026-11-25 真机 trace：快速捏合整段只有 40~70ms、5~9 帧，松手前进度
    /// 单调上升、没有一例回落；旧实现无条件扔掉最后 24ms，等于砍掉一半行程，
    /// 34 次里有 7 次峰值已过 0.5 却被判成未过半弹回。
    static let releaseTrim: TimeInterval = 0.024
    /// 松手速度估计窗口（≈6 帧最小二乘斜率，截止到终值所取样本，不含去尾剔除的回落帧）。
    static let velocityWindow: TimeInterval = 0.048
    /// 快甩提交：松手速度 ≥ 此值（进度/秒）、方向背离零点、进度 ≥ flingMinProgress
    /// 即按速度方向提交。真机 trace：慢速跟手松手时 0~2.5/s，快速捏合 4.5~9.4/s；
    /// 未过半的快捏（0.35~0.47）全部 ≥ 5.3/s。取 3.0 留出余量。
    static let flingVelocity: CGFloat = 3.0
    static let flingMinProgress: CGFloat = 0.25
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

    struct ProgressSample {
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
            if TrackpadTouchMonitor.traceEnabled {
                TrackpadTouchMonitor.trace(
                    "SESSION-OPEN members=\(activeKey.map(String.init).joined(separator: ",")) baseline=\(String(format: "%.3f", baselineSpread))"
                )
            }
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
                    endSession(now: now, reason: "lift", into: &outcome)
                } else if let since = belowSince, now - since >= PinchTouchThresholds.dropoutGrace {
                    endSession(now: now, reason: "dropout", into: &outcome)
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
            // 诊断「捏了没反应」的首要线索：否决当帧的位移 / 张开度 / 比值。
            if TrackpadTouchMonitor.traceEnabled {
                TrackpadTouchMonitor.trace(String(
                    format: "SESSION-VETO emitting=%d move=%.3f delta=%.3f peak=%.3f ratio=%.2f",
                    sessionEmitting ? 1 : 0, Double(maxFingerMove), Double(spreadDelta), Double(peakAbsDelta), Double(ratio)
                ))
            }
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
    private func endSession(now: TimeInterval, reason: String, into outcome: inout IngestOutcome) {
        if sessionEmitting {
            let (final, velocity) = Self.releaseEstimate(history: history, fallback: lastProgress)
            outcome.events.append(PinchGestureEvent(phase: .ended, signedProgress: final, velocity: velocity))
            if TrackpadTouchMonitor.traceEnabled {
                TrackpadTouchMonitor.trace("SESSION-END reason=\(reason) final=\(String(format: "%.2f", Double(final))) v=\(String(format: "%.2f", Double(velocity))) peak=\(String(format: "%.3f", peakAbsDelta))")
            }
        } else if TrackpadTouchMonitor.traceEnabled {
            // 未过识别门就松手：张开度没攒够 emitFloor（捏得太轻 / 起步太慢）。
            TrackpadTouchMonitor.trace("SESSION-END reason=\(reason) silent peak=\(String(format: "%.3f", peakAbsDelta))")
        }
        closeSession(now: now)
    }

    /// ended 终值与松手速度（O3-A 去尾，只剔回落）。
    ///
    /// 时间基准取**最后一个进度样本**而非会话结束时刻：失触路径要等
    /// dropoutGrace 才收尾，零触点帧还可能停发直到下次落指，按结束时刻倒推
    /// 会让窗口落空、速度归零。
    ///
    /// 终值：锚点 = 末样本前 releaseTrim 之外最近的样本；取「锚点 / 末样本」中
    /// 沿末样本方向幅度更大的一个——
    /// - 逐指抬起造成回落：末样本更小 → 取锚点，过半的捏合不被拖到线下；
    /// - 快速捏合松手前仍在增长：末样本更大 → 取末样本，不砍掉真实行程；
    /// - 窗口内先冲高再回收：中间的冲高不参与（不做峰值保持），取锚点；
    /// - 窗口内过零反向：方向以末样本为准，锚点反号时直接取末样本。
    /// 用户在松手前超过 releaseTrim 主动往回收时，锚点已落在回收段上，
    /// 取消不会被峰值误判成提交。
    ///
    /// 速度：截止到终值所取样本、向前 velocityWindow 内的最小二乘斜率——
    /// 被去尾剔除的回落帧不参与拟合，抬手滑移不会把快甩速度拉低或翻号。
    ///
    /// 历史不足（无样本）时退回 fallback（lastProgress）、速度 0。
    static func releaseEstimate(history: [ProgressSample], fallback: CGFloat) -> (progress: CGFloat, velocity: CGFloat) {
        guard let lastIndex = history.indices.last else { return (fallback, 0) }
        let end = history[lastIndex]
        let cut = end.t - PinchTouchThresholds.releaseTrim
        var pick = lastIndex
        if let anchor = history.lastIndex(where: { $0.t < cut }) {
            let sign: CGFloat = end.p >= 0 ? 1 : -1
            if history[anchor].p * sign > end.p * sign {
                pick = anchor
            }
        }
        return (history[pick].p, slope(of: history[...pick], until: history[pick].t))
    }

    /// 截止 until、向前 velocityWindow 内样本的最小二乘斜率（进度/秒），
    /// 比首尾差分抗单帧抖动。样本不足 2 个返回 0。
    private static func slope(of samples: ArraySlice<ProgressSample>, until: TimeInterval) -> CGFloat {
        let window = samples.filter { $0.t >= until - PinchTouchThresholds.velocityWindow }
        guard window.count >= 2 else { return 0 }
        let n = Double(window.count)
        let meanT = window.reduce(0) { $0 + $1.t } / n
        let meanP = window.reduce(0) { $0 + Double($1.p) } / n
        var num = 0.0
        var den = 0.0
        for sample in window {
            let dt = sample.t - meanT
            num += dt * (Double(sample.p) - meanP)
            den += dt * dt
        }
        return den > 0 ? CGFloat(num / den) : 0
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

    /// 设备停止后的收尾事件（主线程、MTDeviceStop 之后调用）：先关闭邮箱并
    /// 取出尚未投递的积压事件（保持顺序），再接上识别器 abort 的 cancelled。
    /// 回归：旧实现直接 abort 同步投递 cancelled，而邮箱里已调度、尚未 drain 的
    /// `.changed` 会在随后的主线程 drain 里**晚于** cancelled 送达——restart 已把
    /// activeMonitor 重新指回自己，drain 不会被拦下；控制器把这条孤立的
    /// changed 当成新会话开启，之后再无终帧，面板卡在半透明跟手态
    /// （ignoresMouseEvents=true、命中测试关闭）。关闭后邮箱拒收在途回调的
    /// 晚到投递，已调度的 drain 取到空集。
    func shutdownEvents() -> [PinchGestureEvent] {
        mailbox.drainAndClose() + recognizer.abort()
    }
}

/// MT 线程投递、主线程取走的事件邮箱。主线程积压时连续的 changed 合并为
/// 最新一条——进度是绝对量（非增量），合并不损失信息；主线程不再对积压帧
/// 逐帧重复写 pinchTransitionProgress 产生无效渲染。
final class PinchEventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [PinchGestureEvent] = []
    private var drainScheduled = false
    /// 设备停止后关闭：此后 post 一律丢弃（在途回调的晚到投递不再进入主线程）。
    private var closed = false

    /// 返回 true 表示调用方需要调度一次主线程 drain。
    func post(_ events: [PinchGestureEvent]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
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

    /// 取走全部积压事件并关闭邮箱（设备停止收尾用，见 TouchPipeline.shutdownEvents）。
    func drainAndClose() -> [PinchGestureEvent] {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        drainScheduled = false
        defer { pending.removeAll() }
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
    // 以下为可选符号（缺失时相应能力退化，不影响启用）：
    /// 停止设备时注销回调，释放设备前保证不再回调到已释放对象。
    let unregisterContactFrame: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?
    /// 设备族 ID（内建板 109、Magic Mouse 112 等，本机探针 2026-11-23 确认）。
    let getFamilyID: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32)?
    /// 传感器表面尺寸（宽、高；单位为 0.01mm 量级，只用于判断横竖比）。
    let getSensorSurfaceDimensions: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32)?

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
            isRunning: unsafeBitCast(isRunning, to: (@convention(c) (UnsafeMutableRawPointer?) -> Bool).self),
            unregisterContactFrame: sym("MTUnregisterContactFrameCallback").map {
                unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self)
            },
            getFamilyID: sym("MTDeviceGetFamilyID").map {
                unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32).self)
            },
            getSensorSurfaceDimensions: sym("MTDeviceGetSensorSurfaceDimensions").map {
                unsafeBitCast($0, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32).self)
            }
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
        isRunning: @convention(c) (UnsafeMutableRawPointer?) -> Bool,
        unregisterContactFrame: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void)?,
        getFamilyID: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>) -> Int32)?,
        getSensorSurfaceDimensions: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32)?
    ) {
        self.handle = handle
        self.isAvailable = isAvailable
        self.createDefault = createDefault
        self.createList = createList
        self.registerContactFrame = registerContactFrame
        self.start = start
        self.stop = stop
        self.isRunning = isRunning
        self.unregisterContactFrame = unregisterContactFrame
        self.getFamilyID = getFamilyID
        self.getSensorSurfaceDimensions = getSensorSurfaceDimensions
    }

    /// 设备族 ID；符号缺失或调用失败返回 nil。
    func familyID(of device: UnsafeMutableRawPointer) -> Int32? {
        guard let getFamilyID else { return nil }
        var family: Int32 = 0
        return getFamilyID(device, &family) == 0 ? family : nil
    }

    /// 传感器表面（宽, 高）；符号缺失、调用失败或尺寸无效返回 nil。
    func surfaceDimensions(of device: UnsafeMutableRawPointer) -> (width: Int32, height: Int32)? {
        guard let getSensorSurfaceDimensions else { return nil }
        var width: Int32 = 0
        var height: Int32 = 0
        guard getSensorSurfaceDimensions(device, &width, &height) == 0, width > 0, height > 0 else { return nil }
        return (width, height)
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
    /// 当前已启动的设备引用（startDevice 填充、stopDevice 清空）。每个元素都
    /// 持有本对象自己的 +1 引用，stopDevice 注销回调、停止后释放。
    private var devices: [UnsafeMutableRawPointer] = []
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

    /// Magic Mouse 的设备族 ID（本机探针 2026-11-23：Magic Mouse 2 = 112；
    /// 113 为同族备用 ID）。鼠标表面同样是 MT 设备、会出现在 MTDeviceCreateList
    /// 里，握鼠标时手掌 + 手指很容易形成 ≥4 触点。
    nonisolated static let mouseFamilyIDs: Set<Int32> = [112, 113]

    /// 设备是否按触控板处理（纯函数，供测试）。排除两类信号任一命中的设备：
    /// - 族 ID 属于 Magic Mouse；
    /// - 传感器表面竖长（高 > 宽）：所有触控板都是横向表面（本机内建板
    ///   12480×7680），Magic Mouse 是竖向（5152×9056）——族 ID 表覆盖不到的
    ///   新款鼠标靠这一条兜底。
    /// 两项信息都拿不到时按触控板处理（宁可多收一台设备，也不误删触控板）。
    nonisolated static func isTrackpad(familyID: Int32?, surface: (width: Int32, height: Int32)?) -> Bool {
        if let familyID, mouseFamilyIDs.contains(familyID) { return false }
        if let surface, surface.height > surface.width { return false }
        return true
    }

    /// 释放本对象持有的设备 +1 引用（MTDevice 是 CF 类型）。
    private static func releaseDevice(_ device: UnsafeMutableRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(device).release()
    }

    private func startDevice() {
        guard let bridge = MultitouchBridge.load(logger: Self.logger) else { return }
        // 多设备（O10）：MTDeviceCreateList 枚举全部 MT 设备（内建板 + 外接 Magic
        // Trackpad，也包括 Magic Mouse——按 isTrackpad 过滤掉），每设备独立
        // pipeline；符号缺失时退化为仅默认设备。
        // 所有权（本机探针 2026-11-23 实测）：CreateList / CreateDefault 每次调用
        // 都返回**新的**设备对象，遵循 CF Create 规则（数组与默认设备均为调用方
        // +1）。这里对保留下来的每台设备自己 retain 一次，数组随即释放；
        // stopDevice 注销回调、停止后 release，引用计数严格配平——重启（唤醒、
        // 热插拔）不再逐次累积设备对象。
        var candidates: [UnsafeMutableRawPointer] = []
        if let createList = bridge.createList {
            if let array = createList() {
                let cfArray = Unmanaged<CFArray>.fromOpaque(array).takeRetainedValue()
                for i in 0..<CFArrayGetCount(cfArray) {
                    guard let raw = CFArrayGetValueAtIndex(cfArray, i) else { continue }
                    let device = UnsafeMutableRawPointer(mutating: raw)
                    let family = bridge.familyID(of: device)
                    guard Self.isTrackpad(familyID: family, surface: bridge.surfaceDimensions(of: device)) else {
                        Self.logger.info("跳过非触控板 MT 设备（family=\(family ?? -1)）")
                        continue
                    }
                    _ = Unmanaged<AnyObject>.fromOpaque(raw).retain()
                    candidates.append(device)
                }
            }
            if candidates.isEmpty {
                Self.logger.info("未发现触控板（MTDeviceCreateList 过滤后为空），手势入口不可用")
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
            candidates = [device]  // Create 规则：已是本对象的 +1
        }

        Self.activeMonitor = self
        // 每次 startDevice 新建 pipeline：识别器/邮箱/空闲帧过滤状态天然重置。
        var pipelines: [Int: TouchPipeline] = [:]
        for device in candidates {
            pipelines[Int(bitPattern: device)] = TouchPipeline()
        }
        // 先发布字典再启动设备：启动瞬间的早期帧也能被正确路由。
        Self.publishPipelines(pipelines)
        let callback = unsafeBitCast(Self.contactFrameCallback, to: UnsafeMutableRawPointer.self)
        var started: [UnsafeMutableRawPointer] = []
        for device in candidates {
            // 设备对象每次都是新建的，无需去重：每次注册一次、停止时注销一次。
            bridge.registerContactFrame(device, callback)
            let status = bridge.start(device, 0)
            if status == 0 {
                started.append(device)
            } else {
                Self.logger.error("MTDeviceStart 失败 status=\(status)")
                bridge.unregisterContactFrame?(device, callback)
                pipelines.removeValue(forKey: Int(bitPattern: device))
                Self.publishPipelines(pipelines)
                Self.releaseDevice(device)
            }
        }
        guard !started.isEmpty else {
            Self.activeMonitor = nil
            Self.pipelinesRef.withLock { $0 = [:] }
            return
        }
        self.devices = started
        Self.logger.info("原始触点识别器已启动（\(started.count) 台触控板，CreateList/CreateDefault）")
        Self.trace("DEVICE-STARTED n=\(started.count)")
    }

    /// 发布 pipeline 字典（@Sendable 锁闭包不能捕获可变局部变量，经 let 参数中转）。
    nonisolated private static func publishPipelines(_ pipelines: [Int: TouchPipeline]) {
        pipelinesRef.withLock { $0 = pipelines }
    }

    private func stopDevice() {
        guard let bridge = MultitouchBridge.load(logger: Self.logger), !devices.isEmpty else { return }
        let pipelines = Self.pipelinesRef.withLock { $0 }
        let callback = unsafeBitCast(Self.contactFrameCallback, to: UnsafeMutableRawPointer.self)
        for device in devices {
            // 先注销回调、再停设备（MTDeviceStop 返回后不再有新回调）；在途回调
            // 持有 pipeline 快照强引用，不受置空影响（O7 生命周期保护）。
            bridge.unregisterContactFrame?(device, callback)
            if bridge.isRunning(device) {
                _ = bridge.stop(device)
            }
            // 收尾事件（O4）：邮箱积压事件按序投递后关闭邮箱，再补发半途会话的
            // cancelled——避免窗口层卡在跟手状态，也避免晚到的 changed 在
            // cancelled 之后重开会话。此时主线程独占 pipeline，不与 MT 回调并发。
            if let pipeline = pipelines[Int(bitPattern: device)] {
                for event in pipeline.shutdownEvents() {
                    onEvent?(event)
                }
            }
            Self.releaseDevice(device)
        }
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
        // 在主线程就地取走「本次要拆的」tap（tap 线程先写 tapRef 再写 runLoopRef，
        // 拿得到 runLoop 就一定拿得到对应的 tap）。
        let tap = Self.suppressorTapRef
        Self.suppressorTapRef = nil
        Self.suppressorRunLoopRef = nil
        Self.suppressorThreadRef = nil
        Self.scheduleTapTeardown(tap: tap, on: runLoop)
    }

    /// 清理在 tap 线程自身执行（失效 tap → 停 runloop → 线程退出）。
    /// 必须 nonisolated：若闭包在 @MainActor 方法内直接构造，会继承主线程隔离，
    /// Swift 6 运行时在 tap 线程执行时做执行器校验并触发 EXC_BREAKPOINT 崩溃。
    ///
    /// 回归：旧实现在 teardown 块里读共享的 `suppressorTapRef`。stop 后紧跟 start
    /// （辅助功能通知连发、唤醒、热插拔都走这条路）时，新线程可能抢先把新 tap
    /// 写进 ref，旧线程的 teardown 随后**失效了新 tap**、旧 tap 却留在已停的
    /// runloop 上——双开抑制整段失效（系统启动台手势与本手势同时响应），旧 tap
    /// 无人服务还会拖慢输入直到被系统超时停用。现在拆除对象在 stop 时就固定。
    nonisolated private static func scheduleTapTeardown(tap: CFMachPort?, on runLoop: CFRunLoop) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
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
