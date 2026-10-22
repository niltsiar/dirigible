import Testing

@testable import DirigibleCore

/// A session at 48 kHz with the mono tracks `t1` to `t<tracks>`, and the take anchor of each
/// capture file that it adds.
struct TakeSession {
    static let takeStart: UInt64 = 1_000_000_000_000
    var session = Session(sampleRate: 48_000)
    var recordings: [CaptureID: Recording] = [:]
    var map: TakeMap { TakeMap(session, recordings: recordings) }
    var tracks: [TrackID] { session.tracks.map(\.id) }

    init(tracks: Int) throws {
        for index in 1...tracks { try session.addTrack(TrackID("t\(index)"), name: "T\(index)", layout: .mono) }
    }

    /// Adds the file `take<take>-<arm>-1` of `length` frames, whose take time origin is `origin`:
    /// a capture `ms` ms after the take start with a latency of 48 x ms - origin frames.
    @discardableResult
    mutating func addTakeFile(take: Int, arm: Int, origin: Int, length: Int, playhead: Int = 0) throws -> FileID {
        let ms = Int((Double(origin) / 48).rounded(.up))
        let id = "take\(take)-\(arm)-1"
        try session.addCapture(
            Capture(
                id: CaptureID(id), deviceUID: "usb", deviceName: "USB",
                hostTimeNanos: Self.takeStart &+ UInt64(bitPattern: Int64(ms * 1_000_000)),
                sampleTime: 0, nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 48 * ms - origin))
        try session.addFile(
            AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: Frames(length), capture: CaptureID(id)))
        recordings[CaptureID(id)] = Recording(
            take: take, playheadFrame: Frames(playhead), takeStartHostTimeNanos: Self.takeStart, armedTracks: tracks)
        return FileID(id)
    }
}

/// The take time map of decision 0061.
struct TakeMapTests {
    /// Probe p1 of run take-sync: the two devices of take 4 of a tester session. The take start is
    /// the first host time of device 2 and the playhead is 3347, so the starts are the origins of
    /// the split clip IDs of that session: 3347 + round(9380083 ns x 48 kHz) - 156 = 3641, and 3347.
    @Test func alignedStartGivesTheTesterOriginDifference() throws {
        let recording = Recording(
            take: 4, playheadFrame: 3347, takeStartHostTimeNanos: 1_223_961_550_170_000, armedTracks: ["t1", "t2"])
        let mic = Capture(
            id: "take4-1-1", deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 1_223_961_559_550_083,
            sampleTime: 0, nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 156)
        let call = Capture(
            id: "take4-2-1", deviceUID: "call", deviceName: "Call", hostTimeNanos: 1_223_961_550_170_000,
            sampleTime: 0, nominalSampleRate: 44_100, measuredSampleRate: 44_100, latency: 0)

        let first = try #require(mic.alignedStart(in: recording, sampleRate: 48_000))
        let second = try #require(call.alignedStart(in: recording, sampleRate: 48_000))

        #expect(first - second == 294)
        #expect([first, second] == [3641, 3347])
    }

    /// A take clip at 1000 with file offset 200 and origin 500, a gap, and an imported clip.
    @Test func aGapAndAnImportedClipHaveNoTakeTime() throws {
        var fixture = try TakeSession(tracks: 1)
        let file = try fixture.addTakeFile(take: 1, arm: 1, origin: 500, length: 96_000)
        try fixture.session.place(Clip(id: "take1-1-1", file: file, start: 1000, offset: 200, length: 48_000), on: "t1")
        try fixture.session.addFile(AudioFile(id: "music", path: "music.wav", layout: .mono, length: 48_000))
        try fixture.session.place(Clip(id: "music", file: "music", start: 96_000, offset: 0, length: 48_000), on: "t1")

        let map = fixture.map

        #expect(map.take(atTimeline: 1000, on: "t1") == TakeMap.TakeTime(take: 1, frame: 700))
        #expect(map.take(atTimeline: 48_999, on: "t1") == TakeMap.TakeTime(take: 1, frame: 48_699))
        #expect(map.take(atTimeline: 49_000, on: "t1") == nil)
        #expect(map.take(atTimeline: 100_000, on: "t1") == nil)
        #expect(map.timeline(atTake: 700, take: 1) == [TakeMap.Place(track: "t1", frame: 1000)])
        #expect(map.timeline(atTake: 699, take: 1) == [])
    }

    /// A finalized file has an origin inside 2 x `Frames.limit`; a larger one comes from a damaged
    /// `session.xml` and is no take time.
    @Test func anOriginPastTwiceTheFrameLimitIsNoTakeTime() throws {
        var fixture = try TakeSession(tracks: 2)
        let limit = 2 * Frames.limit.count
        let kept = try fixture.addTakeFile(take: 1, arm: 1, origin: limit, length: 48_000)
        let past = try fixture.addTakeFile(take: 1, arm: 2, origin: limit + 1, length: 48_000)
        try fixture.session.place(Clip(id: "a", file: kept, start: 0, offset: 0, length: 48_000), on: "t1")
        try fixture.session.place(Clip(id: "b", file: past, start: 0, offset: 0, length: 48_000), on: "t2")

        let map = fixture.map

        #expect(map.origins == [kept: TakeMap.Origin(take: 1, frame: limit)])
        #expect(map.sync == [1: .inSync(offset: -limit)])
    }

