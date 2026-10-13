import AppKit
import DirigibleAudio

/// A change of the vari-speed (decision 0048): Period (`toggle`), ">" (`faster`), "<"
/// (`slower`), or a pick of the menu or the toolbar pop-up (`set`).
enum SpeedChange: Hashable {
    case toggle, faster, slower
    case set(Speed)

    /// The speed after the change from `speed`. Period turns on `last`, the preference.
    func target(from speed: Speed, last: Speed) -> Speed {
        switch self {
        case .toggle: speed == .one ? last : .one
        case .faster: speed.faster
        case .slower: speed.slower
        case .set(let target): target
        }
    }
}

/// The readout of a speed in the number format of `locale`: "1×", "1.5×" ("1,5×" in Spanish).
func speedText(_ speed: Speed, locale: Locale = .current) -> String {
    speed.factor.formatted(.number.locale(locale)) + "×"
}

/// The VoiceOver value of a speed: "1.5 times". `format` is the value of `L10n.speedSpoken`.
func speedSpokenText(_ speed: Speed, locale: Locale = .current, format: String = L10n.speedSpoken.text) -> String {
    String(format: format, locale: locale, speed.factor.formatted(.number.locale(locale)))
}

/// The toolbar pop-up of the vari-speed (decision 0048, ui-panel): its title is the readout, 1x in
/// the normal text color and another speed in the accent color. One width for the widest value
/// in English and Spanish, so the toolbar does not move. The tag of each item is the raw value.
final class SpeedPopUp: NSPopUpButton {
    /// The changes of the shown speed, for the tests: the pop-up changes only on a speed change.
    private(set) var changes = 0
    var speed = Speed.one {
        didSet {
            guard speed != oldValue else { return }
            changes += 1
            show()
        }
    }

    private static let width: CGFloat = {
        let widest = NSPopUpButton(frame: .zero, pullsDown: false)
        widest.addItems(withTitles: ["1,75×", "1.75×"])
        return widest.fittingSize.width.rounded(.up)
    }()

    init() {
        super.init(frame: .zero, pullsDown: false)
        // The toolbar bezel has no gray fill, so the accent readout is legible (A3 on-screen check).
        bezelStyle = .toolbar
        for speed in Speed.allCases {
            addItem(withTitle: speedText(speed))
            lastItem?.tag = speed.rawValue
        }
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        setAccessibilityLabel(L10n.menuTransportSpeed.text)
        show()
    }

    required init?(coder: NSCoder) { nil }

    // VoiceOver reads "Playback Speed" and "1.5 times".
    override func accessibilityValue() -> Any? { speedSpokenText(speed) }

    private func show() {
        for item in itemArray { item.attributedTitle = nil }
        selectItem(withTag: speed.rawValue)
        guard speed != .one, let item = selectedItem else { return }
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [.foregroundColor: NSColor.controlAccentColor, .font: font ?? NSFont.menuFont(ofSize: 0)])
    }
}

extension AppDelegate {
    /// A stored speed other than 1 that is a step; else 1.5.
    static func lastSpeed(stored: Any?) -> Speed {
        guard let factor = stored as? Double, let speed = Speed(rawValue: Int((factor * 100).rounded())),
            speed != .one, speed.factor == factor
        else { return .x150 }
        return speed
    }
}
