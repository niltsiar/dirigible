import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The silence scan of Tools > Find Silences... through `Studio.scanSilences` (decision 0066,
/// criteria C1 to C4, C6 to C8, and C31). Each fixture track is mono with one clip of its audio
/// from frame 0, on the 50 ms window grid. A tone part is a 1 kHz sine at its peak level; a DC
/// part has its RMS level exactly, so a window has that mean square.
@MainActor
struct StudioSilencesTests {
    static let threshold = Gain(dB: -40)!

    /// A package with one mono track `t<n>` (clip `c<n>`, file `f<n>`) for each sample list.
    static func package(_ tracks: [[Float]], rate: Int = 48_000) throws -> MixPackage {
        let package = try MixPackage(sampleRate: rate)
        for (index, samples) in tracks.enumerated() {
            let (file, length) = (FileID("f\(index + 1)"), Frames(samples.count))
            try package.addFile(file, channels: [samples])
            try package.addTrack(
                TrackID("t\(index + 1)"), clip: ClipID("c\(index + 1)"), file: file, start: 0, offset: 0, length: length
            )
        }
        try package.session.write(to: package.url)
        return package
    }

    /// The samples of a mono tone of `parts`.
    static func sine(_ parts: [(seconds: Double, dBFS: Double)], rate: Int = 48_000) -> [Float] {
        tone(parts, rate: rate, layout: .mono)[0]
    }

    /// Constant samples with each part at its RMS level.
    static func dc(_ parts: [(seconds: Double, dBFS: Double)]) -> [Float] {
        parts.flatMap { Array(repeating: Float(pow(10, $0.dBFS / 20)), count: Int(($0.seconds * 48_000).rounded())) }
    }

    /// Three silences of 1.5 s, 1 s, and 2 s: 48 000 ..< 120 000, 144 000 ..< 192 000, and
    /// 216 000 ..< 312 000. The session ends at 336 000.
    static func threeSilences() -> [Float] {
        sine([(1, -20), (1.5, -.infinity), (0.5, -20), (1, -.infinity), (0.5, -20), (2, -.infinity), (0.5, -20)])
    }

    static let threeRows: [Range<Frames>] = [48_000..<120_000, 144_000..<192_000, 216_000..<312_000]

    /// A voice on t1 with a 2 s silence at 48 000 ..< 144 000, and music on t2 for the whole 4 s.
    static func voiceAndMusic() -> [[Float]] {
        [sine([(1, -20), (2, -.infinity), (1, -20)]), sine([(4, -20)])]
    }

    static func scan(
        _ studio: Studio, tracks: Set<TrackID>? = nil, threshold: Gain = threshold, minLength: Frames = 48_000
    ) async throws(StudioError) -> SilenceScan {
        try await studio.scanSilences(tracks: tracks, range: nil, threshold: threshold, minLength: minLength)
    }

    static func sessionBytes(_ package: MixPackage) throws -> Data {
        try Data(contentsOf: package.url.appending(path: "session.xml"))
    }

    /// C1: the rows are the silences of the 0062 rule on the mix of the tracks, with no cut and
    /// no change of the session.
    @Test func theScanGivesTheSilencesOfTheRead() async throws {
        let package = try Self.package([Self.threeSilences()])
        let studio = try await Studio.open(package.url)
        defer { withExtendedLifetime(package) {} }
        let before = studio.session

        let scan = try await Self.scan(studio)

        #expect(scan.silences == Self.threeRows, "\(scan.silences)")
        let read = try mixLevels(
            of: nil, in: before, package: package.url, range: 0..<336_000, silence: Self.threshold
        ).series.silences(threshold: Self.threshold, minLength: 48_000, in: 0..<336_000)
        #expect(scan.silences == read, "the read: \(read)")
        #expect(scan.tracks == ["t1"] && scan.range == 0..<336_000 && scan.outside == nil, "\(scan.tracks)")
        #expect(scan.quietest == nil, "a scan with rows has a quietest level")
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo && studio.transport == .idle, "the scan changed the studio")
    }

    /// C2: with the 1 s minimum, a silence of 20 windows is a row and one of 19 windows is not.
    @Test func aSilenceOfTheMinimumIsARowAndOneWindowLessIsNot() async throws {
        let samples = Self.sine([(1, -20), (1, -.infinity), (0.5, -20), (0.95, -.infinity), (0.5, -20)])
        let package = try Self.package([samples])
        defer { withExtendedLifetime(package) {} }
        let studio = try await Studio.open(package.url)
        let scan = try await Self.scan(studio)
        #expect(scan.silences == [48_000..<96_000], "\(scan.silences)")
    }

    /// C3: a window at -40.04 dBFS (-40.0 at one decimal) is silent, and a window at -39.9 dBFS
    /// splits a silence into two parts under the minimum. The exact threshold frame is in
    /// `LevelSeriesTests.aWindowAtTheThresholdIsSilent`: a float sum of audio cannot hit it exactly.
    @Test func theThresholdIsTheSilenceRuleOfTheRead() async throws {
        let samples = Self.dc([(0.5, -20), (1, -40.04), (0.5, -20), (0.5, -60), (0.05, -39.9), (0.5, -60), (0.5, -20)])
        let package = try Self.package([samples])
        defer { withExtendedLifetime(package) {} }
        let studio = try await Studio.open(package.url)
        let scan = try await Self.scan(studio)
        #expect(scan.silences == [24_000..<72_000], "\(scan.silences)")
    }

    /// C4: the default scan reads every track with mute ignored, so the muted music fills the
    /// voice silence. With t1 only, the silence is a row, and the levels of t2 over the frames of
    /// the scan series come with it, with mute ignored.
    @Test func theScanReadsTheCheckedTracksAndIgnoresMute() async throws {
        let package = try Self.package(Self.voiceAndMusic())
        try package.session.setMuted(true, tracks: ["t2"])
        try package.session.write(to: package.url)
        let studio = try await Studio.open(package.url)
        defer { withExtendedLifetime(package) {} }

        let all = try await Self.scan(studio)
        #expect(all.silences.isEmpty && all.outside == nil && all.tracks == ["t1", "t2"], "\(all.silences)")

        let voice = try await Self.scan(studio, tracks: ["t1"])
        #expect(voice.silences == [48_000..<144_000] && voice.tracks == ["t1"], "\(voice.silences)")
        let outside = try #require(voice.outside, "no levels of the track outside the scan")
        #expect(outside.range == 0..<192_000, "\(outside.range)")
        #expect(outside.runs(over: Self.threshold) == [0..<192_000], "\(outside.runs(over: Self.threshold))")
    }

    /// C6: the scan holds `.findingSilences`, so an edit and a take start are busy; the banner
    /// Cancel ends it with no row, no change, no save, and no undo entry.
    @Test func theScanHoldsItsTransportAndCancelChangesNothing() async throws {
        let package = try Self.package([Self.threeSilences()])
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
        let studio = try await Studio.open(package.url)
        defer { withExtendedLifetime(package) {} }
        studio.environment = .test(TestHAL([StopLevelTests.mic]))
        let (before, bytes) = (studio.session, try Self.sessionBytes(package))
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }

        let scanning = Task { try await Self.scan(studio) }
        await gate.entered()
        #expect(studio.transport == .findingSilences, "scan hold: \(studio.transport)")
        #expect(throws: StudioError.busy) { try studio.edit(ripple: false) { _ throws(SessionError) in } }
        await #expect(throws: StudioError.busy) {
            try await studio.startTake(
                armed: ["t1"], devices: [StopLevelTests.mic], playhead: 0, hostTimeNanos: takeStart)
        }
        studio.cancelReadJob()
        gate.open()
        let result = await scanning.result

        switch result {
        case .success(let scan): Issue.record("a cancelled scan gave rows: \(scan.silences)")
        case .failure(let error): #expect(error as? StudioError == .silencesCancelled, "\(error)")
        }
        #expect(studio.transport == .idle && studio.session.recording == nil, "after the cancel: \(studio.transport)")
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo, "a cancelled scan changed the session")
        #expect(try Self.sessionBytes(package) == bytes, "a cancelled scan saved")
    }

    /// C7: a missing file on a scanned track, or on a track outside the scan, refuses the scan
    /// with its fault.
    @Test(arguments: [(nil, "f1"), (["t1"], "f2")] as [(Set<TrackID>?, FileID)])
    func aMissingFileRefusesTheScan(tracks: Set<TrackID>?, missing: FileID) async throws {
        let package = try Self.package(Self.voiceAndMusic())
        let studio = try await Studio.open(package.url)
        defer { withExtendedLifetime(package) {} }
        let before = studio.session
        try FileManager.default.removeItem(
            at: package.url.appending(path: "\(clipsFolderName)/\(missing.rawValue).wav"))

        await #expect(throws: StudioError.silencesFaults([missing: .missing])) {
            try await Self.scan(studio, tracks: tracks)
        }
        let unchanged = studio.session == before
        #expect(unchanged && studio.transport == .idle, "after the refusal: \(studio.transport)")
    }

    /// C8: 1200 silences at 8 kHz (window 400 frames) give 1200 rows; the 1000-line cap of the
    /// `silences` text does not apply.
    @Test func theListHasNoLineCap() async throws {
        let pair: [(seconds: Double, dBFS: Double)] = [(0.05, -20), (0.05, -.infinity)]
        let parts = Array(repeating: pair, count: 1200).flatMap { $0 }
        let package = try Self.package([Self.sine(parts + [(0.05, -20)], rate: 8_000)], rate: 8_000)
        let studio = try await Studio.open(package.url)
        defer { withExtendedLifetime(package) {} }

        let scan = try await Self.scan(studio, minLength: 400)

        let expected = (0..<1200).map { Frames($0 * 800 + 400)..<Frames($0 * 800 + 800) }
        let same = scan.silences == expected
        #expect(same, "\(scan.silences.count) rows, first \(String(describing: scan.silences.first))")
    }

    /// C31: a -38.0 dBFS floor with one -50.0 dBFS window has no silence at -40 dBFS. The least
    /// threshold that gives one is the floor; -37.9 dBFS gives a row.
    @Test func anEmptyScanGivesTheQuietestLevel() async throws {
        let package = try Self.package([Self.dc([(1, -38), (0.05, -50), (1, -38)])])
        let studio = try await Studio.open(package.url)
        defer { withExtendedLifetime(package) {} }

        let empty = try await Self.scan(studio)
        let quietest = try #require(empty.quietest, "no quietest level")
        let dB = 10 * log10(Double(quietest.meanSquare))
        #expect(empty.silences.isEmpty && abs(dB + 38) < 0.1, "\(empty.silences), \(dB) dBFS")

        let found = try await Self.scan(studio, threshold: Gain(dB: -37.9)!)
        #expect(found.silences.count == 1 && found.quietest == nil, "\(found.silences)")
    }
}
