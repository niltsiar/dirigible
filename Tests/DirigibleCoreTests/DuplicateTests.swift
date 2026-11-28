import Foundation
import Testing

@testable import DirigibleCore

/// Duplicate (run replace-roomtone-split C10b, C14; decision 0053) on `editFixture`: clip "A" on
/// "a" at 0..<48 000 from file frame 10 000, and clip "L" on "a" at 96 000..<144 000. The clip set
/// cases use `ExcerptPasteTests.setFixture`.
struct DuplicateTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 10_000, length: 48_000), on: "a")
        try session.place(Clip(id: "L", file: "f", start: 96_000, offset: 300_000, length: 48_000), on: "a")
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    /// C14: the copy of 0..<48 000 starts at the range end, on the same track. It touches "L" and
    /// moves nothing: not "L", not a clip on another track, not a marker.
    @Test mutating func rangeCopyAtEnd() throws {
        try session.place(Clip(id: "N", file: "f", start: 60_000, offset: 0, length: 20_000), on: "b")
        try session.setMarker(Marker(id: "m", name: "M", position: 100_000, kind: .marker))
        let others = lane("b")
        let markers = session.markers

        let pasted = try session.duplicate(0..<48_000, on: ["a"])

        #expect(pasted == ["A@48000"])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 0, offset: 10_000, length: 48_000),
                Clip(id: "A@48000", file: "f", start: 48_000, offset: 10_000, length: 48_000),
                Clip(id: "L", file: "f", start: 96_000, offset: 300_000, length: 48_000),
            ])
        #expect(lane("b") == others && session.markers == markers)
    }

    /// C14: the copy of a set of clips starts at the end of the last clip of the set, and each copy
    /// keeps its track and its distance from the first clip. Clip "B", which is not in the set,
    /// stays; the empty track between the two tracks gets no clip.
    @Test func clipSetAfterLastEnd() throws {
        var session = try ExcerptPasteTests.setFixture()

        let pasted = try session.duplicate(["A", "C"])

        #expect(pasted == ["A@192000", "C@288000"])
        #expect(session.track("t1")?.clips.map(\.id) == ["A", "B", "A@192000"])
        #expect(session.track("t3")?.clips.map(\.id) == ["C", "C@288000"])
        let first = Clip(id: "A@192000", file: "f", start: 192_000, offset: 48_000, length: 48_000)
        let second = Clip(id: "C@288000", file: "f", start: 288_000, offset: 144_000, length: 48_000)
        #expect(session.clip("A@192000")?.clip == first && session.clip("C@288000")?.clip == second)
        #expect(session.track("t2")?.clips.isEmpty == true)
    }

    /// C14: a copy that reaches a later clip overwrites the audio under it: the copy of 0..<60 000
    /// covers 60 000..<120 000, so "L" keeps only its part after 120 000 and keeps its ID, as a
    /// paste does: a part gets a new ID only when a left part of the clip stays. Nothing else moves.
    @Test mutating func coversLaterClip() throws {
        let pasted = try session.duplicate(0..<60_000, on: ["a"])

        #expect(pasted == ["A@60000"])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 0, offset: 10_000, length: 48_000),
                Clip(id: "A@60000", file: "f", start: 60_000, offset: 10_000, length: 48_000),
                Clip(id: "L", file: "f", start: 120_000, offset: 324_000, length: 24_000),
            ])
    }

    /// C14: a range with no frame and an empty clip set each throw `.emptyExcerpt` and change
    /// nothing. The control copy of a range with frames changes the session.
    @Test mutating func emptyRangeRefused() throws {
        let before = session

        #expect(throws: SessionError.emptyExcerpt) { try session.duplicate(10..<10, on: ["a"]) }
        #expect(session == before)
        #expect(throws: SessionError.emptyExcerpt) { try session.duplicate([]) }
        #expect(session == before)

        try session.duplicate(0..<48_000, on: ["a"])
        #expect(session != before, "a range with frames duplicates")
    }

    /// C10b: a copy keeps the file and the gain envelope of its clip, and `fileVersion` 12 of a
    /// session with a dialogue role, an envelope point, and a clip on a file with a noise reduction
    /// origin (decision 0057). The copy of "R" covers "L".
    @Test mutating func versionKept() throws {
        let origin = RenderOrigin(
            source: "f", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        try session.addFile(AudioFile(id: "f NR", path: "f NR.wav", layout: .mono, length: 480_000, origin: origin))
        try session.place(
            Clip(
                id: "R", file: "f NR", start: 48_000, offset: 0, length: 48_000,
                envelope: envelope([(10_000, -6)])),
            on: "a")
        try session.setRole(.dialogue, tracks: ["a"])
        #expect(session.fileVersion == 12)

        try session.duplicate(48_000..<96_000, on: ["a"])

        #expect(lane("a").map(\.file) == ["f", "f NR", "f NR"])
        #expect(lane("a").last?.envelope == envelope([(10_000, -6)]))
        #expect(session.fileVersion == 12)
        #expect(String(decoding: try session.checkedData(), as: UTF8.self).contains(#"version="12""#))
    }
}
