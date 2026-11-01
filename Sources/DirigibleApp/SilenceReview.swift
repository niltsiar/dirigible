import AppKit
import DirigibleAudio
import DirigibleCore
import Observation
import SwiftUI

/// What a row of the silence list does at Apply (decision 0066).
enum SilenceAction: CaseIterable, Hashable {
    case shorten, mute, mark, skip

    var title: L10n {
        switch self {
        case .shorten: .silencesShorten
        case .mute: .silencesMute
        case .mark: .silencesMark
        case .skip: .silencesSkip
        }
    }
}

/// The settings of a scan (decision 0066, U20): the tracks left out, the threshold in dBFS, the
/// minimum length in ms, and the keep in ms. The app keeps them in `UserDefaults` for the next scan.
struct SilenceSettings: Equatable {
    static let thresholds = -90.0...(-10.0)
    static let minimums = 500...30_000
    static let thresholdKey = "silences.threshold"
    static let minimumKey = "silences.minimum"
    static let keepKey = "silences.keep"
    static let uncheckedKey = "silences.unchecked"

    var unchecked: Set<TrackID> = []
    var threshold = -40.0
    var minimum = 1_000
    /// -1 for a text that is not a number.
    var keep = 500

    init() {}

    init(defaults: UserDefaults?) {
        guard let defaults else { return }
        unchecked = Set((defaults.stringArray(forKey: Self.uncheckedKey) ?? []).map { TrackID($0) })
        if let value = defaults.object(forKey: Self.thresholdKey) as? Double, Self.thresholds.contains(value) {
            threshold = value
        }
        if let value = defaults.object(forKey: Self.minimumKey) as? Int, Self.minimums.contains(value) {
            minimum = value
        }
        if let value = defaults.object(forKey: Self.keepKey) as? Int, value >= 0 { keep = value }
    }

    func save(to defaults: UserDefaults?) {
        defaults?.set(unchecked.map(\.rawValue).sorted(), forKey: Self.uncheckedKey)
        defaults?.set(threshold, forKey: Self.thresholdKey)
        defaults?.set(minimum, forKey: Self.minimumKey)
        if keep >= 0 { defaults?.set(keep, forKey: Self.keepKey) }
    }

    /// True when the keep is not under the minimum: Apply is off, and so is Scan.
    var keepRefused: Bool { !(0..<minimum).contains(keep) }

    /// The tracks that the scan reads: nil for every track, else the checked tracks of `session`
    /// (an ID that the session does not have is ignored).
    func scanned(in session: Session) -> Set<TrackID>? {
        let left = unchecked.intersection(session.tracks.map(\.id))
        return left.isEmpty ? nil : Set(session.tracks.map(\.id)).subtracting(left)
    }
}

/// One lane band of the list: a silence and, for a Shorten row, the cut that Apply removes.
struct SilenceBand: Equatable {
    let silence: Range<Frames>
    let cut: Range<Frames>?
}

/// The rows of one scan with their actions (decision 0066). The settings of the scan stay in it: the
/// start actions, the summary line, and Apply use the keep of the scan, not the keep of the tab.
struct SilenceReview {
    struct Row: Identifiable, Equatable {
        let id: Int
        let silence: Range<Frames>
        /// Why the row starts as Mark, or nil.
        let reason: SilenceWarning?
        var action: SilenceAction
    }

    struct Summary: Equatable {
        var counts: [SilenceAction: Int]
        var removed: Frames
        var length: Frames
    }

    let scan: SilenceScan
    let settings: SilenceSettings
    let rate: Int
    /// The session end at the scan.
    let length: Frames
    let keep: Frames
    var rows: [Row]

    /// A row starts as Shorten, or as Mark when its cut holds a word or a track outside the scan has
    /// sound in it (`Session.silenceEditWarnings`).
    init(scan: SilenceScan, settings: SilenceSettings, session: Session) {
        (self.scan, self.settings, rate, length) = (scan, settings, session.sampleRate, session.end)
        keep = Frames(settings.keep * session.sampleRate / 1_000)
        let keep = keep
        let cuts = scan.silences.map { SilencePlan.cut(of: $0, keep: keep) ?? $0.lowerBound..<$0.lowerBound }
        let warnings = session.silenceEditWarnings(cuts: cuts, outside: scan.outside, threshold: scan.threshold)
        rows = scan.silences.indices.map { index in
            let reason: SilenceWarning? = warnings[index].contains(.word) ? .word : warnings[index].first
            return Row(
                id: index, silence: scan.silences[index], reason: reason, action: reason == nil ? .shorten : .mark)
        }
    }

    func cut(of row: Row) -> Range<Frames>? { SilencePlan.cut(of: row.silence, keep: keep) }

    var summary: Summary {
        var counts = Dictionary(uniqueKeysWithValues: SilenceAction.allCases.map { ($0, 0) })
        var removed = Frames.zero
        for row in rows {
            counts[row.action, default: 0] += 1
            if row.action == .shorten, let cut = cut(of: row) { removed = removed + (cut.upperBound - cut.lowerBound) }
        }
        return Summary(counts: counts, removed: removed, length: length - removed)
    }

    /// The plan of the rows that are not Skip. Nil when no row is left.
    var plan: SilencePlan? {
        var marks = 0
        let edits = rows.compactMap { row -> SilenceEdit? in
            switch row.action {
            case .skip: return nil
            case .shorten: return SilenceEdit(range: row.silence, action: .shorten)
            case .mute: return SilenceEdit(range: row.silence, action: .mute)
            case .mark:
                marks += 1
                return SilenceEdit(range: row.silence, action: .mark(name: L10n.silencesMarkName.format(marks)))
            }
        }
        return edits.isEmpty ? nil : try? SilencePlan(edits, keep: keep)
    }

