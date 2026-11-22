@preconcurrency import AppKit
import Foundation

/// 图标仓库：加载 + 缓存应用图标，支持单色染色（白色→红 / 红→白）。
@MainActor
@Observable
public final class AppIconRepository {

    public static let shared = AppIconRepository()

    /// 缓存上限：约 4 屏应用图标（按 10×6 密度），超出按最近使用淘汰，
    /// 避免长时间运行/反复扫描后缓存按路径无上限增长。
    private static let cacheCapacity = 512

    /// 原色图标缓存（路径 → 图标）。
    private let cache = LRUCache<String, NSImage>(capacity: cacheCapacity)
    /// 染色图标缓存（路径|模式 → 图标）。
    private let tintedCache = LRUCache<String, NSImage>(capacity: cacheCapacity)
    /// 图标失效通知的版本号（视图层据此触发重绘）。
    public private(set) var iconRevision: Int = 0

    public init() {}

    /// 图标主题切换 / 应用图标变更后调用：清缓存并推进版本号触发重绘。
    public func invalidateCache() {
        cache.removeAll()
        tintedCache.removeAll()
        iconRevision += 1
    }

    /// 当前缓存条目数（测试/诊断用）。
    var cacheCounts: (plain: Int, tinted: Int) {
        (cache.count, tintedCache.count)
    }

    /// 取应用图标（原色），带缓存。
    /// 缓存前重采样到位图级显示尺寸（NSWorkspace 图标可能带 1024px 表示，
    /// 只设 image.size 不减位图，整页几十个大纹理每帧采样会拖垮翻帧）。
    public func icon(forPath path: String) -> NSImage {
        if let cached = cache.value(for: path) { return cached }
        let image = Self.resampledIcon(from: NSWorkspace.shared.icon(forFile: path))
        cache.insert(image, for: path)
        return image
    }

    /// 后台预热图标缓存：启动 / 重扫后一次性把全部应用图标按显示像素尺寸重采样入缓存。
    ///
    /// 分页条带一次性物化全部页、scroll 模式滚动跨页时集中物化新 cell——
    /// 这些时机遇到缓存 miss 会在主线程同步做 `NSWorkspace` 查询 + 256px 位图
    /// 重采样（每个 1-2ms，几十个图标就是一次明显的掉帧），预热后网格渲染全部命中。
    /// 系统图标查询（NSWorkspace 主线程 API）批量进行；重采样与染色是纯 CG /
    /// 像素操作，放后台队列，完成后回主线程一次性写入缓存。
    public func preheat(paths: [String], mode: IconColorMode) {
        let missing = paths.filter { cache.value(for: $0) == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let sources: [(String, NSImage)] = await MainActor.run {
                missing.map { ($0, NSWorkspace.shared.icon(forFile: $0)) }
            }
            let resampled: [(String, NSImage)] = sources.map { path, image in
                (path, Self.resampledIcon(from: image))
            }
            var tinted: [String: NSImage] = [:]
            if let tintTarget = mode.tintTarget {
                let color = Self.nsColor(for: tintTarget)
                for (path, image) in resampled {
                    if let tintedIcon = Self.monochromeTint(source: image, color: color) {
                        tinted["\(path)|\(mode.rawValue)"] = tintedIcon
                    }
                }
            }
            await MainActor.run {
                guard let self else { return }
                for (path, image) in resampled {
                    self.cache.insert(image, for: path)
                }
                for (key, image) in tinted {
                    self.tintedCache.insert(image, for: key)
                }
            }
        }
    }

    /// 缓存位图的像素缩放：Retina 2x（网格最大图标 130pt → 260px，见 GridMetrics.baseIconSize）。
    nonisolated private static let pixelScale: CGFloat = 2

