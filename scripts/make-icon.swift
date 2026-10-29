// Draws the app icon and writes Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
// A dark zinc tile, a loop ring in the app's indigo accent with a play head in the green of the
// transport, and a short waveform inside the ring.
import AppKit
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources", isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // The macOS tile: a squircle-like rounded square with a margin, as the system icons have.
    let margin = s * 0.1
    let tile = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.height * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: color(0x000000, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x18181B))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x2E2E35), color(0x141417)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    // A faint beat grid behind everything.
    ctx.setStrokeColor(color(0xFFFFFF, 0.05))
    ctx.setLineWidth(max(1, s * 0.004))
    for i in 1..<8 {
        let x = tile.minX + tile.width * CGFloat(i) / 8
        ctx.move(to: CGPoint(x: x, y: tile.minY)); ctx.addLine(to: CGPoint(x: x, y: tile.maxY))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // The loop ring: an open arc in indigo, with a small arrowhead at its end, like a loop brace bent round.
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = tile.width * 0.30
    let lw = s * 0.062
    ctx.setLineCap(.round)
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(color(0x818CF8))
    let start = CGFloat.pi * 0.62, end = CGFloat.pi * 2.38
    ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
    ctx.strokePath()
    // The arrowhead at the arc's end, pointing along the arc.
    let tip = CGPoint(x: c.x + r * cos(end), y: c.y + r * sin(end))
    let tangent = CGPoint(x: -sin(end), y: cos(end))
    let normal = CGPoint(x: cos(end), y: sin(end))
    let ah = s * 0.11, aw = s * 0.085
    ctx.setFillColor(color(0x818CF8))
    ctx.move(to: CGPoint(x: tip.x + tangent.x * ah, y: tip.y + tangent.y * ah))
    ctx.addLine(to: CGPoint(x: tip.x + normal.x * aw, y: tip.y + normal.y * aw))
    ctx.addLine(to: CGPoint(x: tip.x - normal.x * aw, y: tip.y - normal.y * aw))
    ctx.closePath()
    ctx.fillPath()

    // The waveform inside the ring: a few bars, the tallest in the middle.
    let heights: [CGFloat] = [0.28, 0.55, 0.9, 0.62, 0.4, 0.75, 0.32]
    let bw = s * 0.045, gap = s * 0.028
    let totalW = CGFloat(heights.count) * bw + CGFloat(heights.count - 1) * gap
    var x = c.x - totalW / 2
    for (i, h) in heights.enumerated() {
        let bh = r * 1.05 * h
        let rect = CGRect(x: x, y: c.y - bh / 2, width: bw, height: bh)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: bw / 2, cornerHeight: bw / 2, transform: nil))
        ctx.setFillColor(i == 2 ? color(0x4ADE80) : color(0xF4F4F5, i % 2 == 0 ? 0.92 : 0.7))
        ctx.fillPath()
        x += bw + gap
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    write(draw(size: base), "icon_\(base)x\(base).png")
    write(draw(size: base * 2), "icon_\(base)x\(base)@2x.png")
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
// A preview PNG next to it, for the README and for a look.
write(draw(size: 512), "../AppIcon-preview.png")
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote \(out.appendingPathComponent("AppIcon.icns").path)" : "iconutil failed")
