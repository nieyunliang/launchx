import AppKit
import Carbon.HIToolbox
import Foundation

// MARK: - 错误

/// 全局快捷键注册错误。
public enum HotKeyError: Error, LocalizedError {
    /// Carbon 注册失败（OSStatus 非 noErr），如组合已在本进程注册（-9878）。
    case registrationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let status):
            return "全局快捷键注册失败（OSStatus \(status)），可能已被其他应用或本应用占用。"
        }
    }
}

// MARK: - Carbon → MainActor 桥

/// Carbon 回调与 MainActor 之间的回调盒子。
///
/// Carbon 热键事件处理器运行在主线程事件循环，但 Swift 6 无法静态证明这一点，
/// 处理器内不允许触碰任何 actor 隔离状态——因此：
/// - 回调经 `@unchecked Sendable` 盒子暂存（内部 NSLock 保护读写）；
/// - `fire()` 只负责入队 `DispatchQueue.main.async`，随后在闭包内
///   `MainActor.assumeIsolated` 回到主 actor 执行 onTrigger。
private final class HotKeyBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor () -> Void)?
    private var handlerInstalled = false

    /// 更新 onTrigger（在 MainActor 的 didSet 中调用）。
    func updateHandler(_ newHandler: (@MainActor () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    /// Carbon 处理器调用：不直接执行回调，统一调度回主线程。
    func fire() {
        lock.lock()
        let currentHandler = handler
        lock.unlock()
        guard let currentHandler else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                currentHandler()
            }
        }
    }

    /// 进程级只安装一次 kEventClassKeyboard/kEventHotKeyPressed 处理器。
    func installEventHandlerIfNeeded() -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !handlerInstalled else { return noErr }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            LaunchXHotKeyEventHandler,
            1,
            &spec,
            nil,
            nil
        )
        if status == noErr { handlerInstalled = true }
        return status
    }
}

/// 回调桥（进程级唯一）。顶层 `@unchecked Sendable` 常量：不参与 actor 隔离推断，
/// 可从任意隔离域（含 C 函数指针处理器与 MainActor）同步读取；并发安全由内部锁保证。
private let quickDeckHotKeyBridge = HotKeyBridge()

/// C 函数指针式事件处理器（不捕获上下文）：只做转发，不触碰 actor 隔离状态。
/// 安装时已用精确的 EventTypeSpec（kEventClassKeyboard + kEventHotKeyPressed）过滤，
/// 到达此处理器的事件必为热键按下，无需再查事件类/种。
private let LaunchXHotKeyEventHandler: EventHandlerUPP = { _, event, _ in
    guard event != nil else { return OSStatus(eventNotHandledErr) }
    quickDeckHotKeyBridge.fire()
    return noErr
}

// MARK: - HotKeyCenter

/// 全局快捷键中心（进程内同一时刻只持有一个热键，注册新键即换绑）。
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    /// Carbon 处理器不捕获上下文，经文件级回调桥（quickDeckHotKeyBridge）转发，
    /// 见类型顶部说明。

    public init() {}

    /// 触发回调（保证主线程）。注册新键前若已有旧键，先注销旧键（换绑）。
    public var onTrigger: (@MainActor () -> Void)? {
        didSet { quickDeckHotKeyBridge.updateHandler(onTrigger) }
    }

    /// 当前生效的快捷键；未注册时为 nil。
    public private(set) var currentSpec: HotKeySpec?

    /// Carbon 热键引用（注册成功的凭证，unregister 时交还）。
    private var hotKeyRef: EventHotKeyRef?

    /// 注册当前快捷键，失败抛 `HotKeyError`。
    ///
    /// 换绑顺序：先注册新键、成功后再注销旧键——注册失败时旧键与 `currentSpec`
    /// 完全不受影响（防御要求"失败保持 currentSpec 不变"）；期间位于同一主线程
    /// 调用内，RunLoop 不会中途分发事件，无两键并存的触发窗口。
    /// 重复注册与 `currentSpec` 相同的组合为幂等 no-op（Carbon 对同进程重复
    /// 组合会返回 eventHotKeyExistsErr）。
    public func register(_ spec: HotKeySpec) throws {
        if hotKeyRef != nil, spec == currentSpec { return }

        // 确保键盘事件处理器已安装（进程级一次）
        let installStatus = quickDeckHotKeyBridge.installEventHandlerIfNeeded()
        guard installStatus == noErr else {
            throw HotKeyError.registrationFailed(installStatus)
        }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: 0x5144_4B43, id: 1)  // 'QDKC'
        let status = RegisterEventHotKey(
            spec.keyCode,
            spec.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let newRef = ref else {
            // 失败：不动现有状态（旧键继续可用，currentSpec 不变）
            throw HotKeyError.registrationFailed(status)
        }

        // 成功：注销旧键（换绑）并提交新键
        if let oldRef = hotKeyRef {
            UnregisterEventHotKey(oldRef)
        }
        hotKeyRef = newRef
        currentSpec = spec
    }

    /// 注销当前热键并清理状态；未注册时为安全 no-op。
    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        currentSpec = nil
    }
}