    /// 以图片自身尺寸为准：按最大位图表示的真实像素宽高比归一，最长边 128pt。
    /// （不能直接设成正方形，否则非正方形图标会被拉变形。）
    nonisolated private static func displaySize(of image: NSImage) -> NSSize {
        let target: CGFloat = 128
        guard let rep = image.representations.max(by: {
            max($0.pixelsWide, $0.pixelsHigh) < max($1.pixelsWide, $1.pixelsHigh)
        }), rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            return NSSize(width: target, height: target)
        }
        let scale = target / CGFloat(max(rep.pixelsWide, rep.pixelsHigh))
        return NSSize(width: CGFloat(rep.pixelsWide) * scale, height: CGFloat(rep.pixelsHigh) * scale)
    }

    /// 位图级重采样：挑最大位图表示真正缩到显示像素尺寸，位图与显示尺寸一致后
    /// 合成器不再处理大纹理。非位图表示（如 PDF）退回旧路径（只设显示尺寸）。
    /// 纯 CGContext 位图操作，后台预热与主线程渲染共用。
    nonisolated private static func resampledIcon(from source: NSImage) -> NSImage {
        let displaySize = Self.displaySize(of: source)
        let pixelWidth = max(Int((displaySize.width * pixelScale).rounded()), 1)
        let pixelHeight = max(Int((displaySize.height * pixelScale).rounded()), 1)
        guard let rep = source.representations.max(by: {
                max($0.pixelsWide, $0.pixelsHigh) < max($1.pixelsWide, $1.pixelsHigh)
              }) as? NSBitmapImageRep,
              let cgSource = rep.cgImage,
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            // PERF-EXP: IconServices 后备（macOS 26 NSISIconImageRep 无位图表示）也栅格化，
            // 产出 CGImage 后备 NSImage，避免逐帧 IS→CGImage 提取 + locale 解析
            return rasterizedFallback(source, displaySize: displaySize,
                                      pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
        context.interpolationQuality = .high
        context.draw(cgSource, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let output = context.makeImage() else {
            let fallback = source.copy() as! NSImage
            fallback.size = displaySize
            return fallback
        }
        return NSImage(cgImage: output, size: displaySize)
    }

    /// 把无位图表示的源图标绘制进目标位图上下文，产出 CGImage 后备 NSImage。
    nonisolated private static func rasterizedFallback(
        _ source: NSImage, displaySize: NSSize, pixelWidth: Int, pixelHeight: Int
    ) -> NSImage {
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            let fallback = source.copy() as! NSImage
            fallback.size = displaySize
            return fallback
        }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = graphicsContext
        source.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)),
            from: .zero, operation: .copy, fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else {
            let fallback = source.copy() as! NSImage
            fallback.size = displaySize
            return fallback
        }
        return NSImage(cgImage: output, size: displaySize)
    }

    /// 取染色图标。单色模式把原图渲染为白色/红色轮廓：
    /// 先压成模板（按亮度生成 alpha），再以目标色填充。
    public func tintedIcon(forPath path: String, mode: IconColorMode) -> NSImage? {
        guard mode != .original else { return nil }
        guard let tintTarget = mode.tintTarget else { return nil }
        let target = Self.nsColor(for: tintTarget)
        let key = "\(path)|\(mode.rawValue)"
        if let cached = tintedCache.value(for: key) { return cached }
        let source = icon(forPath: path)
        guard let tinted = Self.monochromeTint(source: source, color: target) else { return nil }
        tintedCache.insert(tinted, for: key)
        return tinted
    }

    /// 染色目标 → NSColor（与 `IconTintTarget` 一一对应）。
    nonisolated static func nsColor(for target: IconTintTarget) -> NSColor {
        switch target {
        case .white:
            return .white
        case .themeRed:
            let c = IconTintTarget.themeRedComponents
            return NSColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        }
    }

    /// 把图像压成单色剪影：亮度 → alpha 生成白色蒙版，再以指定色填充。
    /// 像素按 pixelScale 输出（Retina 不发糊），NSImage 点尺寸保持 source 一致。
    nonisolated public static func monochromeTint(source: NSImage, color: NSColor) -> NSImage? {
        let size = source.size
        guard size.width > 0, size.height > 0,
              let tiff = source.tiffRepresentation,
              let cgSource = CGImageSourceCreateWithData(tiff as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(cgSource, 0, nil) else { return nil }

        let width = max(Int((size.width * pixelScale).rounded()), 1)
        let height = max(Int((size.height * pixelScale).rounded()), 1)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return nil }

        // 白色蒙版：alpha = 原 alpha ×（0.25 + 0.75×亮度），暗色像素变透明
        let pixelCount = width * height
        let ptr = buffer.bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        for i in 0..<pixelCount {
            let offset = i * 4
            let r = Double(ptr[offset]) / 255.0
            let g = Double(ptr[offset + 1]) / 255.0
            let b = Double(ptr[offset + 2]) / 255.0
            let a = Double(ptr[offset + 3]) / 255.0
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            let alpha = a * (0.25 + 0.75 * luminance)
            ptr[offset] = 255
            ptr[offset + 1] = 255
            ptr[offset + 2] = 255
            ptr[offset + 3] = UInt8(max(0, min(1, alpha)) * 255.0)
        }

        guard let maskCG = context.makeImage() else { return nil }
        let maskImage = NSImage(cgImage: maskCG, size: size)

        // 目标色填充 + 蒙版 destinationIn
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        let rect = CGRect(origin: .zero, size: size)
        color.set()
        rect.fill()
        maskImage.draw(
            in: rect,
            from: .zero,
            operation: .destinationIn,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        tinted.unlockFocus()
        return tinted
    }
}


/// 小型 LRU 缓存：命中时更新最近使用时间；超过容量按最久未使用淘汰。
/// 只在插入导致超限时做一次清理（O(n)，n=容量 512），命中路径为 O(1)。
final class LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var access: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be positive")
        self.capacity = capacity
    }

    var count: Int { entries.count }

    func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return entry.value
    }

    func insert(_ value: Value, for key: Key) {
        clock &+= 1
        entries[key] = Entry(value: value, access: clock)
        guard entries.count > capacity else { return }
        let overflow = entries.count - capacity
        let victims = entries.sorted { $0.value.access < $1.value.access }.prefix(overflow)
        for (key, _) in victims {
            entries.removeValue(forKey: key)
        }
    }

    func removeAll() {
        entries.removeAll()
    }
}
