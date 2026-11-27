import AppKit

enum EditorPreferences {
    static let palette: [(id: String, color: NSColor, title: String)] = [
        ("red", .systemRed, "Красный"), ("green", .systemGreen, "Зелёный"),
        ("blue", .systemBlue, "Синий"), ("purple", .systemPurple, "Фиолетовый"),
        ("yellow", .systemYellow, "Жёлтый"), ("black", .black, "Чёрный"), ("white", .white, "Белый")
    ]

    static var fullScreenSelection: Bool {
        get { UserDefaults.standard.bool(forKey: "editor.fullScreenSelection") }
        set { UserDefaults.standard.set(newValue, forKey: "editor.fullScreenSelection") }
    }

    static func load(from defaults: UserDefaults = .standard) -> EditorStyle {
        var style = EditorStyle()
        if let value = defaults.string(forKey: "editor.tool"),
           let tool = DrawingTool(rawValue: value), tool != .selection {
            style.tool = tool
        }
        if let value = defaults.string(forKey: "editor.color"),
           let color = palette.first(where: { $0.id == value })?.color {
            style.color = color
        }
        if defaults.object(forKey: "editor.strokeWidth") != nil {
            let saved = defaults.double(forKey: "editor.strokeWidth")
            if saved.isFinite && saved > 0 {
                style.lineWidth = EditorTypography.nearestStroke(to: CGFloat(saved))
            }
        }
        style.fontSize = EditorTypography.fontSize(forStroke: style.lineWidth)
        if let preset = defaults.object(forKey: "editor.fontSizePreset") as? Int,
           EditorTypography.fontSizes.indices.contains(preset) {
            style.fontSize = EditorTypography.fontSizes[preset]
        } else {
            // Older releases stored the size in points instead of the selected tier.
            let saved = CGFloat(defaults.double(forKey: "editor.fontSize"))
            let previousSizes: [CGFloat] = [12, 14, 18]
            if let preset = previousSizes.firstIndex(of: saved) {
                style.fontSize = EditorTypography.fontSizes[preset]
            }
        }
        return style
    }

    static func save(_ style: EditorStyle, to defaults: UserDefaults = .standard) {
        defaults.set(style.tool == .selection ? DrawingTool.rectangle.rawValue : style.tool.rawValue,
                     forKey: "editor.tool")
        defaults.set(palette.first(where: { $0.color.isEqual(style.color) })?.id ?? "red", forKey: "editor.color")
        defaults.set(Double(style.lineWidth), forKey: "editor.strokeWidth")
        if let preset = EditorTypography.fontSizes.firstIndex(of: style.fontSize) {
            defaults.set(preset, forKey: "editor.fontSizePreset")
        }
    }
}
