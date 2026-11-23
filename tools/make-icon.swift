// Renders the app icon: a line-drawn globe with a knocked-out "DNS" pill (echoing the
// menu bar badge) on a solid squircle. Writes AppIcon.iconset/ and Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift [preview.png]
import AppKit

let background = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)  // near-black ink
let ink = NSColor.white

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt squircle centred on a 1024 canvas, soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(background.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Globe.
    let c = CGPoint(x: 470, y: 548), r: CGFloat = 250, w: CGFloat = 34
    ctx.setStrokeColor(ink.cgColor)
    ctx.setLineWidth(w)
    ctx.setLineCap(.round)
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    // Meridians: centre line + one ellipse.
    ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r)); ctx.strokePath()
    ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.48, y: c.y - r, width: r * 0.96, height: 2 * r))
    // Parallels: equator + two latitudes.
    for dy in [0, r * 0.5, -r * 0.5] {
        ctx.move(to: CGPoint(x: c.x - r, y: c.y + dy)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y + dy)); ctx.strokePath()
    }
    ctx.restoreGState()

    // "DNS" pill over the bottom-right of the globe, with a clear ring cut out around it.
    let pill = CGRect(x: 470, y: 250, width: 330, height: 170)
    let gap: CGFloat = 30
    ctx.setBlendMode(.normal)
    ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: -gap, dy: -gap), cornerWidth: 85 + gap, cornerHeight: 85 + gap, transform: nil))
    ctx.setFillColor(background.cgColor)
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 85, cornerHeight: 85, transform: nil))
    ctx.setFillColor(ink.cgColor)
    ctx.fillPath()

    let font = NSFont.systemFont(ofSize: 112, weight: .heavy)
    let text = NSAttributedString(string: "DNS", attributes: [.font: font, .foregroundColor: background, .kern: 2])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: pill.midX - bounds.width / 2 - bounds.minX, y: pill.midY - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)

    ctx.restoreGState()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(in: NSGraphicsContext.current!.cgContext, size: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let res = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", res.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
if CommandLine.arguments.count > 1 { try png(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
