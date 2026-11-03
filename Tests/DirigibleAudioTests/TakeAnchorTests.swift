import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The take anchor of decision 0021 (criteria 1 to 4, 26, 29): the finalize that ends a take
/// keeps the `Recording` of the take in `Capture/take<n>.anchor`, before the save that removes
/// `<recording>`.
struct TakeAnchorTests {
    let recording = Recording(
        take: 1, playheadFrame: 96_000, takeStartHostTimeNanos: takeStart, armedTracks: ["t1", "t2"])

    /// A pending take 1 on `t1` and `t2` (playhead 96,000) with a closed 2.0 s segment on each.
    func twoTrackPackage() throws -> TakePackage {
        let package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
        return package
    }

    func anchor(_ package: TakePackage, take: Int = 1) -> URL { package.capture.appending(path: "take\(take).anchor") }

    func temporaryFiles(_ package: TakePackage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.capture.path).filter { $0.hasSuffix(".tmp") }
    }

    // MARK: The bytes

    @Test(arguments: [0, 96_000])
    func anAnchorRoundTrips(playhead: Int) throws {
        let recording = Recording(
            take: 3, playheadFrame: Frames(playhead), takeStartHostTimeNanos: takeStart, armedTracks: ["t1", "t2"])

        #expect(try TakeAnchor.decode(TakeAnchor.encode(recording), take: 3) == recording)
    }

    /// P31: the anchor of a pre-roll take is version 2, which the reader of a version 1 build
    /// refuses as newer; a plain take keeps version 1 and its bytes. Only the digit differs.
    @Test func preRollAnchorIsVersion2() throws {
        var preRoll = recording
        preRoll.isPreRoll = true
        let plainBytes = TakeAnchor.encode(recording)
        let preRollBytes = TakeAnchor.encode(preRoll)

        #expect(Array(plainBytes.prefix(8)) == Array("DRGANCH1".utf8))
        #expect(Array(preRollBytes.prefix(8)) == Array("DRGANCH2".utf8))
        #expect(preRollBytes.dropFirst(8) == plainBytes.dropFirst(8))
        #expect(try TakeAnchor.decode(preRollBytes, take: 1) == preRoll)
        #expect(try TakeAnchor.decode(plainBytes, take: 1) == recording)
        var olderReader = ByteReader(Array(preRollBytes))
        #expect(throws: NewerFormat(version: 2)) { try olderReader.magic(Array("DRGANCH1".utf8)) }
    }

    /// The version digit is the one pre-roll mark: digit 2 on the bytes of a plain take reads as a
    /// pre-roll take, and digit 1 on the bytes of a pre-roll take reads as a plain take.
    @Test func theVersionDigitAloneMarksThePreRoll() throws {
        let package = try twoTrackPackage()
        var preRoll = recording
        preRoll.isPreRoll = true
        for (source, digit, expected) in [(recording, "2", preRoll), (preRoll, "1", recording)] {
            try TakeAnchor.encode(source).write(to: anchor(package))
            try setMagicDigit(anchor(package), digit)

            #expect(try TakeAnchor.read(take: 1, in: package.url) == .success(expected), "digit \(digit)")
        }
    }

    /// Every recording that `Session.setRecording` accepts, the reader accepts.
    @Test func aSeededRandomAnchorRoundTrips() throws {
        var random = SeededGenerator(seed: 21)
        let scalars = Array("abcXYZ019-_ .éñ😀\u{7F}\u{FFFD}".unicodeScalars)
        for _ in 0..<200 {
            var session = Session(sampleRate: 48_000)
            var tracks: [TrackID] = []
            for index in 0..<Int.random(in: 1...4, using: &random) {
                let text = (0..<Int.random(in: 0...12, using: &random)).map { _ in
                    String(scalars.randomElement(using: &random)!)
                }
                let id = TrackID("\(index)" + text.joined())
                try session.addTrack(id, name: "Track", layout: .mono)
                tracks.append(id)
            }
            try session.setRecording(
                Recording(
                    take: Int.random(in: Recording.takes, using: &random),
                    playheadFrame: Frames(Int.random(in: 0...Frames.limit.count, using: &random)),
                    takeStartHostTimeNanos: UInt64.random(in: 0...UInt64.max, using: &random), armedTracks: tracks,
                    isPreRoll: Bool.random(using: &random)))
            let recording = try #require(session.recording)

            #expect(try TakeAnchor.decode(TakeAnchor.encode(recording), take: recording.take) == recording)
        }
    }

    enum Damage: String, CaseIterable, CustomTestStringConvertible {
        case badMagic, shortByOne, flippedHashByte, trailingByte, takeZero, takeNotTheName, negativePlayhead
        case controlCharacterInTrackID
        var testDescription: String { rawValue }
    }

    /// The bytes and the take number of the file name for each damaged form.
    func damaged(_ damage: Damage) -> (bytes: Data, take: Int) {
        let good = TakeAnchor.encode(recording)
        var changed = recording
        switch damage {
        case .badMagic: return (Data("X".utf8) + good.dropFirst(), 1)
        case .shortByOne: return (good.dropLast(), 1)
        case .flippedHashByte:
            var bytes = good
            bytes[bytes.count - 1] ^= 0xFF
            return (bytes, 1)
        case .trailingByte: return (good + [0], 1)
        case .takeZero:
            changed.take = 0
            return (TakeAnchor.encode(changed), 0)
        case .takeNotTheName: return (good, 2)
        case .negativePlayhead:
            changed.playheadFrame = Frames(-1)
            return (TakeAnchor.encode(changed), 1)
        case .controlCharacterInTrackID:
            changed.armedTracks = ["t1", "t\u{1}"]
            return (TakeAnchor.encode(changed), 1)
        }
    }

    @Test(arguments: Damage.allCases)
    func theReaderRefusesADamagedAnchor(damage: Damage) throws {
        let (bytes, take) = damaged(damage)

        #expect(try TakeAnchor.decode(bytes, take: take) == nil)
    }

    /// Decision 0024 P9: the magic of version 1 is "DRGANCH1".
    @Test func theWriterStampsVersion1() {
        #expect(TakeAnchor.encode(recording).prefix(8) == Data("DRGANCH1".utf8))
    }

    /// Decision 0024 P3 and P9: digit 3 is a newer anchor; digit 0 and a byte that is not a
    /// digit are damaged.
    @Test func aNewerAnchorIsNewer() throws {
        let package = try twoTrackPackage()
        for (digit, expected) in [("3", .failure(NewerFormat(version: 3))), ("0", nil), ("X", nil)]
            as [(String, Result<Recording, NewerFormat>?)]
        {
            try TakeAnchor.encode(recording).write(to: anchor(package))
            try setMagicDigit(anchor(package), digit)

            #expect(try TakeAnchor.read(take: 1, in: package.url) == expected, "digit \(digit)")
        }
    }

    /// Decision 0024 P4: the finalize of a take whose anchor a newer build wrote places the
    /// segments from `<recording>`, ends the take, and keeps the anchor bytes.
    @Test func aFinalizeKeepsANewerAnchor() async throws {
        let package = try twoTrackPackage()
        try TakeAnchor.encode(recording).write(to: anchor(package))
        try setMagicDigit(anchor(package), "3")
        let bytes = try Data(contentsOf: anchor(package))

        let outcome = await completeTake(of: try package.read(), lock: try PackageLock(package.url))

        #expect(outcome.error == nil)
        #expect(try package.read().recording == nil)
        #expect(try package.read().tracks.map { $0.clips.map(\.id.rawValue) } == [["take1-1-1"], ["take1-2-1"]])
        #expect(try Data(contentsOf: anchor(package)) == bytes)
        #expect(try temporaryFiles(package) == [])
    }

    /// Decision 0024 P4: an anchor that does not read is not written over. The take stays
    /// pending, and no WAV is written before the fault.
    @Test func aFinalizeWithAnUnreadableAnchorStaysPending() async throws {
        let package = try twoTrackPackage()
        try TakeAnchor.encode(recording).write(to: anchor(package))
        try setMagicDigit(anchor(package), "3")
        let bytes = try Data(contentsOf: anchor(package))
        chmod(anchor(package).path, 0o000)

        let outcome = await completeTake(of: try package.read(), lock: try PackageLock(package.url))

        chmod(anchor(package).path, 0o644)
        #expect(outcome.error == .finalize(.readFailed(file: "Capture/take1.anchor", errno: EACCES)))
        #expect(try package.read().recording == recording)
        #expect(try Data(contentsOf: anchor(package)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: package.url.appending(path: "Clips/take1-1-1.wav").path))
    }

    // MARK: The file

    /// Criterion 1, the stop path: `startTake` with the test HAL, then `stopRecording`.
    @Test @MainActor func aFinishedTakeLeavesItsAnchor() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Show.dirigible")
        let mic = InputDevice(
            uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelsPerBuffer: [1], latency: 48)!
        let box = InputDevice(
            uid: "box", name: "Box", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelsPerBuffer: [1], latency: 0)!
        try await offMainActor {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
            try session.setRoute(Route.device(uid: "box", channels: .mono(1)), track: "t2")
            try session.write(to: url)
        }
        let studio = try await Studio.open(url)
        let hal = TestHAL([mic, box])
        studio.environment = .test(hal)
        _ = try await studio.startTake(
            armed: ["t1", "t2"], devices: [mic, box], playhead: 96_000, hostTimeNanos: takeStart)
        for uid in ["mic", "box"] {
            let input = SyntheticInput(hal, uid)
            input.play(records([sine(seconds: 1, rate: 48_000)], layout: [1], rate: 48_000))
            await input.wait()
        }

        try await studio.stopRecording()

        #expect(studio.pendingTake == nil)
        #expect(try TakeAnchor.read(take: 1, in: url) == .success(recording))
    }

    /// Criterion 1, the open path: the recovery at `Studio.open` ends the take.
    @Test func aFinishedTakeLeavesItsAnchorAtOpen() async throws {
        let package = try twoTrackPackage()

        let studio = try await Studio.open(package.url)

        #expect(await studio.pendingTake == nil)
        #expect(try TakeAnchor.read(take: 1, in: package.url) == .success(recording))
    }

    @Test func aFinalizeThatThrowsLeavesNoAnchor() async throws {
        let package = try twoTrackPackage()
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }

        let outcome = await completeTake(of: try package.read(), lock: try PackageLock(package.url))

        guard case .finalize(.writeFailed) = outcome.error else {
            Issue.record("Expected a write error, got \(String(describing: outcome.error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: anchor(package).path))
        #expect(try package.read().recording == recording)
    }

    /// Criterion 2: the anchor is the only record of the arm-to-track map after the save, so a
    /// fault of its write keeps the take pending, as a `Clips/` fault does. A read-only `Capture/`
    /// refuses the temporary anchor file; the read before it finds no anchor (ENOENT).
    @Test func anAnchorWriteFaultKeepsTheTakePending() async throws {
        let package = try twoTrackPackage()
        chmod(package.capture.path, 0o555)
        defer { chmod(package.capture.path, 0o755) }

        let studio = try await Studio.open(package.url)

        #expect(await studio.takeError == .finalize(.writeFailed(file: "Capture/take1.anchor", status: EACCES)))
        #expect(await studio.pendingTake?.take == 1)
        #expect(try package.read().recording == recording)
        #expect(try temporaryFiles(package) == [])

        chmod(package.capture.path, 0o755)
        try await studio.retryFinalize()

        #expect(await studio.pendingTake == nil)
        #expect(await studio.session.tracks.map(\.clips.count) == [1, 1])
        #expect(try TakeAnchor.read(take: 1, in: package.url) == .success(recording))
    }

    /// Criterion 4: a crash after the anchor rename and before the save. The recovery writes the
    /// same anchor again and gives the session of one run.
    @Test func aRecoveryAfterTheAnchorWriteGivesTheSameResult() async throws {
        let crashed = try twoTrackPackage()
        let control = try twoTrackPackage()
        try TakeAnchor.write(recording, in: crashed.url)
        #expect(try crashed.read().recording == recording)

        let recovered = try await Studio.open(crashed.url)
        let oneRun = try await Studio.open(control.url)

        #expect(await recovered.pendingTake == nil)
        #expect(await recovered.session == oneRun.session)
        #expect(try Data(contentsOf: anchor(crashed)) == Data(contentsOf: anchor(control)))
        #expect(try Data(contentsOf: anchor(crashed)) == TakeAnchor.encode(recording))
    }

    /// Criterion 26: a temporary anchor file that a crash left does not block the next finalize.
    @Test func aLeftoverTemporaryAnchorDoesNotBlockTheFinalize() async throws {
        let package = try twoTrackPackage()
        try Data("junk from a crash".utf8).write(to: package.capture.appending(path: ".take1.anchor.tmp"))

        let outcome = await completeTake(of: try package.read(), lock: try PackageLock(package.url))

        #expect(outcome.error == nil)
        #expect(try package.read().recording == nil)
        #expect(try TakeAnchor.read(take: 1, in: package.url) == .success(recording))
        #expect(try temporaryFiles(package) == [])
    }

    /// Criterion 29: only ENOENT and refused bytes mean "no anchor"; another errno throws.
    @Test func anUnreadableAnchorThrows() throws {
        let package = try twoTrackPackage()
        try TakeAnchor.write(recording, in: package.url)
        try Data("not an anchor".utf8).write(to: anchor(package, take: 3))
        chmod(anchor(package).path, 0o000)
        defer { chmod(anchor(package).path, 0o644) }

        #expect(throws: FinalizeError.readFailed(file: "Capture/take1.anchor", errno: EACCES)) {
            try TakeAnchor.read(take: 1, in: package.url)
        }
        #expect(try TakeAnchor.read(take: 2, in: package.url) == nil)
        #expect(try TakeAnchor.read(take: 3, in: package.url) == nil)
    }
}