    var bands: [SilenceBand] {
        rows.map { SilenceBand(silence: $0.silence, cut: $0.action == .shorten ? cut(of: $0) : nil) }
    }

    /// The text of the empty list: the first sentence, and the quietest level when the scan has one.
    /// `table` gives the format of a key: the tests read the tables, which `Bundle.main` lacks.
    func emptyText(locale: Locale = .current, table: (L10n) -> String = { $0.text }) -> String {
        let minimum = Self.plain(Double(settings.minimum) / 1_000, locale: locale)
        let threshold = Self.plain(scan.threshold.dB, locale: locale)
        let first = String(format: table(.silencesEmpty), locale: locale, minimum, threshold)
        guard let level = scan.quietest else { return first }
        let quietest = Self.number(Self.roundedUp(10 * log10(Double(level.meanSquare))), locale: locale)
        return first + " " + String(format: table(.silencesEmptyQuietest), locale: locale, quietest)
    }

    /// A level at one decimal, rounded toward 0 dBFS, so a threshold set to it gives a row.
    static func roundedUp(_ dB: Double) -> Double { (dB * 10).rounded(.up) / 10 }

    /// A setting with a decimal only when it has one: "1", "-40", "-37.5".
    static func plain(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    static func number(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    static func seconds(_ frames: Frames, rate: Int, locale: Locale = .current) -> String {
        number(Double(frames.count) / Double(rate), locale: locale)
    }

    /// "3:42", or "1:03:42" from one hour.
    static func clock(_ frame: Frames, rate: Int) -> String {
        let total = frame.count / rate
        let (hours, minutes, seconds) = (total / 3_600, total / 60 % 60, total % 60)
        let tail = String(format: "%02d", seconds)
        return hours > 0 ? "\(hours):" + String(format: "%02d", minutes) + ":" + tail : "\(minutes):" + tail
    }

    /// What VoiceOver reads for a row: "Silence at 3:42, 2.4 seconds, Shorten", and the reason.
    func label(of row: Row, locale: Locale = .current, table: (L10n) -> String = { $0.text }) -> String {
        let length = row.silence.upperBound - row.silence.lowerBound
        let text = String(
            format: table(.silencesRowLabel), locale: locale, Self.clock(row.silence.lowerBound, rate: rate),
            Self.seconds(length, rate: rate, locale: locale), table(row.action.title))
        return row.reason.map { text + ", " + Self.reasonText($0, table: table) } ?? text
    }

    static func reasonText(_ reason: SilenceWarning, table: (L10n) -> String = { $0.text }) -> String {
        table(reason == .word ? .silencesReasonWord : .silencesReasonSound)
    }

    /// The playhead after Apply: a frame after a cut moves left by the cut, and a frame in a cut
    /// goes to its start (Rule M, decision 0037).
    static func moved(_ frame: Frames, by cuts: [Range<Frames>]) -> Frames {
        var shift = Frames.zero
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if frame >= cut.upperBound {
                shift = shift + (cut.upperBound - cut.lowerBound)
            } else if frame > cut.lowerBound {
                return cut.lowerBound - shift
            }
        }
        return frame - shift
    }
}

/// What the tab says after Apply: the counts, the time removed, and the session length before and
/// after. It stays until the next scan or a settings change.
struct SilenceNote: Equatable {
    let shortened: Int
    let muted: Int
    let marked: Int
    let removed: Frames
    let before: Frames
    let after: Frames
    let rate: Int

    func text(locale: Locale = .current, table: (L10n) -> String = { $0.text }) -> String {
        let seconds = { SilenceReview.seconds($0, rate: rate, locale: locale) }
        return String(
            format: table(shortened == 1 ? .silencesNoteOne : .silencesNoteOther), locale: locale, shortened,
            seconds(removed), seconds(before), seconds(after), muted, marked)
    }
}

/// The Silences tab of a window (decision 0066): the settings, the list of the last scan, its
/// selection, and the note of the last Apply.
@Observable @MainActor final class SilenceState {
    var settings: SilenceSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            note = nil
        }
    }
    var keepText: String
    var review: SilenceReview?
    var selection: Set<Int> = []
    /// The range that the last row click set, so the next scan can tell it from a range that the
    /// user sets.
    @ObservationIgnored var rowRange: Range<Frames>?
    var note: SilenceNote?
    @ObservationIgnored private let defaults: UserDefaults?
    /// True while the keep field has the focus, from the pane.
    @ObservationIgnored var keepFocused = false

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let settings = SilenceSettings(defaults: defaults)
        (self.settings, keepText) = (settings, String(settings.keep))
    }

    /// The text of the keep field. A text that is not a whole number is a refused keep.
    func setKeep(_ text: String) {
        keepText = text
        settings.keep = Int(text.trimmingCharacters(in: .whitespaces)) ?? -1
    }

    /// The settings of the tab are not the settings of the list: Apply is off until Scan Again.
    var isStale: Bool { review.map { $0.settings != settings } ?? false }

    var bands: [SilenceBand] { review?.bands ?? [] }

    /// The action of the selected rows when they share one, else nil.
    var selectedAction: SilenceAction? {
        let actions = Set(review?.rows.filter { selection.contains($0.id) }.map(\.action) ?? [])
        return actions.count == 1 ? actions.first : nil
    }
}
