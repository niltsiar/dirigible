import AppKit

/// The row: the one accessibility element of its cells.
final class IndexRowView: NSTableRowView {
    var spoken = ""
    var actions: [NSAccessibilityCustomAction] = []

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { actions }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func accessibilityLabel() -> String? { spoken }
    override func accessibilityChildren() -> [Any]? { [] }
}

/// A cell with an optional glyph and a truncated text. It is no accessibility element: its row says it.
final class IndexCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private var textLeading: NSLayoutConstraint?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for view in [glyph, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        glyph.contentTintColor = .secondaryLabelColor
        textField = label
        imageView = glyph
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        textLeading = leading
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            leading, label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        for view in [self, glyph, label] { view.setAccessibilityElement(false) }
    }

    required init?(coder: NSCoder) { nil }

    /// The name as a field: a bezel and a background, the label "Name" for VoiceOver.
    func beginEditing(text: String, delegate: NSTextFieldDelegate) -> NSTextField {
        label.delegate = delegate
        label.isEditable = true
        label.isSelectable = true
        label.isBezeled = true
        label.bezelStyle = .squareBezel
        label.drawsBackground = true
        label.stringValue = text
        label.setAccessibilityElement(true)
        label.setAccessibilityLabel(L10n.markerName.text)
        return label
    }

    func endEditing() {
        label.delegate = nil
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.setAccessibilityElement(false)
    }

    /// One image for each symbol: a new image looks up its glyph and draws it again in each cell.
    private static var glyphs: [String: NSImage] = [:]

    private static func glyph(_ symbol: String) -> NSImage? {
        if let image = glyphs[symbol] { return image }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyphs[symbol] = image
        return image
    }

    func show(text: String, symbol: String?) {
        endEditing()
        label.stringValue = text
        glyph.image = symbol.flatMap(Self.glyph)
        glyph.isHidden = symbol == nil
        textLeading?.constant = symbol == nil ? 4 : 24
    }
}
