import AppKit
import SwiftUI
import Testing
@testable import LaunchXCore

// MARK: - 翻页性能基准（数据采集为主；R 系列带一条 120Hz 帧预算回归断言，仅 release 生效）

/// 采集翻页路径的 CPU 侧耗时（SwiftUI body 重算 + AppKit 布局 + CA 提交），
/// 在隐藏 NSWindow + NSHostingView 中跑真实渲染管线。图标用 /System/Applications、
/// /Applications 的真实 .app，量级与实机一致。
///
/// 运行：swift test -c release --filter PageFlipPerformanceTests
/// 结果同时写入 /tmp/launchx-pageflip-perf.txt 供分析。
///
/// 每个场景结束后必须 `window.contentView = nil` 拆掉 hosting 视图：
/// 本套件 serialized 同进程串行，泄漏的窗口/视图树会污染后续场景的计时。
@Suite(.serialized)
@MainActor
final class PageFlipPerformanceTests {

    // MARK: 测量工具

    private func ms(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private struct Samples {
        let values: [Double]
        init(_ values: [Double]) { self.values = values.sorted() }

        var median: Double { percentile(0.5) }
        var p95: Double { percentile(0.95) }
        var max: Double { values.last ?? 0 }
        var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

        private func percentile(_ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let index = min(Int((Double(values.count) - 1) * p), values.count - 1)
            return values[index]
        }

        func summary(_ label: String) -> String {
            String(format: "%@: p50=%.3f ms  p95=%.3f ms  mean=%.3f ms  max=%.3f ms  (n=%d)",
                   label, median, p95, mean, max, values.count)
        }
    }

    private func spinRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: 夹具

    /// 收集真实 .app 路径（System + 用户目录），不足时用假路径补齐
    /// （NSWorkspace 对不存在路径返回通用图标，重采样管线仍然执行）。
    private func collectAppPaths(_ count: Int) -> (paths: [String], realCount: Int) {
        var found: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default
        let roots = ["/System/Applications", "/Applications"]
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                if seen.insert(url.path).inserted { found.append(url.path) }
                if found.count >= count { break }
            }
            if found.count >= count { break }
        }
        let real = Array(found.prefix(count))
        var padded = real
        var i = 0
        while padded.count < count {
            padded.append("/Applications/LaunchXPerfFiller\(i).app")
            i += 1
        }
        return (padded, real.count)
    }

    /// 构造 N 页 × 35 槽（默认密度 7×5）的分页布局。
    private func makePages(appIDs: [String], perPage: Int) -> [PageRecord] {
        stride(from: 0, to: appIDs.count, by: perPage).map { start in
            let slice = appIDs[start..<min(start + perPage, appIDs.count)]
            return PageRecord(items: slice.map { .app(id: $0) })
        }
    }

    private func makeModel(
        paths: [String], perPage: Int, icons: AppIconRepository, directory: URL
    ) -> (LaunchpadModel, LayoutStore) {
        let store = LayoutStore(directory: directory)
        let model = LaunchpadModel(store: store, icons: icons)
        let ids = paths.indices.map { "app\($0)" }
        store.updateLayout { layout in
            for (index, path) in paths.enumerated() {
                layout.apps["app\(index)"] = AppRecord(
                    id: "app\(index)", name: "App \(index)", bundleName: "App \(index)",
                    bundleId: "perf.app.\(index)", version: "1.0",
                    path: path, category: nil
                )
            }
            layout.pages = makePages(appIDs: ids, perPage: perPage)
        }
        model.show()
        return (model, store)
    }

    private func makeWindow(width: CGFloat, height: CGFloat, hosting: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        return window
    }

    /// 同步执行一轮 SwiftUI 重算 + 布局 + 显示 + CA 提交。
    private func renderOnce(_ hosting: NSView) {
        CATransaction.begin()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        CATransaction.commit()
        CATransaction.flush()
    }

    private static let windowSize = CGSize(width: 1512, height: 982)
    private static let perPage = 35  // 默认密度 7×5
    private static let pageCount = 8

    private var reportLines: [String] = []
    private func record(_ line: String) {
        reportLines.append(line)
        print("[perf] \(line)")
    }

    // MARK: 基准

    @Test func pageFlipPerformanceBenchmark() async throws {
        let appCount = Self.pageCount * Self.perPage
        let (paths, realCount) = collectAppPaths(appCount)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        record("环境: 窗口 \(Int(Self.windowSize.width))×\(Int(Self.windowSize.height))pt, "
             + "\(Self.pageCount) 页 × \(Self.perPage) 格 = \(appCount) 应用"
             + "（真实图标 \(realCount) / 占位 \(appCount - realCount)）")

        // ---- 1. 单图标冷加载（NSWorkspace 查询 + 256px 重采样，主线程逐个） ----
        let coldRepo = AppIconRepository()
        let perIcon = Samples(paths.map { path in ms { _ = coldRepo.icon(forPath: path) } })
        record("① 单图标冷加载  " + perIcon.summary("p50/p95"))

        // ---- 2. 整仓同步冷加载（无预热时最坏主线程突发） ----
        let burstRepo = AppIconRepository()
        let burstTotal = ms { for path in paths { _ = burstRepo.icon(forPath: path) } }
        record("② 整仓同步冷加载总量: \(String(format: "%.1f", burstTotal)) ms"
             + String(format: "（%d 个，均值 %.2f ms/个）", paths.count, burstTotal / Double(paths.count)))

        // ---- 3. 首次构建整个页带（冷缓存，paged 条带一次性物化全部页） ----
        let (coldModel, _) = makeModel(
            paths: paths, perPage: Self.perPage, icons: AppIconRepository(), directory: dir.appendingPathComponent("cold")
        )
        coldModel.pageWidth = Self.windowSize.width
        let coldHosting = NSHostingView(
            rootView: LaunchpadContentView(
                model: coldModel,
                wallpaper: LaunchpadWallpaperStore(),
                gridFocus: GridKeyboardFocus()
            )
        )
        let coldWindow = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: coldHosting)
        let firstBuildCold = ms { renderOnce(coldHosting) }
        spinRunLoop(0.3)
        record("③ 首次构建页带（冷缓存）: \(String(format: "%.1f", firstBuildCold)) ms")
        coldWindow.orderOut(nil)
        coldWindow.contentView = nil

        // ---- 4. 首次构建整个页带（暖缓存：图标已预热，纯视图树构建成本） ----
        let warmRepo = AppIconRepository()
        for path in paths { _ = warmRepo.icon(forPath: path) }
        let (warmModel, _) = makeModel(
            paths: paths, perPage: Self.perPage, icons: warmRepo, directory: dir.appendingPathComponent("warm")
        )
        warmModel.pageWidth = Self.windowSize.width
        let warmHosting = NSHostingView(
            rootView: LaunchpadContentView(
                model: warmModel,
                wallpaper: LaunchpadWallpaperStore(),
                gridFocus: GridKeyboardFocus()
            )
        )
        let warmWindow = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: warmHosting)
        let firstBuildWarm = ms { renderOnce(warmHosting) }
        spinRunLoop(0.3)
        record("④ 首次构建页带（暖缓存）: \(String(format: "%.1f", firstBuildWarm)) ms")

        // 管线健康检查：结构性变化（搜索态切换）应产生显著重算，
        // 若该值≈0 说明同步 flush 不生效，后续帧耗时数据不可信。
        warmModel.searchQuery = "zzzz"
        let structural = ms { renderOnce(warmHosting) }
        warmModel.searchQuery = ""
        _ = ms { renderOnce(warmHosting) }
        record("   [sanity] 结构性切换（搜索态）: \(String(format: "%.1f", structural)) ms")

        // ---- 5. 键盘/页码点翻页：currentPage 变化 + 同步重算（往返 40 次） ----
        var flipSamples: [Double] = []
        for _ in 0..<20 {
            flipSamples.append(ms {
                warmModel.nextPage()
                renderOnce(warmHosting)
            })
            flipSamples.append(ms {
                warmModel.previousPage()
                renderOnce(warmHosting)
            })
        }
        record("⑤ 键盘翻页（currentPage + 同步重算，暖缓存）  " + Samples(flipSamples).summary("往返翻页"))

        // ---- 6. 横滑跟手：逐帧写 pageDragOffset + 同步重算（120 帧） ----
        var trackingSamples: [Double] = []
        let width = warmModel.pageWidth
        for i in 0..<120 {
            let progress = Double(i + 1) / 120.0
            trackingSamples.append(ms {
                warmModel.pageDragOffset = -width * progress
                renderOnce(warmHosting)
            })
        }
        warmModel.pageDragOffset = 0
        _ = ms { renderOnce(warmHosting) }
        record("⑥ 横滑跟手逐帧（pageDragOffset + 同步重算）  " + Samples(trackingSamples).summary("120 帧"))

        // ---- 7. 落位收尾原子换页（镜像 finishDragCommit：禁动画事务内换页+归零） ----
        var commitSamples: [Double] = []
        for _ in 0..<20 {
            warmModel.pageDragOffset = -width  // 模拟已滑到整页宽
            commitSamples.append(ms {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    warmModel.currentPage = min(warmModel.currentPage + 1, warmModel.pageCount - 1)
                    warmModel.pageDragOffset = 0
                }
                renderOnce(warmHosting)
            })
            if warmModel.currentPage >= warmModel.pageCount - 1 {
                var back = Transaction()
                back.disablesAnimations = true
                withTransaction(back) {
                    warmModel.currentPage = 0
                    warmModel.pageDragOffset = 0
                }
                _ = ms { renderOnce(warmHosting) }
            }
        }
        record("⑦ 落位收尾原子换页（finishDragCommit 同路径）  " + Samples(commitSamples).summary("20 次"))

        // ---- 8. 落位动画启动成本（settlePageDrag 同步段：withAnimation 事务提交） ----
        var settleSamples: [Double] = []
        for _ in 0..<20 {
            warmModel.pageDragOffset = -width * 0.6
            settleSamples.append(ms {
                warmModel.settlePageDrag(commitDirection: 1)
            })
            // 等收尾定时器执行完再进下一轮（duration+0.05 后 finishDragCommit）
            let deadline = Date().addingTimeInterval(1.0)
            while warmModel.isSettlingPageDrag && Date() < deadline {
                spinRunLoop(0.02)
            }
        }
        record("⑧ settlePageDrag 同步段（动画启动事务）  " + Samples(settleSamples).summary("20 次"))

        // ---- 9. 规模敏感性：16 页（560 应用）暖缓存跟手逐帧 ----
        let bigCount = 16 * Self.perPage
        let (bigPaths, _) = collectAppPaths(bigCount)
        let bigRepo = AppIconRepository()
        for path in bigPaths { _ = bigRepo.icon(forPath: path) }
        let (bigModel, _) = makeModel(
            paths: bigPaths, perPage: Self.perPage, icons: bigRepo,
            directory: dir.appendingPathComponent("big")
        )
        bigModel.pageWidth = Self.windowSize.width
        let bigHosting = NSHostingView(
            rootView: LaunchpadContentView(
                model: bigModel,
                wallpaper: LaunchpadWallpaperStore(),
                gridFocus: GridKeyboardFocus()
            )
        )
        let bigWindow = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: bigHosting)
        let bigBuild = ms { renderOnce(bigHosting) }
        spinRunLoop(0.3)
        var bigTracking: [Double] = []
        for i in 0..<120 {
            let progress = Double(i + 1) / 120.0
            bigTracking.append(ms {
                bigModel.pageDragOffset = -bigModel.pageWidth * progress
                renderOnce(bigHosting)
            })
        }
        record("⑨ 16 页规模：首建(暖缓存) \(String(format: "%.1f", bigBuild)) ms, "
             + "跟手逐帧  " + Samples(bigTracking).summary("120 帧"))

        bigWindow.orderOut(nil)
        bigWindow.contentView = nil
        warmWindow.orderOut(nil)
        warmWindow.contentView = nil

        // 写文件供分析
        let report = reportLines.joined(separator: "\n")
        try? report.write(toFile: "/tmp/launchx-pageflip-perf.txt", atomically: true, encoding: .utf8)

        #expect(realCount > 0)
        #expect(coldModel.pageCount == Self.pageCount)
        #expect(structural > 0)
    }

    // MARK: 诊断 1：规模扫描 —— 跟手每帧成本是否随总 cell 数线性增长

    /// 若每帧成本 ∝ 总 cell 数 → 翻页路径存在整树重算（性能 bug 的直接证据）；
    /// 若基本平坦 → 50ms 是固定开销（CA 提交 / 渲染服务器等待）。
    @Test func trackingFrameCostScalingWithPageCount() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipScale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let appCount = 16 * Self.perPage
        let (paths, _) = collectAppPaths(appCount)
        let repo = AppIconRepository()
        for path in paths { _ = repo.icon(forPath: path) }  // 全部暖缓存，隔离图标因素

        for pageCount in [1, 2, 4, 8, 16] {
            let ids = (0..<(pageCount * Self.perPage)).map { "app\($0)" }
            let store = LayoutStore(directory: dir.appendingPathComponent("p\(pageCount)"))
            let model = LaunchpadModel(store: store, icons: repo)
            store.updateLayout { layout in
                for (index, _) in ids.enumerated() {
                    layout.apps["app\(index)"] = AppRecord(
                        id: "app\(index)", name: "App \(index)", bundleName: "App \(index)",
                        bundleId: "perf.app.\(index)", version: "1.0",
                        path: paths[index], category: nil
                    )
                }
                layout.pages = makePages(appIDs: Array(ids.prefix(pageCount * Self.perPage)), perPage: Self.perPage)
            }
            model.show()
            model.pageWidth = Self.windowSize.width
            let hosting = NSHostingView(
                rootView: LaunchpadContentView(
                    model: model, wallpaper: LaunchpadWallpaperStore(), gridFocus: GridKeyboardFocus()
                )
            )
            let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
            _ = ms { renderOnce(hosting) }
            spinRunLoop(0.2)

            var frames: [Double] = []
            for i in 0..<60 {
                let progress = Double(i + 1) / 60.0
                frames.append(ms {
                    model.pageDragOffset = -model.pageWidth * progress
                    renderOnce(hosting)
                })
            }
            model.pageDragOffset = 0
            _ = ms { renderOnce(hosting) }
            let stats = Samples(frames)
            record(String(format: "[scale] %2d 页 / %3d cell：跟手每帧 p50=%.2f ms  p95=%.2f ms  (n=60)",
                          pageCount, pageCount * Self.perPage, stats.median, stats.p95))
            window.orderOut(nil)
            window.contentView = nil
            spinRunLoop(0.1)
        }

        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-scale.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 诊断 3：帧成本分解 + 稳态对照

    /// 关键对照：稳态（不改任何模型属性）下 renderOnce 的成本。
    /// - 若稳态 ≈ 0 → 基准里的 50ms+ 是模型变更触发的真实重算（代表性成立）；
    /// - 若稳态也很高 → renderOnce 本身强制全量布局/绘制，基准高估了真实路径。
    @Test func frameCostBreakdown() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipBreakdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let appCount = 8 * Self.perPage
        let (paths, _) = collectAppPaths(appCount)
        let repo = AppIconRepository()
        for path in paths { _ = repo.icon(forPath: path) }
        let (model, _) = makeModel(paths: paths, perPage: Self.perPage, icons: repo, directory: dir)
        model.pageWidth = Self.windowSize.width
        let hosting = NSHostingView(
            rootView: LaunchpadContentView(
                model: model, wallpaper: LaunchpadWallpaperStore(), gridFocus: GridKeyboardFocus()
            )
        )
        let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
        _ = ms { renderOnce(hosting) }
        spinRunLoop(0.3)

        let width = model.pageWidth

        // A. 稳态：不改模型，纯 renderOnce（应接近 0 才说明 harness 无全量开销）
        var steady: [Double] = []
        for _ in 0..<60 {
            steady.append(ms { renderOnce(hosting) })
            spinRunLoop(0.001)
        }
        record("A. 稳态 renderOnce（无模型变更）            " + Samples(steady).summary("60 次"))

        // B. 仅模型写入（不渲染）：Observable 失效派发的成本
        var writeOnly: [Double] = []
        for i in 0..<60 {
            let progress = Double(i + 1) / 60.0
            writeOnly.append(ms {
                model.pageDragOffset = -width * progress
            })
            _ = ms { renderOnce(hosting) }  // 消化失效，保持状态一致
        }
        record("B. 仅 pageDragOffset 写入（无渲染）          " + Samples(writeOnly).summary("60 次"))

        // C. 布局 + 显示，但不含 CATransaction.flush（隔离 flush 的渲染服务器等待）
        func renderNoFlush(_ hosting: NSView) {
            CATransaction.begin()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            CATransaction.commit()
        }
        var noFlush: [Double] = []
        for i in 0..<60 {
            let progress = Double(i + 1) / 60.0
            noFlush.append(ms {
                model.pageDragOffset = -width * progress
                renderNoFlush(hosting)
            })
        }
        model.pageDragOffset = 0
        _ = ms { renderOnce(hosting) }
        record("C. 跟手帧（布局+显示，无 flush）             " + Samples(noFlush).summary("60 次"))

        // D. 仅布局，不显示
        func layoutOnly(_ hosting: NSView) {
            CATransaction.begin()
            hosting.layoutSubtreeIfNeeded()
            CATransaction.commit()
        }
        var layoutSamples: [Double] = []
        for i in 0..<60 {
            let progress = Double(i + 1) / 60.0
            layoutSamples.append(ms {
                model.pageDragOffset = -width * progress
                layoutOnly(hosting)
            })
        }
        model.pageDragOffset = 0
        _ = ms { renderOnce(hosting) }
        record("D. 跟手帧（仅布局）                          " + Samples(layoutSamples).summary("60 次"))

        // E. 基准全量（对照 A-E 分解是否闭环）
        var full: [Double] = []
        for i in 0..<60 {
            let progress = Double(i + 1) / 60.0
            full.append(ms {
                model.pageDragOffset = -width * progress
                renderOnce(hosting)
            })
        }
        model.pageDragOffset = 0
        _ = ms { renderOnce(hosting) }
        record("E. 跟手帧全量（写入+布局+显示+flush）        " + Samples(full).summary("60 次"))

        window.orderOut(nil)
        window.contentView = nil
        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-breakdown.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 诊断 2：跟手循环 + sample 采样热点归因

    /// 非 lazy 手工行列网格（PageGridView 复刻，文件级供多测试共用）。
    struct SamplingLocalPageGridView: View {
        @Environment(LaunchpadModel.self) private var model
        @Environment(\.gridMetrics) private var metrics
        let pageIndex: Int

        var body: some View {
            Group {
                if pageIndex < model.layout.pages.count {
                    let items = model.layout.pages[pageIndex].items
                    let columnCount = model.density.columns
                    let rows: [[SlotItem]] = stride(from: 0, to: items.count, by: columnCount).map {
                        Array(items[$0..<min($0 + columnCount, items.count)])
                    }
                    VStack(alignment: .center, spacing: metrics.gridSpacing) {
                        ForEach(rows.indices, id: \.self) { rowIndex in
                            HStack(alignment: .center, spacing: metrics.columnSpacing) {
                                ForEach(rows[rowIndex].indices, id: \.self) { columnIndex in
                                    let slotIndex = rowIndex * columnCount + columnIndex
                                    switch rows[rowIndex][columnIndex] {
                                    case let .app(appID):
                                        if let app = model.layout.apps[appID] {
                                            AppCell(
                                                app: app, pageIndex: pageIndex, folderID: nil,
                                                isSearchResult: false, isKeyboardFocused: false
                                            )
                                            .frame(width: metrics.cellWidth)
                                            .id(slotIndex)
                                        }
                                    case let .folder(folder):
                                        FolderCell(folder: folder, pageIndex: pageIndex)
                                            .frame(width: metrics.cellWidth)
                                            .id(slotIndex)
                                    }
                                }
                            }
                        }
                    }
                    .frame(
                        width: CGFloat(model.density.columns) * metrics.cellWidth,
                        height: CGFloat(model.density.rows) * metrics.cellHeight
                            + CGFloat(model.density.rows - 1) * metrics.gridSpacing,
                        alignment: .topLeading
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 44)
                } else {
                    EmptyStateView(systemImage: "square.grid.3x3", title: "这一页是空的")
                }
            }
            .coordinateSpace(name: "pageSpace")
        }
    }

    /// 无闭包的页面条带（视图值可比较）。
    struct SamplingStripPages: View {
        @Environment(LaunchpadModel.self) private var model
        @Environment(\.gridMetrics) private var metrics
        var body: some View {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(0..<max(model.pageCount, 1), id: \.self) { pageIndex in
                        SamplingLocalPageGridView(pageIndex: pageIndex)
                            .frame(width: max(proxy.size.width, 1), height: proxy.size.height)
                    }
                }
            }
        }
    }

    /// 隔离 offset：逐帧变化只落在本视图，strip 作为存储的子视图值。
    struct IsoOffsetSamplingStrip<Strip: View>: View {
        @Environment(LaunchpadModel.self) private var model
        let width: CGFloat
        @ViewBuilder var strip: Strip
        var body: some View {
            let settled = model.pageCount > 0 ? min(model.currentPage, model.pageCount - 1) : 0
            strip
                .offset(x: -CGFloat(settled) * width + model.pageDragOffset)
        }
    }

    /// 持续 6 秒的最优配置（非lazy + 隔离offset）跟手帧循环，无 sleep 全忙，
    /// 用 /usr/bin/sample 采样，输出热点栈到 /tmp/launchx-tracking-sample.txt。
    @Test func trackingHotspotSampling() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipSample-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let appCount = 8 * Self.perPage
        let (paths, _) = collectAppPaths(appCount)
        let repo = AppIconRepository()
        for path in paths { _ = repo.icon(forPath: path) }
        let (model, _) = makeModel(paths: paths, perPage: Self.perPage, icons: repo, directory: dir)
        model.pageWidth = Self.windowSize.width
        let metrics = GridMetrics.compute(
            areaSize: CGSize(width: Self.windowSize.width, height: Self.windowSize.height - 222),
            density: model.density
        )

        // D 配置：非 lazy 手工行列 + 隔离 offset
        let hosting = NSHostingView(rootView: AnyView(
            IsoOffsetSamplingStrip(width: Self.windowSize.width) {
                SamplingStripPages()
                    .environment(model)
                    .environment(\.gridMetrics, metrics)
            }
            .environment(model)
        ))
        let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
        _ = ms { renderOnce(hosting) }
        spinRunLoop(0.3)

        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [
            "\(getpid())", "6",
            "-file", "/tmp/launchx-tracking-sample.txt",
            "-mayDie",
        ]
        try sampler.run()

        // 6 秒连续跟手（无 sleep，全程忙）：0 → -width → 0 往返扫动
        let deadline = Date().addingTimeInterval(6.0)
        let width = model.pageWidth
        var frameCount = 0
        while Date() < deadline {
            let phase = Double(frameCount % 60) / 60.0
            let progress = frameCount % 120 < 60 ? phase : 1 - phase
            model.pageDragOffset = -width * progress
            renderOnce(hosting)
            frameCount += 1
        }

        sampler.waitUntilExit()
        record("[sample] 采样完成：6 秒连跑 \(frameCount) 个跟手帧（无 sleep）")
        window.orderOut(nil)
        window.contentView = nil

        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-sample-run.txt", atomically: true, encoding: .utf8)
        #expect(frameCount > 60)
    }

    // MARK: 诊断 4：条带架构隔离实验（剥离模型 / cell / preference 逐个归因）

    /// 最小复刻 PagedGridArea 的条带结构，逐层加回嫌疑组件，找出每帧线性成本的来源：
    /// - 纯条带（色块 + offset）：若仍随页数线性 → 条带+offset 架构本身逐帧全量重布局；
    /// - +preference 上报（复刻 AppCell 的 GeometryReader→PreferenceKey→根级 @State 写回）：
    ///   若此层才线性 → 剩余成本是 frame 上报洪水。
    @Observable
    final class PerfDragState {
        var offset: CGFloat = 0
    }

    /// 复刻 ItemFramePreferenceKey 的上报链路。
    private struct PerfFrameKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    private struct PerfStripCell: View {
        let index: Int
        var body: some View {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hue: Double(index % 35) / 35, saturation: 0.6, brightness: 0.8))
                    .frame(width: 66, height: 66)
                Text("App \(index)")
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
        }
    }

    private struct PlainStrip: View {
        @Environment(PerfDragState.self) private var drag
        let pageCount: Int
        let perPage: Int
        let reportFrames: Bool
        @State private var itemFrames: [String: CGRect] = [:]

        var body: some View {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let settled = 0  // 保持在第 1 页，只做跟手偏移
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(0..<max(pageCount, 1), id: \.self) { pageIndex in
                            VStack(alignment: .center, spacing: 40) {
                                ForEach(0..<perPage, id: \.self) { item in
                                    PerfStripCell(index: item)
                                }
                            }
                            .frame(width: width, height: proxy.size.height)
                        }
                    }
                    .offset(x: -CGFloat(settled) * width + drag.offset)
                }
                .clipped()
                .coordinateSpace(name: "pageSpace")
                if reportFrames {
                    // 复刻 AppCell 的逐 cell frame 上报（pageSpace 相对坐标）
                    HStack(spacing: 0) {
                        ForEach(0..<max(pageCount, 1), id: \.self) { pageIndex in
                            VStack(alignment: .center, spacing: 40) {
                                ForEach(0..<perPage, id: \.self) { item in
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: PerfFrameKey.self,
                                            value: ["p\(pageIndex)i\(item)": geo.frame(in: .named("pageSpace"))]
                                        )
                                    }
                                    .frame(width: 80, height: 95)
                                }
                            }
                            .frame(width: width, height: proxy.size.height)
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(PerfFrameKey.self) { frames in
                if !frames.isEmpty { itemFrames = frames }
            }
        }
    }

    @Test func stripIsolationExperiment() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipStrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for reportFrames in [false, true] {
            for pageCount in [1, 2, 4, 8, 16] {
                let drag = PerfDragState()
                let hosting = NSHostingView(
                    rootView: PlainStrip(pageCount: pageCount, perPage: 35, reportFrames: reportFrames)
                        .environment(drag)
                )
                let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
                _ = ms { renderOnce(hosting) }
                spinRunLoop(0.2)

                var frames: [Double] = []
                for i in 0..<60 {
                    let progress = Double(i + 1) / 60.0
                    frames.append(ms {
                        drag.offset = -Self.windowSize.width * progress
                        renderOnce(hosting)
                    })
                }
                drag.offset = 0
                _ = ms { renderOnce(hosting) }
                let label = reportFrames ? "+frame上报" : "纯色块  "
                let stats = Samples(frames)
                record(String(format: "[strip] %@ %2d 页 / %3d cell：每帧 p50=%.2f ms  p95=%.2f ms",
                              label, pageCount, pageCount * 35, stats.median, stats.p95))
                window.orderOut(nil)
                window.contentView = nil
                spinRunLoop(0.1)
            }
        }

        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-strip.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 诊断 5：AppCell 修饰符二分（找出把整树拖成线性重算的具体组件）

    /// 复刻 AppCell 的修饰符栈，按组开关逐层累加：
    /// V0 裸内容 → V1 +contextMenu → V2 +onDrag/onDrop → V3 +keyframeAnimator
    /// → V4 +cell 内 preference overlay → V5 +模型观察（@Environment 可观察对象）。
    /// 全部 8 页 × 35 格；哪一层从平坦跳到线性，哪层就是元凶。
    struct PerfCellFlags: OptionSet {
        let rawValue: Int
        static let contextMenu = PerfCellFlags(rawValue: 1 << 0)
        static let dragDrop = PerfCellFlags(rawValue: 1 << 1)
        static let spring = PerfCellFlags(rawValue: 1 << 2)
        static let frameReport = PerfCellFlags(rawValue: 1 << 3)
        static let modelWatch = PerfCellFlags(rawValue: 1 << 4)
    }

    @Observable
    final class PerfDummyModel {
        var selectedIDs: Set<Int> = []
        var hoverIndex: Int? = nil
        var namesHidden: Bool = false
    }

    private struct PerfAppCell: View {
        let index: Int
        let flags: PerfCellFlags
        @Environment(PerfDummyModel.self) private var dummy  // 模型观察用
        @State private var springTrigger = 0

        var body: some View {
            let hidden = flags.contains(.modelWatch) ? dummy.namesHidden : false
            let selected = flags.contains(.modelWatch) ? dummy.selectedIDs.contains(index) : false
            let hovered = flags.contains(.modelWatch) ? dummy.hoverIndex == index : false
            VStack(spacing: 7) {
                // 图标区（复刻：frame + overlay 高亮 + 点击）
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(hue: Double(index % 35) / 35, saturation: 0.6, brightness: 0.8))
                    .frame(width: 66, height: 66)
                    .overlay {
                        if hovered {
                            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.blue, lineWidth: 2)
                        }
                    }
                    .onTapGesture {}
                if !hidden {
                    Text("App \(index)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.8), radius: 1.5, y: 1)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .frame(maxWidth: 126)
                        .onTapGesture {}
                }
            }
            .padding(.horizontal, 2)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.blue, lineWidth: 2)
                        .padding(-4)
                }
            }
            .contentShape(Rectangle())
            .modifier(PerfCellMenuModifier(enabled: flags.contains(.contextMenu), index: index))
            .modifier(PerfCellDragModifier(enabled: flags.contains(.dragDrop), index: index))
            .modifier(PerfCellSpringModifier(enabled: flags.contains(.spring), trigger: springTrigger))
            .frame(maxWidth: .infinity)
            .opacity(hidden ? 0.55 : 1)
            .modifier(PerfCellDropModifier(enabled: flags.contains(.dragDrop)))
            .overlay {
                if flags.contains(.frameReport) {
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: PerfFrameKey.self,
                            value: ["c\(index)": geo.frame(in: .named("pageSpace"))]
                        )
                    }
                }
            }
        }
    }

    private struct PerfCellMenuModifier: ViewModifier {
        let enabled: Bool
        let index: Int
        func body(content: Content) -> some View {
            if enabled {
                content.contextMenu {
                    Button("打开") {}
                    Button("显示简介") {}
                    Button("在访达中显示") {}
                    Button("重命名…") {}
                    Divider()
                    Button("隐藏") {}
                    Button("添加到程序坞") {}
                }
            } else {
                content
            }
        }
    }

    private struct PerfCellDragModifier: ViewModifier {
        let enabled: Bool
        let index: Int
        func body(content: Content) -> some View {
            if enabled {
                content.onDrag {
                    NSItemProvider(object: "\(index)" as NSString)
                }
            } else {
                content
            }
        }
    }

    private struct PerfCellDropModifier: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content.onDrop(of: [.text], delegate: PerfDropDelegate())
            } else {
                content
            }
        }
    }

    private struct PerfDropDelegate: DropDelegate {
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
        func performDrop(info: DropInfo) -> Bool { true }
    }

    private struct PerfCellSpringModifier: ViewModifier {
        let enabled: Bool
        let trigger: Int
        func body(content: Content) -> some View {
            if enabled {
                content.keyframeAnimator(
                    initialValue: 1.0,
                    trigger: trigger
                ) { view, scale in
                    view.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack(\.self) {
                        CubicKeyframe(0.92, duration: 0.1)
                        SpringKeyframe(1.0, duration: 0.4, spring: .bouncy(duration: 0.3, extraBounce: 0.1))
                    }
                }
            } else {
                content
            }
        }
    }

    private struct PerfModelStrip: View {
        @Environment(PerfDragState.self) private var drag
        let pageCount: Int
        let perPage: Int
        let flags: PerfCellFlags

        var body: some View {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(0..<max(pageCount, 1), id: \.self) { pageIndex in
                            VStack(alignment: .center, spacing: 40) {
                                ForEach(0..<perPage, id: \.self) { item in
                                    PerfAppCell(index: pageIndex * perPage + item, flags: flags)
                                }
                            }
                            .frame(width: width, height: proxy.size.height)
                        }
                    }
                    .offset(x: drag.offset)
                }
                .clipped()
                .coordinateSpace(name: "pageSpace")
            }
            .onPreferenceChange(PerfFrameKey.self) { _ in }
        }
    }

    @Test func appCellModifierBisect() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipBisect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let variants: [(String, PerfCellFlags)] = [
            ("V0 裸内容", []),
            ("V1 +contextMenu", [.contextMenu]),
            ("V2 +drag/drop", [.contextMenu, .dragDrop]),
            ("V3 +keyframe弹簧", [.contextMenu, .dragDrop, .spring]),
            ("V4 +cell内frame上报", [.contextMenu, .dragDrop, .spring, .frameReport]),
            ("V5 +模型观察", [.contextMenu, .dragDrop, .spring, .frameReport, .modelWatch]),
        ]

        let pageCount = 8
        for (label, flags) in variants {
            let drag = PerfDragState()
            let dummy = PerfDummyModel()
            let hosting = NSHostingView(
                rootView: PerfModelStrip(pageCount: pageCount, perPage: 35, flags: flags)
                    .environment(drag)
                    .environment(dummy)
            )
            let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
            _ = ms { renderOnce(hosting) }
            spinRunLoop(0.2)

            var frames: [Double] = []
            for i in 0..<60 {
                let progress = Double(i + 1) / 60.0
                frames.append(ms {
                    drag.offset = -Self.windowSize.width * progress
                    renderOnce(hosting)
                })
            }
            drag.offset = 0
            _ = ms { renderOnce(hosting) }
            let stats = Samples(frames)
            record(String(format: "[bisect] %@：8页/280cell 每帧 p50=%.2f ms  p95=%.2f ms",
                          label, stats.median, stats.p95))
            window.orderOut(nil)
            window.contentView = nil
            spinRunLoop(0.1)
        }

        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-bisect.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 诊断 6：真实视图层级二分（PagedGridArea / PageGridView 逐层挂载）

    /// 真实模型 + 真实内部视图，从内向外逐层挂载，找出层级中引入线性成本的层：
    /// - R1: 最小条带 + 真实 PageGridView（每页 35 个真实 AppCell）
    /// - R2: 真实 PagedGridArea（窗口化 3 页 + 每页独立 offset + 框选手势 + drop）
    /// - R3: 完整 LaunchpadContentView
    /// - R4: 整条物化 + 单一 offset（旧架构对照）
    ///
    /// R2 附带 120 Hz 帧预算（8.33ms）回归断言：结构性回归（整树物化 / 逐帧
    /// 全量重算）会把跟手每帧 p50 推到 ~30ms 量级，远超测量噪声。debug 构建
    /// 的 body 重算失真，断言仅在 release 配置生效。
    @Test func realViewHierarchyBisect() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipReal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let appCount = 8 * Self.perPage
        let (paths, _) = collectAppPaths(appCount)
        let repo = AppIconRepository()
        for path in paths { _ = repo.icon(forPath: path) }
        let (model, _) = makeModel(paths: paths, perPage: Self.perPage, icons: repo, directory: dir)
        let metrics = GridMetrics.compute(
            areaSize: CGSize(width: Self.windowSize.width, height: Self.windowSize.height - 222),
            density: model.density
        )

        // R1: 最小条带 + 真实 PageGridView
        struct RealCellStrip: View {
            @Environment(LaunchpadModel.self) private var model
            var body: some View {
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    HStack(spacing: 0) {
                        ForEach(0..<max(model.pageCount, 1), id: \.self) { pageIndex in
                            PageGridView(pageIndex: pageIndex)
                                .frame(width: width, height: proxy.size.height)
                        }
                    }
                    .offset(x: -CGFloat(min(model.currentPage, model.pageCount - 1)) * width + model.pageDragOffset)
                }
            }
        }

        // R2: 真实 PagedGridArea（需要 Binding）
        struct RealPagedAreaHost: View {
            @Environment(LaunchpadModel.self) private var model
            @State private var itemFrames: [String: CGRect] = [:]
            @State private var marqueeStart: CGPoint? = nil
            var body: some View {
                PagedGridArea(itemFrames: $itemFrames, marqueeStart: $marqueeStart, gridFocus: GridKeyboardFocus())
            }
        }

        func measure(_ label: String, build: () -> any View) -> Samples {
            let hosting = NSHostingView(rootView: AnyView(build()))
            let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
            _ = ms { renderOnce(hosting) }
            spinRunLoop(0.25)
            var frames: [Double] = []
            for i in 0..<60 {
                let progress = Double(i + 1) / 60.0
                frames.append(ms {
                    model.pageDragOffset = -model.pageWidth * progress
                    renderOnce(hosting)
                })
            }
            model.pageDragOffset = 0
            _ = ms { renderOnce(hosting) }
            let stats = Samples(frames)
            record(String(format: "[real] %@：8页/280cell 每帧 p50=%.2f ms  p95=%.2f ms",
                          label, stats.median, stats.p95))
            // 场景收尾必须拆掉 contentView：泄漏的 hosting 视图会污染后续场景/测试
            window.orderOut(nil)
            window.contentView = nil
            spinRunLoop(0.1)
            return stats
        }

        _ = measure("R1 最小条带+真实PageGridView") {
            RealCellStrip()
                .environment(model)
                .environment(\.gridMetrics, metrics)
        }
        let realPagedArea = measure("R2 真实PagedGridArea") {
            RealPagedAreaHost()
                .environment(model)
                .environment(\.gridMetrics, metrics)
        }
        _ = measure("R3 完整LaunchpadContentView") {
            LaunchpadContentView(
                model: model,
                wallpaper: LaunchpadWallpaperStore(),
                gridFocus: GridKeyboardFocus()
            )
        }

        // R4: offset 隔离模式 —— pageDragOffset 只在极小视图里读取，
        // 条带内容作为子视图传入（值不变 → 逐帧不重 diff 整个子树）
        struct IsoOffsetStrip<Strip: View>: View {
            @Environment(LaunchpadModel.self) private var model
            let width: CGFloat
            @ViewBuilder var strip: Strip

            var body: some View {
                let settled = model.pageCount > 0
                    ? min(model.currentPage, model.pageCount - 1) : 0
                strip
                    .offset(x: -CGFloat(settled) * width + model.pageDragOffset)
            }
        }

        struct StripContent: View {
            @Environment(LaunchpadModel.self) private var model
            var body: some View {
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    HStack(spacing: 0) {
                        ForEach(0..<max(model.pageCount, 1), id: \.self) { pageIndex in
                            PageGridView(pageIndex: pageIndex)
                                .frame(width: width, height: proxy.size.height)
                        }
                    }
                }
            }
        }

        _ = measure("R4 整条物化+单一offset(旧架构对照)") {
            IsoOffsetStrip(width: Self.windowSize.width) {
                StripContent()
                    .environment(model)
                    .environment(\.gridMetrics, metrics)
            }
            .environment(model)
            .environment(\.gridMetrics, metrics)
        }

        // 120 Hz 帧预算回归断言：真实 PagedGridArea 跟手每帧 p50 必须落在 8.33ms 内。
        // 结构性回归（整树物化 / offset 读取点上移导致整树 re-diff）会把它推到
        // ~30ms，远超机器噪声；debug 构建的 body 重算失真，仅在 release 生效。
        #if !DEBUG
        let budgetMs = 1000.0 / 120.0
        let measured = String(format: "p50=%.2f ms  p95=%.2f ms", realPagedArea.median, realPagedArea.p95)
        #expect(realPagedArea.median < budgetMs,
                "PagedGridArea 跟手每帧超出 120Hz 预算：\(measured)")
        record("   [budget] R2 跟手每帧 p50=\(String(format: "%.2f", realPagedArea.median)) ms / 120Hz 预算 \(String(format: "%.2f", budgetMs)) ms")
        #endif

        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-real.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 诊断 7：最终对照矩阵（同进程内，消除跨轮系统负载差异）

    /// 两个独立成本源：A) LazyVGrid 逐帧重物化（几何驱动，隔离救不了——已修复：
    /// 生产 PageGridView 改为固定行列网格）B) pageDragOffset 读取点过高 → 祖先层
    /// 逐帧 re-diff 整个子树（隔离可消——已并入生产实现的窗口化条带）。
    /// 2×2 矩阵保留作回归对照；「LazyVGrid」变体现走真实 PageGridView（现为非 lazy），
    /// 与「非lazy」变体只剩视图复刻实现本身的差异。
    @Test func offsetIsolationFinalMatrix() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipMatrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let appCount = 8 * Self.perPage
        let (paths, _) = collectAppPaths(appCount)
        let repo = AppIconRepository()
        for path in paths { _ = repo.icon(forPath: path) }
        let (model, _) = makeModel(paths: paths, perPage: Self.perPage, icons: repo, directory: dir)
        let metrics = GridMetrics.compute(
            areaSize: CGSize(width: Self.windowSize.width, height: Self.windowSize.height - 222),
            density: model.density
        )

        // 非 lazy 网格（PageGridView 的手工行列复刻）
        struct LocalPageGridView: View {
            @Environment(LaunchpadModel.self) private var model
            @Environment(\.gridMetrics) private var metrics
            let pageIndex: Int

            var body: some View {
                Group {
                    if pageIndex < model.layout.pages.count {
                        let items = model.layout.pages[pageIndex].items
                        let columnCount = model.density.columns
                        let rows: [[SlotItem]] = stride(from: 0, to: items.count, by: columnCount).map {
                            Array(items[$0..<min($0 + columnCount, items.count)])
                        }
                        VStack(alignment: .center, spacing: metrics.gridSpacing) {
                            ForEach(rows.indices, id: \.self) { rowIndex in
                                HStack(alignment: .center, spacing: metrics.columnSpacing) {
                                    ForEach(rows[rowIndex].indices, id: \.self) { columnIndex in
                                        let slotIndex = rowIndex * columnCount + columnIndex
                                        switch rows[rowIndex][columnIndex] {
                                        case let .app(appID):
                                            if let app = model.layout.apps[appID] {
                                                AppCell(
                                                    app: app, pageIndex: pageIndex, folderID: nil,
                                                    isSearchResult: false, isKeyboardFocused: false
                                                )
                                                .frame(width: metrics.cellWidth)
                                                .id(slotIndex)
                                            }
                                        case let .folder(folder):
                                            FolderCell(folder: folder, pageIndex: pageIndex)
                                                .frame(width: metrics.cellWidth)
                                                .id(slotIndex)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(
                            width: CGFloat(model.density.columns) * metrics.cellWidth,
                            height: CGFloat(model.density.rows) * metrics.cellHeight
                                + CGFloat(model.density.rows - 1) * metrics.gridSpacing,
                            alignment: .topLeading
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 44)
                    } else {
                        EmptyStateView(systemImage: "square.grid.3x3", title: "这一页是空的")
                    }
                }
                .coordinateSpace(name: "pageSpace")
            }
        }

        // 直连 offset：body 直接读 pageDragOffset（现状模式）
        struct DirectOffsetStrip<Strip: View>: View {
            @Environment(LaunchpadModel.self) private var model
            let width: CGFloat
            @ViewBuilder var strip: Strip
            var body: some View {
                let settled = model.pageCount > 0 ? min(model.currentPage, model.pageCount - 1) : 0
                GeometryReader { proxy in
                    strip
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .offset(x: -CGFloat(settled) * width + model.pageDragOffset)
                }
            }
        }

        // 隔离 offset：逐帧变化只落在极小视图，strip 作为子视图值不变
        struct IsoOffsetStrip<Strip: View>: View {
            @Environment(LaunchpadModel.self) private var model
            let width: CGFloat
            @ViewBuilder var strip: Strip
            var body: some View {
                let settled = model.pageCount > 0 ? min(model.currentPage, model.pageCount - 1) : 0
                strip
                    .offset(x: -CGFloat(settled) * width + model.pageDragOffset)
            }
        }

        func measure(_ label: String, build: () -> any View) {
            let hosting = NSHostingView(rootView: AnyView(build()))
            let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
            _ = ms { renderOnce(hosting) }
            spinRunLoop(0.25)
            var frames: [Double] = []
            for i in 0..<60 {
                let progress = Double(i + 1) / 60.0
                frames.append(ms {
                    model.pageDragOffset = -model.pageWidth * progress
                    renderOnce(hosting)
                })
            }
            model.pageDragOffset = 0
            _ = ms { renderOnce(hosting) }
            let stats = Samples(frames)
            record(String(format: "[matrix] %@：每帧 p50=%.2f ms  p95=%.2f ms", label, stats.median, stats.p95))
            window.orderOut(nil)
        }

        // 无闭包版页面条带：视图值可比较，隔离模式下逐帧跳过子树 re-diff
        struct StripPagesReal: View {
            @Environment(LaunchpadModel.self) private var model
            @Environment(\.gridMetrics) private var metrics
            var body: some View {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(0..<max(model.pageCount, 1), id: \.self) { pageIndex in
                            PageGridView(pageIndex: pageIndex)
                                .frame(width: max(proxy.size.width, 1), height: proxy.size.height)
                        }
                    }
                }
            }
        }

        struct StripPagesNonLazy: View {
            @Environment(LaunchpadModel.self) private var model
            @Environment(\.gridMetrics) private var metrics
            var body: some View {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        ForEach(0..<max(model.pageCount, 1), id: \.self) { pageIndex in
                            LocalPageGridView(pageIndex: pageIndex)
                                .frame(width: max(proxy.size.width, 1), height: proxy.size.height)
                        }
                    }
                }
            }
        }

        var variantMedians: [String: [Double]] = [:]
        let variants: [(String, () -> any View)] = [
            ("A 真实PageGridView+直连", {
                DirectOffsetStrip(width: Self.windowSize.width) {
                    StripPagesReal()
                        .environment(model)
                        .environment(\.gridMetrics, metrics)
                }
                .environment(model)
            }),
            ("B 真实PageGridView+隔离", {
                IsoOffsetStrip(width: Self.windowSize.width) {
                    StripPagesReal()
                        .environment(model)
                        .environment(\.gridMetrics, metrics)
                }
                .environment(model)
            }),
            ("C 非lazy+直连", {
                DirectOffsetStrip(width: Self.windowSize.width) {
                    StripPagesNonLazy()
                        .environment(model)
                        .environment(\.gridMetrics, metrics)
                }
                .environment(model)
            }),
            ("D 非lazy+隔离", {
                IsoOffsetStrip(width: Self.windowSize.width) {
                    StripPagesNonLazy()
                        .environment(model)
                        .environment(\.gridMetrics, metrics)
                }
                .environment(model)
            }),
        ]

        // 4 轮 × 每轮轮换起始变体（消除顺序漂移），每轮 30 帧
        for round in 0..<4 {
            for offset in 0..<variants.count {
                let index = (round + offset) % variants.count
                let (label, build) = variants[index]
                let hosting = NSHostingView(rootView: AnyView(build()))
                let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
                _ = ms { renderOnce(hosting) }
                spinRunLoop(0.2)
                var frames: [Double] = []
                for i in 0..<30 {
                    let progress = Double(i + 1) / 30.0
                    frames.append(ms {
                        model.pageDragOffset = -model.pageWidth * progress
                        renderOnce(hosting)
                    })
                }
                model.pageDragOffset = 0
                _ = ms { renderOnce(hosting) }
                variantMedians[label, default: []].append(Samples(frames).median)
                window.orderOut(nil)
                window.contentView = nil
                spinRunLoop(0.1)
            }
        }

        for (label, values) in variants.map({ ($0.0, variantMedians[$0.0] ?? []) }) {
            let best = values.min() ?? 0
            let median = values.sorted()[values.count / 2]
            record(String(format: "[matrix] %@：跨轮中位 %.2f ms / 最优轮 %.2f ms（轮值 %@）",
                          label, median, best, values.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
        }

        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-matrix.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 诊断 8：窗口化条带（当前页 ±1，共 3 页物化）——120Hz 预算(8.33ms)验证

    /// 每 page 独立 offset = (pageIndex − settled) × pageWidth + pageDragOffset，
    /// 与整条条带在视觉上逐帧等价；物化 cell 数从全部页降到 3 页。
    struct WindowedStrip: View {
        @Environment(LaunchpadModel.self) private var model
        @Environment(\.gridMetrics) private var metrics

        var body: some View {
            let settled = min(model.currentPage, model.pageCount - 1)
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .topLeading) {
                    let windowStart = max(settled - 1, 0)
                    let windowEnd = min(windowStart + 3, model.pageCount)
                    ForEach(windowStart..<max(windowEnd, windowStart + 1), id: \.self) { pageIndex in
                        SamplingLocalPageGridView(pageIndex: pageIndex)
                            .frame(width: width, height: proxy.size.height)
                            .offset(x: CGFloat(pageIndex - settled) * width + model.pageDragOffset)
                    }
                }
                .clipped()
            }
        }
    }

    @Test func windowedStripExperiment() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipWindow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let appCount = 8 * Self.perPage
        let (paths, _) = collectAppPaths(appCount)
        let repo = AppIconRepository()
        for path in paths { _ = repo.icon(forPath: path) }
        let (model, _) = makeModel(paths: paths, perPage: Self.perPage, icons: repo, directory: dir)
        model.pageWidth = Self.windowSize.width
        let metrics = GridMetrics.compute(
            areaSize: CGSize(width: Self.windowSize.width, height: Self.windowSize.height - 222),
            density: model.density
        )
        let hosting = NSHostingView(rootView: AnyView(
            WindowedStrip()
                .environment(model)
                .environment(\.gridMetrics, metrics)
        ))
        let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
        _ = ms { renderOnce(hosting) }
        spinRunLoop(0.3)

        // 跟手逐帧（跨 4 轮取稳定值）
        var medians: [Double] = []
        for _ in 0..<4 {
            var frames: [Double] = []
            for i in 0..<30 {
                let progress = Double(i + 1) / 30.0
                frames.append(ms {
                    model.pageDragOffset = -model.pageWidth * progress
                    renderOnce(hosting)
                })
            }
            model.pageDragOffset = 0
            _ = ms { renderOnce(hosting) }
            medians.append(Samples(frames).median)
            spinRunLoop(0.1)
        }
        record(String(format: "[window] 窗口化条带(3页/105cell) 跟手每帧：跨轮中位 %.2f ms / 最优轮 %.2f ms",
                      medians.sorted()[medians.count / 2], medians.min() ?? 0))

        // 落位收尾原子换页（同 finishDragCommit 路径）
        var commitSamples: [Double] = []
        for _ in 0..<12 {
            model.pageDragOffset = -model.pageWidth
            commitSamples.append(ms {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    model.currentPage = min(model.currentPage + 1, model.pageCount - 1)
                    model.pageDragOffset = 0
                }
                renderOnce(hosting)
            })
            if model.currentPage >= model.pageCount - 1 {
                var back = Transaction()
                back.disablesAnimations = true
                withTransaction(back) { model.currentPage = 0; model.pageDragOffset = 0 }
                _ = ms { renderOnce(hosting) }
            }
        }
        record("[window] 窗口化条带 落位原子换页  " + Samples(commitSamples).summary("12 次"))

        // 落位换页·预建（真实路径镜像）：settlePageDrag 置 pendingCommitDirection →
        // 落位首帧把窗口扩到 4 页（物化成本移到这里）→ takeOverPageSettle 取消定时
        // 收尾并钉住偏移 → 原子换页帧不再物化新页。与上方未预建的落位换页对照。
        var prebuildStart: [Double] = []
        var prebuiltCommit: [Double] = []
        for _ in 0..<12 {
            if model.currentPage >= model.pageCount - 1 {
                var back = Transaction()
                back.disablesAnimations = true
                withTransaction(back) { model.currentPage = 0; model.pageDragOffset = 0 }
                _ = ms { renderOnce(hosting) }
            }
            model.pageDragOffset = -model.pageWidth * 0.9
            model.settlePageDrag(commitDirection: 1)
            prebuildStart.append(ms { renderOnce(hosting) })
            #expect(model.pendingCommitDirection == 1)
            _ = model.takeOverPageSettle()
            prebuiltCommit.append(ms {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    model.currentPage = min(model.currentPage + 1, model.pageCount - 1)
                    model.pageDragOffset = 0
                }
                renderOnce(hosting)
            })
        }
        record("[window] 落位·预建：动画首帧(承担预建)  " + Samples(prebuildStart).summary("12 次"))
        record("[window] 落位·预建：原子换页帧          " + Samples(prebuiltCommit).summary("12 次"))

        // 归因探针 P：窗口右缘「仅移除」换页 6→7（窗口 [5,6,7]→[6,7]：只移除页 5，无新增）。
        // 结论（探针 P/Q 对照，release 实测）：基础渲染 ~4ms；窗口变化帧中，仅新增
        // ~+4ms（预建帧 8.5ms）、仅移除 ~+7ms（P 11.3ms），而新增+移除同帧叠加时
        // display-list/层树增删交互放大到 ~30ms（未预建的落位换页、窗口边缘的键盘翻页）。
        // 预建把「新增」移出换页帧后，换页帧只剩「移除」一项。
        var removalOnly: [Double] = []
        for _ in 0..<12 {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { model.currentPage = 6; model.pageDragOffset = 0 }
            _ = ms { renderOnce(hosting) }
            spinRunLoop(0.05)
            removalOnly.append(ms {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { model.currentPage = 7; model.pageDragOffset = 0 }
                renderOnce(hosting)
            })
            var back = Transaction()
            back.disablesAnimations = true
            withTransaction(back) { model.currentPage = 6 }
            _ = ms { renderOnce(hosting) }
        }
        record("[window] 探针P 仅移除换页(6→7, 窗口右缘)          " + Samples(removalOnly).summary("12 次"))

        // 归因探针 Q：窗口左缘「仅新增」换页 0→1 后回跳 1→0 —— 窗口 [0,1,2] 恒定，
        // 无增无删，对照 P。
        var noChurnFlip: [Double] = []
        for _ in 0..<12 {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { model.currentPage = 0; model.pageDragOffset = 0 }
            _ = ms { renderOnce(hosting) }
            noChurnFlip.append(ms {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { model.currentPage = 1; model.pageDragOffset = 0 }
                renderOnce(hosting)
            })
            var back = Transaction()
            back.disablesAnimations = true
            withTransaction(back) { model.currentPage = 0 }
            _ = ms { renderOnce(hosting) }
        }
        record("[window] 探针Q 无增删换页(0↔1, 窗口恒定)          " + Samples(noChurnFlip).summary("12 次"))

        window.orderOut(nil)
        window.contentView = nil
        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-window.txt", atomically: true, encoding: .utf8)
    }

    // MARK: 诊断 9：耗电探测 —— 三种状态的 CPU 时间消耗（runloop 静置各 8 秒）

    /// CPU 时间是能耗的直接代理（Apple Silicon 包功耗随 CPU 时间近似线性）。
    /// - 基线：runloop 空转（无窗口）；
    /// - 可见静置（玻璃材质）：NSVisualEffectView 实时毛玻璃的持续成本上界；
    /// - 可见静置（壁纸）：真实默认配置（blurWallpaper=true，捕获侧预模糊静态图）；
    /// - 收起静置：orderOut 后（对齐真实 App hide 完成后的状态）。
    @Test func idleEnergyProbe() async throws {
        func cpuTime() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        }
        func measureIdle(_ seconds: Double) -> Double {
            let start = cpuTime()
            spinRunLoop(seconds)
            return cpuTime() - start
        }

        // 基线：无任何窗口
        let baseline = measureIdle(8)

        let appCount = 8 * Self.perPage
        let (paths, _) = collectAppPaths(appCount)
        let repo = AppIconRepository()
        for path in paths { _ = repo.icon(forPath: path) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchXPageFlipIdle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, _) = makeModel(paths: paths, perPage: Self.perPage, icons: repo, directory: dir)

        let wallpaperStore = LaunchpadWallpaperStore()
        let hosting = NSHostingView(rootView: AnyView(
            LaunchpadContentView(model: model, wallpaper: wallpaperStore, gridFocus: GridKeyboardFocus())
        ))
        let window = makeWindow(width: Self.windowSize.width, height: Self.windowSize.height, hosting: hosting)
        _ = ms { renderOnce(hosting) }
        spinRunLoop(0.3)

        // 可见静置（默认玻璃材质路径，无壁纸 = 实时毛玻璃上界）
        let glassIdle = measureIdle(8)

        // 可见静置（壁纸路径 = 真实默认配置：静态预模糊图）
        let image = NSImage(size: NSSize(width: 600, height: 400))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 600, height: 400).fill(); image.unlockFocus()
        wallpaperStore.image = image
        _ = ms { renderOnce(hosting) }
        spinRunLoop(0.3)
        let wallpaperIdle = measureIdle(8)
        wallpaperStore.image = nil

        // 收起静置（orderOut）
        window.orderOut(nil)
        spinRunLoop(0.3)
        let hiddenIdle = measureIdle(8)

        record(String(format: "[idle] 8 秒静置 CPU 时间：基线(无窗口)=%.3fs  可见·玻璃=%.3fs  可见·壁纸=%.3fs  收起=%.3fs",
                      baseline, glassIdle, wallpaperIdle, hiddenIdle))
        try? reportLines.joined(separator: "\n")
            .write(toFile: "/tmp/launchx-pageflip-idle.txt", atomically: true, encoding: .utf8)
    }
}
