import Foundation
import Testing

@testable import DirigibleCore

/// The split of stereo clips into two mono clips on two new tracks (decision 0053). At 48 kHz the
/// handle on each side of a clip is 10 s, 480 000 frames.
struct SplitStereoTests {
    /// A 48 kHz session with the stereo track "t" named "Host" and the stereo file "f" of `length`
    /// frames, with the clips (id, offset in "f", length) one after the other on "t".
    func session(length: Frames = 10_000_000, at first: Frames = .zero, clips: [(ClipID, Frames, Frames)]) throws
        -> Session
    {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t", name: "Host", layout: .stereo)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .stereo, length: length))
        var start = first
        for (id, offset, clipLength) in clips {
            try session.place(Clip(id: id, file: "f", start: start, offset: offset, length: clipLength), on: "t")
            start = start + clipLength
        }
        return session
    }

    func pairs(_ session: Session, _ clips: [ClipID]) throws -> [MonoPair] {
        try session.clipRuns(of: clips).enumerated().map { index, run in
            let number = index == 0 ? "" : " \(index + 1)"
            return MonoPair(run: run, leftStem: "\(run.file) L\(number)", rightStem: "\(run.file) R\(number)")
        }
    }

    /// C1. One stereo clip gives a left clip on a new mono track and a right clip on a second one,
    /// directly under the source track. Start, length, gain, and fades stay, the offset is the old
    /// offset minus the pair start, and the source clip goes.
    @Test func splitGivesLeftAndRightClips() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        try session.setGain(#require(Gain(dB: -3)), clip: "A")
        try session.setFades(["A": #require(Fades(fadeIn: 480, fadeOut: 960))])
        let source = try #require(session.clip("A")?.clip)

        let parts = try session.splitStereo(pairs(session, ["A"]), names: ("L", "R"))

        let part = try #require(parts.first)
        #expect(parts.count == 1 && part.source == "A" && part.left == "A L" && part.right == "A R")
        #expect(session.tracks.map(\.name) == ["Host", "Host L", "Host R"])
        #expect(session.tracks.map(\.layout) == [.stereo, .mono, .mono])
        #expect(session.tracks.map(\.id) == ["t", part.leftTrack, part.rightTrack])
        #expect(session.tracks[0].clips.isEmpty, "the source track stays, empty")
        #expect(session.clip("A") == nil)
        #expect(session.files["f L"] == AudioFile(id: "f L", path: "f L.wav", layout: .mono, length: 1_060_000))
        #expect(session.files["f R"] == AudioFile(id: "f R", path: "f R.wav", layout: .mono, length: 1_060_000))
        for (id, file, track) in [(part.left, "f L", part.leftTrack), (part.right, "f R", part.rightTrack)] {
            let found = try #require(session.clip(id))
            #expect(found.track == track)
            #expect(
                found.clip
                    == Clip(
                        id: id, file: FileID(file), start: source.start, offset: 480_000, length: source.length,
                        gain: source.gain, fades: source.fades))
        }
    }

    /// C1. A clip on a mono track throws `.notStereo` and changes nothing, also with a stereo clip in
    /// the same call.
    @Test func monoClipRefused() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        try session.addTrack("m", name: "Guest", layout: .mono)
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .mono, length: 1_000_000))
        try session.place(Clip(id: "M", file: "g", start: 0, offset: 0, length: 1_000), on: "m")
        let before = session

        #expect(throws: SessionError.notStereo("M")) {
            try session.splitStereo(self.pairs(session, ["A", "M"]), names: ("L", "R"))
        }
        #expect(session == before)
    }

    /// C1. The mono check comes before the transcript check of the new files: with a transcript
    /// that did not load, a mono clip still throws `.notStereo`.
    @Test func monoClipRefusedBeforeTheTranscriptCheck() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        try session.addTrack("m", name: "Guest", layout: .mono)
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .mono, length: 1_000_000))
        try session.place(Clip(id: "M", file: "g", start: 0, offset: 0, length: 1_000), on: "m")
        session.transcripts[TranscriptID(1)] = Transcript(id: TranscriptID(1), name: "t1", words: nil)
        let before = session

        #expect(throws: SessionError.notStereo("M")) {
            try session.splitStereo(self.pairs(session, ["A", "M"]), names: ("L", "R"))
        }
        #expect(session == before)
    }

    /// C1. A new clip plays the gain of the source clip at each source frame: the envelope moves by
    /// the pair start, a point outside the pair becomes a point at the pair edge with the source gain
    /// there (decision 0060), and an empty envelope stays empty.
    @Test func splitKeepsTheEnvelopeGain() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        let points = [(100_000, -10.0), (700_000, -4), (1_200_000, 6), (3_000_000, -20)]
        let source = Clip(
            id: "E", file: "f", start: 100_000, offset: 1_000_000, length: 100_000, envelope: envelope(points))
        try session.place(source, on: "t")
        let before = try #require(session.clip("E")?.clip)

        let parts = try session.splitStereo(pairs(session, ["A", "E"]), names: ("L", "R"))
        let part = try #require(parts.first { $0.source == "E" })

        // The pair is 520_000..<1_580_000 of "f": the points at 100_000 and 3_000_000 fall outside.
        let frames = [0, 180_000, 680_000, 1_060_000]
        for id in [part.left, part.right] {
            let found = try #require(session.clip(id)?.clip)
            #expect(found.envelope.points.map(\.frame.count) == frames)
            for frame in frames + [1, 90_000, 179_999, 400_000, 679_999, 900_000, 1_059_999] {
                let expected = before.envelope.gain(at: Frames(frame + 520_000))
                #expect(abs(found.envelope.gain(at: Frames(frame)) - expected) < 1e-9, "\(id) at \(frame)")
            }
        }
        let plain = try #require(session.clip("A L")?.clip)
        #expect(plain.envelope.isEmpty, "an empty envelope stays empty")
    }

    /// C2. Clips whose written spans touch share one pair: their offsets are relative to the pair
    /// start. A clip far away gets the second pair.
    @Test func runsMergeTouchingSpans() throws {
        var session = try session(clips: [
            ("A", 1_000_000, 100_000), ("B", 2_060_000, 100_000), ("C", 6_000_000, 1_000),
        ])

        let parts = try session.splitStereo(pairs(session, ["C", "B", "A"]), names: ("L", "R"))

        #expect(session.files["f L"]?.length == 2_120_000 && session.files["f L 2"]?.length == 961_000)
        #expect(session.files["f R"]?.length == 2_120_000 && session.files["f R 2"]?.length == 961_000)
        #expect(parts.map(\.source) == ["A", "B", "C"], "by clip start")
        let found = try ["A L", "B L", "C L", "A R", "B R", "C R"].map { try #require(session.clip($0)?.clip) }
        #expect(found.map(\.file.rawValue) == ["f L", "f L", "f L 2", "f R", "f R", "f R 2"])
        #expect(found.map(\.offset.count) == [480_000, 1_540_000, 480_000, 480_000, 1_540_000, 480_000])
        #expect(found.map(\.start.count) == [0, 100_000, 200_000, 0, 100_000, 200_000])
    }

    /// C2. A crossfade between two split clips stays on both new tracks. A crossfade whose partner
    /// is not split goes from the new clip and from the clip that stays.
    @Test func crossfadeKeptOnlyWithPartner() throws {
        var source = try session(clips: [
            ("A", 1_000_000, 100_000), ("B", 3_000_000, 100_000), ("C", 5_000_000, 100_000),
        ])
        try source.setCrossfades(["A": 960, "B": 960])
        var both = source
        var onlyA = source

        _ = try both.splitStereo(pairs(both, ["A", "B"]), names: ("L", "R"))
        _ = try onlyA.splitStereo(pairs(onlyA, ["A"]), names: ("L", "R"))

        for side in ["L", "R"] {
            #expect(both.clip(ClipID("A \(side)"))?.clip.crossfades == Crossfades(start: 0, end: 960), "A \(side)")
            #expect(both.clip(ClipID("B \(side)"))?.clip.crossfades == Crossfades(start: 960, end: 0), "B \(side)")
            #expect(onlyA.clip(ClipID("A \(side)"))?.clip.crossfades == .zero, "A \(side) has no partner")
        }
        #expect(both.clip("C")?.clip.crossfades == .zero, "C lost the crossfade with B")
        #expect(onlyA.clip("B")?.clip.crossfades == Crossfades(start: 0, end: 960), "B kept only its end")
    }

    /// C2. A new clip trims up to the edges of its pair file, which is the handle for a one-clip
    /// run: one frame more is refused.
    @Test func trimExtendsIntoHandle() throws {
        var session = try session(at: 1_000_000, clips: [("A", 1_000_000, 100_000)])
        _ = try session.splitStereo(pairs(session, ["A"]), names: ("L", "R"))

        try session.trim("A L", to: 520_000..<1_580_000)
        #expect(throws: SessionError.clipOutsideFile("A R")) { try session.trim("A R", to: 519_999..<1_100_000) }
        #expect(throws: SessionError.clipOutsideFile("A R")) { try session.trim("A R", to: 1_000_000..<1_580_001) }
        let trimmed = try #require(session.clip("A L")?.clip)
        #expect(trimmed.offset == 0 && trimmed.length.count == 1_060_000)
    }

    /// C2. Both new tracks copy the gain, mute, solo, and role of the source track, and have no
    /// route. A source track with no role gives two tracks with no role.
    @Test func tracksCopyMixState() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        try session.setRoute(.device(uid: "usb-1", channels: .stereo(1, 2)), track: "t")
        try session.setGain(#require(Gain(dB: -3)), track: "t")
        try session.setMuted(true, tracks: ["t"])
        try session.setSoloed(true, tracks: ["t"])
        try session.setRole(.dialogue, tracks: ["t"])
        var plain = try self.session(clips: [("A", 1_000_000, 100_000)])

        _ = try session.splitStereo(pairs(session, ["A"]), names: ("L", "R"))
        _ = try plain.splitStereo(pairs(plain, ["A"]), names: ("L", "R"))

        for track in session.tracks.dropFirst() {
            #expect(track.role == .dialogue && track.isMuted && track.isSoloed, "\(track.name)")
            #expect(track.gain == Gain(dB: -3) && track.route == nil, "\(track.name)")
        }
        #expect(plain.tracks.dropFirst().map(\.role) == [nil, nil])
        #expect(session.tracks[0].route != nil, "the source track keeps its route")
    }

    /// C3. A run that is not the run of its clips, and a stem whose ID or path is in the pool, throw
    /// and change nothing.
    @Test func badPairRefused() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        try session.addFile(AudioFile(id: "g", path: "f R.wav", layout: .mono, length: 1_000))
        try session.addFile(AudioFile(id: "f L", path: "other.wav", layout: .mono, length: 1_000))
        let before = session
        let run = try #require(try session.clipRuns(of: ["A"]).first)
        let short = ClipRun(file: "f", span: 600_000..<1_580_000, clips: ["A"])

        #expect(throws: SessionError.frameOutOfRange) {
            try session.splitStereo([MonoPair(run: short, leftStem: "x L", rightStem: "x R")], names: ("L", "R"))
        }
        #expect(throws: SessionError.duplicateID("f L")) {
            try session.splitStereo([MonoPair(run: run, leftStem: "f L", rightStem: "x R")], names: ("L", "R"))
        }
        #expect(throws: SessionError.duplicateID("f R.wav")) {
            try session.splitStereo([MonoPair(run: run, leftStem: "x L", rightStem: "f R")], names: ("L", "R"))
        }
        #expect(session == before)
    }

    /// C3b. A pair file names the capture of its source file, so the capture stays after the source
    /// file goes.
    @Test func pairKeepsCapture() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: "k1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 1, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try session.addTrack("t", name: "Host", layout: .stereo)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .stereo, length: 2_000_000, capture: "k1"))
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 100_000, length: 100_000), on: "t")

        _ = try session.splitStereo(pairs(session, ["A"]), names: ("L", "R"))

        #expect(session.files["f L"]?.capture == "k1" && session.files["f R"]?.capture == "k1")
        try session.removeFile("f")
        #expect(throws: SessionError.captureInUse("k1")) { try session.removeCapture("k1") }
    }

    /// C4c. 500 clips of one file give one pair, and no side is longer than the source.
    @Test func denseEditWritesAtMostTheSource() throws {
        let clips = (0..<500).map { (ClipID("c\($0)"), Frames($0 * 2_000), Frames(1_000)) }
        var session = try session(length: 5_000_000, clips: clips)

        let parts = try session.splitStereo(pairs(session, clips.map(\.0)), names: ("L", "R"))

        #expect(parts.count == 500 && session.files.count == 3, "one pair for the run")
        #expect(session.files["f L"]?.length == 1_479_000 && session.files["f R"]?.length == 1_479_000)
        #expect(session.tracks[1].clips.count == 500 && session.tracks[2].clips.count == 500)
    }

    /// C4c. Two clips that play on in one file stay a seamless join on each new track, and Heal
    /// joins them there exactly when it joined the source clips: with equal envelope gain at the
    /// join, not with different gain.
    @Test(arguments: [(-6.0, true), (-12.0, false)])
    func seamlessJoinStaysSeamless(rightGain: Double, heals: Bool) throws {
        var session = try session(clips: [])
        let envelopes = [envelope([(1_000_000, -6)]), envelope([(1_100_000, rightGain)])]
        try session.place(
            Clip(id: "A", file: "f", start: 0, offset: 1_000_000, length: 100_000, envelope: envelopes[0]), on: "t")
        try session.place(
            Clip(id: "B", file: "f", start: 100_000, offset: 1_100_000, length: 100_000, envelope: envelopes[1]),
            on: "t")
        #expect(session.tracks[0].clips.canHeal(after: 0) == heals, "the source clips")

        _ = try session.splitStereo(pairs(session, ["A", "B"]), names: ("L", "R"))

        for track in session.tracks.dropFirst() {
            #expect(track.clips.join(after: 0) == .seamless, "\(track.name)")
            #expect(track.clips.canHeal(after: 0) == heals, "\(track.name)")
        }
    }

    /// C9. A session with an envelope point and a crossfade at a seamless join keeps its version
    /// through the split: 10, and 11 with a role on the source track (a split that drops the
    /// envelope gives 9 in the first case). The saved file reads back equal.
    @Test(arguments: [(false, 10), (true, 11)])
    func versionKept(role: Bool, version: Int) throws {
        var session = try session(clips: [])
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 1_000_000, length: 100_000), on: "t")
        try session.place(
            Clip(
                id: "B", file: "f", start: 100_000, offset: 1_100_000, length: 100_000,
                envelope: envelope([(1_150_000, -6)])),
            on: "t")
        if role { try session.setRole(.dialogue, tracks: ["t"]) }
        try session.setCrossfades(["A": 960])
        #expect(session.fileVersion == version)

        _ = try session.splitStereo(pairs(session, ["A", "B"]), names: ("L", "R"))

        #expect(session.fileVersion == version)
        let data = try session.checkedData()
        #expect(String(decoding: data, as: UTF8.self).contains(#"version="\#(version)""#))
        #expect(try Session(xml: data, newest: 11) == session)
    }

    /// Each source track gets its two tracks directly under it, in session order. A new clip ID that
    /// is taken gets the next number.
    @Test func newTracksSitUnderTheirSourceAndIDsStayFree() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        try session.addTrack("u", name: "Guest", layout: .stereo)
        try session.addTrack("v", name: "Music", layout: .stereo)
        try session.place(Clip(id: "B", file: "f", start: 0, offset: 2_000_000, length: 1_000), on: "u")
        try session.place(Clip(id: "A L", file: "f", start: 0, offset: 3_000_000, length: 1_000), on: "v")

        let parts = try session.splitStereo(pairs(session, ["B", "A"]), names: ("I", "D"))

        #expect(session.tracks.map(\.name) == ["Host", "Host I", "Host D", "Guest", "Guest I", "Guest D", "Music"])
        #expect(parts.map(\.source) == ["A", "B"] && parts[0].left == "A L 2" && parts[0].right == "A R")
        #expect(parts[1].leftTrack == session.tracks[4].id && parts[1].rightTrack == session.tracks[5].id)
        #expect(session.clip("A L")?.track == "v", "the clip that held the ID stays")
    }

    /// The session of `clips` with each clip rendered by `repoint` into "f NR", 1 dB added.
    func rendered(clips: [(ClipID, Frames, Frames)]) throws -> Session {
        var session = try session(clips: clips)
        let runs = try session.clipRuns(of: clips.map(\.0)).map {
            RenderedRun(run: $0, stem: "f NR", treatment: Treatment(.noise(.standard)), addedGain: .zero)
        }
        _ = try session.repoint(runs)
        return session
    }

    /// C11. A split to mono of a rendered stereo file gives files with no origin.
    @Test func splitFilesHaveNoOrigin() throws {
        var session = try rendered(clips: [("A", 1_000_000, 100_000)])
        #expect(session.files["f NR"]?.origin != nil)

        _ = try session.splitStereo(try pairs(session, ["A"]), names: ("L", "R"))

        let added = session.files.values.filter { $0.layout == .mono }
        #expect(added.count == 2 && added.allSatisfy { $0.origin == nil })
        #expect(session.tracks.flatMap(\.clips).allSatisfy { session.origins(of: $0.id).isEmpty })
    }

    /// C11. Each mono clip of a split of a rendered clip shows the words of the root at the same
    /// timeline range, and a cut by words cuts the same frames.
    @Test func splitOfRenderedClipKeepsTheWords() throws {
        var session = try self.session(clips: [("A", 1_000_000, 100_000)])
        session.addWords([(1, 1_010_000..<1_020_000, "Hello")], file: "f")
        let runs = try session.clipRuns(of: ["A"]).map {
            RenderedRun(run: $0, stem: "f NR", treatment: Treatment(.noise(.standard)), addedGain: .zero)
        }
        _ = try session.repoint(runs)

        _ = try session.splitStereo(try pairs(session, ["A"]), names: ("L", "R"))

        let words = session.words()
        #expect(words.map(\.text) == ["Hello", "Hello"] && words.allSatisfy { $0.range == 10_000..<20_000 })
        var cut = session
        #expect(try cut.cutWords([try #require(words.first).occurrence]) == [10_000..<20_000])
    }
}
