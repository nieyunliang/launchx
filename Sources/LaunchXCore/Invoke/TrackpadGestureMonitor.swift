import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

/// 触控板捏合手势监听：
/// - 主通道：CGEventTap（过滤型）监听会话级 magnify 事件。NSEvent 全局监视器按
///   系统设计不投递手势事件（官方文档仅承诺鼠标/键盘/滚轮/tablet 类型），必须走
///   event tap，创建前提是「辅助功能」权限；过滤型回调可返回 nil 吞帧——listen-only
///   只能旁路监听，捏合事件照常流入系统，Dock 会在本应用唤起的同时响应同一捏合
///   打开系统启动台；
/// - 拦截策略：识别前的早期帧仍放行（吞掉全部 magnify 会破坏双指缩放），累计过
///   识别阈值后逐帧输出方向与进度，并吞掉本手势剩余帧直至 ended/cancelled。
///   因早期帧已放行，与 Dock 识别器存在竞态，能否完全压制以真机实测
///   为准（无法压制时的系统侧兜底：defaults write com.apple.dock
///   showLaunchpadGestureEnabled -int 0 && killall Dock）；
/// - macOS 27 实测：真实 magnify 事件在 tap 层以 type 30 到达且带载荷，但私有字段
///   不经 `NSEvent(cgEvent:)` 映射（转换结果 magnification 恒为 0），因此直接读取
///   CGEvent 私有字段：132 = CGGesturePhase（began/changed/ended/cancelled），
///   124 = 本次手势的实时累计放大倍率（张开为正、捏合为负，手势内单调收敛）；
/// - tap 层还有持续的低频 type 29（kCGEventGesture）壳事件（无载荷），直接忽略；
/// - 公共 API 不暴露指头数：实测累计幅度由捏合幅度决定而非指头数，档位阈值为
///   按真实数据（四指捏合累计约 0.09）标定的近似分档，相邻档位存在互串可能；
/// - 双向跟手：张开输出正进度、捏合输出负进度，由调用方分别驱动展开与收起；
/// - 降级通道：无辅助功能权限时 CGEventTap 创建失败，退回本地 NSEvent 监视器——
///   只能收到发往本应用窗口的事件，即面板已显示时可捏合收起，无法捏合唤起；
/// - 监听系统辅助功能授权变化（com.apple.accessibility.api），授权后自动重建 tap。
public enum PinchGestureEventPhase: Sendable {
    case began
    case changed
    case ended
    case cancelled
}

/// 一次识别后的捏合手势帧。`signedProgress` 绝对值范围为 0...1；
/// 正值表示张开（展开启动台），负值表示捏合（收起启动台）。
public struct PinchGestureEvent: Sendable {
    public let phase: PinchGestureEventPhase
    public let signedProgress: CGFloat

    public init(phase: PinchGestureEventPhase, signedProgress: CGFloat) {
        self.phase = phase
        self.signedProgress = signedProgress
    }
}

@MainActor
public final class TrackpadGestureMonitor {

    public var onEvent: ((PinchGestureEvent) -> Void)?

    private static let logger = Logger(subsystem: "dev.yunliang.launchx", category: "GestureMonitor")

    /// 监听的 CG 事件类型：magnify（与 NSEvent.EventType.magnify 同一数值空间）。
    private static let magnifyCGType: UInt32 = UInt32(NSEvent.EventType.magnify.rawValue)

    /// CGEvent 私有字段号（macOS 27 实测标定；不在公开 CGEventField 枚举内）：
    /// - 132：CGGesturePhase（kCGGesturePhaseBegan=1 / Changed=2 / Ended=4 / Cancelled=8 / MayBegin=128）
    /// - 124：本次手势实时累计放大倍率（手势内单调、方向带符号）
    private static let fieldGesturePhase = CGEventField(rawValue: 132)!
    private static let fieldCumulativeMagnification = CGEventField(rawValue: 124)!

    /// 完整手势行程对应的 |实时累计放大倍率|。原 NSEvent 口径的经验值
    /// （0.30-0.75）比真实数据大 3-5 倍，按 macOS 27 实测（四指捏合累计约 0.087）缩放标定。
    private var triggerMagnitude: CGFloat { Self.triggerMagnitude(for: mode) }

    /// 在完整行程的前 20% 开始识别，之前的小幅缩放不受影响；识别后将剩余行程映射为 0...1。
    nonisolated static let recognitionRatio: CGFloat = 0.2

    /// 阈值映射（纯函数，供测试直接验证各档相对关系）。
    nonisolated static func triggerMagnitude(for mode: PinchGesture) -> CGFloat {
        switch mode {
        case .off: return .infinity
        case .threeFinger: return 0.05
        case .fourFinger: return 0.075
        case .fourFiveFinger: return 0.10
        case .fiveFinger: return 0.13
        }
    }