    /// Take 1 on three tracks with origins 0, 324, and -72156 at playhead 48000, a head trim of 5 s,
    /// then take 2 on two tracks at the session end. Then 300 seeded edits. After each edit, for
    /// sampled take frames: each place holds a clip that plays file frame t - origin, the places
    /// are in timeline order, a scan of every clip finds no clip that the map left out, and the
    /// inverse of each place is t.
    @Test(arguments: [1, 2, 3] as [UInt64])
    func theMapFollowsSeededEdits(seed: UInt64) throws {
        var random = SplitMix(seed: seed)
        var fixture = try TakeSession(tracks: 3)
        for (arm, origin) in [(1, 0), (2, 324), (3, -72_156)] {
            let file = try fixture.addTakeFile(take: 1, arm: arm, origin: origin, length: 2_880_000, playhead: 48_000)
            let aligned = 48_000 + origin
            try fixture.session.place(
                Clip(
                    id: ClipID(file.rawValue), file: file, start: Frames(max(0, aligned)),
                    offset: Frames(max(0, -aligned)),
                    length: Frames(2_880_000 - max(0, -aligned))), on: TrackID("t\(arm)"))
        }
        try fixture.session.rippleDelete(0..<240_000, on: fixture.tracks)
        let end = fixture.session.tracks.compactMap { $0.clips.last?.end.count }.max() ?? 0
        for (arm, origin) in [(1, 100), (2, 0)] {
            let file = try fixture.addTakeFile(take: 2, arm: arm, origin: origin, length: 1_440_000, playhead: end)
            try fixture.session.place(
                Clip(id: ClipID(file.rawValue), file: file, start: Frames(end + origin), offset: 0, length: 1_440_000),
                on: TrackID("t\(arm)"))
        }

        var hits = 0
        for step in 0..<300 {
            edit(&fixture.session, &random)
            let map = fixture.map
            var failed: Set<String> = []
            for take in [1, 2] {
                for _ in 0..<10 {
                    let frame = Int.random(in: -80_000...3_000_000, using: &random)
                    let places = map.timeline(atTake: frame, take: take)
                    hits += places.count
                    if places.map(\.frame) != places.map(\.frame).sorted() { failed.insert("order") }
                    if places.count != clips(of: fixture.session, map, playing: frame, take: take) {
                        failed.insert("count")
                    }
                    for place in places {
                        guard
                            let clip = fixture.session.track(place.track)?.clips.first(where: {
                                $0.range.contains(place.frame)
                            }),
                            let origin = map.origins[clip.file], origin.take == take,
                            (clip.offset + place.frame - clip.start).count == frame - origin.frame
                        else {
                            failed.insert("clip")
                            continue
                        }
                        if map.take(atTimeline: place.frame, on: place.track)
                            != TakeMap.TakeTime(take: take, frame: frame)
                        {
                            failed.insert("inverse")
                        }
                    }
                }
            }
            #expect(failed.isEmpty, "seed \(seed), step \(step): \(failed.sorted())")
            if !failed.isEmpty { break }
        }
        #expect(hits > 3000, "seed \(seed): \(hits) places")
    }

    /// The count of clips of a file of `take` whose take range holds `frame`.
    func clips(of session: Session, _ map: TakeMap, playing frame: Int, take: Int) -> Int {
        session.tracks.flatMap(\.clips).filter { clip in
            guard let origin = map.origins[clip.file], origin.take == take else { return false }
            let first = origin.frame + clip.offset.count
            return first <= frame && frame < first + clip.length.count
        }.count
    }

    /// One seeded edit: a ripple insert or delete on all tracks or one, a split, a trim, a move, a
    /// paste of a copy, a heal, or a 1-frame nudge. An edit that throws changes nothing.
    func edit(_ session: inout Session, _ random: inout SplitMix) {
        let tracks = session.tracks.map(\.id)
        let chosen = Bool.random(using: &random) ? tracks : [tracks.randomElement(using: &random)!]
        let end = max(1, session.tracks.compactMap { $0.clips.last?.end.count }.max() ?? 1)
        let frame = Frames(Int.random(in: 0...end, using: &random))
        let clip = session.tracks.flatMap(\.clips).randomElement(using: &random)
        switch Int.random(in: 0..<8, using: &random) {
        case 0: try? session.rippleInsert(Frames(Int.random(in: 1...96_000, using: &random)), at: frame, on: chosen)
        case 1:
            try? session.rippleDelete(frame..<frame + Frames(Int.random(in: 1...24_000, using: &random)), on: chosen)
        case 2: _ = try? session.splitClips(at: [frame], on: chosen)
        case 3:
            guard let clip, clip.length.count > 8 else { return }
            let cut = clip.length.count / 4
            let lower = clip.start + Frames(Int.random(in: 0...cut, using: &random))
            let upper = clip.end - Frames(Int.random(in: 0...cut, using: &random))
            try? session.trim(clip.id, to: lower..<upper)
        case 4:
            guard let clip else { return }
            try? session.move(clip.id, to: tracks.randomElement(using: &random)!, start: frame)
        case 5:
            let copy = try? session.excerpt(
                of: frame..<frame + Frames(Int.random(in: 1...96_000, using: &random)), on: chosen)
            if let copy {
                _ = try? session.paste(copy, at: Frames(Int.random(in: 0...end, using: &random)), on: chosen)
            }
        case 6: _ = try? session.heal()
        default:
            guard let clip else { return }
            try? session.nudge([clip.id], by: Bool.random(using: &random) ? 1 : -1)
        }
    }
}
