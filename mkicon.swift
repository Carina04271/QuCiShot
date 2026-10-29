import Foundation
import AppKit
import CoreGraphics

// 生成 1024x1024 圆角正方形图标（外部透明），macOS 会再套一层统一圆角形状。
// 设计：蓝底 + 晾衣绳上的三张白卡片 + 白色取词框，呼应「晾衣绳截图」。

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }

let canvas = CGRect(x: 0, y: 0, width: size, height: size)

// MARK: 圆角底板（inset 让图标有呼吸感，四角透明）
let inset: CGFloat = 24
let plate = canvas.insetBy(dx: inset, dy: inset)
let radius: CGFloat = 232 // ≈ 22.7%，接近 macOS 标准圆角比例
let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()

// 竖向渐变：亮蓝 -> 深蓝
let colors = [
    CGColor(red: 0.36, green: 0.62, blue: 0.99, alpha: 1),  // #5C9EFC
    CGColor(red: 0.11, green: 0.38, blue: 0.92, alpha: 1),  // #1C61EB
    CGColor(red: 0.05, green: 0.24, blue: 0.72, alpha: 1),  // #0D3DB8
] as CFArray
if let gradient = CGGradient(colorsSpace: cs, colors: colors, locations: [0.0, 0.55, 1.0]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])
}

// 顶部高光，增加质感
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
ctx.fill(CGRect(x: plate.minX, y: plate.maxY - 300, width: plate.width, height: 300))
ctx.restoreGState()

// MARK: 顶部晾衣绳
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.90))
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 196, y: 726))
ctx.addLine(to: CGPoint(x: 828, y: 726))
ctx.strokePath()

// MARK: 卡片（夹子挂在绳子上）
func card(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, clipColor: CGColor) {
    // 投影
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.20))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x + 6, y: y - 10, width: w, height: h),
                             cornerWidth: 20, cornerHeight: 20, transform: nil))
    ctx.fillPath()
    // 白色卡纸
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                       cornerWidth: 20, cornerHeight: 20, transform: nil))
    ctx.fillPath()

    // 卡片上的文字线
    ctx.setStrokeColor(CGColor(red: 0.62, green: 0.68, blue: 0.76, alpha: 1))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    var ly = y + h - 42
    var lw = w - 44
    while ly > y + 34 {
        ctx.move(to: CGPoint(x: x + 22, y: ly))
        ctx.addLine(to: CGPoint(x: x + 22 + lw, y: ly))
        lw = max(46, lw - 48)
        ly -= 38
    }
    ctx.strokePath()

    // 夹子（从卡片顶边向上伸，跨过绳子）
    let clipRect = CGRect(x: x + w / 2 - 24, y: y + h - 10, width: 48, height: 70)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.14))
    ctx.addPath(CGPath(roundedRect: clipRect.offsetBy(dx: 3, dy: -3),
                       cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(clipColor)
    ctx.addPath(CGPath(roundedRect: clipRect, cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.fillPath()
}

// 左右两张小卡片（先画，压在后面）
card(x: 176, y: 448, w: 168, h: 208,
     clipColor: CGColor(red: 0.13, green: 0.83, blue: 0.83, alpha: 1)) // 青 #22D3EE
card(x: 680, y: 448, w: 168, h: 208,
     clipColor: CGColor(red: 0.29, green: 0.87, blue: 0.50, alpha: 1)) // 绿 #4ADE80

// 中间大卡片（正在识别的那张）
card(x: 302, y: 330, w: 420, h: 336,
     clipColor: CGColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)) // 橙 #F59E0B

// MARK: 取词框选标记（白框 + 对角十字）
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(CGPath(roundedRect: CGRect(x: 348, y: 452, width: 328, height: 96),
                                 cornerWidth: 10, cornerHeight: 10, transform: nil))
ctx.setLineWidth(15)
ctx.strokePath()

ctx.setLineWidth(11)
ctx.move(to: CGPoint(x: 348, y: 452)); ctx.addLine(to: CGPoint(x: 676, y: 548))
ctx.move(to: CGPoint(x: 676, y: 452)); ctx.addLine(to: CGPoint(x: 348, y: 548))
ctx.strokePath()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: "Resources/icon.png"))
print("icon written \(size)x\(size)")
