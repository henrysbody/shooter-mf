import AppKit
import Carbon

@main
enum KadrMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var editor: CaptureCoordinator!
    private var welcome: WelcomeWindowController?
    private var hotKeyAvailable = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        editor = CaptureCoordinator()
        editor.onError = { [weak self] message in self?.showError(message) }
        setupMenu()
        registerHotKey()
        if CommandLine.arguments.contains("--demo") {
            editor.showDemo()
        } else if !UserDefaults.standard.bool(forKey: "hasOpenedKadr") {
            UserDefaults.standard.set(true, forKey: "hasOpenedKadr")
            showWelcome()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !editor.isEditing { showWelcome() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }

    private func setupMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.font = EditorTypography.menuFont
        appMenu.addItem(withTitle: "О приложении Shooter MF", action: #selector(showWelcome), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить Shooter MF", action: #selector(quit), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editMenu = NSMenu(title: "Правка")
        editMenu.font = EditorTypography.menuFont
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Shooter MF — скриншоты")
        statusItem.button?.toolTip = "Shooter MF · ⌘⇧S"
        let menu = NSMenu()
        menu.font = EditorTypography.menuFont
        let capture = NSMenuItem(title: "Сделать скриншот", action: #selector(startCapture), keyEquivalent: "s")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "Shooter MF · помощь", action: #selector(showWelcome), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let permission = NSMenuItem(title: "Настройки доступа к экрану…", action: #selector(openPermissions), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Завершить Shooter MF", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func registerHotKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.startCapture() }
            return noErr
        }, 1, &event, userData, &hotKeyHandler)
        let id = EventHotKeyID(signature: OSType(0x4B414452), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(cmdKey | shiftKey), id,
                                        GetApplicationEventTarget(), 0, &hotKey)
        hotKeyAvailable = handlerStatus == noErr && result == noErr
    }

    @objc private func startCapture() {
        guard !editor.isSaving else { return }
        welcome?.window?.orderOut(nil)
        if editor.isEditing { editor.cancel() }
        editor.start()
    }

    @objc private func showWelcome() {
        if welcome == nil {
            welcome = WelcomeWindowController(hotKeyAvailable: hotKeyAvailable)
            welcome?.onCapture = { [weak self] in self?.startCapture() }
        }
        welcome?.showWindow(nil)
        welcome?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Не удалось сделать скриншот"
        alert.informativeText = message
        alert.addButton(withTitle: "Понятно")
        alert.addButton(withTitle: "Настройки доступа")
        if alert.runModal() == .alertSecondButtonReturn { openPermissions() }
    }

    @objc private func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
