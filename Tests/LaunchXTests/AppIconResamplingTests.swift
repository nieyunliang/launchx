import XCTest
import AppKit
@testable import LaunchXCore

/// 图标缓存重采样：位图必须缩到位图级显示尺寸（≤130pt × 2x），
/// 否则整页 1024px 大纹理每帧采样会拖垮翻页帧率（性能回归防线）。
@MainActor
final class AppIconResamplingTests: XCTestCase {

    private static let sampleAppPath = "/System/Applications/Calculator.app"

    private func sampleIconPath() throws -> String {
        guard FileManager.default.fileExists(atPath: Self.sampleAppPath) else {
            throw XCTSkip("样例应用不存在：\(Self.sampleAppPath)")
        }
        return Self.sampleAppPath
    }

    private func largestBitmapPixels(of image: NSImage) -> Int {
        image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .map { max($0.pixelsWide, $0.pixelsHigh) }
            .max() ?? 0
    }

    /// 缓存图标位图不超过 2x 显示像素（130pt → 260px），点尺寸保持原比例。
    func testCachedIconBitmapIsDownsampledToDisplayPixels() throws {
        let path = try sampleIconPath()
        let icon = AppIconRepository.shared.icon(forPath: path)
        XCTAssertLessThanOrEqual(largestBitmapPixels(of: icon), 261)
        XCTAssertEqual(max(icon.size.width, icon.size.height), 128, accuracy: 0.5)
    }

    /// 染色图标位图按 2x 输出（Retina 不发糊），NSImage 点尺寸与原图一致。
    func testTintedIconKeepsPointSizeAtDoublePixels() throws {
        let path = try sampleIconPath()
        let source = AppIconRepository.shared.icon(forPath: path)
        guard let tinted = AppIconRepository.shared.tintedIcon(forPath: path, mode: .whiteToRed) else {
            return XCTFail("染色图标生成失败")
        }
        XCTAssertEqual(tinted.size, source.size)
        XCTAssertLessThanOrEqual(largestBitmapPixels(of: tinted), 261)
    }

    func testLRUCacheEvictsLeastRecentlyUsedEntries() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        // 访问 a 后 b 成为最久未使用
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c")
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
        XCTAssertEqual(cache.count, 2)

        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }
}
