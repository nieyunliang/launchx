// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "LaunchX",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LaunchXCore", targets: ["LaunchXCore"]),
    ],
    targets: [
        // 全部逻辑模块（可被测试 import）
        .target(
            name: "LaunchXCore",
            path: "Sources/LaunchXCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 可执行入口（仅 main.swift，薄壳）
        .executableTarget(
            name: "LaunchX",
            dependencies: ["LaunchXCore"],
            path: "Sources/LaunchX",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 测试共用夹具（makeApp 等）
        .target(
            name: "LaunchXTestSupport",
            dependencies: ["LaunchXCore"],
            path: "Tests/LaunchXTestSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 测试按领域拆分，用 scripts/test.sh <组> 只跑相关部分（见脚本说明）
        // 布局 / 存储 / 索引 / 排序 / 整理 / 网格 / 本地化 / Dock / 图标 / 壁纸（纯逻辑）
        .testTarget(
            name: "LaunchXCoreTests",
            dependencies: ["LaunchXCore", "LaunchXTestSupport"],
            path: "Tests/LaunchXCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 翻页 / 手势 / 捏合逻辑（不开窗口）
        .testTarget(
            name: "LaunchXPagingTests",
            dependencies: ["LaunchXCore", "LaunchXTestSupport"],
            path: "Tests/LaunchXPagingTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 卸载器 / 完全磁盘访问
        .testTarget(
            name: "LaunchXUninstallTests",
            dependencies: ["LaunchXCore", "LaunchXTestSupport"],
            path: "Tests/LaunchXUninstallTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // LaunchpadModel 行为 + 历次回归
        .testTarget(
            name: "LaunchXModelTests",
            dependencies: ["LaunchXCore", "LaunchXTestSupport"],
            path: "Tests/LaunchXModelTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 真实窗口挂载根视图（短暂开窗）
        .testTarget(
            name: "LaunchXUITests",
            dependencies: ["LaunchXCore", "LaunchXTestSupport"],
            path: "Tests/LaunchXUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 翻页性能：开窗翻页约 100 秒，需 LAUNCHX_PERF=1 才运行
        .testTarget(
            name: "LaunchXPerfTests",
            dependencies: ["LaunchXCore", "LaunchXTestSupport"],
            path: "Tests/LaunchXPerfTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
