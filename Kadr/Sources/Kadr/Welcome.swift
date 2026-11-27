import AppKit

final class WelcomeWindowController: NSWindowController {
    var onCapture: (() -> Void)?

    init(hotKeyAvailable: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 635),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Shooter MF"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 0.095, green: 0.1, blue: 0.13, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        super.init(window: window)
        guard let content = window.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.widthAnchor.constraint(equalToConstant: 448)
        ])
        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.applicationIconName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 76), icon.heightAnchor.constraint(equalToConstant: 76)])
        stack.addArrangedSubview(icon)
        let heading = NSTextField(labelWithString: "Shooter MF")
        heading.font = .systemFont(ofSize: 25, weight: .bold)
        heading.textColor = .white
        stack.addArrangedSubview(heading)
        let subtitle = NSTextField(wrappingLabelWithString: "Скриншоты без лишних движений.")
        subtitle.font = .systemFont(ofSize: 16)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(24, after: subtitle)

        let instructions = NSStackView()
        instructions.orientation = .vertical
        instructions.alignment = .leading
        instructions.spacing = 8
        instructions.addArrangedSubview(instruction(key: "⌘⇧S", text: "Сделать скриншот"))
        instructions.addArrangedSubview(instruction(key: "⌘C / ⌘S", text: "Копировать / сохранить"))
        instructions.addArrangedSubview(instruction(key: "F", text: "Полный экран / предыдущая область"))
        instructions.addArrangedSubview(instruction(key: "T / S / R", text: "Текст / прямоугольник / овал"))
        instructions.addArrangedSubview(instruction(key: "E / A", text: "Линия / стрелка"))
        instructions.addArrangedSubview(instruction(key: "D / Q", text: "Карандаш / маркер"))
        instructions.addArrangedSubview(instruction(key: "1–7", text: "Цвет по порядку палитры"))
        instructions.addArrangedSubview(instruction(key: "+ / − / Tab", text: "Толщина кисти / размер текста"))
        instructions.addArrangedSubview(instruction(key: "Enter / ⇧Enter", text: "Завершить ввод / новая строка"))
        instructions.addArrangedSubview(instruction(key: "⇧", text: "Квадрат, круг или угол с шагом 45°"))
        stack.addArrangedSubview(instructions)
        stack.setCustomSpacing(24, after: instructions)

        let button = NSButton(title: "Сделать скриншот", target: self, action: #selector(capture))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 16, weight: .semibold)
        button.contentTintColor = .white
        button.bezelColor = NSColor(srgbRed: 0.43, green: 0.4, blue: 0.95, alpha: 1)
        button.keyEquivalent = "\r"
        stack.addArrangedSubview(button)

        let footerText = hotKeyAvailable
            ? "Shooter MF доступен в строке меню. При первом снимке\nmacOS попросит доступ к записи экрана."
            : "⌘⇧S занято другим приложением. Сделайте снимок\nкнопкой здесь или через значок в строке меню."
        let footer = NSTextField(wrappingLabelWithString: footerText)
        footer.font = .systemFont(ofSize: 13)
        footer.textColor = hotKeyAvailable ? .tertiaryLabelColor : .systemOrange
        footer.alignment = .center
        stack.addArrangedSubview(footer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func capture() { onCapture?() }

    private func instruction(key: String, text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY
        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        keyLabel.textColor = NSColor(srgbRed: 0.72, green: 0.7, blue: 1, alpha: 1)
        keyLabel.alignment = .center
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.widthAnchor.constraint(equalToConstant: 124).isActive = true
        row.addArrangedSubview(keyLabel)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .labelColor
        row.addArrangedSubview(label)
        return row
    }
}
