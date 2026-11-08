// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "LaunchX",
    platforms: [.macOS(.v27)],
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
        .testTarget(
            name: "LaunchXTests",
            dependencies: ["LaunchXCore"],
            path: "Tests/LaunchXTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
