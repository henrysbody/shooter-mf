import AppKit
import QuartzCore

final class PaletteHint {
    private weak var anchor: NSView?
    private var timer: Timer?
    private var panel: NSPanel?

    deinit {
        timer?.invalidate()
        panel?.close()
    }

    func begin(_ text: String?, for view: NSView) {
        dismiss()
        guard let text, !text.isEmpty else { return }
        anchor = view
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self, weak view] _ in
            guard let self, let view, self.anchor === view else { return }
            self.show(text, beside: view)
        }
    }

    func end(for view: NSView) {
        if anchor === view { dismiss() }
    }

    func update(_ text: String?, for view: NSView) {
        if anchor === view { begin(text, for: view) }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        anchor = nil
        panel?.orderOut(nil)
    }

    private func show(_ text: String, beside view: NSView) {
        guard let window = view.window, window.isVisible, let screen = window.screen else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 9, y: 5)
        let size = NSSize(width: ceil(label.frame.width) + 18, height: ceil(label.frame.height) + 10)
        let surface = PaletteSurface(radius: 7)
        surface.addSubview(label)
        let box = window.convertToScreen(view.convert(view.bounds, to: nil))
        let safe = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        let right = box.maxX + 6
        let x = right + size.width <= safe.maxX ? right : max(safe.minX, box.minX - size.width - 6)
        let y = min(max(box.midY - size.height / 2, safe.minY), safe.maxY - size.height)
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        if panel == nil {
            let hint = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
            hint.isReleasedWhenClosed = false
            hint.isOpaque = false
            hint.backgroundColor = .clear
            hint.hasShadow = true
            hint.hidesOnDeactivate = true
            hint.ignoresMouseEvents = true
            panel = hint
        }
        guard let panel else { return }
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.collectionBehavior = window.collectionBehavior
        panel.contentView = surface
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

/// Both panels use one clipped surface so the fill and border share the same corners.
final class PaletteSurface: NSView {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.115, green: 0.124, blue: 0.15, alpha: 0.98).cgColor
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.19).cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self))
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
}

/// A small, non-activating list that leaves focus with the capture canvas.
final class PaletteMenu: NSPanel {
    var onChoose: ((Int) -> Void)?

    private let selectedIndex: Int
    private var rows: [PaletteMenuRow] = []
    private var highlightedIndex: Int? {
        didSet {
            if let oldValue { rows[oldValue].isHovered = false }
            if let highlightedIndex { rows[highlightedIndex].isHovered = true }
        }
    }

    init(items: [NSMenuItem], selectedIndex: Int, showsTitles: Bool, hints: PaletteHint) {
        self.selectedIndex = selectedIndex
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: EditorTypography.menuFont.pointSize, weight: .medium)
        let iconWidth = items.compactMap { $0.image?.size.width }.max() ?? 24
        let labelWidth = showsTitles
            ? ceil(items.map { ($0.title as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0)
            : 0
        let rowSize = NSSize(width: max(38, iconWidth + (showsTitles ? 10 + labelWidth + 20 : 0)), height: 36)
        let inset: CGFloat = 7
        let spacing: CGFloat = 2
        let size = NSSize(width: rowSize.width + inset * 2,
                          height: inset * 2 + rowSize.height * CGFloat(items.count)
                              + spacing * CGFloat(max(0, items.count - 1)))
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        appearance = NSAppearance(named: .darkAqua)
        let surface = PaletteSurface(radius: 13)
        contentView = surface

        for (index, item) in items.enumerated() {
            let y = size.height - inset - rowSize.height - CGFloat(index) * (rowSize.height + spacing)
            let row = PaletteMenuRow(frame: NSRect(origin: NSPoint(x: inset, y: y), size: rowSize),
                                     item: item, iconWidth: iconWidth, labelWidth: labelWidth, font: labelFont,
                                     hints: hints)
            row.tag = index
            row.target = self
            row.action = #selector(choose(_:))
            row.onPointerChange = { [weak self] inside in
                guard let self else { return }
                if inside { self.highlightedIndex = index }
                else if self.highlightedIndex == index { self.highlightedIndex = nil }
            }
            surface.addSubview(row)
            rows.append(row)
        }
    }

    func show(above button: NSRect, in visibleFrame: NSRect) {
        let margin: CGFloat = 6
        let x = min(max(button.midX - frame.width / 2, visibleFrame.minX + margin),
                    visibleFrame.maxX - frame.width - margin)
        let y = min(button.maxY + 8, visibleFrame.maxY - frame.height - margin)
        let target = NSRect(origin: NSPoint(x: x, y: y), size: frame.size)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = reduceMotion ? 1 : 0
        setFrame(reduceMotion ? target : target.offsetBy(dx: 0, dy: -5), display: true)
        orderFrontRegardless()
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    func moveHighlight(by step: Int) {
        guard !rows.isEmpty else { return }
        let start = highlightedIndex ?? selectedIndex
        highlightedIndex = (start + step + rows.count) % rows.count
    }

    func chooseHighlighted() {
        let index = highlightedIndex ?? selectedIndex
        if rows.indices.contains(index) { onChoose?(index) }
    }

    @objc private func choose(_ row: NSButton) { onChoose?(row.tag) }
}

private final class PaletteMenuRow: NSButton {
    var onPointerChange: ((Bool) -> Void)?
    var isHovered = false { didSet { needsDisplay = true } }

    private let icon: NSImage?
    private let label: NSAttributedString?
    private let iconWidth: CGFloat
    private let labelWidth: CGFloat
    private weak var hints: PaletteHint?
    private let hintText: String?

    init(frame: NSRect, item: NSMenuItem, iconWidth: CGFloat, labelWidth: CGFloat, font: NSFont, hints: PaletteHint) {
        icon = item.image.map { $0.isTemplate ? $0.paletteTintedWhite() : $0 }
        label = labelWidth > 0
            ? NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: NSColor.white])
            : nil
        self.iconWidth = iconWidth
        self.labelWidth = labelWidth
        self.hints = hints
        hintText = item.toolTip
        super.init(frame: frame)
        title = item.title
        setAccessibilityLabel(item.title)
        setAccessibilityHelp(hintText)
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
        onPointerChange?(true)
        hints?.begin(hintText, for: self)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerChange?(false)
        hints?.end(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        hints?.end(for: self)
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.19 : 0.10).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let gap: CGFloat = 10
        let contentWidth = iconWidth + (label == nil ? 0 : gap + labelWidth)
        let contentX = bounds.midX - contentWidth / 2
        if let icon {
            let imageRect = NSRect(x: contentX + (iconWidth - icon.size.width) / 2,
                                   y: bounds.midY - icon.size.height / 2,
                                   width: icon.size.width, height: icon.size.height)
            icon.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: nil)
        }
        if let label {
            label.draw(at: NSPoint(x: contentX + iconWidth + gap, y: bounds.midY - label.size().height / 2))
        }
    }
}

extension NSImage {
    func paletteTintedWhite() -> NSImage {
        let tinted = copy() as! NSImage
        tinted.isTemplate = false
        tinted.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}