    /// 将识别点之后的累计幅度映射为跟手进度，并限制在 0...1。
    nonisolated static func normalizedProgress(magnitude: CGFloat, threshold: CGFloat) -> CGFloat {
        guard threshold.isFinite, threshold > 0 else { return 0 }
        let recognition = threshold * recognitionRatio
        return min(max((magnitude - recognition) / (threshold - recognition), 0), 1)
    }

    /// 吞帧与事件投递决策（纯函数，供测试验证拦截策略）。
    /// 识别后的 changed/ended/cancelled 均需投递，确保调用方能完成或回退当前过渡。
    nonisolated static func consumeDecision(
        phase: CGGesturePhase,
        magnitude: CGFloat,
        recognitionThreshold: CGFloat,
        intercepting: Bool
    ) -> (consume: Bool, intercepting: Bool, emit: Bool) {
        switch phase {
        case .began, .mayBegin, .none:
            return (false, false, false)
        case .cancelled:
            return (intercepting, false, intercepting)
        case .changed, .ended:
            let active = intercepting || magnitude >= recognitionThreshold
            return (active, active && phase != .ended, active)
        @unknown default:
            return (false, intercepting, false)
        }
    }

    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapContext: TapContext?
    private var fallbackLocalMonitor: Any?
    private var axChangeObserver: (any NSObjectProtocol)?
    private var lastEventAt = Date.distantPast
    /// 识别后对当前手势吞帧拦截至手势结束（阻止事件继续驱动 Dock 的启动台手势）。
    private var intercepting = false
    /// 已投递的最近进度；ended 帧幅度为 0 时沿用，避免错误回退。
    private var signedProgress: CGFloat = 0

    public private(set) var mode: PinchGesture = .off

    public init() {}

    /// 更新模式并重启监听。
    public func setMode(_ newMode: PinchGesture) {
        guard newMode != mode else { return }
        mode = newMode
        restart()
    }

