import AppKit

/// A compact floating palette; the canvas handles moving and resizing directly.
final class EditorToolbar: NSPanel {
    var onStyleChange: ((EditorStyle) -> Void)?
    var onCopy: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private var style: EditorStyle
    private let toolPopup = IconPopupButton(frame: .zero, pullsDown: false)
    private let colorPopup = IconPopupButton(frame: .zero, pullsDown: false)
    private let thicknessPopup = IconPopupButton(frame: .zero, pullsDown: false)
    private let hints = PaletteHint()
    private var choicePanel: PaletteMenu?
    var hasOpenChoices: Bool { choicePanel != nil }
    private weak var choiceButton: IconPopupButton?
    private var choiceDismissMonitor: Any?
    private static let tools: [(tool: DrawingTool, title: String, symbol: String, keyCode: UInt16, shortcut: String)] = [
        (.pen, "Карандаш", "pencil.tip", 2, "D"),
        (.highlighter, "Маркер", "highlighter", 12, "Q"),
        (.rectangle, "Прямоугольник", "rectangle", 1, "S"),
        (.ellipse, "Овал", "oval", 15, "R"),
        (.arrow, "Стрелка", "arrow.up.right", 0, "A"),
        (.line, "Линия", "line.diagonal", 14, "E"),
        (.text, "Текст", "textformat", 17, "T")
    ]
    private let thicknesses = EditorTypography.strokeWidths

