import AppKit
import CoreGraphics
import Darwin
import Foundation
import OSLog

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
// - 效率：单指空闲帧（光标移动/单指滚动）不进主线程，125Hz 只在多触活动或
//   触点数变化时转发；抑制 tap 跑在专用线程，吞帧决策不被主线程 UI 阻塞。
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
    /// 抑制窗口续期步长 = 会话结束尾部：最后一段会话帧之后仍继续吞帧的时长
    /// （覆盖系统侧终帧；会话存活期间由识别器逐帧续期）。
    static let suppressTail: TimeInterval = 0.10
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

@MainActor
final class PinchTouchRecognizer {

    private struct TrackedContact {
        var id: Int32
        var x: Float
        var y: Float
        var originX: Float
        var originY: Float
        var state: Int32
    }

    private var contacts: [Int32: TrackedContact] = [:]
    private var sessionActive = false
    private var sessionEmitting = false
    private var baselineSpread: Float = 0
    private var lastProgress: CGFloat = 0
    private var cooldownUntil: TimeInterval = 0

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
            baselineSpread = Self.spread(of: touching) ?? 0
            lastProgress = 0
        }

        // 4. 会话收尾：接触数跌破候选下限 = 手指离板（用户松手意图）
        if sessionActive, touching.count < PinchTouchThresholds.minContacts {
            if sessionEmitting {
                outcome.events.append(PinchGestureEvent(phase: .ended, signedProgress: lastProgress))
            }
            closeSession(now: now)
        }

        outcome.sessionActive = sessionActive
        return outcome
    }

    /// 会话进行中的一帧。产生的手势事件与否决/确认标记写入 outcome。
    private func advanceSession(touching: [TrackedContact], now: TimeInterval, into outcome: inout IngestOutcome) {
        // 接触数跌破候选下限：交给收尾逻辑按「松手」落位，不走否决
        //（此时 spread 不可靠，且抬手滑移是正常现象，不应触发否决）。
        guard touching.count >= PinchTouchThresholds.minContacts else { return }

        // 每指位移：当前接触者相对各自落点的最大位移
        var maxFingerMove: Float = 0
        for c in touching {
            let dx = c.x - c.originX
            let dy = c.y - c.originY
            maxFingerMove = max(maxFingerMove, (dx * dx + dy * dy).squareRoot())
        }

        // 张开度变化：当前平均两两间距 - 会话起点间距
        let currentSpread = Self.spread(of: touching)
        let spreadDelta = (currentSpread ?? baselineSpread) - baselineSpread

        // 位移否决：手指大幅平移而跨度几乎不变 = 滑动（LaunchOS movementThreshold 同款）
        let ratio = spreadDelta.magnitude / max(maxFingerMove, 0.0001)
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
        }
    }

    private func closeSession(now: TimeInterval) {
        sessionActive = false
        sessionEmitting = false
        lastProgress = 0
        cooldownUntil = now + PinchTouchThresholds.sessionCooldown
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
    func arm(now: TimeInterval = Date().timeIntervalSince1970) {
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
    func confirmPinch(now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock()
        defer { lock.unlock() }
        swipeLatched = false
        armedUntil = now + PinchTouchThresholds.suppressTail
    }

    /// MT 线程每帧上报接触数：
    /// - ≥4 触点：临时武装抑制（抢在主线程会话开启前压制真捏合最早帧；
    ///   三指滑动只有 3 触点，永不触发）；
    /// - <3 触点：解除滑动闭锁（触点撤离）。
    func note(touchingCount: Int, now: TimeInterval = Date().timeIntervalSince1970) {
        lock.lock()
        defer { lock.unlock() }
        if touchingCount >= PinchTouchThresholds.minContacts {
            armLocked(now: now)
        } else if touchingCount < 3, swipeLatched {
            swipeLatched = false
        }
    }

    /// 是否处于吞帧窗口。
    func isActive(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
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
    let registerContactFrame: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    let start: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    let stop: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    let release: @convention(c) (UnsafeMutableRawPointer?) -> Void
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
            let release = sym("MTDeviceRelease"),
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
            registerContactFrame: unsafeBitCast(registerContactFrame, to: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void).self),
            start: unsafeBitCast(start, to: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32).self),
            stop: unsafeBitCast(stop, to: (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
            release: unsafeBitCast(release, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
            isRunning: unsafeBitCast(isRunning, to: (@convention(c) (UnsafeMutableRawPointer?) -> Bool).self)
        )
        cached = bridge
        return bridge
    }

    private init(
        handle: UnsafeMutableRawPointer,
        isAvailable: @convention(c) () -> Bool,
        createDefault: @convention(c) () -> UnsafeMutableRawPointer?,
        registerContactFrame: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void,
        start: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32,
        stop: @convention(c) (UnsafeMutableRawPointer?) -> Int32,
        release: @convention(c) (UnsafeMutableRawPointer?) -> Void,
        isRunning: @convention(c) (UnsafeMutableRawPointer?) -> Bool
    ) {
        self.handle = handle
        self.isAvailable = isAvailable
        self.createDefault = createDefault
        self.registerContactFrame = registerContactFrame
        self.start = start
        self.stop = stop
        self.release = release
        self.isRunning = isRunning
    }
}

// MARK: - 触控板手势监视器（公开入口，替代原 CGEventTap 方案）

@MainActor
public final class TrackpadTouchMonitor {

    public var onEvent: ((PinchGestureEvent) -> Void)?

    nonisolated private static let logger = Logger(subsystem: "dev.yunliang.launchx", category: "TouchMonitor")

    /// MT 回调线程读取；startDevice 前设置、stopDevice 后置空（回调期间恒有效）。
    nonisolated(unsafe) private static var activeMonitor: TrackpadTouchMonitor?
    /// MT 回调线程读写的上次转发帧接触数（回调串行；仅供空闲帧过滤决策）。
    nonisolated(unsafe) private static var lastForwardedTouching = 0
    /// ≥3 触点抑制窗口（MT 线程写 / tap 回调读）。
    nonisolated static let suppressor = GestureSuppressor()

    /// 空闲帧过滤决策（纯函数，供测试）：转发 = 多触活动（≥2）或触点数下降
    /// （离板/收尾帧）。单指空闲帧（光标移动、单指滚动）对识别器无意义——
    /// 会话只由 ≥4 触点开启、存活帧必然 ≥4、离板帧触点数必然下降——跳过
    /// 即可，省去 125Hz 的主线程 hop。
    nonisolated static func shouldForwardMTFrame(touching: Int, lastTouching: Int) -> Bool {
        touching >= 2 || touching < lastTouching
    }

    private let recognizer = PinchTouchRecognizer()
    private var device: UnsafeMutableRawPointer?
    private var axChangeObserver: (any NSObjectProtocol)?

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
    }

    public func restart() {
        stop()
        guard isEnabled else { return }
        startDevice()
        startSuppressorTap()
        observePermissionChange()
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
        guard bridge.isAvailable() else {
            Self.logger.warning("本机无内置触控板（MTDeviceIsAvailable=false），手势入口不可用")
            return
        }
        guard let device = bridge.createDefault() else {
            Self.logger.warning("MTDeviceCreateDefault 失败，手势入口不可用")
            return
        }
        Self.activeMonitor = self
        bridge.registerContactFrame(device, unsafeBitCast(Self.contactFrameCallback, to: UnsafeMutableRawPointer.self))
        let status = bridge.start(device, 0)
        if status != 0 {
            Self.logger.error("MTDeviceStart 失败 status=\(status)")
            Self.activeMonitor = nil
            return
        }
        self.device = device
        Self.logger.info("原始触点识别器已启动（MTDeviceCreateDefault + contact frame 回调）")
        Self.trace("DEVICE-STARTED")
    }

    private func stopDevice() {
        guard let bridge = MultitouchBridge.load(logger: Self.logger), let device else { return }
        Self.activeMonitor = nil
        Self.lastForwardedTouching = 0
        if bridge.isRunning(device) {
            _ = bridge.stop(device)
        }
        bridge.release(device)
        self.device = nil
        Self.trace("DEVICE-STOPPED")
    }

    // MARK: MT 回调 → 主线程识别

    /// MT 接触帧回调（MT 内部线程；无上下文参数，经 static 转交）。
    /// MTTouch 是 Swift 声明的布局结构，无法出现在 @convention(c) 签名里，
    /// 因此以 UnsafeRawPointer 按偏移解读（布局经本机探针验证）。
    private static let contactFrameCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int32, Double, Int32) -> Void = { _, touches, count, _, _ in
        guard let touches, count > 0 else { return }
        // 第一遍只数接触数：单指空闲帧在此短路（不构建样本、不进主线程）
        var touching = 0
        for i in 0..<Int(count) {
            let state = touches.advanced(by: i * MemoryLayout<MTTouch>.stride).load(fromByteOffset: 20, as: Int32.self)
            if state == 3 || state == 4 { touching += 1 }
        }
        suppressor.note(touchingCount: touching)
        let forward = shouldForwardMTFrame(touching: touching, lastTouching: lastForwardedTouching)
        lastForwardedTouching = touching
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
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let monitor = TrackpadTouchMonitor.activeMonitor else { return }
                monitor.ingest(samples)
            }
        }
    }

    /// 主线程：喂识别器，转发事件并驱动系统侧抑制窗口。
    /// 抑制由识别器会话驱动：判定为滑动当帧闭锁放行（切窗口载荷帧不许吞），
    /// 确认真捏合后恢复压制（压系统启动台），会话存活期间逐帧续期。
    /// 返回本帧识别产出（测试直接驱动时用于断言）。
    @discardableResult
    func ingest(_ samples: [TouchSample], now: TimeInterval = Date().timeIntervalSince1970) -> IngestOutcome {
        let outcome = recognizer.ingest(samples, now: now)
        if outcome.vetoed {
            Self.suppressor.latchSwipe()
            Self.trace("LATCH-SWIPE")
        } else if outcome.pinchConfirmed {
            Self.suppressor.confirmPinch(now: now)
            Self.trace("CONFIRM-PINCH")
        }
        if outcome.sessionActive {
            Self.suppressor.arm(now: now)
        }
        if Self.traceEnabled, !outcome.events.isEmpty {
            Self.trace(outcome.events.map { "EV \($0.phase) p=\(String(format: "%.2f", $0.signedProgress))" }.joined(separator: " | "))
        }
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
