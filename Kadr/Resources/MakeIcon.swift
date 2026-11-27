import AppKit

let output = CommandLine.arguments[1]
let folder = URL(fileURLWithPath: output, isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255,
            alpha: alpha)
}

func polygon(_ points: [NSPoint], fill: NSColor) {
    let path = NSBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    path.close()
    fill.setFill()
    path.fill()
}

func drawIcon(pixelSize: Int, name: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize,
                              pixelsHigh: pixelSize, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixelSize) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
                                  xRadius: 210, yRadius: 210)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.23)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -15)
    shadow.set()
    NSGradient(starting: color(0x537EFF), ending: color(0x2944BC))!.draw(in: background, angle: -80)
    NSShadow().set()

    let inset = NSBezierPath(roundedRect: NSRect(x: 65.5, y: 65.5, width: 893, height: 893),
                             xRadius: 208, yRadius: 208)
    color(0xFFFFFF, alpha: 0.18).setStroke()
    inset.lineWidth = 3
    inset.stroke()

    let region = NSBezierPath(roundedRect: NSRect(x: 254, y: 265, width: 508, height: 492),
                              xRadius: 12, yRadius: 12)
    color(0xBDEEFF, alpha: 0.13).setFill()
    region.fill()

    let corners = [
        [NSPoint(x: 250, y: 615), NSPoint(x: 250, y: 762), NSPoint(x: 397, y: 762)],
        [NSPoint(x: 618, y: 762), NSPoint(x: 765, y: 762), NSPoint(x: 765, y: 615)],
        [NSPoint(x: 250, y: 412), NSPoint(x: 250, y: 265), NSPoint(x: 397, y: 265)],
        [NSPoint(x: 765, y: 412), NSPoint(x: 765, y: 265), NSPoint(x: 618, y: 265)]
    ]
    for points in corners {
        let path = NSBezierPath()
        path.move(to: points[0])
        path.line(to: points[1])
        path.line(to: points[2])
        path.lineWidth = 35
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }

    NSGraphicsContext.saveGraphicsState()
    let pencilShadow = NSShadow()
    pencilShadow.shadowColor = color(0x15246B, alpha: 0.4)
    pencilShadow.shadowBlurRadius = 18
    pencilShadow.shadowOffset = NSSize(width: 0, height: -10)
    pencilShadow.set()
    polygon([NSPoint(x: 422, y: 211), NSPoint(x: 453, y: 318), NSPoint(x: 744, y: 609),
             NSPoint(x: 823, y: 530), NSPoint(x: 532, y: 239)], fill: color(0xFFD477))
    NSShadow().set()
    polygon([NSPoint(x: 453, y: 318), NSPoint(x: 744, y: 609), NSPoint(x: 783, y: 570),
             NSPoint(x: 493, y: 279)], fill: color(0xFFE7A4))
    polygon([NSPoint(x: 422, y: 211), NSPoint(x: 453, y: 318), NSPoint(x: 532, y: 239)], fill: color(0xFFEDCA))
    polygon([NSPoint(x: 422, y: 211), NSPoint(x: 434, y: 254), NSPoint(x: 465, y: 223)], fill: color(0x293456))
    polygon([NSPoint(x: 744, y: 609), NSPoint(x: 776, y: 641), NSPoint(x: 855, y: 562),
             NSPoint(x: 823, y: 530)], fill: color(0xFF9DA8))
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixelSize: size, name: "icon_\(size)x\(size).png")
    try drawIcon(pixelSize: size * 2, name: "icon_\(size)x\(size)@2x.png")
}

// Store PNG representations in the standard modern ICNS container. Keeping the
// small and Retina representations makes the icon sharp in Finder and menus.
if CommandLine.arguments.count > 2 {
    let entries = [
        ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
        ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
        ("ic14", "icon_256x256@2x.png")
    ]
    func bigEndianLength(_ value: Int) -> Data {
        var number = UInt32(value).bigEndian
        return withUnsafeBytes(of: &number) { Data($0) }
    }
    var body = Data()
    for (tag, name) in entries {
        let png = try Data(contentsOf: folder.appendingPathComponent(name))
        body.append(Data(tag.utf8))
        body.append(bigEndianLength(png.count + 8))
        body.append(png)
    }
    var container = Data("icns".utf8)
    container.append(bigEndianLength(body.count + 8))
    container.append(body)
    try container.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
