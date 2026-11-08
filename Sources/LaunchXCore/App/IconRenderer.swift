import AppKit

/// LaunchX 图标渲染器：程序坞图标与菜单栏模板图标共用
/// 「深空底 + 应用瓦片网格」视觉语言，与 resources/AppIcon.icns（scripts/icon_gen.swift 生成）同源。
enum AppIconRenderer {

    // MARK: - 程序坞图标

    /// 自绘主题图标（128pt）：
    /// - brand：彩色九宫格 + 白色焦点瓦（与 .icns 完全一致）
    /// - classic：2×2 玻璃瓦（暗色为白玻璃，亮色为石墨）
    /// - launchx：白玻璃九宫格 + 彩色焦点瓦
    /// - rocket：彩色九宫格 + 橙色焦点瓦 + 白色火箭符号
    nonisolated static func appIcon(for theme: AppIconTheme, dark: Bool) -> NSImage {
        let side: CGFloat = 128
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

        let palette = Self.palette(for: theme, dark: dark)
        drawBoard(in: ctx, side: side, palette: palette)
        drawTiles(in: ctx, side: side, palette: palette)
        if palette.rocketCenter {
            drawRocketBadge(in: ctx, side: side, rows: palette.tiles.count)
        }
        return image
    }

    // MARK: - 菜单栏模板图标

    /// 菜单栏模板图标：与新图标同语言的圆角瓦片网格（classic 为 2×2，其余 3×3）。
    nonisolated static func menuBarIcon(for theme: AppIconTheme) -> NSImage {
        let side: CGFloat = 18
        let count = theme == .classic ? 2 : 3
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        defer { image.unlockFocus() }

        let margin = side * 0.06
        let gap = side * 0.115
        let tile = (side - 2 * margin - CGFloat(count - 1) * gap) / CGFloat(count)
        NSColor.black.setFill()
        for row in 0..<count {
            for col in 0..<count {
                let rect = CGRect(x: margin + CGFloat(col) * (tile + gap),
                                  y: margin + CGFloat(row) * (tile + gap),
                                  width: tile, height: tile)
                NSBezierPath(roundedRect: rect, xRadius: tile * 0.32, yRadius: tile * 0.32).fill()
            }
        }
        image.isTemplate = true
        return image
    }

    // MARK: - 主题调色板

    private struct Palette {
        var boardTop: CGColor
        var boardBottom: CGColor
        var glow: CGColor
        var tiles: [[(CGColor, CGColor)]]   // 每格（顶部色, 底部色），行序自上而下
        var rocketCenter = false
    }

    private static func palette(for theme: AppIconTheme, dark: Bool) -> Palette {
        switch theme {
        case .brand:
            return Palette(
                boardTop: cg(0.10, 0.11, 0.26), boardBottom: cg(0.20, 0.22, 0.48),
                glow: cg(0.38, 0.42, 0.92),
                tiles: coloredTiles(center: (cg(1, 1, 1), cg(0.94, 0.95, 1.00)))
            )
        case .classic where dark:
            return Palette(
                boardTop: cg(0.09, 0.09, 0.11), boardBottom: cg(0.22, 0.22, 0.26),
                glow: cg(0.55, 0.55, 0.60),
                tiles: [[glass(0.98, 0.98, 1.00, top: 0.95, bottom: 0.82),
                         glass(0.98, 0.98, 1.00, top: 0.95, bottom: 0.82)],
                        [glass(0.98, 0.98, 1.00, top: 0.95, bottom: 0.82),
                         glass(0.98, 0.98, 1.00, top: 0.95, bottom: 0.82)]]
            )
        case .classic:
            return Palette(
                boardTop: cg(0.86, 0.87, 0.90), boardBottom: cg(0.70, 0.71, 0.76),
                glow: cg(0.45, 0.47, 0.55),
                tiles: [[glass(0.24, 0.26, 0.32, top: 0.88, bottom: 0.78),
                         glass(0.24, 0.26, 0.32, top: 0.88, bottom: 0.78)],
                        [glass(0.24, 0.26, 0.32, top: 0.88, bottom: 0.78),
                         glass(0.24, 0.26, 0.32, top: 0.88, bottom: 0.78)]]
            )
        case .launchx:
            let glass: (CGColor, CGColor) = (cg(0.98, 0.98, 1.00, 0.95), cg(0.90, 0.90, 0.95, 0.85))
            return Palette(
                boardTop: cg(0.03, 0.11, 0.22), boardBottom: cg(0.05, 0.24, 0.40),
                glow: cg(0.16, 0.58, 0.78),
                tiles: [[glass, glass, glass],
                        [glass, (cg(0.05, 0.50, 0.92), cg(0.28, 0.72, 0.98)), glass],
                        [glass, glass, glass]]
            )
        case .rocket:
            return Palette(
                boardTop: cg(0.08, 0.10, 0.22), boardBottom: cg(0.16, 0.20, 0.44),
                glow: cg(0.38, 0.42, 0.92),
                tiles: coloredTiles(center: (cg(1.00, 0.42, 0.15), cg(1.00, 0.68, 0.28))),
                rocketCenter: true
            )
        }
    }

