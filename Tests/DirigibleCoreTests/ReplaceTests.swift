import Foundation
import Testing

@testable import DirigibleCore

/// Replace (run replace-roomtone-split C10, C10b, C11; decision 0053) on `editFixture`: clip "A" on
/// "a" at 0..<48 000 before the range, and clip "L" on "a" at 240 000..<288 000 after it. The
/// clipboard comes from another session of the same pool: clip "K" of file "f" from frame 100 000.
struct ReplaceTests {
    var session: Session

    init() throws {
        session = try editFixture()
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000), on: "a")
        try session.place(Clip(id: "L", file: "f", start: 240_000, offset: 300_000, length: 48_000), on: "a")
    }

    /// A clipboard of `length` frames: one clip "K" of file "f" from file frame 100 000.
    static func clipboard(_ length: Frames) throws -> Excerpt {
        var source = try editFixture()
        try source.place(Clip(id: "K", file: "f", start: 0, offset: 100_000, length: length), on: "a")
        return try source.excerpt(of: 0..<length, on: ["a"])
    }

    func lane(_ track: TrackID) -> [Clip] {
        session.track(track).map { Array($0.clips) } ?? []
    }

    /// C10: a 2 s range with a 3 s clipboard moves a later clip +1 s; a 3 s range with a 2 s
    /// clipboard moves it -1 s. The clip before the range stays.
    @Test(arguments: [(Frames(192_000), Frames(144_000), Frames(288_000)), (240_000, 96_000, 192_000)])
    mutating func longerAndShorterClipboard(end: Frames, length: Frames, laterStart: Frames) throws {
        let pasted = try session.replace(96_000..<end, with: try Self.clipboard(length), on: ["a"])

        #expect(pasted == ["K@96000"])
        #expect(
            lane("a") == [
                Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000),
                Clip(id: "K@96000", file: "f", start: 96_000, offset: 100_000, length: length),
                Clip(id: "L", file: "f", start: laterStart, offset: 300_000, length: 48_000),
            ])
    }

    /// C10: the range goes from every track, also from a track that is not a target, and the later
    /// clips there move by the length difference.
    @Test mutating func clearsNonTargetTracks() throws {
        try session.place(Clip(id: "N", file: "f", start: 60_000, offset: 0, length: 60_000), on: "b")
        try session.place(Clip(id: "M", file: "f", start: 200_000, offset: 0, length: 20_000), on: "b")

        try session.replace(96_000..<192_000, with: try Self.clipboard(144_000), on: ["a"])

        #expect(
            lane("b") == [
                Clip(id: "N", file: "f", start: 60_000, offset: 0, length: 36_000),
                Clip(id: "M", file: "f", start: 248_000, offset: 0, length: 20_000),
            ])
    }

    /// C11: a marker inside the range or at its start ends at the range start; a marker at or after
    /// the range end moves by the length difference; a marker before the range stays. The frames
    /// are literal in `session.xml`.
    @Test mutating func markerRule() throws {
        let positions: [(MarkerID, Frames, Frames)] = [
            ("before", 50_000, 50_000), ("start", 96_000, 96_000), ("inside", 150_000, 96_000),
            ("end", 192_000, 240_000), ("after", 300_000, 348_000),
        ]
        for (id, position, _) in positions {
            try session.setMarker(Marker(id: id, name: "M", position: position, kind: .marker))
        }

        try session.replace(96_000..<192_000, with: try Self.clipboard(144_000), on: ["a"])

        let read = try Session(xml: try session.checkedData())
        for (id, _, expected) in positions {
            #expect(read.markers[id]?.position == expected, "\(id)")
        }
    }

    /// C10b: a Replace and a fill keep `fileVersion` 12 of a session with a dialogue role, an
    /// envelope point, and a clip on a file with a noise reduction origin (decision 0057).
    @Test(arguments: ["replace", "fill"])
    mutating func versionKept(edit: String) throws {
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
        let clipboard = try session.excerpt(of: 48_000..<96_000, on: ["a"])

        if edit == "replace" {
            try session.replace(120_000..<200_000, with: clipboard, on: ["b"])
        } else {
            try session.fill(120_000..<200_000, with: clipboard, on: ["b"])
        }

        // The fill repeats the 48 000-frame clipboard twice over the 80 000-frame range.
        #expect(lane("b").map(\.file) == (edit == "replace" ? ["f NR"] : ["f NR", "f NR"]))
        #expect(session.fileVersion == 12)
        #expect(String(decoding: try session.checkedData(), as: UTF8.self).contains(#"version="12""#))
    }
}
