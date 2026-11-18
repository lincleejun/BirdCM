// Draws the app icon (pine-green tile, cream perched bird with an eye) and the menu-bar template image.
// swift macos/tools/icon.swift OUT_DIR  ->  OUT_DIR/AppIcon.iconset/*.png, OUT_DIR/MenuIcon.png, OUT_DIR/MenuIcon@2x.png
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let pine = NSColor(srgbRed: 0x25 / 255.0, green: 0x4d / 255.0, blue: 0x39 / 255.0, alpha: 1)
let pineDark = NSColor(srgbRed: 0x18 / 255.0, green: 0x35 / 255.0, blue: 0x27 / 255.0, alpha: 1)
let cream = NSColor(srgbRed: 0xff / 255.0, green: 0xfd / 255.0, blue: 0xf4 / 255.0, alpha: 1)

/// A perched bird facing right in a 100 x 100 box: round head, beak, body tapering to a tail, a branch.
func bird(in r: CGRect) -> (body: NSBezierPath, eye: NSBezierPath, branch: NSBezierPath) {
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x / 100 * r.width, y: r.minY + y / 100 * r.height) }
    let s = r.width / 100
    let b = NSBezierPath()
    b.move(to: p(14, 30))                                              // tail tip
    b.curve(to: p(40, 44), controlPoint1: p(24, 34), controlPoint2: p(32, 38))
    b.curve(to: p(56, 66), controlPoint1: p(42, 56), controlPoint2: p(46, 64))   // back up to the nape
    b.curve(to: p(72, 80), controlPoint1: p(58, 74), controlPoint2: p(64, 80))   // crown
    b.curve(to: p(80, 72), controlPoint1: p(77, 80), controlPoint2: p(79, 76))
    b.line(to: p(90, 69))                                              // beak tip
    b.line(to: p(79, 65))
    b.curve(to: p(70, 50), controlPoint1: p(78, 59), controlPoint2: p(76, 54))   // throat, breast
    b.curve(to: p(52, 34), controlPoint1: p(66, 42), controlPoint2: p(60, 36))   // belly
    b.curve(to: p(14, 30), controlPoint1: p(40, 32), controlPoint2: p(24, 28))
    b.close()
    let eye = NSBezierPath(ovalIn: CGRect(x: p(72, 71).x - 3.4 * s, y: p(72, 71).y - 3.4 * s, width: 6.8 * s, height: 6.8 * s))
    let branch = NSBezierPath()
    branch.lineWidth = 5 * s
    branch.lineCapStyle = .round
    branch.move(to: p(30, 27))
    branch.line(to: p(84, 27))
    let leg = NSBezierPath()
    leg.move(to: p(52, 35)); leg.line(to: p(52, 27))
    leg.move(to: p(60, 37)); leg.line(to: p(60, 27))
    branch.append(leg)
    return (b, eye, branch)
}

func png(_ size: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ r: CGRect) {
    let tile = r.insetBy(dx: r.width * 0.1, dy: r.width * 0.1)       // the macOS icon grid: 824 of 1024
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: pine, ending: pineDark)!.draw(in: path, angle: -90)
    let (b, eye, branch) = bird(in: tile.insetBy(dx: tile.width * 0.12, dy: tile.width * 0.12))
    cream.setFill(); b.fill()
    cream.setStroke(); branch.stroke()
    pine.setFill(); eye.fill()
}

func menuIcon(_ r: CGRect) {
    let (b, eye, branch) = bird(in: r.insetBy(dx: -r.width * 0.04, dy: -r.width * 0.06).offsetBy(dx: 0, dy: r.width * 0.06))
    NSColor.black.setFill(); b.fill()
    NSColor.black.setStroke(); branch.stroke()
    NSGraphicsContext.current!.compositingOperation = .clear
    eye.fill()
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try png(pt, appIcon).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try png(pt * 2, appIcon).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
try png(18, menuIcon).write(to: out.appendingPathComponent("MenuIcon.png"))
try png(36, menuIcon).write(to: out.appendingPathComponent("MenuIcon@2x.png"))
