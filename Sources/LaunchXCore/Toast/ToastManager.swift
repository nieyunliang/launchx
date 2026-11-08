import Foundation
import Observation

/// Toast 项。
public struct ToastItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case info
        case success
        case error
    }

    public let id: UUID
    public let kind: Kind
    public let message: String
    /// 自动消失时间；nil 表示常驻（需手动关闭）。
    public let duration: TimeInterval?

    public init(id: UUID = UUID(), kind: Kind, message: String, duration: TimeInterval? = 3.0) {
        self.id = id
        self.kind = kind
        self.message = message
        self.duration = duration
    }
}

/// Toast 通知中心（面板底部悬浮队列）。
@MainActor
@Observable
public final class ToastManager {

    public static let shared = ToastManager()

    /// 当前展示中的 Toast 队列（最多 3 条）。
    public private(set) var items: [ToastItem] = []

    private var dismissalTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func show(_ kind: ToastItem.Kind, _ message: String, duration: TimeInterval? = 3.0) {
        let item = ToastItem(kind: kind, message: message, duration: duration)
        items.append(item)
        if items.count > 3 {
            dismiss(id: items.first!.id)
        }
        guard let duration else { return }
        let id = item.id
        dismissalTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    public func dismiss(id: UUID) {
        dismissalTasks[id]?.cancel()
        dismissalTasks[id] = nil
        items.removeAll { $0.id == id }
    }

    public func dismissAll() {
        for id in dismissalTasks.keys {
            dismissalTasks[id]?.cancel()
        }
        dismissalTasks.removeAll()
        items.removeAll()
    }
}

/// 便捷入口。
public extension ToastManager {
    func info(_ message: String) { show(.info, message) }
    func success(_ message: String) { show(.success, message) }
    func error(_ message: String) { show(.error, message, duration: 5.0) }
}