    init(style: EditorStyle) {
        var initialStyle = style
        if initialStyle.tool == .selection { initialStyle.tool = .rectangle }
        self.style = initialStyle
        super.init(contentRect: NSRect(x: 0, y: 0, width: 140, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)

        let background = PaletteSurface(radius: 12)
        contentView = background

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        configure(toolPopup, label: "Инструмент")
        toolPopup.showsChoiceTitles = false
        for definition in Self.tools {
            toolPopup.addItem(withTitle: definition.title)
            toolPopup.lastItem?.image = Self.toolIcon(definition.symbol)
            toolPopup.lastItem?.toolTip = "\(definition.title) (\(definition.shortcut))"
        }
        toolPopup.selectItem(at: Self.tools.firstIndex(where: { $0.tool == initialStyle.tool }) ?? 0)
        toolPopup.hintText = toolPopup.selectedItem?.toolTip
        toolPopup.target = self
        toolPopup.action = #selector(toolChanged)
        row.addArrangedSubview(toolPopup)

        configure(colorPopup, label: "Цвет")
        colorPopup.showsChoiceTitles = false
        for (index, definition) in EditorPreferences.palette.enumerated() {
            colorPopup.addItem(withTitle: definition.title)
            colorPopup.lastItem?.image = Self.colorSwatch(definition.color)
            colorPopup.lastItem?.toolTip = "\(definition.title) (\(index + 1))"
        }
        colorPopup.selectItem(at: EditorPreferences.palette.firstIndex(where: { $0.color.isEqual(initialStyle.color) }) ?? 0)
        colorPopup.hintText = colorPopup.selectedItem?.toolTip
        colorPopup.target = self
        colorPopup.action = #selector(colorChanged)
        row.addArrangedSubview(colorPopup)

        configure(thicknessPopup, label: "Толщина кисти")
        refreshThicknessMenu()
        thicknessPopup.target = self
        thicknessPopup.action = #selector(thicknessChanged)
        row.addArrangedSubview(thicknessPopup)

        setContentSize(NSSize(width: row.fittingSize.width + 20, height: 44))
    }

    func place(on screen: NSScreen, selection: NSRect, reserveBelow: CGFloat = 0) {
        let safe = screen.visibleFrame
        let margin: CGFloat = 8
        let gap: CGFloat = 15
        let minX = safe.minX + margin
        let minY = safe.minY + margin
        let maxX = max(minX, safe.maxX - frame.width - margin)
        let maxY = max(minY, safe.maxY - frame.height - margin)
        let x = selection.midX - frame.width / 2
        let below = selection.minY - gap - frame.height
        let above = selection.maxY + gap
        let y: CGFloat
        if below >= minY { y = below }
        else if above <= maxY { y = above }
        else { y = selection.minY + gap }
        let origin = NSPoint(x: min(max(x, minX), maxX), y: min(max(y, minY + reserveBelow), maxY))
        if origin != frame.origin {
            dismissChoices()
            hints.dismiss()
            setFrameOrigin(origin)
        }
        if !isVisible { orderFrontRegardless() }
    }

    func setHistory(canUndo: Bool, canRedo: Bool) {}

    func selectTool(_ tool: DrawingTool) {
        guard let index = Self.tools.firstIndex(where: { $0.tool == tool }) else { return }
        dismissChoices()
        toolPopup.selectItem(at: index)
        toolChanged()
    }

    func selectTool(forKeyCode keyCode: UInt16) -> Bool {
        let tool = keyCode == 4 ? .highlighter : Self.tools.first(where: { $0.keyCode == keyCode })?.tool
        guard let tool else { return false }
        selectTool(tool)
        return true
    }

    func selectColor(at index: Int) {
        guard EditorPreferences.palette.indices.contains(index) else { return }
        dismissChoices()
        colorPopup.selectItem(at: index)
        colorChanged()
    }

    func stepSize(by step: Int, wraps: Bool = false) -> Bool {
        let current = thicknessPopup.indexOfSelectedItem
        guard thicknesses.indices.contains(current) else { return false }
        let count = thicknesses.count
        let next = wraps ? (current + step + count) % count : min(max(current + step, 0), count - 1)
        dismissChoices()
        if next != current {
            thicknessPopup.selectItem(at: next)
            thicknessChanged()
        }
        return true
    }

    @objc private func toolChanged() {
        let index = toolPopup.indexOfSelectedItem
        guard Self.tools.indices.contains(index) else { return }
        style.tool = Self.tools[index].tool
        toolPopup.hintText = toolPopup.selectedItem?.toolTip
        refreshThicknessMenu()
        onStyleChange?(style)
    }
    @objc private func colorChanged() {
        let index = colorPopup.indexOfSelectedItem
        guard EditorPreferences.palette.indices.contains(index) else { return }
        style.color = EditorPreferences.palette[index].color
        colorPopup.hintText = colorPopup.selectedItem?.toolTip
        onStyleChange?(style)
    }
    @objc private func thicknessChanged() {
        let index = thicknessPopup.indexOfSelectedItem
        guard thicknesses.indices.contains(index) else { return }
        if style.tool == .text {
            style.fontSize = EditorTypography.fontSizes[index]
        } else {
            style.lineWidth = thicknesses[index]
        }
        updateThicknessToolTip()
        onStyleChange?(style)
    }
    private func refreshThicknessMenu() {
        thicknessPopup.removeAllItems()
        let textMode = style.tool == .text
        for (index, width) in thicknesses.enumerated() {
            let title = textMode ? "\(Int(EditorTypography.fontSizes[index])) pt" : String(Int(width))
            thicknessPopup.addItem(withTitle: title)
            thicknessPopup.lastItem?.image = Self.strokeSample(width)
            thicknessPopup.lastItem?.toolTip = textMode ? title : "\(title) pt"
        }
        let selected = textMode ? EditorTypography.fontSizes.firstIndex(of: style.fontSize)
                                : thicknesses.firstIndex(of: style.lineWidth)
        thicknessPopup.selectItem(at: selected ?? 1)
        updateThicknessToolTip()
    }

    private func updateThicknessToolTip() {
        let textMode = style.tool == .text
        let label = textMode ? "Размер текста" : "Толщина кисти"
        let size = thicknessPopup.selectedItem?.toolTip ?? ""
        thicknessPopup.hintText = "\(label) · \(size) (+ / − / Tab / ⇧Tab)"
        thicknessPopup.setAccessibilityLabel(label)
    }

    private func configure(_ popup: IconPopupButton, label: String) {
        popup.isBordered = false
        (popup.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        popup.controlSize = .regular
        popup.imagePosition = .imageOnly
        popup.imageScaling = .scaleProportionallyDown
        popup.focusRingType = .none
        popup.hints = hints
        popup.setAccessibilityLabel(label)
        popup.onOpen = { [weak self] button in self?.showChoices(for: button) }
        popup.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            popup.widthAnchor.constraint(equalToConstant: 36),
            popup.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    func handleChoiceKey(_ event: NSEvent) -> Bool {
        guard let choicePanel, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return false
        }
        switch event.keyCode {
        case 53: dismissChoices()
        case 125: choicePanel.moveHighlight(by: 1)
        case 126: choicePanel.moveHighlight(by: -1)
        case 36, 49, 76: choicePanel.chooseHighlighted()
        default: return false
        }
        return true
    }

    override func close() {
        dismissChoices()
        hints.dismiss()
        super.close()
    }

    override func orderOut(_ sender: Any?) {
        dismissChoices()
        hints.dismiss()
        super.orderOut(sender)
    }

    private func showChoices(for button: IconPopupButton) {
        let wasOpen = choiceButton === button
        dismissChoices()
        hints.dismiss()
        guard !wasOpen, let screen, let items = button.menu?.items, !items.isEmpty else { return }

        let panel = PaletteMenu(items: items, selectedIndex: button.indexOfSelectedItem,
                                showsTitles: button.showsChoiceTitles, hints: hints)
        panel.level = NSWindow.Level(rawValue: level.rawValue + 1)
        panel.collectionBehavior = collectionBehavior
        panel.onChoose = { [weak self, weak button] index in
            self?.dismissChoices()
            button?.choose(at: index)
        }
        choiceButton = button
        choicePanel = panel
        choiceDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let panel = self.choicePanel, event.window !== panel else { return event }
            if event.window === self, let anchor = self.choiceButton,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                return event
            }
            self.dismissChoices()
            // A click on the canvas dismisses the menu before drawing resumes.
            return event.window?.contentView is CanvasView ? nil : event
        }
        let anchor = convertToScreen(button.convert(button.bounds, to: nil))
        panel.show(above: anchor, in: screen.visibleFrame)
        NSCursor.arrow.set()
    }

