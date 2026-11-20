import Foundation
import Testing

@testable import DirigibleCore

/// The stem plan of a stem export (criteria C1, C2, C5, and C8): the grouping, the heard rule, the
/// empty stems, and the file names.
struct StemPlanTests {
    /// The byte limit of a stem name that the writer passes: `exportNameLimit` (209) minus `.flac`.
    static let limit = 204

    /// A session with one track for each name, each with one clip at 0..<48000, in order.
    static func session(_ tracks: [(id: TrackID, name: String, role: Track.Role?)]) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 48_000))
        for (index, track) in tracks.enumerated() {
            try session.addTrack(track.id, name: track.name, layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(index)"), file: "f", start: 0, offset: 0, length: 48_000), on: track.id)
            if let role = track.role { try session.setRole(role, tracks: [track.id]) }
        }
        return session
    }

    /// Host and Guest (dialogue), Bed (music), and Sting (no role).
    static func show() throws -> Session {
        try session([
            ("h", "Host", .dialogue), ("g", "Guest", .dialogue), ("b", "Bed", .music), ("s", "Sting", nil),
        ])
    }

    static func plan(
        _ session: Session, by grouping: StemGrouping, tracks: Set<TrackID>? = nil, range: Range<Frames> = 0..<48_000,
        titles: StemTitles = .english, limit: Int = limit
    ) -> StemPlan? {
        session.stemPlan(by: grouping, tracks: tracks, range: range, titles: titles, limit: limit)
    }

    /// C2: one stem for each role of a heard track, in the order dialogue, music, effects, then the
    /// tracks with no role; no stem for a role that no track has.
    @Test func roleStemsGroupTheHeardTracksOfARole() throws {
        let plan = try #require(Self.plan(Self.show(), by: .role))
        #expect(plan.stems.map(\.key) == [.role(.dialogue), .role(.music), .role(nil)])
        #expect(plan.stems.map(\.tracks) == [["h", "g"], ["b"], ["s"]])
        #expect(plan.stems.map(\.name) == ["Dialogue", "Music", "No Role"])
        #expect(plan.empty.isEmpty && !plan.noRoleSet && plan.range == 0..<48_000)
    }

    /// C1: a muted track and a track that is not soloed give no stem; `tracks` limits both groupings.
    @Test func trackStemsAreTheHeardTracks() throws {
        var session = try Self.show()
        try session.setMuted(true, tracks: ["b"])
        #expect(Self.plan(session, by: .track)?.stems.map(\.key) == [.track("h"), .track("g"), .track("s")])
        #expect(Self.plan(session, by: .role)?.stems.map(\.key) == [.role(.dialogue), .role(nil)])
        try session.setMuted(false, tracks: ["b"])
        try session.setSoloed(true, tracks: ["h"])
        #expect(Self.plan(session, by: .track)?.stems.map(\.name) == ["01 Host"])
        #expect(Self.plan(session, by: .role)?.stems.map(\.tracks) == [["h"]])
        try session.setSoloed(false, tracks: ["h"])
        #expect(Self.plan(session, by: .track, tracks: ["g", "b"])?.stems.map(\.name) == ["01 Guest", "02 Bed"])
        #expect(Self.plan(session, by: .role, tracks: ["g", "b"])?.stems.map(\.tracks) == [["g"], ["b"]])
    }

    /// C5: a stem with no clip that sounds in the range gets no file and is named in `empty`. A clip
    /// that ends at the range start is not in the range; a clip that ends one frame after it is.
    @Test func aStemWithNoClipInTheRangeIsEmpty() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 48_000))
        for (id, role) in [("a", Track.Role.dialogue), ("b", .music)] as [(TrackID, Track.Role)] {
            try session.addTrack(id, name: id.rawValue, layout: .mono)
            try session.setRole(role, tracks: [id])
        }
        try session.place(Clip(id: "ca", file: "f", start: 0, offset: 0, length: 1_000), on: "a")
        try session.place(Clip(id: "cb", file: "f", start: 0, offset: 0, length: 1_001), on: "b")
        let track = try #require(Self.plan(session, by: .track, range: 1_000..<2_000))
        #expect(track.stems.map(\.key) == [.track("b")] && track.empty == [.track("a")])
        #expect(track.stems.map(\.name) == ["01 b"])
        let role = try #require(Self.plan(session, by: .role, range: 1_000..<2_000))
        #expect(role.stems.map(\.key) == [.role(.music)] && role.empty == [.role(.dialogue)])
    }

    /// C5: no stem with a clip in the range, or no heard track, gives no plan.
    @Test func aPlanWithNoClipIsNil() throws {
        var session = try Self.show()
        #expect(Self.plan(session, by: .track, range: 48_000..<96_000) == nil)
        #expect(Self.plan(session, by: .role, range: 48_000..<96_000) == nil)
        try session.setMuted(true, tracks: ["h", "g", "b", "s"])
        #expect(Self.plan(session, by: .track) == nil && Self.plan(session, by: .role) == nil)
    }

    /// C2: a role plan where no heard track of the set has a role is one stem with the no-role title,
    /// and the plan says so for the note line.
    @Test func aRolePlanWithNoRoleSetIsMarked() throws {
        let session = try Self.show()
        let none = try #require(Self.plan(session, by: .role, tracks: ["s"]))
        #expect(none.stems.map(\.key) == [.role(nil)] && none.stems.map(\.name) == ["No Role"] && none.noRoleSet)
        #expect(Self.plan(session, by: .role, tracks: ["s", "b"])?.noRoleSet == false)
        #expect(Self.plan(session, by: .track, tracks: ["s"])?.noRoleSet == false)
    }

    /// C8: the names have no `/` or `:`, are unique, and fit the limit, cut at a character boundary.
    @Test func stemNamesAreSafeUniqueAndFitTheNameLimit() throws {
        func names(_ tracks: [String], titles: StemTitles = .english, by grouping: StemGrouping = .track) throws
            -> [String]
        {
            let session = try Self.session(tracks.enumerated().map { (TrackID("t\($0.offset)"), $0.element, nil) })
            return try #require(Self.plan(session, by: grouping, titles: titles)).stems.map(\.name)
        }
        #expect(try names(["a/b:c", " \u{3000} ", "Host", "Host"]) == ["01 a-b-c", "02 t1", "03 Host", "04 Host"])
        #expect(
            try names((1...12).map { "n\($0)" }).map { String($0.prefix(3)) }
                == (1...12).map { String(format: "%02d ", $0) })
        let hundred = try names((1...100).map { "n\($0)" })
        #expect(hundred.first == "001 n1" && hundred.last == "100 n100")
        let ascii = try names([String(repeating: "a", count: 201), String(repeating: "b", count: 202)])
        #expect(ascii.map(\.utf8.count) == [204, 204])
        #expect(
            ascii[0] == "01 " + String(repeating: "a", count: 201)
                && ascii[1] == "02 " + String(repeating: "b", count: 201))
        let wide = try #require(names([String(repeating: "é", count: 102)]).first)
        #expect(wide == "01 " + String(repeating: "é", count: 100) && wide.utf8.count == 203)
        let titles = StemTitles(dialogue: "Voz", music: "voz", effects: "Efectos", none: "Sin/rol")
        var session = try Self.show()
        try session.setRole(.effects, tracks: ["s"])
        let role = try #require(Self.plan(session, by: .role, titles: titles))
        #expect(role.stems.map(\.name) == ["Voz", "voz 2", "Efectos"])
        try session.setRole(nil, tracks: ["s"])
        let decomposed = StemTitles(
            dialogue: "Dia\u{0301}logo", music: "Mu\u{0301}sica", effects: "E", none: ".Sin/rol")
        let local = try #require(Self.plan(session, by: .role, titles: decomposed)).stems.map(\.name)
        #expect(local.map { Array($0.utf8) } == ["Diálogo", "Música", "Sin-rol"].map { Array($0.utf8) })
    }

    /// C8: a stem name follows the 0067 rule of a part title: each character that macOS, exFAT,
    /// FAT32, or SMB refuses becomes a dash, in a track name and in a role title.
    @Test(arguments: ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\u{7F}", "\u{9F}"])
    func eachCharacterThatAVolumeRefusesBecomesADash(character: String) throws {
        let session = try Self.session([("t", "a\(character)b", .music)])
        #expect(Self.plan(session, by: .track)?.stems.map(\.name) == ["01 a-b"])
        let titles = StemTitles(dialogue: "D", music: "M\(character)x", effects: "E", none: "N")
        #expect(Self.plan(session, by: .role, titles: titles)?.stems.map(\.name) == ["M-x"])
    }

    /// C8: a track named `Q&A? "live"` gives a name that an exFAT volume takes.
    @Test func aTrackNameWithAQuestionMarkAndQuotesGetsDashes() throws {
        let session = try Self.session([("t", "Q&A? \"live\"", nil)])
        #expect(Self.plan(session, by: .track)?.stems.map(\.name) == ["01 Q&A- -live-"])
    }
}
