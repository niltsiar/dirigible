import AppKit
import DirigibleAudio
import DirigibleCore

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// The name field of a row: it takes text only while a rename is open.
final class BinNameField: NSTextField {
    convenience init(bold: Bool) {
        self.init(labelWithString: "")
        isEditable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        font = bold ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize) : .systemFont(ofSize: NSFont.systemFontSize)
        translatesAutoresizingMaskIntoConstraints = false
    }
}

/// The row of a bin: its name.
final class BinHeaderCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let name = BinNameField(bold: true)
        addSubview(name)
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The row of an item: the name, the length in the time format of the ruler, and the media fault
/// mark of the timeline clips, with a help tag that names the fault (C24, C32). It reads no peaks.
/// VoiceOver reads it as one element with three actions (C30).
final class BinItemCell: NSTableCellView {
    let length = NSTextField(labelWithString: "")
    let faultMark = NSImageView()
    var actions: () -> [NSAccessibilityCustomAction] = { [] }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let name = BinNameField(bold: false)
        textField = name
        length.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        length.textColor = .secondaryLabelColor
        faultMark.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        faultMark.contentTintColor = .systemRed
        for view in [name, length, faultMark] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        length.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            faultMark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            faultMark.centerYAnchor.constraint(equalTo: centerYAnchor),
            faultMark.widthAnchor.constraint(equalToConstant: 14),
            name.leadingAnchor.constraint(equalTo: faultMark.trailingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            length.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            length.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            length.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ item: BinItem, rate: Int, fault: MediaFault?) {
        textField?.stringValue = item.name
        length.stringValue = rulerLabel(Double(item.length.count) / Double(rate), tenths: false)
        faultMark.isHidden = fault == nil
        faultMark.toolTip =
            switch fault {
            case .missing: L10n.binsMissing.text
            case .short: L10n.binsShort.text
            case .unreadable: L10n.binsUnreadable.text
            case nil: nil
            }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .cell }
    override func accessibilityChildren() -> [Any]? { nil }

    override func accessibilityLabel() -> String? {
        "\(textField?.stringValue ?? ""), \(length.stringValue)"
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { actions() }
}
