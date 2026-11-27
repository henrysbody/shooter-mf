import AppKit
import CoreText

enum DrawingTool: String, CaseIterable {
    case selection, pen, highlighter, text, rectangle, ellipse, arrow, line
}

struct EditorStyle {
    var tool: DrawingTool = .rectangle
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4
    var fontSize: CGFloat = EditorTypography.fontSize(forStroke: 4)
}

/// All geometry is stored in screen points with a bottom-left origin. Export applies
/// the original display's pixel scale once, so Retina screenshots stay sharp.
final class CanvasView: NSView, NSTextViewDelegate {
    var style = EditorStyle() {
        didSet {
            if style.tool != oldValue.tool { commitTextEditing() }
            refreshCursor()
        }
    }
    var selectionRect: NSRect? {
        didSet {
            needsDisplay = true
            onSelectionChange?(selectionRect)
            refreshCursor()
        }
    }
    var onSelectionChange: ((NSRect?) -> Void)?
    var onHistoryChange: ((Bool, Bool) -> Void)?
    var onDeleteAnnotations: ((Int) -> Void)?
    var onBeginInteraction: (() -> Void)?
    var onRequestCopy: (() -> Void)?
    var onRequestCancel: (() -> Void)?
    var canUndo: Bool { !undoHistory.isEmpty }
    var canRedo: Bool { !redoHistory.isEmpty }
    var isEditingText: Bool { textEditor != nil }
    var isDragging: Bool { interaction != nil }

    private let screenshot: CGImage
    private var annotations: [Annotation] = []
    private var undoHistory: [[Annotation]] = []
    private var redoHistory: [[Annotation]] = []
    private var draft: Annotation?
    private var interaction: Interaction?
    private var textEditor: AnnotationTextView?
    private var previousCrop: NSRect?
    private var selectedAnnotation: Int?
    private var editingTextIndex: Int?
    private var annotationPreview: Annotation?
    private var tracking: NSTrackingArea?
    private let handleRadius: CGFloat = 7
    private let handleHitRadius: CGFloat = 12
    private var textShadowPadding: CGFloat { ceil(12 * bounds.width / CGFloat(screenshot.width)) }

    init(image: CGImage, frame: NSRect) {
        screenshot = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsScale = window?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    func toggleFullScreen() -> Bool {
        if selectionRect == bounds {
            let size = NSSize(width: min(360, bounds.width * 0.5), height: min(220, bounds.height * 0.4))
            selectionRect = previousCrop ?? NSRect(x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            previousCrop = nil
            return false
        }
        previousCrop = hasSelection() ? selectionRect : nil
        selectionRect = bounds
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited,
                                           .cursorUpdate, .inVisibleRect, .enabledDuringMouseDrag],
                                 owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func refreshCursor() {
        guard let window, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return }
        if interaction == nil && NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) != window.windowNumber {
            return
        }
        updateCursor(at: point)
    }

