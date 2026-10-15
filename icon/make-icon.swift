// Draws HubTouch's app icon at every size macOS needs and packs them into AppIcon.icns.
// Usage: swift icon/make-icon.swift   (run from the repository root)

import AppKit

/// Design canvas; every coordinate below is in this 1024-point space.
let canvasSize: CGFloat = 1024

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func drawBackground() {
    // macOS icon grid: an 824-point rounded square centered on the canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0x3D3DD6).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x6C5CF5), ending: color(0x2F8BF7))?.draw(in: path, angle: -60)
}

func drawPhone() -> NSRect {
    let phone = NSRect(x: 347, y: 212, width: 330, height: 600)
    let path = NSBezierPath(roundedRect: phone, xRadius: 72, yRadius: 72)
    color(0xFFFFFF, alpha: 0.14).setFill()
    path.fill()
    path.lineWidth = 26
    NSColor.white.setStroke()
    path.stroke()
    return phone
}

func drawTouchPoint(at center: NSPoint) {
    for (radius, alpha) in [(84.0, 0.18), (66.0, 0.3)] as [(CGFloat, CGFloat)] {
        color(0xFFFFFF, alpha: alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
    }
    let radius: CGFloat = 46
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
}

/// Arrow pointing away from the phone's center, showing the fingers spreading in a pinch.
func drawPinchArrow(from start: NSPoint, direction: CGVector) {
    let length: CGFloat = 72
    let tip = NSPoint(x: start.x + direction.dx * length, y: start.y + direction.dy * length)
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: tip)
    shaft.lineWidth = 20
    shaft.lineCapStyle = .round
    NSColor.white.setStroke()
    shaft.stroke()

    let headLength: CGFloat = 40
    let angle = atan2(direction.dy, direction.dx)
    let head = NSBezierPath()
    for side in [-1.0, 1.0] as [CGFloat] {
        let wingAngle = angle + .pi - side * (.pi / 4)
        head.move(to: tip)
        head.line(to: NSPoint(x: tip.x + cos(wingAngle) * headLength, y: tip.y + sin(wingAngle) * headLength))
    }
    head.lineWidth = 20
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()
}

func drawIcon(pixelSize: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixelSize) / canvasSize
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

    drawBackground()
    let phone = drawPhone()
    let center = NSPoint(x: phone.midX, y: phone.midY)
    // Toward the phone's corners, so the gesture and its arrows stay inside the outline.
    let cornerLength = hypot(phone.width / 2, phone.height / 2)
    let diagonal = CGVector(dx: phone.width / 2 / cornerLength, dy: phone.height / 2 / cornerLength)
    func point(along direction: CGVector, from origin: NSPoint, distance: CGFloat) -> NSPoint {
        NSPoint(x: origin.x + direction.dx * distance, y: origin.y + direction.dy * distance)
    }
    let reversed = CGVector(dx: -diagonal.dx, dy: -diagonal.dy)
    let upperRight = point(along: diagonal, from: center, distance: 120)
    let lowerLeft = point(along: reversed, from: center, distance: 120)
    // Arrows turn into noise at the smallest sizes, so those show only the touch points.
    if pixelSize > 64 {
        drawPinchArrow(from: point(along: diagonal, from: upperRight, distance: 70), direction: diagonal)
        drawPinchArrow(from: point(along: reversed, from: lowerLeft, distance: 70), direction: reversed)
    }
    drawTouchPoint(at: upperRight)
    drawTouchPoint(at: lowerLeft)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let iconDirectory = URL(fileURLWithPath: "icon")
let iconset = iconDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let png = drawIcon(pixelSize: pointSize * scale).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appendingPathComponent("icon_\(pointSize)x\(pointSize)\(suffix).png"))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", iconDirectory.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote icon/AppIcon.icns" : "iconutil failed")
