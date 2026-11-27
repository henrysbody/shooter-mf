import AppKit

/// A local fixture for visual checks; --demo never requests screen access.
enum DemoImage {
    static func make(size: NSSize, scale: CGFloat) -> CGImage {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.22, blue: 0.38, alpha: 1),
                            NSColor(srgbRed: 0.46, green: 0.34, blue: 0.47, alpha: 1)])!.draw(in: NSRect(origin: .zero, size: size), angle: 25)
        let card = NSRect(x: size.width * 0.15, y: size.height * 0.2, width: size.width * 0.7, height: size.height * 0.6)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 28
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: card.minX + 22 + CGFloat(index) * 19, y: card.maxY - 30, width: 10, height: 10)).fill()
        }
        let titleY = card.maxY - 100
        draw("Хорошие идеи начинаются с заметки.", at: NSPoint(x: card.minX + 36, y: titleY), size: min(30, card.width / 24), weight: .bold, color: NSColor(calibratedWhite: 0.15, alpha: 1))
        draw("Выделите важное. Добавьте контекст. Поделитесь.", at: NSPoint(x: card.minX + 36, y: titleY - 38), size: 16, color: .gray)
        let tileWidth = (card.width - 96) / 3
        for index in 0..<3 {
            let tile = NSRect(x: card.minX + 36 + CGFloat(index) * (tileWidth + 12), y: card.minY + 42, width: tileWidth, height: max(80, card.height - 210))
            [NSColor(srgbRed: 0.88, green: 0.86, blue: 0.97, alpha: 1), NSColor(srgbRed: 0.83, green: 0.91, blue: 0.87, alpha: 1), NSColor(srgbRed: 0.97, green: 0.87, blue: 0.8, alpha: 1)][index].setFill()
            NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12).fill()
            draw(["01", "02", "03"][index], at: NSPoint(x: tile.minX + 18, y: tile.maxY - 42), size: 22, weight: .semibold, color: .darkGray)
            draw(["Идея", "Детали", "Результат"][index], at: NSPoint(x: tile.minX + 18, y: tile.minY + 20), size: 15, weight: .medium, color: .darkGray)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private static func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size + 2, weight: weight), .foregroundColor: color])
    }
}
