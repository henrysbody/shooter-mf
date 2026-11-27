import AppKit
import CoreText

@main
struct CanvasExportTests {
    static func main() throws {
        _ = NSApplication.shared
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let source = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8,
                               bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        source.setFillColor(NSColor.white.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
        source.setFillColor(NSColor.red.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        source.setFillColor(NSColor.blue.cgColor)
        source.fill(CGRect(x: 200, y: 120, width: 200, height: 120))
        let canvas = CanvasView(image: source.makeImage()!, frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        canvas.selectionRect = NSRect(x: 20, y: 10, width: 50, height: 40)
        let first = canvas.renderedSelection()!
        let firstRep = first.representations[0] as! NSBitmapImageRep
        assert(firstRep.pixelsWide == 100 && firstRep.pixelsHigh == 80, "Retina crop dimensions")
        let sample = firstRep.colorAt(x: 50, y: 40)!.usingColorSpace(.deviceRGB)!
        assert(sample.redComponent > 0.98 && sample.greenComponent < 0.02 && sample.blueComponent < 0.02,
               "Bottom-left screenshot crop preserved")
        canvas.selectionRect = NSRect(x: 110, y: 70, width: 50, height: 40)
        let upper = canvas.renderedSelection()!.representations[0] as! NSBitmapImageRep
        let upperSample = upper.colorAt(x: 50, y: 40)!.usingColorSpace(.deviceRGB)!
        assert(upperSample.blueComponent > 0.98 && upperSample.redComponent < 0.02,
               "Top-right screenshot crop preserved without inversion")

        canvas.selectionRect = NSRect(x: 10, y: 10, width: 180, height: 100)
        canvas.style = EditorStyle(tool: .pen, color: .green, lineWidth: 4)
        canvas.mouseDown(with: mouse(.leftMouseDown, 60, 60))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 100, 60))
        canvas.mouseUp(with: mouse(.leftMouseUp, 100, 60))
        assert(canvas.canUndo && !canvas.canRedo, "Drawing records history")
        let drawn = canvas.renderedSelection()!.representations[0] as! NSBitmapImageRep
        let green = drawn.colorAt(x: 140, y: 100)!.usingColorSpace(.deviceRGB)!
        assert(green.greenComponent > 0.95 && green.redComponent < 0.1, "Stroke maps to crop pixels")
        canvas.undo()
        assert(!canvas.canUndo && canvas.canRedo, "Undo state")
        canvas.redo()
        assert(canvas.canUndo && !canvas.canRedo, "Redo state")

        canvas.style.tool = .selection
        canvas.mouseDown(with: mouse(.leftMouseDown, 100, 70))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 500, 500))
        canvas.mouseUp(with: mouse(.leftMouseUp, 500, 500))
        assert(canvas.selectionRect!.maxX <= 200 && canvas.selectionRect!.maxY <= 120, "Moving crop clamps to display")
        canvas.selectionRect = nil
        canvas.mouseDown(with: mouse(.leftMouseDown, 20, 20))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 100, 70, modifiers: .shift))
        canvas.mouseUp(with: mouse(.leftMouseUp, 100, 70, modifiers: .shift))
        assert(canvas.selectionRect!.width == canvas.selectionRect!.height, "Shift selection is square")
        canvas.selectionRect = nil
        assert(canvas.renderedSelection() == nil, "Empty selection cannot export")
        try testToolsAndText()
        testAnnotationEditing()
        testLineEditing()
        testPencilMovement()
        testFullScreenSelection()
        testAngleSnapping()
        testStraightChalkProfiles()
        testPencilProfile()
        testAnnotationTypography()
        testTextSpacing()
        testEscape()
        testTextShadows()
        testTextShadowPadding()
        testShapeShadows()
        testResizeAcrossAnchors(canvas)
        testCompactCropInteraction(image: source.makeImage()!)
        testPreferences()
        if CommandLine.arguments.contains("--window") { testVisibleWindowLifecycle(image: source.makeImage()!) }
        print("Canvas tests passed: Retina crop, shape movement and resizing, text editing, outlines, shadows, history, and clipped export.")
    }

    static func testPreferences() {
        let suiteName = "com.kadr.tests.\(UUID().uuidString)"
        let first = UserDefaults(suiteName: suiteName)!
        defer { first.removePersistentDomain(forName: suiteName) }
        let fresh = EditorPreferences.load(from: first)
        assert(fresh.tool == .rectangle && fresh.fontSize == 24 && fresh.lineWidth == 4,
               "Fresh preferences use rectangle, 4pt stroke and 24pt text")
        for (previous, current) in [(12, 16), (14, 24), (18, 36)] {
            first.set(previous, forKey: "editor.fontSize")
            assert(EditorPreferences.load(from: first).fontSize == CGFloat(current),
                   "Existing font size keeps its tier in the new presets")
        }
        let chosen = EditorStyle(tool: .text, color: .systemPurple, lineWidth: 2, fontSize: 24)
        EditorPreferences.save(chosen, to: first)
        let second = UserDefaults(suiteName: suiteName)!
        let restored = EditorPreferences.load(from: second)
        assert(restored.tool == .text && restored.color.isEqual(NSColor.systemPurple)
               && restored.lineWidth == 2 && restored.fontSize == 24,
               "A new preferences instance restores purple, 2pt stroke and 24pt text")
        first.set("unknown-tool", forKey: "editor.tool")
        first.set("unknown-color", forKey: "editor.color")
        first.set(-10, forKey: "editor.strokeWidth")
        first.set(999, forKey: "editor.fontSize")
        first.set(999, forKey: "editor.fontSizePreset")
        let invalid = EditorPreferences.load(from: second)
        assert(invalid.tool == .rectangle && invalid.color.isEqual(NSColor.systemRed)
               && invalid.lineWidth == 4 && invalid.fontSize == 24,
               "Invalid preferences safely fall back to defaults")
        assert(EditorTypography.strokeWidths.count == 3 && EditorTypography.fontSizes == [16, 24, 36],
               "Exactly three stroke and font presets are available")
    }

    static func testCompactCropInteraction(image: CGImage) {
        let canvas = CanvasView(image: image, frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        assert(canvas.style.tool == .rectangle, "Rectangle is the default tool")
        assert(canvas.style.fontSize == 24, "Default text size is 24pt")
        drag(canvas, from: NSPoint(x: 40, y: 40), to: NSPoint(x: 320, y: 180))
        assert(canvas.selectionRect == NSRect(x: 40, y: 40, width: 280, height: 140),
               "Initial crop drag works with the default rectangle tool")
        canvas.style.tool = .pen
        let historyBeforeMove = canvas.canUndo
        // This part of the border is well away from its corner and midpoint handles.
        drag(canvas, from: NSPoint(x: 95, y: 181), to: NSPoint(x: 125, y: 201))
        assert(canvas.selectionRect == NSRect(x: 70, y: 60, width: 280, height: 140),
               "Crop moves by dragging its border while pen is selected")
        assert(canvas.canUndo == historyBeforeMove, "Border movement does not create a pen stroke")
        // Eleven points from the corner exceeds the former 8pt handle target.
        drag(canvas, from: NSPoint(x: 59, y: 49), to: NSPoint(x: 90, y: 80))
        assert(canvas.selectionRect == NSRect(x: 90, y: 80, width: 260, height: 120),
               "Enlarged resize handle accepts an 11pt near miss with pen selected")
        drag(canvas, from: NSPoint(x: 10, y: 10), to: NSPoint(x: 60, y: 50))
        assert(canvas.selectionRect == NSRect(x: 10, y: 10, width: 50, height: 40),
               "Dragging outside an existing crop creates a new crop with pen selected")
    }

    /// Optional integration smoke: AppKit builds tracking areas only for a visible
    /// window, which catches cursor-registration failures hidden raster tests miss.
    static func testVisibleWindowLifecycle(image: CGImage) {
        final class TestWindow: NSWindow {
            override var canBecomeKey: Bool { true }
        }
        let canvas = CanvasView(image: image, frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        let window = TestWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 240),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pumpEvents()
        for rect in [NSRect(x: 20, y: 20, width: 0, height: 0),
                     NSRect(x: 20, y: 20, width: 2, height: 3),
                     NSRect(x: 20, y: 20, width: 10, height: 10),
                     NSRect(x: 20, y: 20, width: 240, height: 160)] {
            canvas.selectionRect = rect
            window.invalidateCursorRects(for: canvas)
            window.displayIfNeeded()
            pumpEvents()
        }
        for tool in DrawingTool.allCases {
            canvas.style.tool = tool
            window.invalidateCursorRects(for: canvas)
            pumpEvents()
        }
        canvas.style.tool = .text
        var copyRequests = 0
        var cancelRequests = 0
        canvas.onRequestCopy = { copyRequests += 1 }
        canvas.onRequestCancel = { cancelRequests += 1 }
        canvas.mouseDown(with: mouse(.leftMouseDown, 80, 100))
        let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
        assert(!editor.drawsBackground && window.firstResponder === editor,
               "The transparent editor receives keyboard input")
        editor.insertText("ТекстAB", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        window.sendEvent(deleteKey(51, in: window))
        window.sendEvent(deleteKey(117, in: window))
        assert(editor.string == "Текст" && canvas.isEditingText && window.firstResponder === editor,
               "Backspace and forward Delete edit the characters while typing")
        pumpEvents()
        let attributes = editor.attributedString().attributes(at: 0, effectiveRange: nil)
        assert(attributes[.strokeColor] == nil && attributes[.strokeWidth] == nil && attributes[.shadow] == nil,
               "The shared layout draws the shadow without changing typing attributes")
        let originalFrame = editor.frame
        let shiftReturnEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "\r", charactersIgnoringModifiers: "\r",
                                               isARepeat: false, keyCode: 36)!
        let returnEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          characters: "\r", charactersIgnoringModifiers: "\r",
                                          isARepeat: false, keyCode: 36)!
        window.sendEvent(shiftReturnEvent)
        pumpEvents()
        assert(canvas.isEditingText && !canvas.canUndo && editor.string == "Текст\n",
               "Shift+Return inserts a line break and keeps the text editor active")
        assert(editor.frame.height > originalFrame.height && editor.frame.maxY == originalFrame.maxY,
               "The editor grows down without shifting the first line")
        editor.insertText("Вторая строка", replacementRange: NSRange(location: NSNotFound, length: 0))
        assert(editor.string == "Текст\nВторая строка", "Typing continues on the new line")
        window.sendEvent(returnEvent)
        pumpEvents()
        assert(window.isVisible && copyRequests == 0 && cancelRequests == 0,
               "Return leaves the editor window open")
        assert(!canvas.isEditingText && canvas.canUndo, "Return commits the multiline text as one annotation")
        window.close()
        pumpEvents()
        print("Visible-window smoke passed: tiny crops, cursors, and native multiline text input.")
    }

    static func pumpEvents() {
        let deadline = Date(timeIntervalSinceNow: 0.08)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        } while Date() < deadline
    }

    static func testToolsAndText() throws {
        let context = CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
        let canvas = CanvasView(image: context.makeImage()!, frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.selectionRect = NSRect(x: 10, y: 10, width: 180, height: 100)
        assert(darkPixelCount(bitmap(canvas)) == 0, "Export contains no dimming, handles or border")

        canvas.style = EditorStyle(tool: .rectangle, color: .black, lineWidth: 4)
        drag(canvas, from: NSPoint(x: 40, y: 40), to: NSPoint(x: 120, y: 90))
        assert(darkPixelCount(bitmap(canvas)) > 400, "Rectangle exports visible outline")
        assert(pixel(bitmap(canvas), x: 140, y: 90).redComponent > 0.98, "Rectangle remains unfilled")
        canvas.undo()
        assert(darkPixelCount(bitmap(canvas)) == 0, "Rectangle undo restores original pixels")

        canvas.style.tool = .ellipse
        drag(canvas, from: NSPoint(x: 40, y: 40), to: NSPoint(x: 120, y: 90), modifiers: .shift)
        assert(darkPixelCount(bitmap(canvas)) > 300, "Ellipse exports visible outline")
        canvas.undo()

        canvas.style = EditorStyle(tool: .highlighter, color: .blue, lineWidth: 4)
        drag(canvas, from: NSPoint(x: 40, y: 70), to: NSPoint(x: 130, y: 70))
        let highlighted = pixel(bitmap(canvas), x: 130, y: 80)
        assert(highlighted.blueComponent > 0.98 && highlighted.redComponent > 0.5 && highlighted.redComponent < 0.85,
               "Highlighter stays translucent over screenshot")
        canvas.undo()

        canvas.style = EditorStyle(tool: .arrow, color: .black, lineWidth: 4)
        let left = NSPoint(x: 40, y: 70)
        let right = NSPoint(x: 140, y: 70)
        drag(canvas, from: left, to: right)
        let pointsRight = bitmap(canvas)
        assert(hasInkNear(pointsRight, x: 228, y: 68) && !hasInkNear(pointsRight, x: 220, y: 68)
               && !hasInkNear(pointsRight, x: 92, y: 68),
               "The shorter arrowhead points toward the right release point")
        canvas.undo()
        drag(canvas, from: right, to: left)
        let pointsLeft = bitmap(canvas)
        assert(hasInkNear(pointsLeft, x: 92, y: 68) && !hasInkNear(pointsLeft, x: 228, y: 68),
               "Reversing the drag moves the arrowhead to the left release point")
        canvas.undo()
        drag(canvas, from: left, to: left)
        assert(!canvas.canUndo, "An arrow with no drag does not create a mark or history entry")

        canvas.style = EditorStyle(tool: .text, color: .black, lineWidth: 4)
        var copyRequests = 0
        var cancelRequests = 0
        canvas.onRequestCopy = { copyRequests += 1 }
        canvas.onRequestCancel = { cancelRequests += 1 }
        canvas.mouseDown(with: mouse(.leftMouseDown, 30, 95))
        assert(canvas.isEditingText, "Canvas exposes active text editing to the app keyboard router")
        let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
        assert(!editor.drawsBackground && editor.string.isEmpty, "Live text has no background or placeholder")
        assert(editor.font?.pointSize == 24, "Live text uses the selected 24pt size")
        editor.insertText("Кадр\n\nТекст", replacementRange: NSRange(location: NSNotFound, length: 0))
        let firstRow = Int((canvas.selectionRect!.maxY - editor.frame.maxY) * 2)
        let lineHeight = editor.layoutManager!.defaultLineHeight(for: editor.font!) * 2
        let secondRow = firstRow + Int(lineHeight.rounded())
        let thirdRow = firstRow + Int((lineHeight * 2).rounded())
        let exported = bitmap(canvas)
        assert(!canvas.isEditingText && editor.superview == nil, "Export commits and dismisses the live text editor")
        assert(darkPixelCount(exported, rows: firstRow..<secondRow) > 80
               && darkPixelCount(exported, rows: (secondRow + 10)..<(thirdRow - 10)) == 0
               && darkPixelCount(exported, rows: thirdRow..<exported.pixelsHigh) > 80,
               "Export preserves both Cyrillic lines and the blank line between them")
        let fixedText = exported.representation(using: .png, properties: [:])!
        canvas.style.fontSize = 36
        canvas.style.lineWidth = 8
        assert(bitmap(canvas).representation(using: .png, properties: [:])! == fixedText,
               "Existing text keeps its original font size when stroke presets change")
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "\r", charactersIgnoringModifiers: "\r",
                                             isARepeat: false, keyCode: 36)!)
        assert(copyRequests == 0 && cancelRequests == 0 && canvas.hasSelection(),
               "Return after committing leaves the editor open")
        canvas.undo()
        assert(darkPixelCount(bitmap(canvas)) == 0, "Text annotation is undoable")
        canvas.redo()
        assert(darkPixelCount(bitmap(canvas)) > 80, "Text annotation can be redone")
        canvas.undo()

        // A stroke crossing the crop must not leak beyond it or alter export size.
        canvas.selectionRect = NSRect(x: 40, y: 40, width: 80, height: 40)
        canvas.style = EditorStyle(tool: .pen, color: .black, lineWidth: 20)
        drag(canvas, from: NSPoint(x: 60, y: 60), to: NSPoint(x: 190, y: 60))
        let clipped = bitmap(canvas)
        assert(clipped.pixelsWide == 160 && clipped.pixelsHigh == 80, "Clipped stroke keeps exact crop dimensions")
        assert(darkPixelCount(clipped) > 100, "Cross-boundary stroke exports inside crop")
        _ = window // Retain the window while the text editor is in use.
    }

    static func testResizeAcrossAnchors(_ canvas: CanvasView) {
        canvas.style.tool = .selection
        canvas.selectionRect = NSRect(x: 50, y: 40, width: 70, height: 50)
        // Drag the bottom-left corner beyond the original top-right corner.
        drag(canvas, from: NSPoint(x: 50, y: 40), to: NSPoint(x: 170, y: 110))
        assert(canvas.selectionRect == NSRect(x: 120, y: 90, width: 50, height: 20),
               "Corner resize crosses its anchor without negative dimensions")
        canvas.selectionRect = NSRect(x: 50, y: 40, width: 70, height: 50)
        drag(canvas, from: NSPoint(x: 50, y: 65), to: NSPoint(x: 160, y: 65))
        assert(canvas.selectionRect == NSRect(x: 120, y: 40, width: 40, height: 50),
               "Side resize crosses its anchor and preserves the other axis")
        canvas.selectionRect = NSRect(x: 50, y: 40, width: 70, height: 50)
        drag(canvas, from: NSPoint(x: 85, y: 90), to: NSPoint(x: 85, y: 15))
        assert(canvas.selectionRect == NSRect(x: 50, y: 15, width: 70, height: 25),
               "Vertical side resize crosses its anchor")
    }

    static func testAnnotationEditing() {
        let canvas = CanvasView(image: solidImage(width: 500, height: 360),
                                frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.selectionRect = canvas.bounds
        canvas.style = EditorStyle(tool: .rectangle, color: .black)
        let origin = NSPoint(x: 60, y: 60)
        let corner = NSPoint(x: 150, y: 130)
        drag(canvas, from: origin, to: corner)
        let initial = bitmap(canvas).tiffRepresentation!
        drag(canvas, from: NSPoint(x: 100, y: 130), to: NSPoint(x: 100, y: 130))
        assert(bitmap(canvas).tiffRepresentation! == initial, "Selection handles never appear in the export")
        drag(canvas, from: NSPoint(x: 153, y: 132), to: NSPoint(x: 223, y: 182))
        let resized = bitmap(canvas).tiffRepresentation!
        assert(resized != initial && hasInkNear(bitmap(canvas), x: 220, y: 250),
               "A rectangle corner moves by the drag delta while its opposite corner stays anchored")
        canvas.undo()
        assert(bitmap(canvas).tiffRepresentation! == initial, "One undo restores the rectangle's original size")
        canvas.redo()
        assert(bitmap(canvas).tiffRepresentation! == resized, "Redo restores the resized rectangle")

        drag(canvas, from: NSPoint(x: 100, y: 180), to: NSPoint(x: 132, y: 210))
        let movedRectangle = bitmap(canvas)
        assert(hasInkNear(movedRectangle, x: 92, y: 245) && hasInkNear(movedRectangle, x: 252, y: 245)
               && pixel(movedRectangle, x: 60, y: 260).redComponent > 0.98,
               "Dragging the contour translates both sides of the rectangle by the same amount")
        assert(canvas.selectionRect == canvas.bounds, "Moving a mark leaves the crop in place")
        canvas.undo()
        assert(bitmap(canvas).tiffRepresentation! == resized, "One undo restores the rectangle's position")
        canvas.redo()
        assert(bitmap(canvas).tiffRepresentation! == movedRectangle.tiffRepresentation!,
               "Redo restores the rectangle's movement")

        canvas.style.tool = .arrow
        let tail = NSPoint(x: 280, y: 80), tip = NSPoint(x: 380, y: 80)
        drag(canvas, from: tail, to: tip)
        drag(canvas, from: tip, to: tip)
        let movedTip = NSPoint(x: 380, y: 145)
        drag(canvas, from: tip, to: movedTip)
        assert(hasInkNear(bitmap(canvas), x: 374, y: 218)
               && pixel(bitmap(canvas), x: 376, y: 282).redComponent > 0.98,
               "The arrowhead follows its handle")
        drag(canvas, from: NSPoint(x: 330, y: 112), to: NSPoint(x: 348, y: 146))
        let movedArrow = bitmap(canvas)
        assert(hasInkNear(movedArrow, x: 348, y: 214) && hasInkNear(movedArrow, x: 392, y: 184)
               && pixel(movedArrow, x: 330, y: 248).redComponent > 0.98,
               "Dragging the shaft moves the entire arrow without resizing it")

        canvas.style.tool = .ellipse
        drag(canvas, from: NSPoint(x: 350, y: 230), to: NSPoint(x: 450, y: 300))
        drag(canvas, from: NSPoint(x: 400, y: 300), to: NSPoint(x: 370, y: 315))
        let movedOval = bitmap(canvas)
        assert(hasInkNear(movedOval, x: 370, y: 45) && hasInkNear(movedOval, x: 320, y: 80)
               && pixel(movedOval, x: 400, y: 60).redComponent > 0.98,
               "Dragging the contour of an oval moves it without changing its radii")

        canvas.style = EditorStyle(tool: .text, color: .black, fontSize: 24)
        canvas.mouseDown(with: mouse(.leftMouseDown, 85, 280))
        let newText = canvas.subviews.compactMap { $0 as? NSTextView }.first!
        newText.insertText("Кадр\nДва", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.commitTextEditing()
        let originalText = bitmap(canvas).tiffRepresentation!
        canvas.style = EditorStyle(tool: .rectangle, color: .systemRed, fontSize: 36)
        drag(canvas, from: NSPoint(x: 104, y: 266), to: NSPoint(x: 204, y: 276))
        let movedText = bitmap(canvas).tiffRepresentation!
        assert(movedText != originalText, "A label can be moved while the rectangle tool is selected")
        canvas.undo()
        assert(bitmap(canvas).tiffRepresentation! == originalText, "One undo restores the label's position")
        canvas.redo()
        assert(bitmap(canvas).tiffRepresentation! == movedText, "Redo restores the label's movement")
        canvas.mouseDown(with: mouse(.leftMouseDown, 204, 276, clickCount: 2))
        let existing = canvas.subviews.compactMap { $0 as? NSTextView }.first!
        assert(existing.string == "Кадр\nДва" && existing.font?.pointSize == 24
               && existing.textColor?.isEqual(NSColor.black) == true,
               "Double-click reopens the same label with its original style")
        existing.selectAll(nil)
        existing.insertText("Правка", replacementRange: NSRange(location: NSNotFound, length: 0))
        canvas.commitTextEditing()
        let edited = bitmap(canvas).tiffRepresentation!
        assert(edited != movedText, "Changing text updates the exported label")
        canvas.undo()
        assert(bitmap(canvas).tiffRepresentation! == movedText, "Undo restores the old text without moving it")
        canvas.redo()
        assert(bitmap(canvas).tiffRepresentation! == edited, "Redo restores the edit")
        var deletedCounts: [Int] = []
        canvas.onDeleteAnnotations = { deletedCounts.append($0) }
        for keyCode in [UInt16(51), 117] {
            canvas.keyDown(with: deleteKey(keyCode))
            assert(darkPixelCount(bitmap(canvas)) == 0 && canvas.selectionRect == canvas.bounds,
                   "With no selected mark, Delete and Backspace clear the annotations and keep the crop")
            assert(deletedCounts.last == 4, "Bulk deletion reports all four removed marks")
            canvas.keyDown(with: deleteKey(keyCode))
            canvas.undo()
            assert(bitmap(canvas).tiffRepresentation! == edited, "Bulk deletion undoes in a single step")
            canvas.redo()
            assert(darkPixelCount(bitmap(canvas)) == 0, "Redo clears the annotations again")
            canvas.undo()
        }
        let rectangleEdge = NSPoint(x: 132, y: 210)
        for keyCode in [UInt16(51), 117] {
            drag(canvas, from: rectangleEdge, to: rectangleEdge)
            canvas.keyDown(with: deleteKey(keyCode))
            let deleted = bitmap(canvas)
            assert(pixel(deleted, x: 132, y: 150).redComponent > 0.98
                   && hasInkNear(deleted, x: 348, y: 214) && deletedCounts.last == 1,
                   "Delete removes just the selected annotation")
            let notifications = deletedCounts.count
            canvas.keyDown(with: deleteKey(keyCode, repeating: true))
            assert(bitmap(canvas).tiffRepresentation! == deleted.tiffRepresentation! && deletedCounts.count == notifications,
                   "A held Delete key cannot clear the remaining marks")
            canvas.undo()
            assert(bitmap(canvas).tiffRepresentation! == edited, "Undo restores the deleted annotation")
            canvas.redo()
            assert(bitmap(canvas).tiffRepresentation! == deleted.tiffRepresentation!,
                   "Redo deletes the annotation again")
            canvas.undo()
        }
        _ = window
    }

    static func testLineEditing() {
        let frame = NSRect(x: 0, y: 0, width: 250, height: 160)
        let canvas = CanvasView(image: solidImage(width: 250, height: 160), frame: frame)
        canvas.selectionRect = frame
        canvas.style = EditorStyle(tool: .line, color: .black, lineWidth: 4)
        let start = NSPoint(x: 50, y: 50), end = NSPoint(x: 190, y: 50)
        drag(canvas, from: start, to: start)
        assert(!canvas.canUndo, "Clicking with the line tool does not leave a dot")
        drag(canvas, from: start, to: end, modifiers: .shift)
        let line = bitmap(canvas)
        assert(hasInkNear(line, x: 120, y: 110) && !hasInkNear(line, x: 182, y: 103),
               "The horizontal line uses its two exact endpoints and has no arrowhead")
        drag(canvas, from: NSPoint(x: 100, y: 50), to: NSPoint(x: 112, y: 75))
        let moved = bitmap(canvas)
        assert(hasInkNear(moved, x: 112, y: 85) && !hasInkNear(moved, x: 120, y: 110),
               "Dragging the chalk line moves its two ends together")
        drag(canvas, from: NSPoint(x: 202, y: 75), to: NSPoint(x: 202, y: 105))
        let resized = bitmap(canvas)
        assert(hasInkNear(resized, x: 68, y: 85) && hasInkNear(resized, x: 193, y: 57)
               && !hasInkNear(resized, x: 193, y: 85),
               "Dragging an endpoint keeps the opposite end in place")
        canvas.undo()
        assert(bitmap(canvas).tiffRepresentation! == moved.tiffRepresentation!,
               "Undo restores both line geometry and its stable texture")
    }

    static func testPencilMovement() {
        let frame = NSRect(x: 0, y: 0, width: 260, height: 180)
        let canvas = CanvasView(image: solidImage(width: 260, height: 180), frame: frame)
        canvas.selectionRect = frame
        canvas.style = EditorStyle(tool: .pen, color: .black, lineWidth: 8)
        canvas.mouseDown(with: mouse(.leftMouseDown, 55, 50))
        for (x, y) in [(82.0, 106.0), (110.0, 118.0), (147.0, 103.0), (173.0, 55.0)] {
            canvas.mouseDragged(with: mouse(.leftMouseDragged, x, y))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, 173, 55))
        let original = bitmap(canvas)
        assert(hasInkNear(original, x: 110, y: 64), "The curved pencil stroke uses more than its two endpoints")

        let grab = NSPoint(x: 110, y: 116)
        drag(canvas, from: grab, to: NSPoint(x: 130, y: 240))
        let moved = bitmap(canvas)
        assert(hasInkNear(moved, x: 130, y: 10) && !hasInkNear(moved, x: 110, y: 64),
               "Dragging the pencil through its curve moves the whole stroke and keeps the farthest point inside the crop")
        assert(hasInkNear(moved, x: 96, y: 36), "The trailing part moves by the same amount")
        canvas.undo()
        assert(bitmap(canvas).tiffRepresentation! == original.tiffRepresentation!, "Undo restores the whole pencil stroke")
        canvas.redo()
        assert(bitmap(canvas).tiffRepresentation! == moved.tiffRepresentation!, "Redo preserves the moved stroke and bristles")

        let empty = NSPoint(x: 140, y: 126)
        drag(canvas, from: empty, to: empty)
        assert(hasInkNear(bitmap(canvas), x: 140, y: 54), "Clicking inside the bounds but away from the ink makes a new mark")
        drag(canvas, from: empty, to: NSPoint(x: 143, y: 107))
        assert(hasInkNear(bitmap(canvas), x: 143, y: 73) && !hasInkNear(bitmap(canvas), x: 140, y: 54),
               "A single pencil dot can also be moved")
    }

    static func testFullScreenSelection() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let canvas = CanvasView(image: solidImage(width: 800, height: 500), frame: frame)
        let original = NSRect(x: 85, y: 110, width: 210, height: 100)
        canvas.selectionRect = original
        assert(canvas.toggleFullScreen() && canvas.selectionRect == frame)
        assert(!canvas.toggleFullScreen() && canvas.selectionRect == original)
        canvas.selectionRect = nil
        assert(canvas.toggleFullScreen() && canvas.selectionRect == frame)
        assert(!canvas.toggleFullScreen() && canvas.selectionRect == NSRect(x: 220, y: 150, width: 360, height: 200))
    }

    static func testAngleSnapping() {
        let frame = NSRect(x: 0, y: 0, width: 240, height: 160)
        let canvas = CanvasView(image: solidImage(width: 240, height: 160), frame: frame)
        canvas.selectionRect = frame
        for tool in [DrawingTool.line, .arrow] {
            canvas.style = EditorStyle(tool: tool, color: .black, lineWidth: 4)
            drag(canvas, from: NSPoint(x: 50, y: 50), to: NSPoint(x: 144, y: 94), modifiers: .shift)
            let image = bitmap(canvas)
            assert(hasInkNear(image, x: 100, y: 60) && !hasInkNear(image, x: 100, y: 87),
                   "Shift snaps \(tool) to the nearest 45-degree direction")
            canvas.undo()
        }
    }

    static func testPencilProfile() {
        let brush = ChalkStroke(width: 8)
        let rising = [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100)]
        let falling = [CGPoint(x: 20, y: 100), CGPoint(x: 100, y: 20)]
        func width(_ points: [CGPoint], normal: CGVector) -> CGFloat {
            let offsets = brush.pencil(points).flatMap { $0 }.map { $0.x * normal.dx + $0.y * normal.dy }
            return offsets.max()! - offsets.min()!
        }
        let rise = width(rising, normal: CGVector(dx: 1, dy: -1))
        let fall = width(falling, normal: CGVector(dx: 1, dy: 1))
        assert(rise > fall * 1.4, "The ascending diagonal is visibly broader")
        assert(abs(rise - width(Array(rising.reversed()), normal: CGVector(dx: 1, dy: -1))) < 0.5,
               "The nib follows the diagonal regardless of drag direction")

        let corner = CGPoint(x: 80, y: 20)
        let contour = CGMutablePath()
        let pencil = brush.pencil([rising[0], corner, CGPoint(x: 80, y: 80)])
        for polygon in pencil {
            contour.addLines(between: polygon)
            contour.closeSubpath()
        }
        assert(!contour.contains(corner) && contour.contains(CGPoint(x: 76.25, y: 36.875)),
               "The outline follows the rounded curve between mouse samples")
        assert(pencil.count > 12 && pencil.flatMap { $0 }.map(\.y).max() == 80,
               "The pencil separates into bristles aimed along the curved path")

        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let canvas = CanvasView(image: context.makeImage()!, frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        canvas.selectionRect = canvas.bounds
        canvas.style = EditorStyle(tool: .pen, color: .red, lineWidth: 4)
        drag(canvas, from: CGPoint(x: 28, y: 50), to: CGPoint(x: 165, y: 50))
        let rendered = bitmap(canvas)
        let above = rendered.colorAt(x: 100, y: 45)!.usingColorSpace(.deviceRGB)!
        let below = rendered.colorAt(x: 100, y: 54)!.usingColorSpace(.deviceRGB)!
        assert(below.redComponent < above.redComponent - 0.03,
               "The pencil export contains a soft shadow below the stroke")
    }

    static func testStraightChalkProfiles() {
        let brush = ChalkStroke(width: 8)
        func path(_ points: [CGPoint]) -> CGPath {
            let result = CGMutablePath()
            result.addLines(between: points)
            result.closeSubpath()
            return result
        }

        let start = CGPoint(x: 20, y: 50), tip = CGPoint(x: 160, y: 50)
        let linePaths = brush.line(from: start, to: tip)
        let line = CGMutablePath()
        for polygon in linePaths {
            line.addPath(path(polygon))
        }
        for column in stride(from: 52, through: 127, by: 3) {
            let x = CGFloat(column)
            assert(line.contains(CGPoint(x: x, y: 53.75)) && line.contains(CGPoint(x: x, y: 46.25))
                   && !line.contains(CGPoint(x: x, y: 54.3)) && !line.contains(CGPoint(x: x, y: 45.7)),
                   "The body stays straight and the edge grain is contained")
        }
        assert(line.boundingBoxOfPath.minX == 20 && line.boundingBoxOfPath.maxX == 160,
               "The bristles reach both endpoints")
        let starts = linePaths.dropFirst().filter { $0.allSatisfy { $0.x < 80 } }.map { $0.map(\.x).min()! }
        let ends = linePaths.dropFirst().filter { $0.allSatisfy { $0.x > 100 } }.map { $0.map(\.x).max()! }
        assert(Set(starts).count > 5 && Set(ends).count > 5,
               "Each end has bristles with independent lengths")
        assert(linePaths == brush.line(from: start, to: tip) &&
               linePaths != ChalkStroke(width: 8, seed: 12_345).line(from: start, to: tip),
               "Repainting keeps the same pattern and a different seed creates another")
        let short = brush.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 22, y: 50))
        assert(short.flatMap { $0 }.map(\.x).max() == 22,
               "Even a short line finishes within its release point")

        let arrowPaths = brush.arrow(from: start, to: tip,
                                     left: CGPoint(x: 128, y: 61.2), right: CGPoint(x: 128, y: 38.8))
        let arrow = CGMutablePath()
        for polygon in arrowPaths { arrow.addPath(path(polygon)) }
        assert(arrow.boundingBoxOfPath.maxX == tip.x && arrow.contains(CGPoint(x: 159, y: 50))
               && !arrow.contains(CGPoint(x: 159, y: 50.75))
               && arrow.contains(CGPoint(x: 52, y: 53.6)),
               "The arrow has a broad shaft and converges to the precise release point")
        let tail = arrowPaths.dropFirst().dropLast(2)
        assert(tail.count > 5 && tail.allSatisfy { $0.allSatisfy { $0.x < 50 } },
               "Bristles are confined to the arrow's tail")
        let wing = path(arrowPaths[arrowPaths.count - 2])
        assert(wing.contains(CGPoint(x: 128, y: 61.2)) && wing.contains(CGPoint(x: 134, y: 58.1))
               && !wing.contains(CGPoint(x: 134, y: 61.3)) && !arrow.contains(CGPoint(x: 130, y: 55)),
               "The free wing tip flares away from the shaft past the inward bend")

        let rect = CGRect(x: 20, y: 20, width: 160, height: 72)
        let rectangle = path(brush.rectangle(rect))
        assert(rectangle.contains(CGPoint(x: 176, y: 95)) && rectangle.contains(CGPoint(x: 105, y: 92))
               && !rectangle.contains(CGPoint(x: 105, y: 95.5)),
               "Rectangle edges meet at square corners and the overlapping ends keep the seam closed")
        assert(rectangle.contains(CGPoint(x: 45, y: 96)) && !rectangle.contains(CGPoint(x: 155, y: 96))
               && rectangle.contains(CGPoint(x: 155, y: 16)) && !rectangle.contains(CGPoint(x: 45, y: 16)),
               "Rectangle strokes become thicker toward the upper-left and lower-right corners")
        let oval = path(brush.oval(rect))
        assert(oval.contains(CGPoint(x: 180, y: 56)) && oval.contains(CGPoint(x: 100, y: 20))
               && !oval.contains(CGPoint(x: 185, y: 56)) && !oval.contains(CGPoint(x: 100, y: 25)),
               "The oval follows the geometric ellipse")
        func outsideOval(at angle: CGFloat) -> CGPoint {
            let x = cos(angle), y = sin(angle)
            let rx = rect.width / 2, ry = rect.height / 2
            let nx = x / rx, ny = y / ry
            let normal = hypot(nx, ny)
            return CGPoint(x: rect.midX + rx * x + 4.15 * nx / normal,
                           y: rect.midY + ry * y + 4.15 * ny / normal)
        }
        assert(oval.contains(outsideOval(at: 0.75 * .pi)) && oval.contains(outsideOval(at: 1.75 * .pi))
               && !oval.contains(outsideOval(at: 0.25 * .pi)) && !oval.contains(outsideOval(at: 1.25 * .pi)),
               "The oval is wider along the upper-left and lower-right diagonal")
    }

    static func testTextShadows() {
        for scale in [1, 2] {
            let size = NSRect(x: 0, y: 0, width: 240, height: 120)
            func render(_ ink: NSColor, size fontSize: CGFloat) -> (NSBitmapImageRep, CGRect) {
                let image = solidImage(width: 240 * scale, height: 120 * scale)
                let canvas = CanvasView(image: image, frame: size)
                let window = NSWindow(contentRect: size, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = canvas
                canvas.selectionRect = size
                let font = EditorTypography.font(ofSize: fontSize) as CTFont
                var glyph = CTFontGetGlyphWithName(font, "H" as CFString)
                let inkBounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
                let edge = ((32 + inkBounds.minX) * CGFloat(scale)).rounded() / CGFloat(scale)
                canvas.style = EditorStyle(tool: .text, color: ink, fontSize: fontSize)
                canvas.mouseDown(with: mouse(.leftMouseDown, edge - inkBounds.minX - 2, 88))
                let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
                editor.insertText("H     H", replacementRange: NSRange(location: NSNotFound, length: 0))
                let manager = editor.layoutManager!
                manager.ensureLayout(for: editor.textContainer!)
                let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                let baseline = manager.location(forGlyphAt: 0)
                let origin = editor.textContainerOrigin
                let glyphFrame = CGRect(x: editor.frame.minX + origin.x + fragment.minX + baseline.x + inkBounds.minX,
                                        y: size.height - editor.frame.maxY + origin.y + fragment.minY + baseline.y - inkBounds.maxY,
                                        width: inkBounds.width, height: inkBounds.height)
                    .applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
                let result = bitmap(canvas)
                _ = window
                return (result, glyphFrame)
            }
            for fontSize in EditorTypography.fontSizes {
                let (white, glyph) = render(.white, size: fontSize)
                let row = Int(glyph.midY)
                let left = Int(glyph.minX.rounded())
                let right = Int(glyph.maxX.rounded())
                let nearLeft = 1 - pixel(white, x: left - 2, y: row).redComponent
                let nearRight = 1 - pixel(white, x: right + 1, y: row).redComponent
                let rightTail = 1 - pixel(white, x: right + 5, y: row).redComponent
                assert(pixel(white, x: left, y: row).redComponent > 0.82 && nearLeft > 0.008 && nearLeft < 0.15,
                       "\(fontSize) pt text has a faint shadow on the left and a clean glyph edge at \(scale)× (\(nearLeft))")
                assert(nearRight > nearLeft + 0.025 && rightTail > 0.003 && rightTail < nearRight,
                       "The shadow touches the right edge and fades outward at \(scale)× (\(nearRight), \(rightTail))")
                if fontSize == 36 {
                    let figure = CanvasView(image: solidImage(width: 240 * scale, height: 120 * scale), frame: size)
                    figure.selectionRect = size
                    let width = fontSize * 0.09
                    figure.style = EditorStyle(tool: .rectangle, color: .white, lineWidth: width)
                    drag(figure, from: NSPoint(x: 125, y: 25), to: NSPoint(x: 176 - width / 2, y: 95))
                    let reference = bitmap(figure)
                    let figureNear = 1 - pixel(reference, x: 176 * scale + 1, y: 60 * scale).redComponent
                    let figureTail = 1 - pixel(reference, x: 176 * scale + 5, y: 60 * scale).redComponent
                    assert(rightTail / nearRight > figureTail / figureNear + 0.05,
                           "The directional text shadow has a softer falloff than the figure shadow at \(scale)×")
                }
            }
            let (black, glyph) = render(.black, size: 36)
            let row = Int(glyph.midY)
            let left = Int(glyph.minX.rounded())
            assert(pixel(black, x: left, y: row).redComponent < 0.28,
                   "Black text uses its own fill through the first pixel of the glyph")
            assert(pixel(black, x: 100 * scale, y: row).redComponent > 0.99,
                   "The space between letters has no backdrop")
            let (white, _) = render(.white, size: 36)
            let stemX = left + 2 * scale
            let topShadow = 1 - pixel(white, x: stemX, y: Int(glyph.minY) - 1).redComponent
            let bottomShadow = 1 - pixel(white, x: stemX + 3, y: Int(glyph.maxY) + 2).redComponent
            let bottomTail = 1 - pixel(white, x: stemX + 3, y: Int(glyph.maxY) + 8).redComponent
            assert(topShadow > 0.008 && bottomShadow > topShadow + 0.025 && bottomTail < bottomShadow,
                   "Shadow surrounds the glyph and falls more strongly below it (\(topShadow), \(bottomShadow), \(bottomTail))")
        }
    }

    static func testTextShadowPadding() {
        let size = NSRect(x: 0, y: 0, width: 160, height: 100)
        for scale in [1, 2] {
            let canvas = CanvasView(image: solidImage(width: 160 * scale, height: 100 * scale), frame: size)
            let window = NSWindow(contentRect: size, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = canvas
            canvas.selectionRect = size
            canvas.style = EditorStyle(tool: .text, color: .white, fontSize: 16)
            canvas.mouseDown(with: mouse(.leftMouseDown, 35, 72))
            let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
            editor.insertText("Кадр", replacementRange: NSRange(location: NSNotFound, length: 0))
            let manager = editor.layoutManager!, container = editor.textContainer!
            let contentHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY,
                                    manager.defaultLineHeight(for: editor.font!))
            let inputBottom = editor.frame.maxY - ceil(contentHeight) - 2
            let paddedBottom = editor.frame.minY
            assert(paddedBottom < inputBottom && editor.frame.maxY == 72,
                   "Padding below the label gives the shadow room at the original text position")
            assert(editor.hitTest(NSPoint(x: 40, y: inputBottom + 3)) === editor
                   && editor.hitTest(NSPoint(x: 40, y: (inputBottom + paddedBottom) / 2)) == nil,
                   "The shadow margin remains outside the text hit area")

            let image = bitmap(canvas)
            func darkest(atY y: CGFloat) -> CGFloat {
                let row = Int(((size.height - y) * CGFloat(scale)).rounded())
                return (35 * scale..<100 * scale).map { pixel(image, x: $0, y: row).redComponent }.min()!
            }
            assert(darkest(atY: inputBottom) < 0.997 && darkest(atY: paddedBottom) > 0.997,
                   "The 16 pt shadow fades before it reaches the new clip at \(scale)×")
            _ = window
        }
    }

    static func testEscape() {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let crop = NSRect(x: 25, y: 25, width: 240, height: 150)
        let canvas = CanvasView(image: solidImage(width: 320, height: 200), frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        var closeRequests = 0
        canvas.onRequestCancel = { closeRequests += 1 }
        func escape(repeatKey: Bool = false) {
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                                 isARepeat: repeatKey, keyCode: 53)!)
        }

        canvas.mouseDown(with: mouse(.leftMouseDown, 25, 25))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 265, 175))
        assert(canvas.hasSelection(), "There is an in-progress crop to cancel")
        escape()
        canvas.mouseUp(with: mouse(.leftMouseUp, 265, 175))
        assert(canvas.selectionRect == nil && closeRequests == 0, "Escape discards an unfinished crop")

        canvas.selectionRect = crop
        canvas.mouseDown(with: mouse(.leftMouseDown, 265, 175))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 300, 195))
        assert(canvas.selectionRect != crop, "Dragging the crop handle previews a resize")
        escape()
        canvas.mouseUp(with: mouse(.leftMouseUp, 300, 195))
        assert(canvas.selectionRect == crop, "Escape restores the original crop after resizing")
        canvas.mouseDown(with: mouse(.leftMouseDown, 80, 80))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, 160, 120))
        escape()
        canvas.mouseUp(with: mouse(.leftMouseUp, 160, 120))
        assert(!canvas.canUndo && canvas.selectionRect == crop && closeRequests == 0,
               "Escape discards the draft without changing the crop or history")

        func type(_ text: String) {
            let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        canvas.style.tool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, 80, 140))
        type("Черновик")
        escape()
        assert(!canvas.isEditingText && !canvas.canUndo && closeRequests == 0,
               "The first Escape discards uncommitted text without closing the window")
        canvas.mouseDown(with: mouse(.leftMouseDown, 80, 140))
        type("Исходный текст")
        let original = bitmap(canvas).tiffRepresentation!
        canvas.mouseDown(with: mouse(.leftMouseDown, 96, 126, clickCount: 2))
        type("Правка")
        escape()
        assert(!canvas.isEditingText && bitmap(canvas).tiffRepresentation! == original,
               "Escape restores the previous text when editing an annotation")
        escape(repeatKey: true)
        assert(closeRequests == 0, "Holding Escape cannot close the window after canceling an action")
        escape()
        assert(closeRequests == 1, "A separate Escape press closes the idle editor")
        _ = window
    }

    static func testTextSpacing() {
        let size = NSRect(x: 0, y: 0, width: 200, height: 120)
        for scale in [1, 2] {
            let image = solidImage(width: 200 * scale, height: 120 * scale)
            let canvas = CanvasView(image: image, frame: size)
            let window = NSWindow(contentRect: size, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = canvas
            canvas.selectionRect = size
            for (fontSize, expectedPixels) in [(CGFloat(16), 0), (24, 1), (36, 2)] {
                canvas.style = EditorStyle(tool: .text, fontSize: fontSize)
                canvas.mouseDown(with: mouse(.leftMouseDown, 30, 88))
                let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
                let sample = expectedPixels == 0 ? "АУН" : "ННН"
                editor.insertText(sample, replacementRange: NSRange(location: NSNotFound, length: 0))
                if expectedPixels == 0 {
                    assert(editor.typingAttributes[.kern] == nil
                           && editor.textStorage!.attribute(.kern, at: 0, effectiveRange: nil) == nil,
                           "The smallest size uses the font's natural kerning")
                }
                let manager = editor.layoutManager!
                func step() -> CGFloat {
                    manager.ensureLayout(for: editor.textContainer!)
                    return manager.location(forGlyphAt: 1).x - manager.location(forGlyphAt: 0).x
                }
                let adjusted = step()
                editor.textStorage!.removeAttribute(.kern, range: NSRange(location: 0, length: 3))
                let original = step()
                assert(abs((adjusted - original) * CGFloat(scale) - CGFloat(expectedPixels)) < 0.08,
                       "\(Int(fontSize)) pt text adjusts letter spacing by \(expectedPixels) pixel(s) at \(scale)×")
                assert(canvas.cancelCurrentAction(), "Each text sample is editable")
            }
            _ = window
        }
    }

    static func testAnnotationTypography() {
        let cyrillic = Array("АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя".utf16)
        let sample = Array("HЖ".utf16)
        for size in EditorTypography.fontSizes {
            let font = EditorTypography.font(ofSize: size)
            assert(font.fontName == "KadrText-Medium", "All sizes use the bundled Geologica face")
            var glyphs = [CGGlyph](repeating: 0, count: cyrillic.count)
            assert(CTFontGetGlyphsForCharacters(font as CTFont, cyrillic, &glyphs, cyrillic.count)
                   && glyphs.allSatisfy { $0 != 0 }, "The bundled face covers the Russian alphabet")
            var sampleGlyphs = [CGGlyph](repeating: 0, count: sample.count)
            var advances = [CGSize](repeating: .zero, count: sample.count)
            assert(CTFontGetGlyphsForCharacters(font as CTFont, sample, &sampleGlyphs, sample.count))
            CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, sampleGlyphs, &advances, sample.count)
            assert(abs(advances[0].width - size * 1509 / 2000) < 0.05
                   && abs(advances[1].width - size * 2019 / 2000) < 0.05,
                   "The bundled face uses the expected Geologica metrics for both scripts")
        }

        let size = NSRect(x: 0, y: 0, width: 320, height: 180)
        let canvas = CanvasView(image: solidImage(width: 320, height: 180), frame: size)
        let window = NSWindow(contentRect: size, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        canvas.selectionRect = size
        canvas.style = EditorStyle(tool: .pen, color: .systemRed, lineWidth: 8)
        drag(canvas, from: NSPoint(x: 30, y: 65), to: NSPoint(x: 200, y: 65))
        canvas.style.tool = .text
        canvas.mouseDown(with: mouse(.leftMouseDown, 30, 150))
        let editor = canvas.subviews.compactMap { $0 as? NSTextView }.first!
        assert(editor.textColor?.isEqual(NSColor.systemRed) == true, "Text uses the selected shape color")
        editor.insertText("Текст", replacementRange: NSRange(location: NSNotFound, length: 0))
        let image = bitmap(canvas)
        let reference = pixel(image, x: 100, y: 115)
        let matchesShape = (30..<80).contains { y in
            (30..<145).contains { x in
                let ink = pixel(image, x: x, y: y)
                return abs(ink.redComponent - reference.redComponent) < 0.01
                    && abs(ink.greenComponent - reference.greenComponent) < 0.01
                    && abs(ink.blueComponent - reference.blueComponent) < 0.01
            }
        }
        assert(matchesShape, "The rendered glyphs use the selected palette color")
        _ = window
    }

    static func testShapeShadows() {
        for scale in [1, 2] {
            let size = NSRect(x: 0, y: 0, width: 220, height: 140)
            let canvas = CanvasView(image: solidImage(width: 220 * scale, height: 140 * scale), frame: size)
            canvas.selectionRect = size
            for tool in [DrawingTool.rectangle, .ellipse, .arrow, .line] {
                canvas.style = EditorStyle(tool: tool, color: .white, lineWidth: 2)
                let horizontal = tool == .arrow || tool == .line
                let start = NSPoint(x: 42, y: horizontal ? 70 : 38)
                let end = NSPoint(x: 145, y: horizontal ? 70 : 102)
                drag(canvas, from: start, to: end)
                let image = bitmap(canvas)
                let middleRow = 70 * scale
                let bottomRow = (horizontal ? 70 : 102) * scale
                let edgeShadow = ((middleRow + 1)...(middleRow + 4)).contains { y in
                    ((145 * scale + 1)...(145 * scale + 4)).contains { x in
                        pixel(image, x: x, y: y).redComponent < (horizontal ? 0.988 : 0.96)
                    }
                }
                assert(edgeShadow, "\(tool) casts a shadow to the right")
                assert(pixel(image, x: 94 * scale, y: bottomRow + 4).redComponent < 0.96,
                       "\(tool) casts a shadow below its stroke")
                assert(pixel(image, x: 42 * scale - 5, y: middleRow + 2).redComponent > 0.98,
                       "\(tool)'s left side stays clear")
                canvas.undo()
            }
        }
    }

    static func solidImage(width: Int, height: Int, color: NSColor = .white) -> CGImage {
        let source = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        source.setFillColor(color.cgColor)
        source.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return source.makeImage()!
    }

    static func bitmap(_ canvas: CanvasView) -> NSBitmapImageRep {
        canvas.renderedSelection()!.representations[0] as! NSBitmapImageRep
    }

    static func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> NSColor {
        bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }

    static func hasInkNear(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> Bool {
        ((y - 2)...(y + 2)).contains { row in
            ((x - 2)...(x + 2)).contains { column in pixel(bitmap, x: column, y: row).redComponent < 0.35 }
        }
    }

    static func darkPixelCount(_ bitmap: NSBitmapImageRep, rows: Range<Int>? = nil) -> Int {
        var count = 0
        for y in rows ?? 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let color = pixel(bitmap, x: x, y: y)
                if color.redComponent < 0.9 || color.greenComponent < 0.9 || color.blueComponent < 0.9 { count += 1 }
            }
        }
        return count
    }

    static func drag(_ canvas: CanvasView, from start: NSPoint, to end: NSPoint,
                     modifiers: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: mouse(.leftMouseDown, start.x, start.y, modifiers: modifiers))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, end.x, end.y, modifiers: modifiers))
        canvas.mouseUp(with: mouse(.leftMouseUp, end.x, end.y, modifiers: modifiers))
    }

    static func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat,
                      modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: modifiers,
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: clickCount, pressure: 1)!
    }

    static func deleteKey(_ code: UInt16, in window: NSWindow? = nil, repeating: Bool = false) -> NSEvent {
        let characters = code == 51 ? "\u{7F}" : "\u{F728}"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: repeating, keyCode: code)!
    }
}
