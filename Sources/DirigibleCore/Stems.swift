import Foundation

/// How a stem export groups the heard tracks of its set into files.
public enum StemGrouping: String, CaseIterable, Sendable {
    /// One stem for each heard track.
    case track
    /// One stem for each role of a heard track, then one for the heard tracks with no role.
    case role
}

/// One file of a stem export: the mix of its tracks over the range of its plan.
public struct Stem: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case track(TrackID)
        /// Nil: the heard tracks with no role.
        case role(Track.Role?)
    }

    public let key: Key
    /// Heard tracks only, never empty.
    public let tracks: Set<TrackID>
    /// The file name with no extension: no `/` or `:`, unique in the plan, and in the byte limit of
    /// the plan.
    public let name: String
}

/// The stems of one export. Each stem file starts at the range start and has the range length.
public struct StemPlan: Hashable, Sendable {
    public let range: Range<Frames>
    /// In session order, or in role order. At least one.
    public let stems: [Stem]
    /// The stems of heard tracks with no clip that sounds in the range. They get no file.
    public let empty: [Stem.Key]
    /// A role plan where no heard track of the set has a role.
    public let noRoleSet: Bool
}

/// The file names of the role stems. The app gives the titles of its language; the CLI and the
/// tools give `.english`.
public struct StemTitles: Hashable, Sendable {
    public var dialogue: String
    public var music: String
    public var effects: String
    public var none: String

    public init(dialogue: String, music: String, effects: String, none: String) {
        (self.dialogue, self.music, self.effects, self.none) = (dialogue, music, effects, none)
    }

    public static let english = StemTitles(dialogue: "Dialogue", music: "Music", effects: "Effects", none: "No Role")

    func title(_ role: Track.Role?) -> String {
        switch role {
        case .dialogue: dialogue
        case .music: music
        case .effects: effects
        case nil: none
        }
    }
}

extension Session {
    /// The stems of the tracks of `ids` (nil: all tracks) that the mix hears (`heardTracks(in:)`,
    /// decision 0039), over `range`. A track stem is named `01 Host`: its place among the stems with
    /// a file, with at least two digits, and the track name (the track ID when the name is only
    /// white space). A role stem is named by `titles`. Each name is in NFC, cut at a character
    /// boundary to `limit` UTF-8 bytes, and unique with a case-insensitive compare (a later equal
    /// name gets " 2", then " 3"). Nil when no stem has a clip that sounds in the range.
    public func stemPlan(
        by grouping: StemGrouping, tracks ids: Set<TrackID>?, range: Range<Frames>, titles: StemTitles, limit: Int
    ) -> StemPlan? {
        let heard = heardTracks(in: ids)
        let groups: [(key: Stem.Key, tracks: [Track])] =
            switch grouping {
            case .track: heard.map { (key: .track($0.id), tracks: [$0]) }
            case .role:
                (Track.Role.allCases.map(Optional.some) + [nil]).compactMap {
                    role -> (key: Stem.Key, tracks: [Track])? in
                    let tracks = heard.filter { $0.role == role }
                    return tracks.isEmpty ? nil : (key: .role(role), tracks: tracks)
                }
            }
        let sounding = groups.filter { $0.tracks.contains { !$0.clips.clips(soundingIn: range).isEmpty } }
        guard !sounding.isEmpty else { return nil }
        let digits = max(2, String(sounding.count).count)
        var names: [String] = []
        for (place, group) in sounding.enumerated() {
            let text: String
            switch group.key {
            case .track:
                let track = group.tracks[0]
                let number = String(repeating: "0", count: digits - String(place + 1).count) + String(place + 1)
                let name = Self.fileText(track.name)
                text = "\(number) \(name.isEmpty ? Self.fileText(track.id.rawValue) : name)"
            case .role(let role):
                let title = String(Self.fileText(titles.title(role)).drop { $0 == "." })
                text = title.isEmpty ? (role?.rawValue ?? "none") : title
            }
            names.append(Self.unique(text, in: names, limit: limit))
        }
        let stems = zip(sounding, names).map { Stem(key: $0.key, tracks: Set($0.tracks.map(\.id)), name: $1) }
        return StemPlan(
            range: range, stems: stems,
            empty: groups.filter { group in !sounding.contains { $0.key == group.key } }.map(\.key),
            noRoleSet: grouping == .role && heard.allSatisfy { $0.role == nil })
    }

    /// `text` in NFC with each `/`, `:`, and control character as `-`, and no white space at the
    /// ends.
    private static func fileText(_ text: String) -> String {
        let scalars = text.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            $0 == "/" || $0 == ":" || $0.properties.generalCategory == .control ? "-" : $0
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// `text` cut to `limit` UTF-8 bytes at a character boundary, with " 2", " 3", and on when an
    /// earlier name of `names` is equal with a case-insensitive compare.
    private static func unique(_ text: String, in names: [String], limit: Int) -> String {
        let taken = Set(names.map { $0.folding(options: .caseInsensitive, locale: nil) })
        var count = 1
        while true {
            let suffix = count == 1 ? "" : " \(count)"
            var name = text
            while name.utf8.count + suffix.utf8.count > limit, !name.isEmpty { name.removeLast() }
            while name.last?.isWhitespace == true { name.removeLast() }
            name += suffix
            if !taken.contains(name.folding(options: .caseInsensitive, locale: nil)) { return name }
            count += 1
        }
    }
}
