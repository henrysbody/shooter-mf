import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

final class CaptureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class CaptureCoordinator {
    var onError: ((String) -> Void)?
    var isEditing: Bool { !windows.isEmpty }
    var isSaving: Bool { savePanelOpen }
    private var windows: [CaptureWindow] = []
    private var activeCanvas: CanvasView?
    private var toolbar: EditorToolbar?
    private var copyToast: CopyToast?
    private var undoToast: UndoToast?
    private var eventMonitor: Any?
    private var captureInProgress = false
    private var generation = 0
    private var previousApp: NSRunningApplication?
    private var style = EditorPreferences.load()
    private var savePanelOpen = false
    private let pasteboard: NSPasteboard
    private let chooseSaveURL: () -> URL?

    init(pasteboard: NSPasteboard = .general, chooseSaveURL: (() -> URL?)? = nil) {
        self.pasteboard = pasteboard
        self.chooseSaveURL = chooseSaveURL ?? Self.promptForSaveURL
    }

    func start() {
        guard !captureInProgress else { return }
        copyToast?.close()
        copyToast = nil
        captureInProgress = true
        previousApp = NSWorkspace.shared.frontmostApplication
        generation += 1
        let request = generation
        Task { @MainActor in
            defer { captureInProgress = false }
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                onError?("Разрешите приложению Shooter MF запись экрана в Системных настройках → Конфиденциальность и безопасность → Запись экрана. Затем снова нажмите ⌘⇧S. Если macOS предложит перезапустить приложение, согласитесь.")
                return
            }
            do {
                // Give the menu and welcome window time to leave the compositor.
                try await Task.sleep(nanoseconds: 160_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                var captures: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
                    let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = Int(screen.frame.width * screen.backingScaleFactor)
                    config.height = Int(screen.frame.height * screen.backingScaleFactor)
                    config.showsCursor = false
                    config.colorSpaceName = CGColorSpace.sRGB
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    captures.append((screen, image))
                }
                guard request == generation else { return }
                guard !captures.isEmpty else { throw CaptureError.noDisplays }
                present(captures)
            } catch {
                guard request == generation else { return }
                onError?("\(error.localizedDescription)\n\nПроверьте доступ к записи экрана для Shooter MF и попробуйте ещё раз.")
            }
        }
    }

    func showDemo() {
        guard let screen = NSScreen.main else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        present([(screen, DemoImage.make(size: screen.frame.size, scale: screen.backingScaleFactor))])
    }

    private func present(_ captures: [(NSScreen, CGImage)]) {
        style = EditorPreferences.load()
        for (screen, image) in captures {
            let window = CaptureWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            let canvas = CanvasView(image: image, frame: NSRect(origin: .zero, size: screen.frame.size))
            canvas.autoresizingMask = [.width, .height]
            canvas.style = style
            canvas.onSelectionChange = { [weak self, weak canvas, weak window] rect in
                guard let self, let canvas, let window else { return }
                if rect != nil && self.activeCanvas !== canvas {
                    self.dismissUndoToast(reposition: false)
                    self.activeCanvas = canvas
                    for other in self.windows where other !== window {
                        (other.contentView as? CanvasView)?.selectionRect = nil
                    }
                    window.makeKeyAndOrderFront(nil)
                }
                guard self.activeCanvas === canvas else { return }
                self.placeEditorControls(for: canvas)
                self.toolbar?.setHistory(canUndo: canvas.canUndo, canRedo: canvas.canRedo)
            }
            canvas.onHistoryChange = { [weak self, weak canvas] undo, redo in
                guard let self, self.activeCanvas === canvas else { return }
                self.dismissUndoToast()
                self.toolbar?.setHistory(canUndo: undo, canRedo: redo)
            }
            canvas.onDeleteAnnotations = { [weak self, weak canvas] count in
                guard let self, let canvas, self.activeCanvas === canvas else { return }
                self.showUndoToast(for: canvas, deleted: count)
            }
            canvas.onBeginInteraction = { [weak self] in self?.dismissUndoToast() }
            canvas.onRequestCopy = { [weak self] in self?.copy() }
            canvas.onRequestCancel = { [weak self] in self?.cancel() }
            window.contentView = canvas
            window.orderFrontRegardless()
            windows.append(window)
        }
        activeCanvas = windows.first?.contentView as? CanvasView
        toolbar = EditorToolbar(style: style)
        toolbar?.onStyleChange = { [weak self] style in
            guard let self else { return }
            self.activeCanvas?.commitTextEditing()
            self.style = style
            EditorPreferences.save(style)
            for window in self.windows { (window.contentView as? CanvasView)?.style = style }
        }
        toolbar?.onCopy = { [weak self] in self?.copy() }
        toolbar?.onCancel = { [weak self] in self?.cancel() }
        toolbar?.onUndo = { [weak self] in self?.activeCanvas?.undo() }
        toolbar?.onRedo = { [weak self] in self?.activeCanvas?.redo() }
        let mouse = NSEvent.mouseLocation
        let screen = captures.first(where: { NSMouseInRect(mouse, $0.0.frame, false) })?.0 ?? captures[0].0
        if let index = captures.firstIndex(where: { $0.0 === screen }) {
            activeCanvas = windows[index].contentView as? CanvasView
            windows[index].makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        activeCanvas?.window?.makeFirstResponder(activeCanvas)
        if EditorPreferences.fullScreenSelection, let canvas = activeCanvas { canvas.selectionRect = canvas.bounds }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isEditing, !self.savePanelOpen else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func placeEditorControls(for canvas: CanvasView) {
        guard let toolbar else { return }
        guard let window = canvas.window, let screen = window.screen, let rect = canvas.selectionRect,
              canvas.hasSelection() else {
            dismissUndoToast(reposition: false)
            if toolbar.isVisible { toolbar.orderOut(nil) }
            return
        }
        let selection = window.convertToScreen(canvas.convert(rect, to: nil))
        let extra = undoToast == nil ? 0 : UndoToast.height + UndoToast.gap
        toolbar.place(on: screen, selection: selection, reserveBelow: extra)
        undoToast?.place(below: toolbar.frame, on: screen)
    }

    private func showUndoToast(for canvas: CanvasView, deleted: Int) {
        let toast = UndoToast(deleted: deleted)
        toast.onUndo = { [weak self, weak canvas] in
            guard let self, let canvas, self.activeCanvas === canvas,
                  !canvas.isEditingText, !canvas.isDragging else { return }
            canvas.undo()
        }
        toast.onExpire = { [weak self] in self?.dismissUndoToast() }
        undoToast = toast
        placeEditorControls(for: canvas)
        undoToast?.show()
    }

    private func dismissUndoToast(reposition: Bool = true) {
        guard let toast = undoToast else { return }
        undoToast = nil
        toast.close()
        if reposition, let activeCanvas { placeEditorControls(for: activeCanvas) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 && event.isARepeat { return true }
        if toolbar?.handleChoiceKey(event) == true { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            if event.keyCode == 8 { copy(); return true }
            if event.keyCode == 6 {
                if activeCanvas?.window?.firstResponder is NSTextView { return false }
                if modifiers.contains(.shift) { activeCanvas?.redo() } else { activeCanvas?.undo() }
                return true
            }
            if event.keyCode == 1 && modifiers.contains(.shift) { return true }
            if event.keyCode == 1 { saveAs(); return true }
            return false
        }
        if event.keyCode == 53 {
            if activeCanvas?.cancelCurrentAction() != true { cancel() }
            return true
        }
        if activeCanvas?.isEditingText == true || activeCanvas?.window?.firstResponder is NSTextView { return false }
        if toolbar?.hasOpenChoices == true && (event.keyCode == 51 || event.keyCode == 117) { return true }
        if modifiers.intersection([.option, .control]).isEmpty, activeCanvas?.isDragging != true, let toolbar {
            if event.characters == "+" { return toolbar.stepSize(by: 1) }
            if event.characters == "-" || event.characters == "−" { return toolbar.stepSize(by: -1) }
            let shift = modifiers.contains(.shift)
            switch event.keyCode {
            case 48: return toolbar.stepSize(by: shift ? -1 : 1, wraps: true)
            case 24, 69: return toolbar.stepSize(by: 1)
            case 27, 78:
                if !shift { return toolbar.stepSize(by: -1) }
            default: break
            }
        }
        guard modifiers.intersection([.shift, .option, .control]).isEmpty else { return false }
        if event.keyCode == 3, let canvas = activeCanvas {
            if !event.isARepeat && !canvas.isDragging {
                toolbar?.dismissChoices()
                EditorPreferences.fullScreenSelection = canvas.toggleFullScreen()
            }
            return true
        }
        let colors: [UInt16] = [18, 19, 20, 21, 23, 22, 26]
        let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89]
        if let index = colors.firstIndex(of: event.keyCode) ?? keypad.firstIndex(of: event.keyCode) {
            toolbar?.selectColor(at: index)
            return true
        }
        return toolbar?.selectTool(forKeyCode: event.keyCode) == true
    }

    func copy() {
        if let screenshot = exportSelection(), copyAndFinish(screenshot) { return }
        NSSound.beep()
    }

    private typealias ExportedScreenshot = (png: Data, tiff: Data)

    private func exportSelection() -> ExportedScreenshot? {
        guard let image = activeCanvas?.renderedSelection(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (png, tiff)
    }

    private func copyAndFinish(_ screenshot: ExportedScreenshot) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(screenshot.png, forType: .png),
              item.setData(screenshot.tiff, forType: .tiff) else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        let screen = activeCanvas?.window?.screen ?? NSScreen.main
        finish()
        copyToast?.close()
        copyToast = CopyToast()
        if let screen { copyToast?.show(on: screen) }
        return true
    }

    private func saveAs() {
        guard !savePanelOpen, let screenshot = exportSelection() else { NSSound.beep(); return }
        dismissUndoToast()
        savePanelOpen = true
        defer { savePanelOpen = false }
        let activeWindow = activeCanvas?.window
        for window in windows { window.orderOut(nil) }
        toolbar?.orderOut(nil)

        if let url = chooseSaveURL() {
            do {
                try screenshot.png.write(to: url, options: .atomic)
                if !copyAndFinish(screenshot) {
                    finish()
                    NSSound.beep()
                }
                return
            } catch {
                let alert = NSAlert()
                alert.messageText = "Не удалось сохранить скриншот"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Понятно")
                alert.runModal()
            }
        }
        for window in windows { window.orderFrontRegardless() }
        activeWindow?.makeKeyAndOrderFront(nil)
        if activeCanvas?.hasSelection() == true { toolbar?.orderFrontRegardless() }
        activeWindow?.makeFirstResponder(activeCanvas)
    }

    private static func promptForSaveURL() -> URL? {
        let panel = NSSavePanel()
        panel.title = "Сохранить скриншот"
        panel.prompt = "Сохранить"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        panel.nameFieldStringValue = "Shooter MF \(date.string(from: Date())).png"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func cancel() {
        generation += 1
        finish()
    }

    private func finish() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        dismissUndoToast(reposition: false)
        toolbar?.close()
        toolbar = nil
        for window in windows { window.close() }
        windows.removeAll()
        activeCanvas = nil
        NSCursor.arrow.set()
        previousApp?.activate(options: [])
        previousApp = nil
    }
}

private enum CaptureError: LocalizedError {
    case noDisplays
    var errorDescription: String? { "Не найден доступный экран." }
}
