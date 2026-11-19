import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0077 D2 to D4: the drift check in memory, the holders of a drift source, and the words
/// of a new drift-corrected file (criteria D11 to D13 of run `2026-11-19-waveform-drift`).
struct SessionDriftTests {
    let unused: UnusedFilesTests

    init() throws {
        unused = try UnusedFilesTests()
    }

    static func link(_ source: FileID, offset: Frames = 0, ratio: Double = 1 / (1 + 100e-6)) throws -> DriftOrigin {
        DriftOrigin(source: source, offset: offset, ratio: try #require(DriftRatio(ratio)), addedGain: .zero)
    }

    /// The session of `UnusedFilesTests.session` with the plain file `source`, its drift-corrected
    /// file `drift` (48 000 frames each), a render of `drift` named `rendered`, and a clip on the top
    /// file of the chain when `placed`.
    static func chain(
        _ drift: FileID, of source: FileID, rendered: FileID? = nil, placed: Bool, others: [(FileID, String)] = []
    ) throws -> Session {
        var session = try UnusedFilesTests.session([(source, "\(source.rawValue).wav")] + others)
        try session.addFile(
            AudioFile(
                id: drift, path: "\(drift.rawValue).wav", layout: .mono, length: 48_000, drift: try link(source)))
        var top = drift
        if let rendered {
            let origin = RenderOrigin(
                source: drift, offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
            try session.addFile(
                AudioFile(id: rendered, path: "\(rendered.rawValue).wav", layout: .mono, length: 48_000, origin: origin)
            )
            top = rendered
        }
        if placed { try session.place(Clip(id: "c", file: top, start: 0, offset: 0, length: 1), on: "a") }
        return session
    }

    /// D11: `addFile` and `addDriftFile` refuse a source with a capture (a take file and a split half
    /// of a take), a file with an origin and a drift link, and a last frame past the source. The
    /// session does not change. The bound length on a plain source passes (control).
    @Test func eachBadDriftLinkIsRefusedInMemory() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: CaptureID("take"), deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 0, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try session.addFile(
            AudioFile(id: "take", path: "take.wav", layout: .mono, length: 28_800_000, capture: CaptureID("take")))
        try session.addFile(
            AudioFile(id: "half", path: "half.wav", layout: .mono, length: 14_400_000, capture: CaptureID("take")))
        try session.addFile(AudioFile(id: "guest", path: "guest.wav", layout: .mono, length: 28_800_000))
        #expect(session.files["take"]?.isTakeFile == true && session.files["half"]?.isTakeFile == false)
        let before = session
        let worked = try Self.link("guest", ratio: 1 / 1.0001)
        let noise = RenderOrigin(source: "guest", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        let file = { (length: Frames, origin: RenderOrigin?, drift: DriftOrigin) in
            AudioFile(id: "x", path: "x.wav", layout: .mono, length: length, origin: origin, drift: drift)
        }
        let added: [(String, AudioFile)] = [
            ("take file", file(1_000, nil, try Self.link("take"))),
            ("split half", file(1_000, nil, try Self.link("half"))),
            ("origin and drift", file(1_000, noise, try Self.link("guest"))),
            ("last frame", file(28_802_882, nil, worked)),
        ]
        for (name, bad) in added {
            #expect(throws: SessionError.invalidOrigin("x"), "addFile: \(name)") { try session.addFile(bad) }
        }
        let made: [(String, Frames, DriftOrigin)] = [
            ("take file", 1_000, try Self.link("take")), ("split half", 1_000, try Self.link("half")),
            ("last frame", 28_802_882, worked),
        ]
        for (name, length, link) in made {
            #expect(throws: SessionError.invalidOrigin("x"), "addDriftFile: \(name)") {
                try session.addDriftFile(stem: "x", length: length, drift: link, wordsFrom: link.source)
            }
        }
        #expect(session == before)

        var plain = session
        try plain.addFile(file(28_802_881, nil, worked))
        try session.addDriftFile(stem: "x", length: 28_802_881, drift: worked, wordsFrom: "guest")
        #expect(plain.files["x"]?.drift == worked && session.files["x"] == plain.files["x"])
    }

    /// D12: a clip on the drift-corrected file keeps its source. The unrelated file "u" is the one
    /// item, and the prune moves only it.
    @Test func removeUnusedFilesKeepsADriftSource() throws {
        var session = try Self.chain("guest drift", of: "guest", placed: true, others: [("u", "u.wav")])
        for name in ["guest.wav", "guest drift.wav", "u.wav"] { try unused.plant(name) }

        let scan = try unused.scan(session)
        let report = try scan.prune(&session, save: unused.save, trash: UnusedFilesTests.fakeTrashURL)

        #expect(UnusedFilesTests.paths(scan) == ["u.wav"])
        #expect(report.moved.map(\.item.path) == ["u.wav"] && report.failed.isEmpty)
        #expect(session.files["guest"] != nil && session.files["guest drift"]?.drift?.source == "guest")
    }

    /// D12: `removeFile` refuses the source of a drift link, and the session does not change. After
    /// the drift-corrected file goes, the source goes too (control).
    @Test func aDriftSourceCannotBeRemovedAlone() throws {
        var session = try Self.chain("guest drift", of: "guest", placed: false)
        let before = session

        #expect(throws: SessionError.fileIsSource("guest", of: "guest drift")) { try session.removeFile("guest") }

        #expect(session == before)
        try session.removeFile("guest drift")
        try session.removeFile("guest")
        #expect(session.files.isEmpty)
    }

    /// D12: with no clip, Remove Unused Files removes both files, whether the ID order puts the
    /// source first ("guest") or last ("z").
    @Test func bothFilesGoTogetherInEitherOrder() throws {
        for (drift, source) in [("guest drift", "guest"), ("a drift", "z")] as [(FileID, FileID)] {
            var session = try Self.chain(drift, of: source, placed: false)
            let planted = try [drift, source].map { try unused.plant("\($0.rawValue).wav") }
            let scan = try unused.scan(session)

            let report = try scan.prune(&session, save: unused.save, trash: UnusedFilesTests.fakeTrashURL)

            #expect(Set(UnusedFilesTests.paths(scan)) == ["\(drift.rawValue).wav", "\(source.rawValue).wav"])
            #expect(report.moved.count == 2 && report.failed.isEmpty && session.files.isEmpty, "\(drift)")
            // The fake trash moves nothing: the next pair must not see these files as strays.
            for url in planted { try FileManager.default.removeItem(at: url) }
        }
    }

    /// D12: a clip on a render of the drift-corrected file (clip, "guest drift NR", "guest drift",
    /// "guest") keeps the whole chain. Only "u" goes.
    @Test func removeUnusedFilesKeepsTheSourceUnderARender() throws {
        var session = try Self.chain(
            "guest drift", of: "guest", rendered: "guest drift NR", placed: true, others: [("u", "u.wav")])
        for name in ["guest.wav", "guest drift.wav", "guest drift NR.wav", "u.wav"] { try unused.plant(name) }

        let scan = try unused.scan(session)
        let report = try scan.prune(&session, save: unused.save, trash: UnusedFilesTests.fakeTrashURL)

        #expect(UnusedFilesTests.paths(scan) == ["u.wav"])
        #expect(report.moved.map(\.item.path) == ["u.wav"] && report.failed.isEmpty)
        #expect(Set(session.files.keys) == ["guest", "guest drift", "guest drift NR"])
    }

    /// D12: with no clip on the chain, Remove Unused Files removes the three files together.
    @Test func bothFilesGoTogetherUnderARender() throws {
        var session = try Self.chain("guest drift", of: "guest", rendered: "guest drift NR", placed: false)
        let names = ["guest.wav", "guest drift.wav", "guest drift NR.wav"]
        for name in names { try unused.plant(name) }
        let scan = try unused.scan(session)

        let report = try scan.prune(&session, save: unused.save, trash: UnusedFilesTests.fakeTrashURL)

        #expect(Set(UnusedFilesTests.paths(scan)) == Set(names))
        #expect(report.moved.count == 3 && report.failed.isEmpty && session.files.isEmpty)
    }

    /// D13: the words of the source go into the new file through the time map of the worked example
    /// of D14 (offset 0, ratio 1 / 1.0001): each end lands within 1 frame of round(f x 1.0001), with
    /// its number, and the transcript loads after a save and an open. Fail value: a copy by the
    /// offset only puts the last word 2880 frames early.
    @Test func theWordsOfTheSourceMoveThroughTheTimeMap() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "guest", path: "guest.wav", layout: .mono, length: 28_800_000))
        session.addWords(
            [(1, 0..<4_800, "one"), (2, 14_400_000..<14_404_800, "two"), (3, 28_795_200..<28_800_000, "three")],
            file: "guest")

        try session.addDriftFile(
            stem: "guest drift", length: 28_802_881, drift: try Self.link("guest", ratio: 1 / 1.0001),
            wordsFrom: "guest")

        let reopened = try session.reopened()
        let words = reopened.transcripts[TranscriptID(1)]?.words?["guest drift"]?.all ?? []
        let expected: [(Int, Int, Int)] = [(1, 0, 4_800), (2, 14_401_440, 14_406_240), (3, 28_798_080, 28_802_880)]
        #expect(reopened.transcriptsNotLoaded.isEmpty && words.count == expected.count, "\(words)")
        for (word, (number, start, end)) in zip(words, expected) {
            #expect(word.number == number, "\(word)")
            #expect(
                abs(word.range.lowerBound.count - start) <= 1 && abs(word.range.upperBound.count - end) <= 1, "\(word)")
        }
    }
}
