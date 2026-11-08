// LaunchX 原创图标生成器（纯 CoreGraphics，无窗口依赖）
// 设计：深空渐变底板 + 3×3 应用瓦片网格（启动台隐喻），中央瓦片为白色焦点
// 用法: swift icon_gen.swift <输出.png> <边长px>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3,
      let size = Double(CommandLine.arguments[2]), size > 0 else {
    FileHandle.standardError.write("用法: icon_gen.swift <输出.png> <边长px>\n".data(using: .utf8)!)
    exit(64)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let s = size

// ---- 基础画布 ----
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

// 逻辑坐标：以 512 为基准按比例缩放，y 轴向上（CG 默认）
let k = s / 512.0
func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: (512 - y) * k) }
func len(_ v: Double) -> CGFloat { CGFloat(v * k) }

// ---- 圆角方形底板 + 深空渐变 ----
let radius = 116.0 * k
let board = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                   cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(board)
ctx.clip()

// 深藏青 → 靛蓝，对角渐变（呼应全屏覆盖层的深色底）
let bgColors = [CGColor(red: 0.10, green: 0.11, blue: 0.26, alpha: 1.0),
                CGColor(red: 0.20, green: 0.22, blue: 0.48, alpha: 1.0)] as CFArray
let bgGrad = CGGradient(colorsSpace: space, colors: bgColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(bgGrad, start: pt(0, 0), end: pt(512, 512), options: [])

// 中央提亮的径向光晕，让瓦片区域有舞台感
let glowColors = [CGColor(red: 0.38, green: 0.42, blue: 0.92, alpha: 0.45),
                  CGColor(red: 0.38, green: 0.42, blue: 0.92, alpha: 0.0)] as CFArray
let glow = CGGradient(colorsSpace: space, colors: glowColors, locations: [0.0, 1.0])!
ctx.drawRadialGradient(glow, startCenter: pt(256, 256), startRadius: 0,
                       endCenter: pt(256, 256), endRadius: 300 * k, options: [])

// 边缘暗角，压深四角、聚拢视线
let vg = [CGColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 0.22),
          CGColor(red: 0.02, green: 0.03, blue: 0.10, alpha: 0.0)] as CFArray
let vignette = CGGradient(colorsSpace: space, colors: vg, locations: [0.0, 1.0])!
ctx.drawRadialGradient(vignette, startCenter: pt(256, 256), startRadius: 240 * k,
                       endCenter: pt(256, 256), endRadius: 560 * k, options: [])

// ---- 顶部高光（白→透明，玻璃质感）----
let hl = [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
          CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray
let hlGrad = CGGradient(colorsSpace: space, colors: hl, locations: [0.0, 1.0])!
ctx.drawLinearGradient(hlGrad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.55), options: [])

// ---- 3×3 应用瓦片网格 ----
let margin = 92.0, gap = 22.0
let tile = (512.0 - 2 * margin - 2 * gap) / 3.0  // ≈ 96
let tileRadius = tile * 0.26

// 每格一色（亮色 + 同系深色，纵向渐变），中央为白色焦点瓦片
func cg(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: 1)
}
let tilePairs: [[(CGColor, CGColor)]] = [
    [(cg(1.00, 0.36, 0.32), cg(1.00, 0.62, 0.25)), (cg(1.00, 0.62, 0.10), cg(1.00, 0.82, 0.30)), (cg(0.16, 0.72, 0.30), cg(0.50, 0.88, 0.36))],
    [(cg(0.05, 0.50, 0.92), cg(0.28, 0.72, 0.98)), (cg(1, 1, 1), cg(1, 1, 1)), (cg(0.55, 0.22, 0.88), cg(0.78, 0.38, 0.94))],
    [(cg(0.92, 0.28, 0.56), cg(1.00, 0.48, 0.42)), (cg(0.08, 0.66, 0.64), cg(0.26, 0.82, 0.80)), (cg(0.24, 0.42, 0.94), cg(0.54, 0.52, 1.00))],
]

for row in 0..<3 {
    for col in 0..<3 {
        let x = margin + Double(col) * (tile + gap)
        let y = margin + Double(row) * (tile + gap)
        let rect = CGRect(x: len(x), y: len(512 - y - tile), width: len(tile), height: len(tile))
        let path = CGPath(roundedRect: rect, cornerWidth: len(tileRadius),
                          cornerHeight: len(tileRadius), transform: nil)

        ctx.saveGState()
        // 瓦片落影：先带阴影填充，再裁剪进路径画渐变
        ctx.setShadow(offset: CGSize(width: 0, height: len(-7)), blur: len(12),
                      color: CGColor(red: 0.02, green: 0.03, blue: 0.12, alpha: 0.50))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.clip()

        let pair = tilePairs[row][col]
        if row == 1 && col == 1 {
            // 中央焦点瓦片：纯白 + 顶部微渐变
            let w = [CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                     CGColor(red: 0.94, green: 0.95, blue: 1.00, alpha: 1)] as CFArray
            let wg = CGGradient(colorsSpace: space, colors: w, locations: [0.0, 1.0])!
            ctx.drawLinearGradient(wg, start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.minX, y: rect.minY), options: [])
        } else {
            let colors = [pair.0, pair.1] as CFArray
            let g2 = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0])!
            ctx.drawLinearGradient(g2, start: CGPoint(x: rect.minX, y: rect.maxY),
                                   end: CGPoint(x: rect.minX, y: rect.minY), options: [])
        }
        // 瓦片顶部高光
        let th = [CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
                  CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray
        let thg = CGGradient(colorsSpace: space, colors: th, locations: [0.0, 1.0])!
        ctx.drawLinearGradient(thg, start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.minX, y: rect.maxY - len(tile * 0.55)), options: [])
        ctx.restoreGState()
    }
}

ctx.restoreGState() // board clip

// ---- 输出 PNG ----
let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("PNG 写入失败: \(outputURL.path)\n".data(using: .utf8)!)
    exit(1)
}