    /// 彩色九宫格（与 .icns 相同的色表），center 为焦点瓦配色（nil 保留彩色）。
    private static func coloredTiles(center: (CGColor, CGColor)?) -> [[(CGColor, CGColor)]] {
        var tiles = [[(cg(1.00, 0.36, 0.32), cg(1.00, 0.62, 0.25)), (cg(1.00, 0.62, 0.10), cg(1.00, 0.82, 0.30)), (cg(0.16, 0.72, 0.30), cg(0.50, 0.88, 0.36))],
                     [(cg(0.05, 0.50, 0.92), cg(0.28, 0.72, 0.98)), (cg(1, 1, 1), cg(1, 1, 1)), (cg(0.55, 0.22, 0.88), cg(0.78, 0.38, 0.94))],
                     [(cg(0.92, 0.28, 0.56), cg(1.00, 0.48, 0.42)), (cg(0.08, 0.66, 0.64), cg(0.26, 0.82, 0.80)), (cg(0.24, 0.42, 0.94), cg(0.54, 0.52, 1.00))]]
        if let center { tiles[1][1] = center }
        return tiles
    }

    private static func glass(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, top: CGFloat, bottom: CGFloat) -> (CGColor, CGColor) {
        (cg(r, g, b, top), cg(r, g, b, bottom))
    }

    private static func cg(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    // MARK: - 绘制（512 逻辑坐标等比缩放，与 icon_gen.swift 同源）

    private static func drawBoard(in ctx: CGContext, side: CGFloat, palette: Palette) {
        let k = side / 512.0
        let radius = 116.0 * Double(k)
        let board = CGPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                           cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(board)
        ctx.clip()

        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bg = CGGradient(colorsSpace: space, colors: [palette.boardTop, palette.boardBottom] as CFArray,
                            locations: [0.0, 1.0])!
        // 对角渐变：palette.boardTop 在左上、boardBottom 在右下（y 轴向上）
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: side), end: CGPoint(x: side, y: 0), options: [])

        let glow = CGGradient(colorsSpace: space, colors: [palette.glow.copy(alpha: 0.45)!, palette.glow.copy(alpha: 0.0)!] as CFArray,
                              locations: [0.0, 1.0])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: side / 2, y: side / 2), startRadius: 0,
                               endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: 300 * k, options: [])

        let vg = CGGradient(colorsSpace: space,
                            colors: [CGColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 0.22),
                                     CGColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 0.0)] as CFArray,
                            locations: [0.0, 1.0])!
        ctx.drawRadialGradient(vg, startCenter: CGPoint(x: side / 2, y: side / 2), startRadius: 240 * k,
                               endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: 560 * k, options: [])

        let hl = CGGradient(colorsSpace: space,
                            colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                                     CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                            locations: [0.0, 1.0])!
        ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: side), end: CGPoint(x: 0, y: side * 0.55), options: [])
        ctx.restoreGState()
    }

    private static func drawTiles(in ctx: CGContext, side: CGFloat, palette: Palette) {
        let k = side / 512.0
        let rows = palette.tiles.count
        let margin: CGFloat = rows >= 3 ? 92 : 118
        let gap: CGFloat = rows >= 3 ? 22 : 26
        let tile = (512 - 2 * margin - CGFloat(rows - 1) * gap) / CGFloat(rows)
        let tileRadius = tile * 0.26

        for (r, row) in palette.tiles.enumerated() {
            for (c, pair) in row.enumerated() {
                let x = margin + CGFloat(c) * (tile + gap)
                let y = margin + CGFloat(r) * (tile + gap)
                // 逻辑坐标 y 向下，转 CG y 轴向上
                let rect = CGRect(x: CGFloat(x) * k, y: (512 - y - tile) * k,
                                  width: tile * k, height: tile * k)
                let path = CGPath(roundedRect: rect, cornerWidth: tileRadius * k,
                                  cornerHeight: tileRadius * k, transform: nil)

                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -7 * k), blur: 12 * k,
                              color: CGColor(red: 0.02, green: 0.03, blue: 0.12, alpha: 0.50))
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                ctx.addPath(path)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.clip()

                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                let g = CGGradient(colorsSpace: space, colors: [pair.0, pair.1] as CFArray,
                                   locations: [0.0, 1.0])!
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
                                       end: CGPoint(x: rect.minX, y: rect.minY), options: [])

                let th = CGGradient(colorsSpace: space,
                                    colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
                                             CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                                    locations: [0.0, 1.0])!
                ctx.drawLinearGradient(th, start: CGPoint(x: rect.minX, y: rect.maxY),
                                       end: CGPoint(x: rect.minX, y: rect.maxY - tile * 0.55 * k), options: [])
                ctx.restoreGState()
            }
        }
    }

    /// 火箭主题：中央瓦片上叠白色火箭符号。
    private static func drawRocketBadge(in ctx: CGContext, side: CGFloat, rows: Int) {
        let k = side / 512.0
        let margin: CGFloat = 92
        let gap: CGFloat = 22
        let tile = (512 - 2 * margin - 2 * gap) / 3
        // 中央瓦片中心（第 1 行第 1 列）
        let cx = (margin + tile + gap + tile / 2) * k
        let cy = (512 - margin - tile - gap - tile / 2) * k

        guard let base = NSImage(systemSymbolName: "rocket.fill", accessibilityDescription: "LaunchX")?
            .withSymbolConfiguration(.init(pointSize: tile * 0.62 * k, weight: .semibold)) else { return }
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let drawRect = CGRect(x: cx - base.size.width / 2, y: cy - base.size.height / 2,
                              width: base.size.width, height: base.size.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * k), blur: 3 * k,
                      color: CGColor(red: 0.30, green: 0.10, blue: 0.0, alpha: 0.35))
        tinted.draw(in: drawRect)
        ctx.restoreGState()
    }
}