    private func updateCursor(at point: NSPoint) {
        if case .move = interaction {
            NSCursor.closedHand.set()
            return
        }
        if case .moveAnnotation = interaction {
            NSCursor.closedHand.set()
            return
        }
        if case .resizeAnnotation(let handle, _, _) = interaction {
            handle.cursor.set()
            return
        }
        if case .resize(_, let handle) = interaction {
            handle.cursor.set()
            return
        }
        guard let rect = selectionRect else {
            NSCursor.crosshair.set()
            return
        }
        if let handle = hitHandle(point, in: rect) {
            handle.cursor.set()
        } else if hitMoveBorder(point, in: rect) {
            NSCursor.openHand.set()
        } else if let handle = hitAnnotationHandle(at: point) {
            handle.cursor.set()
        } else if rect.contains(point), annotation(at: point) != nil {
            NSCursor.openHand.set()
        } else if style.tool == .selection && rect.contains(point) {
            NSCursor.openHand.set()
        } else if style.tool == .text && rect.contains(point) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(screenshot, in: bounds)
        context.restoreGState()

        if let rect = selectionRect {
            context.saveGState()
            context.clip(to: rect)
            for (index, annotation) in annotations.enumerated() where index != editingTextIndex {
                (index == selectedAnnotation ? annotationPreview ?? annotation : annotation).draw(in: context)
            }
            draft?.draw(in: context)
            drawAnnotationSelection(in: context)
            context.restoreGState()

            NSColor.black.withAlphaComponent(0.40).setFill()
            let outside = NSBezierPath(rect: bounds)
            outside.appendRect(rect)
            outside.windingRule = .evenOdd
            outside.fill()

            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.95).setStroke()
            outline.stroke()
            for handle in Handle.allCases {
                let center = handle.point(in: rect)
                let handleRect = NSRect(x: center.x - handleRadius, y: center.y - handleRadius,
                                        width: handleRadius * 2, height: handleRadius * 2)
                NSColor.white.setFill()
                let path = NSBezierPath(roundedRect: handleRect, xRadius: 3, yRadius: 3)
                path.fill()
                NSColor.black.withAlphaComponent(0.35).setStroke()
                path.lineWidth = 0.75
                path.stroke()
            }
        } else {
            NSColor.black.withAlphaComponent(0.34).setFill()
            bounds.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onBeginInteraction?()
        commitTextEditing()
        window?.makeFirstResponder(self)
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        if let rect = selectionRect, let handle = hitHandle(point, in: rect) {
            selectedAnnotation = nil
            interaction = .resize(rect: rect, handle: handle)
            return
        }
        guard let rect = selectionRect else {
            selectedAnnotation = nil
            interaction = .select(start: point, previous: nil)
            selectionRect = NSRect(origin: point, size: .zero)
            return
        }
        if hitMoveBorder(point, in: rect) {
            selectedAnnotation = nil
            interaction = .move(start: point, rect: rect)
            NSCursor.closedHand.set()
            return
        }
        if rect.contains(point), let index = selectedAnnotation, let handle = hitAnnotationHandle(at: point) {
            interaction = .resizeAnnotation(handle: handle, start: point, original: annotations[index])
            return
        }
        if rect.contains(point), let index = annotation(at: point) {
            selectedAnnotation = index
            needsDisplay = true
            let item = annotations[index]
            if item.tool == .text && event.clickCount >= 2 {
                beginText(at: item.points[0], editing: index)
            } else {
                interaction = .moveAnnotation(start: point, original: item)
                NSCursor.closedHand.set()
            }
            return
        }
        selectedAnnotation = nil
        needsDisplay = true
        if style.tool == .selection {
            if rect.contains(point) {
                interaction = .move(start: point, rect: rect)
                NSCursor.closedHand.set()
            } else {
                interaction = .select(start: point, previous: rect)
                selectionRect = NSRect(origin: point, size: .zero)
            }
            return
        }
        guard rect.contains(point) else {
            interaction = .select(start: point, previous: rect)
            selectionRect = NSRect(origin: point, size: .zero)
            return
        }
        if style.tool == .text {
            beginText(at: point)
        } else {
            draft = Annotation(tool: style.tool, color: style.color, width: style.lineWidth,
                               points: [point], text: nil)
            interaction = .draw(start: point)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampedPoint(convert(event.locationInWindow, from: nil))
        guard let interaction else { return }
        switch interaction {
        case .select(let start, _):
            let endpoint = event.modifierFlags.contains(.shift) ? squarePoint(point, from: start) : point
            selectionRect = normalizedRect(from: start, to: endpoint)
        case .move(let start, let original):
            let dx = min(max(point.x - start.x, bounds.minX - original.minX), bounds.maxX - original.maxX)
            let dy = min(max(point.y - start.y, bounds.minY - original.minY), bounds.maxY - original.maxY)
            selectionRect = original.offsetBy(dx: dx, dy: dy)
        case .resize(let original, let handle):
            let anchor = handle.opposite.point(in: original)
            switch handle {
            case .left, .right:
                selectionRect = NSRect(x: min(anchor.x, point.x), y: original.minY,
                                       width: abs(point.x - anchor.x), height: original.height)
            case .top, .bottom:
                selectionRect = NSRect(x: original.minX, y: min(anchor.y, point.y),
                                       width: original.width, height: abs(point.y - anchor.y))
            default:
                let endpoint = event.modifierFlags.contains(.shift) ? squarePoint(point, from: anchor) : point
                selectionRect = normalizedRect(from: anchor, to: endpoint)
            }
        case .resizeAnnotation(let handle, let start, let original):
            guard point != start else {
                annotationPreview = nil
                needsDisplay = true
                return
            }
            let center = handle.point(in: original)
            let target = clampedPoint(NSPoint(x: center.x + point.x - start.x, y: center.y + point.y - start.y))
            var updated = original
            switch handle {
            case .corner(let corner):
                let anchor = corner.opposite.point(in: original.shapeBounds)
                let end = event.modifierFlags.contains(.shift) ? squarePoint(target, from: anchor) : target
                let resized = normalizedRect(from: anchor, to: end)
                guard resized.width >= 2, resized.height >= 2 else {
                    annotationPreview = nil
                    needsDisplay = true
                    return
                }
                updated.points = [resized.origin, NSPoint(x: resized.maxX, y: resized.maxY)]
            case .endpoint(let index):
                let anchor = original.points[1 - index]
                updated.points[index] = event.modifierFlags.contains(.shift) ? anglePoint(target, from: anchor) : target
                guard updated.canCommit else {
                    annotationPreview = nil
                    needsDisplay = true
                    return
                }
            }
            annotationPreview = updated
            needsDisplay = true
        case .moveAnnotation(let start, let original):
            guard let crop = selectionRect else { return }
            let area = original.movementBounds
            let dx = min(max(point.x - start.x, min(0, crop.minX - area.minX)), max(0, crop.maxX - area.maxX))
            let dy = min(max(point.y - start.y, min(0, crop.minY - area.minY)), max(0, crop.maxY - area.maxY))
            var moved = original
            moved.points = original.points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
            annotationPreview = moved
            needsDisplay = true
        case .draw(let start):
            guard var item = draft else { return }
            if item.tool == .pen || item.tool == .highlighter {
                if let previous = item.points.last,
                   hypot(previous.x - point.x, previous.y - point.y) < 0.35 { return }
                item.points.append(point)
            } else {
                var endpoint = point
                if event.modifierFlags.contains(.shift) {
                    endpoint = item.tool == .arrow || item.tool == .line
                        ? anglePoint(point, from: start) : squarePoint(point, from: start)
                }
                item.points = [start, endpoint]
            }
            draft = item
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard interaction != nil else { return }
        mouseDragged(with: event)
        if let index = selectedAnnotation, let updated = annotationPreview,
           annotations[index].points != updated.points {
            pushHistory()
            annotations[index] = updated
            notifyHistory()
        }
        annotationPreview = nil
        if let draft {
            self.draft = nil
            if draft.canCommit {
                pushHistory()
                annotations.append(draft)
                notifyHistory()
            }
        }
        if let rect = selectionRect, rect.width < 8 || rect.height < 8 {
            selectionRect = nil
        }
        interaction = nil
        needsDisplay = true
        refreshCursor()
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": commitTextEditing(); onRequestCopy?(); return
            case "z":
                if textEditor != nil { super.keyDown(with: event); return }
                shift ? redo() : undo(); return
            default: break
            }
        }
        if event.keyCode == 53 {
            if !event.isARepeat && !cancelCurrentAction() { onRequestCancel?() }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers.isEmpty, textEditor == nil, interaction == nil, hasSelection() {
                // Holding the key after deleting one selected mark must not clear the others.
                if !event.isARepeat { deleteAnnotations() }
                return
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 { return }
        super.keyDown(with: event)
    }

    private func deleteAnnotations() {
        guard !annotations.isEmpty else { return }
        pushHistory()
        let deleted: Int
        if let index = selectedAnnotation {
            annotations.remove(at: index)
            deleted = 1
        } else {
            deleted = annotations.count
            annotations.removeAll()
        }
        selectedAnnotation = nil
        notifyHistory()
        needsDisplay = true
        refreshCursor()
        onDeleteAnnotations?(deleted)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": commitTextEditing(); onRequestCopy?(); return true
        case "z":
            if textEditor != nil { return super.performKeyEquivalent(with: event) }
            event.modifierFlags.contains(.shift) ? redo() : undo(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    func hasSelection() -> Bool {
        guard let selectionRect else { return false }
        return selectionRect.width >= 8 && selectionRect.height >= 8
    }

    func cancelCurrentAction() -> Bool {
        if textEditor != nil {
            cancelTextEditing()
            return true
        }
        guard let canceled = interaction else { return false }
        interaction = nil
        draft = nil
        annotationPreview = nil
        switch canceled {
        case .select(_, let previous): selectionRect = previous
        case .move(_, let original), .resize(let original, _): selectionRect = original
        case .draw, .moveAnnotation, .resizeAnnotation: break
        }
        needsDisplay = true
        refreshCursor()
        return true
    }

    func undo() {
        commitTextEditing()
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(annotations)
        annotations = previous
        selectedAnnotation = nil
        notifyHistory()
        needsDisplay = true
    }

    func redo() {
        commitTextEditing()
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(annotations)
        annotations = next
        selectedAnnotation = nil
        notifyHistory()
        needsDisplay = true
    }

    /// Composites only pixels and annotations. No handles, dimming or editor chrome.
    func renderedSelection() -> NSImage? {
        commitTextEditing()
        guard hasSelection(), let selected = selectionRect, bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(screenshot.width) / bounds.width
        let scaleY = CGFloat(screenshot.height) / bounds.height
        let pixelMinX = max(0, floor(selected.minX * scaleX))
        let pixelMinY = max(0, floor(selected.minY * scaleY))
        let pixelMaxX = min(CGFloat(screenshot.width), ceil(selected.maxX * scaleX))
        let pixelMaxY = min(CGFloat(screenshot.height), ceil(selected.maxY * scaleY))
        let pixelWidth = Int(pixelMaxX - pixelMinX)
        let pixelHeight = Int(pixelMaxY - pixelMinY)
        guard pixelWidth > 0, pixelHeight > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.translateBy(x: -pixelMinX, y: -pixelMinY)
        context.scaleBy(x: scaleX, y: scaleY)
        context.interpolationQuality = .none
        context.draw(screenshot, in: bounds)
        context.clip(to: selected)
        for annotation in annotations { annotation.draw(in: context) }
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: CGFloat(pixelWidth) / scaleX,
                                        height: CGFloat(pixelHeight) / scaleY))
        bitmap.size = image.size
        image.addRepresentation(bitmap)
        return image
    }

    func commitTextEditing() {
        guard let editor = textEditor else { return }
        let frame = editor.frame
        let layoutWidth = editor.textContainer?.containerSize.width ?? frame.width
        let text = NSMutableAttributedString(attributedString: editor.attributedString())
        applyTextKern(textKern(for: editor), to: text)
        let color = editor.textColor ?? style.color
        let index = editingTextIndex
        cancelTextEditing()
        let isEmpty = text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let index, annotations[index].text?.storage.string == text.string { return }
        if index == nil && isEmpty { return }
        pushHistory()
        let origin = NSPoint(x: frame.minX, y: frame.maxY)
        let updated = Annotation(tool: .text, color: color, width: style.lineWidth, points: [origin],
                                 text: TextAnnotation(text, width: layoutWidth))
        if let index {
            if isEmpty {
                annotations.remove(at: index)
                selectedAnnotation = nil
            } else {
                annotations[index] = updated
            }
        } else {
            annotations.append(updated)
        }
        notifyHistory()
        needsDisplay = true
        if index != nil && isEmpty { onDeleteAnnotations?(1) }
    }

    private func cancelTextEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil
        editingTextIndex = nil
        editor.delegate = nil
        if window?.firstResponder === editor { window?.makeFirstResponder(self) }
        editor.removeFromSuperview()
        needsDisplay = true
    }

    private func beginText(at point: NSPoint, editing index: Int? = nil) {
        guard let rect = selectionRect else { return }
        let existing = index.map { annotations[$0] }
        let storedText = existing?.text
        let font = storedText?.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                   ?? EditorTypography.font(ofSize: style.fontSize)
        let width = storedText?.container.containerSize.width ?? max(1, rect.maxX - point.x)
        let editor = AnnotationTextView(frame: .zero)
        editor.onCommit = { [weak self] in self?.commitTextEditing() }
        guard let container = editor.textContainer else { return }
        let manager = AnnotationTextLayout()
        container.replaceLayoutManager(manager)
        let height = min(rect.height, ceil(manager.defaultLineHeight(for: font)) + 2)
        let top = existing == nil ? max(point.y, rect.minY + height) : point.y
        let ink = existing?.color ?? style.color
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.textContainerInset = .zero
        editor.frame = NSRect(x: point.x, y: top - height,
                              width: max(1, min(width + textShadowPadding, rect.maxX - point.x)), height: height)
        editor.clipsToBounds = true
        TextAnnotation.configure(container, width: width)
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = font
        editor.textColor = ink
        editor.insertionPointColor = ink
        if let storedText {
            editor.textStorage?.setAttributedString(storedText.storage)
            editor.setSelectedRange(NSRange(location: storedText.storage.length, length: 0))
        }
        editor.delegate = self
        addSubview(editor)
        textEditor = editor
        editingTextIndex = index
        window?.makeFirstResponder(editor)
        applyTextKern(to: editor)
        updateTextEditorFrame()
    }

    private func textKern(for editor: NSTextView) -> CGFloat? {
        let pixelWidth = bounds.width / CGFloat(screenshot.width)
        return EditorTypography.letterSpacing(forFontSize: editor.font?.pointSize ?? style.fontSize,
                                              pixelWidth: pixelWidth)
    }

    private func applyTextKern(to editor: NSTextView) {
        let kern = textKern(for: editor)
        if let storage = editor.textStorage, storage.length > 0, !editor.hasMarkedText() {
            applyTextKern(kern, to: storage)
        }
        editor.typingAttributes[.kern] = kern.map { $0 as Any }
    }

    private func applyTextKern(_ kern: CGFloat?, to text: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: text.length)
        if let kern {
            text.addAttribute(.kern, value: kern, range: range)
        } else {
            text.removeAttribute(.kern, range: range)
        }
    }

