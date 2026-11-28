import Foundation
import LaunchXCore

// MARK: - 测试工具

public func makeApp(
    _ id: String,
    name: String? = nil,
    bundleName: String? = nil,
    addedAt: Date = Date(timeIntervalSince1970: 1000),
    lastOpenedAt: Date? = nil,
    launchCount: Int = 0,
    hidden: Bool = false,
    bundleId: String? = nil
) -> AppRecord {
    AppRecord(
        id: id,
        name: name ?? id,
        bundleName: bundleName ?? name ?? id,
        bundleId: bundleId ?? id,
        version: "1.0",
        path: "/Applications/\(id).app",
        category: nil,
        hidden: hidden,
        isAlias: false,
        addedAt: addedAt,
        lastOpenedAt: lastOpenedAt,
        launchCount: launchCount,
        isNew: false
    )
}

public func register(_ apps: [AppRecord], into layout: inout LayoutSnapshot) {
    for app in apps {
        layout.apps[app.id] = app
    }
}
