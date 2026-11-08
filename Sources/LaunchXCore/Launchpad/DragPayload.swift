import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 一次拖拽会话的载荷：会话 id + 拖拽的应用 id 列表。
/// 会话 id 在每次 `DragObserver.beginDrag` 时生成，用来拒绝「上一次拖拽的陈旧载荷 / 外部同名文本」。
public struct DragSessionPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sessionID: UUID
    public let appIDs: [String]

    public init(
        version: Int = DragSessionPayload.currentVersion,
        sessionID: UUID,
        appIDs: [String]
    ) {
        self.version = version
        self.sessionID = sessionID
        self.appIDs = appIDs
    }
}

/// 拖拽载荷工具：会话 id + 应用 id 列表序列化为 JSON 文本传输。
///
/// 之所以不再用「id1\nid2」纯文本：`UTType.plainText` 会接收任何外部拖入的文本，
/// 旧版仅凭 DragObserver 的进程内状态判断来源，拖拽取消后 2 分钟内拖入普通文本
/// 也可能被当成拖拽而移动应用。JSON 载荷 + 会话 UUID 校验可以彻底拒绝非本会话来源。
public enum DragPayload {

    public static let type = UTType.plainText

    /// 生成拖拽载荷文本（JSON）。
    public static func encode(_ appIDs: [String], sessionID: UUID) -> String {
        let payload = DragSessionPayload(sessionID: sessionID, appIDs: appIDs)
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 生成拖拽载荷（供 `.onDrag` 返回）。
    public static func provider(_ appIDs: [String], sessionID: UUID) -> NSItemProvider {
        NSItemProvider(object: encode(appIDs, sessionID: sessionID) as NSString)
    }

    /// 解析载荷文本；外部普通文本、旧格式、未知版本一律返回 nil。
    public static func decode(_ raw: String) -> DragSessionPayload? {
        guard let data = raw.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DragSessionPayload.self, from: data),
              payload.version == DragSessionPayload.currentVersion,
              !payload.appIDs.isEmpty else {
            return nil
        }
        return payload
    }

    /// 从 drop 的 item provider 异步读取并解析载荷。
    /// - Returns: 是否存在可读的 provider；解析结果通过 completion 回到主线程。
    @discardableResult
    public static func load(
        from info: DropInfo,
        completion: @escaping @MainActor @Sendable (DragSessionPayload?) -> Void
    ) -> Bool {
        guard let provider = info.itemProviders(for: [type]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            let raw = (object as? NSString).map { $0 as String }
            let payload = raw.flatMap(decode)
            Task { @MainActor in
                completion(payload)
            }
        }
        return true
    }
}
