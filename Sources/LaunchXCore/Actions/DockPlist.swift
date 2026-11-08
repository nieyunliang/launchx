import Foundation

// MARK: - 错误

public enum DockPlistError: Error, LocalizedError, Equatable {
    /// 解不开 / 结构不对（原数据不受影响）
    case malformedPlist
    /// 序列化写回失败
    case serializationFailed

    public var errorDescription: String? {
        switch self {
        case .malformedPlist:
            return "Dock 配置无法解析，已放弃修改（原配置未受影响）。"
        case .serializationFailed:
            return "Dock 配置写回失败（原配置未受影响）。"
        }
    }
}

// MARK: - 纯函数：Dock 配置变更

/// 对 `com.apple.dock` 导出的 plist 数据做「追加 / 前插 / 移除 file-tile」的纯逻辑，
/// 与 defaults export/import 副作用壳解耦，便于单测。
public enum DockPlist {

    /// 勾选「显示程序坞图标」时的插入位置（0 起）：2 = Dock 应用区第 3 格。
    /// 数组不足该长度时自动落在末尾。要调位置只改这里。
    public static let preferredInsertIndex = 2

    /// 在 dock 配置的 persistent-apps 数组末尾追加一个 file-tile。
    /// 已存在同路径 tile 时原样返回（去重，不重复添加）。
    public static func addFileTile(toDockPlist data: Data, appURL: URL, label: String) throws -> Data {
        if containsFileTile(dockPlist: data, appURL: appURL) {
            return data
        }
        let mutableRoot = try mutableRoot(from: data)
        let appsArray = try persistentApps(in: mutableRoot, createIfMissing: true)
        appsArray.add(fileTile(appURL: appURL, label: label))
        return try serialized(mutableRoot)
    }

    /// 把 appURL 的 file-tile 放到 persistent-apps 的 `preferredInsertIndex`（默认下标 2）。
    /// - 已在目标位置：原样返回（调用方据此跳过写回与 Dock 重载）。
    /// - 尚未固定：插到目标位置（数组不够长时落在末尾）。
    /// - 已固定在其它位置：移动到目标位置，重复 tile 收敛为一个。
    public static func moveFileTileToFront(
        dockPlist data: Data, appURL: URL, label: String
    ) throws -> Data {
        let mutableRoot = try mutableRoot(from: data)
        let appsArray = try persistentApps(in: mutableRoot, createIfMissing: true)
        let indexes = fileTileIndexes(in: appsArray, appURL: appURL)
        // 目标位置按「移除后仍成立」的下标比较；已在目标位置时直接返回，避免无谓的 Dock 重载
        let currentTarget = min(preferredInsertIndex, max(appsArray.count - 1, 0))
        if indexes == [currentTarget] {
            return data
        }
        // 倒序移除，避免下标前移
        for index in indexes.reversed() {
            appsArray.removeObject(at: index)
        }
        let insertIndex = min(preferredInsertIndex, appsArray.count)
        appsArray.insert(fileTile(appURL: appURL, label: label), at: insertIndex)
        return try serialized(mutableRoot)
    }

    /// 从 persistent-apps 移除指向 appURL 的 tile（不存在 / 无该键时原样返回）。
    public static func removeFileTile(dockPlist data: Data, appURL: URL) throws -> Data {
        let mutableRoot = try mutableRoot(from: data)
        guard let appsArray = mutableRoot["persistent-apps"] as? NSMutableArray else {
            if mutableRoot["persistent-apps"] == nil {
                return data
            }
            // 键存在但不是数组：结构异常，防御性失败
            throw DockPlistError.malformedPlist
        }
        let indexes = fileTileIndexes(in: appsArray, appURL: appURL)
        guard !indexes.isEmpty else {
            return data
        }
        for index in indexes.reversed() {
            appsArray.removeObject(at: index)
        }
        return try serialized(mutableRoot)
    }

    /// 是否已含指向 appURL 的 tile（按标准化后的文件路径比较）。
    public static func containsFileTile(dockPlist data: Data, appURL: URL) -> Bool {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
            let apps = root["persistent-apps"] as? [Any] else {
            return false
        }
        let target = appURL.standardizedFileURL.path
        return apps.contains { tilePath($0) == target }
    }

    // MARK: - 内部

    private static func mutableRoot(from data: Data) throws -> NSMutableDictionary {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [.mutableContainersAndLeaves], format: nil
        ) as? NSMutableDictionary else {
            throw DockPlistError.malformedPlist
        }
        return root
    }

    private static func persistentApps(
        in root: NSMutableDictionary, createIfMissing: Bool
    ) throws -> NSMutableArray {
        if let existing = root["persistent-apps"] as? NSMutableArray {
            return existing
        }
        if root["persistent-apps"] == nil, createIfMissing {
            let array = NSMutableArray()
            root["persistent-apps"] = array
            return array
        }
        // 键存在但不是数组：结构异常，防御性失败
        throw DockPlistError.malformedPlist
    }

    private static func serialized(_ root: NSMutableDictionary) throws -> Data {
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: root, format: .xml, options: 0
            )
        } catch {
            throw DockPlistError.serializationFailed
        }
    }

    /// tile 指向的文件路径（无 file-data 的非 file-tile 返回 nil）。
    private static func tilePath(_ tile: Any) -> String? {
        guard let tile = tile as? [String: Any],
              let tileData = tile["tile-data"] as? [String: Any],
              let fileData = tileData["file-data"] as? [String: Any],
              let urlString = fileData["_CFURLString"] as? String,
              let url = URL(string: urlString) else {
            return nil
        }
        return url.standardizedFileURL.path
    }

    private static func fileTileIndexes(in apps: NSArray, appURL: URL) -> [Int] {
        let target = appURL.standardizedFileURL.path
        var indexes: [Int] = []
        for (index, tile) in apps.enumerated() where tilePath(tile) == target {
            indexes.append(index)
        }
        return indexes
    }

    /// 构造 file-tile 元素（目录形 file URL，_CFURLStringType=15）。
    private static func fileTile(appURL: URL, label: String) -> [String: Any] {
        let directoryURL = URL(fileURLWithPath: appURL.standardizedFileURL.path, isDirectory: true)
        return [
            "tile-type": "file-tile",
            "tile-data": [
                "file-data": [
                    "_CFURLString": directoryURL.absoluteString,
                    "_CFURLStringType": 15,
                ],
                "file-label": label,
                "file-type": 32,
            ] as [String: Any],
        ]
    }
}
