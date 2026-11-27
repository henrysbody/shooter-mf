import AppKit

/// A brief confirmation that does not take focus or require notification access.
final class CopyToast: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 218, height: 42),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        ignoresMouseEvents = true
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        appearance = NSAppearance(named: .darkAqua)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .withinWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        contentView = background

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        icon.contentTintColor = .systemGreen
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: "Скопировано в буфер")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(icon)
        background.addSubview(label)
        setContentSize(NSSize(width: 57 + ceil(label.intrinsicContentSize.width), height: 42))
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 15),
            icon.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])
    }

    func show(on screen: NSScreen) {
        let safe = screen.visibleFrame
        setFrameOrigin(NSPoint(x: safe.midX - frame.width / 2, y: safe.minY + 14))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in self?.close() })
        }
    }
}

final class UndoToast: NSPanel {
    static let height: CGFloat = 36
    static let gap: CGFloat = 6
    private let countdown = NSTextField(labelWithString: "3 с")
    private var timer: Timer?
    private var deadline: TimeInterval = 0
    var onUndo: (() -> Void)?
    var onExpire: (() -> Void)?

    init(deleted: Int) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 210, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        appearance = NSAppearance(named: .darkAqua)

        let background = PaletteSurface(radius: 10)
        contentView = background
        let message = NSTextField(labelWithString: deleted == 1 ? "Пометка удалена" : "Пометки удалены")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .white
        let action = UndoToastButton(title: "", target: self, action: #selector(undoPressed))
        action.isBordered = false
        action.focusRingType = .none
        action.setAccessibilityLabel("Отменить удаление")
        action.setAccessibilityHelp("⌘Z")
        action.translatesAutoresizingMaskIntoConstraints = false
        let actionLabel = NSTextField(labelWithString: "Отменить")
        actionLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        actionLabel.textColor = NSColor(srgbRed: 0.75, green: 0.70, blue: 1, alpha: 1)
        countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countdown.textColor = .secondaryLabelColor
        countdown.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let row = NSStackView(views: [message, actionLabel, countdown])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(action)
        action.addSubview(row)
        setContentSize(NSSize(width: ceil(row.fittingSize.width) + 22, height: Self.height))
        NSLayoutConstraint.activate([
            action.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            action.topAnchor.constraint(equalTo: background.topAnchor),
            action.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            row.centerXAnchor.constraint(equalTo: action.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: action.centerYAnchor)
        ])
    }

    override var canBecomeKey: Bool { false }

    func place(below toolbar: NSRect, on screen: NSScreen) {
        let safe = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(toolbar.midX - frame.width / 2, safe.minX), max(safe.minX, safe.maxX - frame.width))
        let y = max(safe.minY, toolbar.minY - Self.gap - frame.height)
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        deadline = ProcessInfo.processInfo.systemUptime + 3
        orderFrontRegardless()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let seconds = Int(ceil(deadline - ProcessInfo.processInfo.systemUptime))
        if seconds > 0 { countdown.stringValue = "\(seconds) с" }
        else { onExpire?() }
    }

    @objc private func undoPressed() {
        if ProcessInfo.processInfo.systemUptime < deadline { onUndo?() }
        else { onExpire?() }
    }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }
}

private final class UndoToastButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