    func dismissChoices() {
        if choicePanel != nil { hints.dismiss() }
        if let choiceDismissMonitor { NSEvent.removeMonitor(choiceDismissMonitor) }
        choiceDismissMonitor = nil
        choiceButton = nil
        choicePanel?.close()
        choicePanel = nil
    }

    private static func toolIcon(_ name: String) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .medium, scale: .medium)) else { return nil }
        let icon = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { bounds in
            let scale = 20 / max(symbol.size.width, symbol.size.height)
            let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
            let frame = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height)
            symbol.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        icon.isTemplate = true
        return icon
    }

    private static func colorSwatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let path = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 20, height: 20))
            color.setFill()
            path.fill()
            NSColor.gray.withAlphaComponent(0.65).setStroke()
            path.lineWidth = 0.75
            path.stroke()
            return true
        }
    }

    private static func strokeSample(_ thickness: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 22), flipped: false) { _ in
            NSColor.white.setFill()
            let height = max(2.5, thickness * 0.75)
            NSBezierPath(roundedRect: NSRect(x: 2, y: (22 - height) / 2, width: 24, height: height),
                         xRadius: height / 2, yRadius: height / 2).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

}

private final class IconPopupButton: NSPopUpButton {
    var showsChoiceTitles = true
    var onOpen: ((IconPopupButton) -> Void)?
    weak var hints: PaletteHint?
    var hintText: String? {
        didSet {
            setAccessibilityHelp(hintText)
            if hintText != oldValue { hints?.update(hintText, for: self) }
        }
    }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        hints?.begin(hintText, for: self)
    }

    override func mouseExited(with event: NSEvent) { hints?.end(for: self) }
    override func mouseDown(with event: NSEvent) { performClick(nil) }
    override func performClick(_ sender: Any?) { if isEnabled { onOpen?(self) } }

    func choose(at index: Int) {
        selectItem(at: index)
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }
}