    public func restart() {
        stop()
        guard mode != .off else { return }

        // 权限健康检查：CGEventTap 需要「辅助功能」权限，缺失时弹系统授权引导
        if !Self.hasPermission {
            // 字面量即 kAXTrustedCheckOptionPrompt 的键值（避免 Swift 6 下引用非隔离全局 var）
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            observePermissionChange()
        }

        let context = TapContext(monitor: self)
        tapContext = context

        // 主通道：CGEventTap 过滤型（需辅助功能权限；未授权时创建失败，走本地降级通道）。
        // 必须过滤型而非 listen-only：listen-only 只能旁路监听，无法吞帧，
        // 同一捏合会同步触发 Dock 的启动台手势（系统启动台与本应用同时唤起）。
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << Self.magnifyCGType),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            eventTap = tap
            tapSource = source
            Self.logger.info("手势过滤 tap 已创建（监听 magnify，识别后逐帧跟手并吞帧）")
        } else {
            tapContext = nil
            Self.logger.warning("CGEventTap 创建失败（缺辅助功能权限），降级为本地监视器")
            // 降级：本地监视器仅在本应用窗口为 key 时收到手势（可收起、不能唤起）
            fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleLocalEvent(event)
                }
                return event
            }
        }
    }

    public func stop() {
        if intercepting {
            onEvent?(PinchGestureEvent(phase: .cancelled, signedProgress: signedProgress))
        }
        intercepting = false
        signedProgress = 0
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            tapSource = nil
        }
        tapContext = nil
        if let monitor = fallbackLocalMonitor {
            NSEvent.removeMonitor(monitor)
            fallbackLocalMonitor = nil
        }
        if let observer = axChangeObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            axChangeObserver = nil
        }
    }

    /// 是否已具备「辅助功能」权限（CGEventTap 的创建前提）。
    nonisolated public static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    /// 监听辅助功能授权变化：用户在系统设置授权后自动重建 tap，无需重启应用。
    private func observePermissionChange() {
        guard axChangeObserver == nil else { return }
        axChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode != .off else { return }
                self.restart()
            }
        }
    }

    // MARK: - CGEventTap 回调

    /// CGEventTap 的 userInfo：弱引用监视器，避免 tap 比监视器长寿时悬垂。
    @MainActor
    private final class TapContext {
        fileprivate weak var monitor: TrackpadGestureMonitor?
        init(monitor: TrackpadGestureMonitor) { self.monitor = monitor }
    }

    /// tap 回调（C 函数指针，不能捕获上下文，状态经 userInfo 传递）。
    /// tap source 挂在主 run loop 上，回调固定在主线程执行。
    /// 过滤型语义：返回 nil 即从事件流删除该帧（Dock 等下游监听者收不到），
    /// 返回事件则原样放行。
    private static let tapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
        guard let opaque = userInfo else { return Unmanaged.passUnretained(cgEvent) }
        let context = Unmanaged<TapContext>.fromOpaque(opaque).takeUnretainedValue()
        // assumeIsolated 与回调同线程同步执行；事件引用经裸指针传递，
        // nonisolated(unsafe) 豁免发送检查（此处不跨线程，安全）
        nonisolated(unsafe) let eventPtr = Unmanaged.passUnretained(cgEvent).toOpaque()
        var consume = false
        MainActor.assumeIsolated {
            consume = context.monitor?.handleTapEvent(
                type: type,
                cgEvent: Unmanaged<CGEvent>.fromOpaque(eventPtr).takeUnretainedValue()
            ) ?? false
        }
        if consume { return nil }
        return Unmanaged.passUnretained(cgEvent)
    }

    /// 返回是否吞掉该帧（交给 tap 回调决定放行与否）。
    private func handleTapEvent(type: CGEventType, cgEvent: CGEvent) -> Bool {
        // tap 被系统禁用（回调超时 / 用户操作）后重新启用
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue
            || type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }
        guard type.rawValue == Self.magnifyCGType else { return false }

        let phaseRaw = cgEvent.getIntegerValueField(Self.fieldGesturePhase)
        guard let phase = CGGesturePhase(rawValue: UInt32(clamping: phaseRaw)), phase != .none else {
            Self.logger.debug("magnify 事件无 phase 字段（\(phaseRaw)，忽略）")
            return false
        }
        let cumulative = cgEvent.getDoubleValueField(Self.fieldCumulativeMagnification)
        // 热路径（每手势帧一次）：不做字段枚举/字符串构建等标定期记录。
        return evaluate(phase: phase, cumulative: cumulative)
    }

    /// 降级通道入口（本地 NSEvent，AppKit 原生事件，magnification 为每帧增量，逐帧求和）。
    private func handleLocalEvent(_ event: NSEvent) {
        guard event.type == .magnify else { return }
        // 仅过滤「phase 为空而动量非空」的纯动量事件（抬手后的缩放惯性）
        if event.phase == [] && event.momentumPhase != [] { return }
        let now = Date()
        if event.phase.contains(.began) || now.timeIntervalSince(lastEventAt) > 0.4 {
            if intercepting {
                _ = evaluate(phase: .cancelled, cumulative: accumulatedLocal)
            }
            accumulatedLocal = 0
        }
        lastEventAt = now
        accumulatedLocal += event.magnification

        let phase: CGGesturePhase
        if event.phase.contains(.began) {
            phase = .began
        } else if event.phase.contains(.ended) {
            phase = .ended
        } else if event.phase.contains(.cancelled) {
            phase = .cancelled
        } else if event.phase.contains(.mayBegin) {
            phase = .mayBegin
        } else {
            phase = .changed
        }
        _ = evaluate(phase: phase, cumulative: accumulatedLocal)
    }

    private var accumulatedLocal: CGFloat = 0

    // MARK: - 逐帧跟手

    /// f124 已是手势内实时累计；本地通道则先逐帧求和，再共用同一状态机。
    /// 识别后持续投递进度，手势结束仅投递 ended，由调用方决定完成或回退。
    private func evaluate(phase: CGGesturePhase, cumulative: CGFloat) -> Bool {
        let magnitude = abs(cumulative)
        let wasIntercepting = intercepting
        let decision = Self.consumeDecision(
            phase: phase,
            magnitude: magnitude,
            recognitionThreshold: triggerMagnitude * Self.recognitionRatio,
            intercepting: wasIntercepting
        )
        intercepting = decision.intercepting

        if phase == .began {
            signedProgress = 0
            onEvent?(PinchGestureEvent(phase: .began, signedProgress: 0))
        } else if decision.emit {
            if phase == .changed || magnitude > 0 {
                let progress = Self.normalizedProgress(magnitude: magnitude, threshold: triggerMagnitude)
                let sign: CGFloat = cumulative == 0 ? (signedProgress < 0 ? -1 : 1) : (cumulative < 0 ? -1 : 1)
                signedProgress = sign * progress
            }
            let eventPhase: PinchGestureEventPhase = switch phase {
            case .ended: .ended
            case .cancelled: .cancelled
            default: .changed
            }
            onEvent?(PinchGestureEvent(phase: eventPhase, signedProgress: signedProgress))
            if !wasIntercepting {
                Self.logger.info("捏合手势开始跟手 mode=\(self.mode.rawValue, privacy: .public) 累计=\(magnitude, privacy: .public)")
            }
        }

        if phase == .ended || phase == .cancelled {
            signedProgress = 0
        }
        return decision.consume
    }
}