    func textDidChange(_ notification: Notification) {
        if let editor = textEditor { applyTextKern(to: editor) }
        updateTextEditorFrame()
    }

    private func updateTextEditorFrame() {
        guard let editor = textEditor, let rect = selectionRect, let font = editor.font,
              let manager = editor.layoutManager, let container = editor.textContainer else { return }
        manager.ensureLayout(for: container)
        let contentHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY,
                                manager.defaultLineHeight(for: font))
        let top = editor.frame.maxY
        let height = max(1, min(top - rect.minY, ceil(contentHeight) + 2 + textShadowPadding))
        let inputHeight = max(1, min(top - rect.minY, ceil(contentHeight) + 2))
        editor.inputFrame = NSRect(x: editor.frame.minX, y: top - inputHeight,
                                   width: max(1, min(container.containerSize.width, editor.frame.width)),
                                   height: inputHeight)
        editor.frame = NSRect(x: editor.frame.minX, y: top - height, width: editor.frame.width, height: height)
        needsDisplay = true
    }

    func textDidEndEditing(_ notification: Notification) { commitTextEditing() }

    private func pushHistory() {
        undoHistory.append(annotations)
        if undoHistory.count > 100 { undoHistory.removeFirst() }
        redoHistory.removeAll()
    }

    private func notifyHistory() { onHistoryChange?(!undoHistory.isEmpty, !redoHistory.isEmpty) }

    private func clampedPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func normalizedRect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func squarePoint(_ point: NSPoint, from anchor: NSPoint) -> NSPoint {
        let directionX: CGFloat = point.x < anchor.x ? -1 : 1
        let directionY: CGFloat = point.y < anchor.y ? -1 : 1
        let roomX = directionX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let roomY = directionY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        let side = min(max(abs(point.x - anchor.x), abs(point.y - anchor.y)), roomX, roomY)
        return NSPoint(x: anchor.x + directionX * side, y: anchor.y + directionY * side)
    }

    private func anglePoint(_ point: NSPoint, from anchor: NSPoint) -> NSPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let x = cos(angle).rounded(), y = sin(angle).rounded()
        var length = (dx * x + dy * y) / (x * x + y * y)
        if x != 0 { length = min(length, x > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX) }
        if y != 0 { length = min(length, y > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY) }
        return NSPoint(x: anchor.x + x * length, y: anchor.y + y * length)
    }

    private func hitHandle(_ point: NSPoint, in rect: NSRect) -> Handle? {
        guard rect.width >= 8, rect.height >= 8 else { return nil }
        return Handle.allCases.min(by: {
            let a = $0.point(in: rect), b = $1.point(in: rect)
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }).flatMap { handle in
            let center = handle.point(in: rect)
            return abs(center.x - point.x) <= handleHitRadius && abs(center.y - point.y) <= handleHitRadius ? handle : nil
        }
    }

    private func hitMoveBorder(_ point: NSPoint, in rect: NSRect) -> Bool {
        guard rect.width >= 8, rect.height >= 8 else { return false }
        let outer = rect.insetBy(dx: -5, dy: -5)
        let inner = rect.insetBy(dx: 5, dy: 5)
        return outer.contains(point) && (inner.width <= 0 || inner.height <= 0 || !inner.contains(point))
    }

    private func annotation(at point: NSPoint) -> Int? {
        annotations.indices.reversed().first { annotations[$0].contains(point) }
    }

    private func hitAnnotationHandle(at point: NSPoint) -> AnnotationHandle? {
        guard let index = selectedAnnotation, textEditor == nil else { return nil }
        let item = annotations[index]
        return item.handles.min {
            $0.distance(to: point, in: item) < $1.distance(to: point, in: item)
        }.flatMap { $0.distance(to: point, in: item) <= 8 ? $0 : nil }
    }

    private func drawAnnotationSelection(in context: CGContext) {
        guard let index = selectedAnnotation, textEditor == nil else { return }
        let item = annotationPreview ?? annotations[index]
        context.setStrokeColor(NSColor.white.cgColor)
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1)
        if let area = item.textBounds ?? (item.tool == .pen ? item.movementBounds : nil) {
            context.setStrokeColor(NSColor.systemBlue.cgColor)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.stroke(area.insetBy(dx: -2, dy: -1))
        }
        for handle in item.handles {
            let center = handle.point(in: item)
            let rect = NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    private enum Interaction {
        case select(start: NSPoint, previous: NSRect?)
        case move(start: NSPoint, rect: NSRect)
        case resize(rect: NSRect, handle: Handle)
        case draw(start: NSPoint)
        case resizeAnnotation(handle: AnnotationHandle, start: NSPoint, original: Annotation)
        case moveAnnotation(start: NSPoint, original: Annotation)
    }

    private enum AnnotationHandle {
        case corner(Handle)
        case endpoint(Int)

        func point(in annotation: Annotation) -> NSPoint {
            switch self {
            case .corner(let corner): return corner.point(in: annotation.shapeBounds)
            case .endpoint(let index): return annotation.points[index]
            }
        }

        func distance(to location: NSPoint, in annotation: Annotation) -> CGFloat {
            let center = point(in: annotation)
            return hypot(center.x - location.x, center.y - location.y)
        }

        var cursor: NSCursor {
            switch self {
            case .corner(let corner): return corner.cursor
            case .endpoint: return .crosshair
            }
        }
    }

    private enum Handle: CaseIterable {
        case bottomLeft, bottom, bottomRight, right, topRight, top, topLeft, left
        func point(in rect: NSRect) -> NSPoint {
            switch self {
            case .bottomLeft: return NSPoint(x: rect.minX, y: rect.minY)
            case .bottom: return NSPoint(x: rect.midX, y: rect.minY)
            case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
            case .right: return NSPoint(x: rect.maxX, y: rect.midY)
            case .topRight: return NSPoint(x: rect.maxX, y: rect.maxY)
            case .top: return NSPoint(x: rect.midX, y: rect.maxY)
            case .topLeft: return NSPoint(x: rect.minX, y: rect.maxY)
            case .left: return NSPoint(x: rect.minX, y: rect.midY)
            }
        }
        var opposite: Handle {
            switch self {
            case .bottomLeft: return .topRight
            case .bottom: return .top
            case .bottomRight: return .topLeft
            case .right: return .left
            case .topRight: return .bottomLeft
            case .top: return .bottom
            case .topLeft: return .bottomRight
            case .left: return .right
            }
        }
        var cursor: NSCursor {
            switch self {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
    }

    private struct Annotation {
        var tool: DrawingTool
        var color: NSColor
        var width: CGFloat
        var points: [NSPoint]
        var text: TextAnnotation?
        let brushSeed = UInt32.random(in: .min ... .max)

        var canCommit: Bool { (tool != .arrow && tool != .line) || segmentLength >= 2 }

        var shapeBounds: NSRect {
            let start = points[0], end = points[points.count - 1]
            return NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        }

        var textBounds: NSRect? {
            guard let text else { return nil }
            let used = text.manager.usedRect(for: text.container)
            return NSRect(x: points[0].x + used.minX, y: points[0].y - used.maxY,
                          width: used.width, height: used.height)
        }

        var movementBounds: NSRect {
            if let textBounds { return textBounds }
            if tool == .pen { return pencilBounds.insetBy(dx: -width, dy: -width) }
            if tool == .arrow, let geometry = arrowGeometry {
                let headBounds = chalkBounds([geometry.left, points[points.count - 1], geometry.right])
                return shapeBounds.union(headBounds).insetBy(dx: -width, dy: -width)
            }
            if tool == .line || tool == .rectangle || tool == .ellipse {
                return shapeBounds.insetBy(dx: -width, dy: -width)
            }
            return shapeBounds.insetBy(dx: -width / 2, dy: -width / 2)
        }

        private var pencilBounds: NSRect {
            if points.count == 1 { return NSRect(origin: points[0], size: .zero) }
            return chalkBounds(points)
        }

        private func chalkBounds(_ vertices: [NSPoint]) -> NSRect {
            let path = CGMutablePath()
            path.addLines(between: vertices)
            return path.boundingBoxOfPath
        }

        var handles: [AnnotationHandle] {
            switch tool {
            case .rectangle, .ellipse: return [.corner(.bottomLeft), .corner(.bottomRight), .corner(.topRight), .corner(.topLeft)]
            case .arrow, .line: return [.endpoint(0), .endpoint(1)]
            default: return []
            }
        }

        func contains(_ point: NSPoint) -> Bool {
            let tolerance = max(12, width + 8)
            let path = CGMutablePath()
            switch tool {
            case .text:
                return textBounds?.insetBy(dx: -3, dy: -3).contains(point) ?? false
            case .pen:
                let radius = tolerance / 2
                guard pencilBounds.insetBy(dx: -radius, dy: -radius).contains(point) else { return false }
                if points.count == 1 {
                    return hypot(point.x - points[0].x, point.y - points[0].y) <= radius
                }
                path.addLines(between: ChalkStroke(width: width).pencilCenterline(points))
            case .rectangle:
                path.addRect(shapeBounds)
            case .ellipse:
                path.addEllipse(in: shapeBounds)
            case .arrow:
                guard let geometry = arrowGeometry, let tip = points.last else { return false }
                path.addLines(between: [geometry.left, tip, geometry.right])
                path.addLines(between: [points[0], tip])
            case .line:
                guard canCommit else { return false }
                path.addLines(between: [points[0], points[1]])
            default:
                return false
            }
            return path.copy(strokingWithWidth: tolerance, lineCap: .round, lineJoin: .round,
                             miterLimit: 10).contains(point)
        }

        private var segmentLength: CGFloat {
            guard let start = points.first, let end = points.last else { return 0 }
            return hypot(end.x - start.x, end.y - start.y)
        }

        func draw(in context: CGContext) {
            guard let start = points.first else { return }
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            switch tool {
            case .highlighter:
                let diameter = max(12, width * 4)
                context.setAlpha(0.32)
                context.setLineWidth(diameter)
                context.setLineCap(.butt)
                if points.count == 1 {
                    context.fillEllipse(in: NSRect(x: start.x - diameter / 2, y: start.y - diameter / 2,
                                                   width: diameter, height: diameter))
                } else {
                    context.beginPath()
                    context.move(to: start)
                    for point in points.dropFirst() { context.addLine(to: point) }
                    context.strokePath()
                }
            case .pen, .rectangle, .ellipse, .arrow, .line:
                drawChalk(in: context)
            case .text:
                text?.draw(at: start, in: context)
            case .selection: break
            }
            context.restoreGState()
        }

        private func drawChalk(in context: CGContext) {
            if (tool == .rectangle || tool == .ellipse) && shapeBounds.isEmpty { return }
            guard canCommit, let start = points.first, let end = points.last else { return }
            let brush = ChalkStroke(width: width, seed: brushSeed)
            let paths: [[CGPoint]]
            switch tool {
            case .pen: paths = brush.pencil(points)
            case .rectangle: paths = [brush.rectangle(shapeBounds)]
            case .ellipse: paths = [brush.oval(shapeBounds)]
            case .arrow:
                guard let head = arrowGeometry else { return }
                paths = brush.arrow(from: start, to: end, left: head.left, right: head.right)
            case .line: paths = brush.line(from: start, to: end)
            default: return
            }
            let silhouette = CGMutablePath()
            for path in paths where !path.isEmpty {
                silhouette.addLines(between: path)
                silhouette.closeSubpath()
            }
            if tool == .pen && silhouette.isEmpty {
                silhouette.addEllipse(in: CGRect(x: start.x - width / 2, y: start.y - width / 2,
                                                 width: width, height: width))
            }
            context.setAnnotationShadow()
            context.addPath(silhouette)
            context.fillPath()
        }

        private var arrowGeometry: (left: NSPoint, right: NSPoint)? {
            let length = segmentLength
            guard length >= 2 else { return nil }
            let start = points[0], tip = points[points.count - 1]
            let dx = (tip.x - start.x) / length
            let dy = (tip.y - start.y) / length
            let headLength = min(length * 0.54, max(13, width * 4.05))
            let halfHead = headLength * 0.35
            let base = NSPoint(x: tip.x - dx * headLength, y: tip.y - dy * headLength)
            return (NSPoint(x: base.x - dy * halfHead, y: base.y + dx * halfHead),
                    NSPoint(x: base.x + dy * halfHead, y: base.y - dx * halfHead))
        }
    }

    /// Keep the same TextKit layout for editing, preview and export.
    private struct TextAnnotation {
        let storage: NSTextStorage
        let manager = AnnotationTextLayout()
        let container: NSTextContainer

        init(_ text: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: text)
            container = NSTextContainer()
            Self.configure(container, width: width)
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
        }

        static func configure(_ container: NSTextContainer, width: CGFloat) {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            container.lineFragmentPadding = min(2, width / 4)
        }

        func draw(at origin: NSPoint, in context: CGContext) {
            context.translateBy(x: origin.x, y: origin.y)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
            NSGraphicsContext.restoreGraphicsState()
        }

    }
}

private final class AnnotationTextView: NSTextView {
    // Let the shadow draw into the padding while keeping clicks in the original input area.
    var inputFrame: NSRect = .zero
    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        if event.modifierFlags.contains(.shift) { insertNewline(nil) }
        else { onCommit?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        inputFrame.contains(point) ? super.hitTest(point) : nil
    }
}

private final class AnnotationTextLayout: NSLayoutManager {
    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>,
                               count: Int, font: NSFont, textMatrix: CGAffineTransform,
                               attributes: [NSAttributedString.Key: Any], in context: CGContext) {
        let silhouette = CGMutablePath()
        for index in 0..<count {
            let position = positions[index]
            var transform = textMatrix
            transform.tx = position.x
            transform.ty = position.y
            if let glyph = CTFontCreatePathForGlyph(font as CTFont, glyphs[index], &transform) {
                silhouette.addPath(glyph)
            }
        }
        if !silhouette.isEmpty {
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(NSColor.black.cgColor)
            context.setShadow(offset: .zero, blur: 5, color: NSColor.black.withAlphaComponent(0.075).cgColor)
            context.addPath(silhouette)
            context.fillPath()

            context.setAnnotationShadow(blur: 5)
            context.addPath(silhouette)
            context.fillPath()

            // Keep the shadows behind the antialiased glyph drawn by TextKit.
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setBlendMode(.destinationOut)
            context.addPath(silhouette)
            context.fillPath()
            context.endTransparencyLayer()
            context.restoreGState()
        }
        super.showCGGlyphs(glyphs, positions: positions, count: count, font: font, textMatrix: textMatrix,
                           attributes: attributes, in: context)
    }
}

private extension CGContext {
    func setAnnotationShadow(blur: CGFloat = 3) {
        setShadow(offset: CGSize(width: 3, height: -3), blur: blur,
                  color: NSColor.black.withAlphaComponent(0.36).cgColor)
    }
}
