import Testing

@testable import DirigibleCore

/// Criteria C5, C7, and C17 of decision 0076: the sync edit, the search span, and the default
/// reference. The pool file "f" is long enough for every clip of a test.
struct SessionSyncTests {
    static func session(rate: Int = 48_000, tracks: [TrackID] = ["a", "b", "c"]) throws -> Session {
        var session = Session(sampleRate: rate)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: Frames(1 << 36)))
        for track in tracks { try session.addTrack(track, name: track.rawValue, layout: .mono) }
        return session
    }

    static func clip(_ id: ClipID, start: Int, length: Int, offset: Int = 0) -> Clip {
        Clip(id: id, file: "f", start: Frames(start), offset: Frames(offset), length: Frames(length))
    }

    /// A lag of -10 s on a clip at 4 s gives start 0 and 6 s of head cut; a clip of 6 s or less
    /// there ends at or under frame 0 and is refused. A lag of +2 s moves the start only.
    @Test func aStartUnderZeroCutsTheHead() throws {
        var session = try Self.session()
        try session.place(Self.clip("C", start: 192_000, length: 960_000, offset: 48_000), on: "a")
        try session.place(Self.clip("O", start: 0, length: 48_000), on: "b")
        let before = session

        var moved = session
        #expect(try moved.sync("C", by: 96_000) == SyncCut(head: .zero, replaced: []))
        #expect(moved.clip("C")?.clip == Self.clip("C", start: 288_000, length: 960_000, offset: 48_000))

        var cut = session
        #expect(try cut.sync("C", by: -480_000) == SyncCut(head: 288_000, replaced: []))
        #expect(cut.clip("C")?.clip == Self.clip("C", start: 0, length: 672_000, offset: 336_000))
        #expect(cut.track("b") == before.track("b"), "another track changed")

        for length in [240_000, 288_000] {
            var short = try Self.session()
            try short.place(Self.clip("S", start: 192_000, length: length), on: "a")
            let unchanged = short
            #expect(throws: SessionError.frameOutOfRange) { _ = try short.sync("S", by: -480_000) }
            #expect(short == unchanged)
        }
    }

    /// Two adjacent parts A (0 to 10 s) and B (10 to 20 s) and a clip E (40 to 45 s) on track a, and
    /// O on track b. The sync of A by 5 s cuts the head of B; by 10 s it covers B, which goes; by
    /// 32 s it cuts E and not B; a move into empty space cuts nothing. Clips on track b never count.
    @Test func aMoveNamesEachOtherClipThatItCuts() throws {
        let second = 48_000
        var session = try Self.session()
        try session.place(Self.clip("A", start: 0, length: 10 * second), on: "a")
        try session.place(Self.clip("B", start: 10 * second, length: 10 * second), on: "a")
        try session.place(Self.clip("E", start: 40 * second, length: 5 * second), on: "a")
        try session.place(Self.clip("O", start: 0, length: 60 * second), on: "b")

        for (lag, replaced) in [(5, ["B"]), (10, ["B"]), (32, ["E"]), (50, [])] as [(Int, [ClipID])] {
            var moved = session
            #expect(
                try moved.sync("A", by: Frames(lag * second)) == SyncCut(head: .zero, replaced: replaced),
                "lag \(lag) s")
        }
        var covered = session
        _ = try covered.sync("A", by: Frames(10 * second))
        #expect(covered.clip("B") == nil, "B is under A")
    }

    /// The call preset (Host, then Guest on the app route) plus an imported guest file gives
    /// Guest; with no app route the first other track with a clip in the default span; with no
    /// other clip there, nil. An excluded track is never the result.
    @Test func theDefaultReferenceIsTheCallTrack() throws {
        let minute = 60 * 48_000
        var call = try Self.session(tracks: [])
        try call.addCallTracks(
            host: "host", guest: "guest", names: ("Host", "Guest"), hostDevice: ("mic", 1), guestApp: "us.zoom.xos")
        try call.addTrack("import", name: "Import", layout: .mono)
        try call.place(Self.clip("H", start: 0, length: 20 * minute), on: "host")
        try call.place(Self.clip("Z", start: 0, length: 20 * minute), on: "guest")
        try call.place(Self.clip("G", start: 0, length: 19 * minute), on: "import")
        #expect(call.defaultSyncReference(for: "G") == "guest")
        #expect(call.defaultSyncReference(for: "G", excluding: "guest") == "host", "the excluded call track")
        #expect(call.defaultSyncReference(for: "G", excluding: "host") == "guest")

        var far = call
        try far.removeClips(["Z"])
        try far.place(Self.clip("Z", start: 60 * minute, length: minute), on: "guest")
        #expect(far.defaultSyncReference(for: "G") == "host", "an app track with no clip in the span")

        var plain = try Self.session()
        try plain.place(Self.clip("G", start: 0, length: minute), on: "c")
        #expect(plain.defaultSyncReference(for: "G") == nil)
        try plain.place(Self.clip("B", start: 2 * minute, length: minute), on: "b")
        #expect(plain.defaultSyncReference(for: "G") == "b")
        try plain.place(Self.clip("A", start: 3 * minute, length: minute), on: "a")
        #expect(plain.defaultSyncReference(for: "G") == "a")
        #expect(plain.defaultSyncReference(for: "G", excluding: "a") == "b")
        #expect(plain.defaultSyncReference(for: "G", excluding: "b") == "a")
        #expect(plain.defaultSyncReference(for: "unknown") == nil)
    }

    /// The values of the cap probe of the run (`probes/cap/out-cap.txt`), with the 44.1 kHz cap of
    /// an excerpt of 120273 coarse samples (60 s at 2004.5 Hz).
    struct Cap: Sendable, CustomTestStringConvertible {
        let rate: Int
        let cap: Int
        let noCut: (pass: Int, maxWithin: Int)
        let atZero: (pass: Int, maxWithin: Int)
        let clamp: (keeps: Int, clamps: Int, clamped: Int)
        var testDescription: String { "\(rate) Hz" }
    }

    static let caps = [
        Cap(
            rate: 48_000, cap: 399_773_184, noCut: (2364, 113_486_592), atZero: (4728, 226_973_184),
            clamp: (4728, 4729, 86_390_592)),
        Cap(
            rate: 44_100, cap: 366_452_746, noCut: (2354, 103_846_373), atZero: (4709, 207_692_746),
            clamp: (4709, 4710, 79_370_873)),
    ]

    /// At each rate, the coarse FFT of a span at the cap and of the longest excerpt (a clip just under
    /// 60 s) fits 2^24 points: n is the span samples plus the excerpt samples minus 1, and a decimation
    /// by f = floor(rate / 2000) gives at most ceil(N / f) samples of N frames.
    @Test(arguments: [
        1, 1_999, 3_999, 8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
    ])
    func theCapAndTheLongestExcerptFitTheCoarseFFT(rate: Int) throws {
        let factor = max(1, rate / 2000)
        func coarse(_ frames: Int) -> Int { (frames + factor - 1) / factor }
        let cap = try Self.session(rate: rate).syncSpanCap.count
        let points = coarse(cap) + coarse(60 * rate - 1) - 1
        #expect(points <= 1 << 24, "\(points) points at \(rate) Hz")
    }

    /// A 1 h clip with no cut passes the largest whole-second `within` and is refused at one more
    /// second; so does a 1 h clip at frame 0. The default `within` keeps 1800 s up to the clamp
    /// length and clamps one second over it. A clip over the cap is refused for every `within`.
    @Test(arguments: caps) func aSpanOverTheCapIsRefusedOrClamped(_ values: Cap) throws {
        let (rate, hour) = (values.rate, 3600 * values.rate)
        func session(clip start: Int, length: Int) throws -> Session {
            var session = try Self.session(rate: rate)
            try session.place(Self.clip("C", start: start, length: length), on: "a")
            try session.place(Self.clip("R", start: 0, length: 20_000 * rate), on: "b")
            return session
        }
        #expect(try Self.session(rate: rate).syncSpanCap == Frames(values.cap))

        let noCut = try session(clip: 5000 * rate, length: hour)
        let pass = Frames(values.noCut.pass * rate)
        #expect(
            try noCut.syncSpan("C", to: "b", within: pass) == Frames(5000 * rate) - pass..<Frames(8600 * rate) + pass)
        #expect(throws: SessionError.syncSpanTooLong(maxWithin: Frames(values.noCut.maxWithin))) {
            try noCut.syncSpan("C", to: "b", within: pass + Frames(rate))
        }

        let atZero = try session(clip: 0, length: hour)
        let zeroPass = Frames(values.atZero.pass * rate)
        #expect(try atZero.syncSpan("C", to: "b", within: zeroPass) == 0..<Frames(hour) + zeroPass)
        #expect(throws: SessionError.syncSpanTooLong(maxWithin: Frames(values.atZero.maxWithin))) {
            try atZero.syncSpan("C", to: "b", within: zeroPass + Frames(rate))
        }

        let keeps = try session(clip: 2000 * rate, length: values.clamp.keeps * rate)
        #expect(try keeps.syncWithin("C") == Frames(1800 * rate))
        let clamps = try session(clip: 2000 * rate, length: values.clamp.clamps * rate)
        #expect(try clamps.syncWithin("C") == Frames(values.clamp.clamped))
        #expect(throws: SessionError.syncSpanTooLong(maxWithin: Frames(values.clamp.clamped))) {
            try clamps.syncWithin("C", within: Frames(1800 * rate))
        }

        let over = try session(clip: 0, length: values.cap + 1)
        #expect(throws: SessionError.syncSpanTooLong(maxWithin: 0)) { try over.syncWithin("C") }
        #expect(throws: SessionError.syncSpanTooLong(maxWithin: 0)) { try over.syncWithin("C", within: 0) }
    }
}
