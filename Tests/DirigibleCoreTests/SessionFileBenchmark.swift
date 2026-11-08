import Foundation
import Testing

@testable import DirigibleCore

/// Leveler C34: the size, the open, the save, and the peak memory of a ridden session, in an
/// optimized build (`make bench FILTER=SessionFileBenchmark`). The ride list has 18 954 points on a
/// 2 h clip, as the decimated ride of a real 2 h speech take, with gains on the 0.01 dB grid. In
/// debug a miss only prints a report line.
struct SessionFileBenchmark {
    static let twoHours = 345_600_000
    static let open = Duration.milliseconds(100)
    static let save = Duration.milliseconds(200)
    static let peakBytes = 256 << 20

    /// The ride list of clip `index`: 18 954 points on a 2 h file, a seeded walk of the gain in
    /// `-6...6` dB, shifted by 0.01 dB for each index, so the lists of two clips differ.
    static func ride(_ index: Int) -> GainEnvelope {
        var random = SplitMix(seed: 41)
        var dB = 0
        let points = (0..<18_954).map { step in
            dB = min(600, max(-600, dB + Int.random(in: -40...40, using: &random)))
            return (2_400 + step * 18_233, Double(dB + index) / 100)
        }
        return envelope(points)
    }

    /// `clips` 2 h clips, each on its own file and track, each split into `parts` parts, with a
    /// ride when `ridden`.
    static func fixture(clips: Int, parts: Int, ridden: Bool) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for index in 0..<clips {
            let (file, track) = (FileID("f\(index)"), TrackID("t\(index)"))
            try session.addFile(AudioFile(id: file, path: "f\(index).wav", layout: .mono, length: Frames(twoHours)))
            try session.addTrack(track, name: "Track \(index)", layout: .mono)
            let id = ClipID("c\(index)")
            try session.place(Clip(id: id, file: file, start: 0, offset: 0, length: Frames(twoHours)), on: track)
            if ridden { try session.setRides([id: ride(index)]) }
            let cut = twoHours / parts
            try session.splitClips(at: (1..<parts).map { Frames($0 * cut) }, on: [track])
        }
        return session
    }

    /// Fixture 5: each part of `session` moves to a rendered file of its run.
    static func repointed(_ session: Session) throws -> Session {
        var session = session
        let clips = session.tracks.flatMap { $0.clips.map(\.id) }
        let runs = try session.clipRuns(of: clips).map {
            RenderedRun(run: $0, stem: "\($0.file) NR", treatment: Treatment(.noise(.standard)), addedGain: .zero)
        }
        _ = try session.repoint(runs)
        return session
    }

    static func median(_ times: [Duration]) -> Duration { times.sorted()[times.count / 2] }

    /// The median of 5 opens with `Session(contentsOf:)`, and of 5 saves with `write(under:)` and
    /// a backup due at each save (no backup in `Backups/`).
    static func times(_ session: Session) throws -> (size: Int, open: Duration, save: Duration) {
        let package = FileManager.default.temporaryDirectory.appending(path: "RideBench-\(UUID())/R.dirigible")
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        try session.write(to: package)
        let lock = try PackageLock(package)
        var (opens, saves) = ([Duration](), [Duration]())
        for _ in 0..<5 {
            try? FileManager.default.removeItem(at: package.appending(path: "Backups"))
            let save = ContinuousClock.now
            try session.write(under: lock, backups: .standard)
            saves.append(ContinuousClock.now - save)
            let open = ContinuousClock.now
            let read = try Session(contentsOf: package)
            opens.append(ContinuousClock.now - open)
            #expect(read == session)
        }
        #expect(FileManager.default.fileExists(atPath: package.appending(path: "Backups").path), "a backup was due")
        let size = try Data(contentsOf: package.appending(path: "session.xml")).count
        return (size, median(opens), median(saves))
    }

    static func peakResidentBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func ridesOfTwoHoursFitTheLimits() throws {
        let fixtures: [(name: String, clips: Int, parts: Int, repoint: Bool)] = [
            ("1", 1, 200, false), ("2", 2, 1, false), ("3", 6, 1, false), ("4", 6, 200, false), ("5", 6, 200, true),
        ]
        for fixture in fixtures {
            func build(_ ridden: Bool) throws -> Session {
                let session = try Self.fixture(clips: fixture.clips, parts: fixture.parts, ridden: ridden)
                return fixture.repoint ? try Self.repointed(session) : session
            }
            let ridden = try Self.times(try build(true))
            let plain = try Self.times(try build(false))
            print(
                "bench report: C34 fixture \(fixture.name): size \(ridden.size) B, open \(ridden.open), save "
                    + "\(ridden.save); no ride: size \(plain.size) B, open \(plain.open), save \(plain.save); "
                    + "the ride adds open \(ridden.open - plain.open), save \(ridden.save - plain.save)")
            if fixture.clips == 6 {
                expectWithinBudget(ridden.open, Self.open, "C34 fixture \(fixture.name) open \(ridden.open)")
                expectWithinBudget(ridden.save, Self.save, "C34 fixture \(fixture.name) save \(ridden.save)")
            }
            let points = Self.ride(0).points.count * fixture.clips
            #expect(ridden.size - plain.size <= points * 20 + fixture.clips * fixture.parts * 200, "\(ridden.size)")
        }
        let whole = try Self.times(try Self.fixture(clips: 1, parts: 1, ridden: true))
        let split = try Self.times(try Self.fixture(clips: 1, parts: 200, ridden: true))
        #expect(split.size <= whole.size + 199 * 200, "C34 (1): \(split.size) against \(whole.size)")
        let peak = Self.peakResidentBytes()
        print("bench report: C34 peak RSS \(peak >> 20) MB")
        #expect(peak <= Self.peakBytes, "peak RSS \(peak) B")
    }
}
