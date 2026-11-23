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

/// The row of a bin, of a store group, or of the Favorites header: its name.
final class BinHeaderCell: NSTableCellView {
    init(_ title: String, indent: CGFloat = 4) {
        super.init(frame: .zero)
        let name = BinNameField(bold: true)
        name.stringValue = title
        addSubview(name)
        textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The note row of the Favorites section: "No Favorites" with the hint (C31), or the text of the
/// store fault under the same title (C38). It is one static text for VoiceOver.
final class FavoritesNoteCell: NSTableCellView {
    let detail = NSTextField(wrappingLabelWithString: "")

    /// The title and two lines of the hint, or four lines of a fault text. A longer text ends with an
    /// ellipsis, and its help tag and VoiceOver read the whole text.
    static func height(_ fault: StudioError?) -> CGFloat { fault == nil ? 52 : 68 }

    init(_ fault: StudioError?) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: fault == nil ? L10n.favoritesEmpty.text : "")
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.isHidden = fault != nil
        detail.stringValue = fault.map { L10n.message(for: $0) } ?? L10n.favoritesEmptyHint.text
        detail.toolTip = detail.stringValue
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = fault == nil ? 2 : 4
        detail.cell?.truncatesLastVisibleLine = true
        textField = title
        let stack = NSStackView(views: fault == nil ? [title, detail] : [detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        title.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The wrap needs a width: the stack gives each view its own width.
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityChildren() -> [Any]? { nil }

    override func accessibilityLabel() -> String? {
        [textField?.stringValue ?? "", detail.stringValue].filter { !$0.isEmpty }.joined(separator: ", ")
    }
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
