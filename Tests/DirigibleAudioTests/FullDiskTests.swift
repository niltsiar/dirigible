import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Packages on a disk image: a full disk (criterion 18), a volume that goes away during a read,
/// and a read-only volume. Slow: each test makes and attaches a disk image. The disk work runs
/// off the main actor: under load it takes seconds, and the `@MainActor` record tests wait for
/// the main actor (the tdd skill). Only the two tests that open a Studio are `@MainActor`.
struct FullDiskTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    @MainActor func aTakeOnAFullDiskStaysPendingUntilARetryAfterSpaceIsFree() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleFull", image.path)
            try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { try? Self.hdiutil("detach", volume.path, "-force") }

        let package = volume.appending(path: "Show.dirigible")
        let caf = package.appending(path: "Capture/take1-1-1.caf")
        let filler = volume.appending(path: "filler")
        let before = LockedBox<Data>()
        try await offMainActor {
            // 10 s of mono: a 1.92 MB CAF and a 1.44 MB WAV.
            let source = try TakePackage()
            try source.segment(samples: sine(seconds: 10, rate: 48_000))
            try FileManager.default.copyItem(at: source.url, to: package)
            before.value = try Data(contentsOf: caf)
            try Self.fill(volume, leaving: 400_000, with: filler)
        }
        let cafBytes = try #require(before.value)

        let studio = try await Studio.open(package)

        #expect(studio.pendingTake?.take == 1)
        guard case .finalize(.writeFailed(file: "Clips/take1-1-1.wav", _)) = studio.takeError else {
            Issue.record("Expected a WAV write error, got \(String(describing: studio.takeError))")
            return
        }
        #expect(try Data(contentsOf: caf) == cafBytes)

        try FileManager.default.removeItem(at: filler)
        try await studio.retryFinalize()

        #expect(studio.pendingTake == nil)
        #expect(studio.session.track("t1")?.clips.first?.length == 480_000)
    }

    /// A placement on a volume with 400 KB free (a 1.44 MB WAV) throws the write error, keeps the
    /// session, and leaves no WAV and no temporary WAV (decision 0021, plan gate 1 item 3). The disk
    /// check reads 100 GB through the test seam, so the WAV write itself fails.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    @MainActor func aPlacementOnAFullImageLeavesNoPartialWAV() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "place.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigiblePlace", image.path)
            try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = volume.appending(path: "Show.dirigible")
        try await offMainActor {
            // 10 s of mono: a 1.92 MB CAF and a 1.44 MB WAV. The take ends, then its clip, its pool
            // file, and its WAV go.
            let source = try TakePackage()
            try source.segment(samples: sine(seconds: 10, rate: 48_000))
            var session = try finalizeTake(of: source.read(), in: source.url)
            try session.clear(.zero..<Frames.limit, on: ["t1"])
            try session.removeFile("take1-1-1")
            try session.write(to: source.url)
            try FileManager.default.removeItem(at: source.url.appending(path: "Clips/take1-1-1.wav"))
            try FileManager.default.copyItem(at: source.url, to: package)
            try Self.fill(volume, leaving: 400_000, with: volume.appending(path: "filler"))
        }
        let studio = try await Studio.open(package)
        studio.environment = .test(TestHAL([]))
        let session = studio.session

        let error = await #expect(throws: StudioError.self) { try await studio.place(SegmentName(stem: "take1-1-1")!) }

        guard case .finalize(.writeFailed(file: "Clips/take1-1-1.wav", _)) = error else {
            Issue.record("Expected a WAV write error, got \(String(describing: error))")
            return
        }
        #expect(studio.session == session)
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.appending(path: "Clips").path) == [])
    }

    /// The real shape of an I/O fault (probe 2026-09-24, probe-read-error.swift): the volume goes
    /// away before block 1, and AVAudioFile throws -40 with no errno. It is an unreadable segment
    /// (decision 0021), not a bad file, so the take stays pending unless the user leaves it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aCAFReadErrorWithNoErrnoIsTakeWide() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "gone.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleGone", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        let package = volume.appending(path: "Show.dirigible")
        // The fault detaches the volume, so this detach can fail.
        defer { Self.run(["detach", volume.path, "-force"]) }
        // 10 s of mono: 8 blocks of 65,536 frames.
        let source = try TakePackage()
        try source.segment(samples: sine(seconds: 10, rate: 48_000))
        try FileManager.default.copyItem(at: source.url, to: package)
        let session = try Session(contentsOf: package)
        let detach = ReadFault(stem: "take1-1-1", block: 1) { try Self.hdiutil("detach", volume.path, "-force") }

        #expect(
            throws: FinalizeError.segmentUnreadable(
                SegmentName(stem: "take1-1-1")!, file: "Capture/take1-1-1.caf", errno: EIO)
        ) {
            try finalizeTake(of: session, in: package, readFault: detach)
        }
    }

    /// Decision 0012: a read-only volume opens without a lock, with and without a `.lock` file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    @MainActor func aPackageOnAReadOnlyVolumeOpensUnlocked() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "readonly.dmg")
        let volume = folder.url.appending(path: "volume")
        try await offMainActor {
            try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleReadOnly", image.path)
            try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        }
        defer { Self.run(["detach", volume.path, "-force"]) }
        let names = ["New.dirigible", "Opened.dirigible"]
        try await offMainActor {
            for name in names { try Session(sampleRate: 48_000).write(to: volume.appending(path: name)) }
            try Data().write(to: volume.appending(path: "Opened.dirigible/.lock"))
            try Self.hdiutil("detach", volume.path)
            try Self.hdiutil("attach", image.path, "-readonly", "-nobrowse", "-mountpoint", volume.path)
        }

        for name in names {
            let studio = try await Studio.open(volume.appending(path: name))
            #expect(studio.session == Session(sampleRate: 48_000), "\(name)")
        }
    }

    /// A 10 s stereo render (3.84 MB) to a volume with 400 KB free throws and leaves no output
    /// and no temporary file (plan gate 1 item 5).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRenderOnAFullDiskLeavesNoOutput() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleRender", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = try RenderMixTests.package()
        try Self.fill(volume, leaving: 400_000, with: volume.appending(path: "filler"))
        let out = volume.appending(path: "mix.caf")

        #expect(throws: ExportError.self) {
            try exportMix(
                package.session, source: #require(ExportSource(range: 0..<480_000)), options: .render, to: out,
                package: { package.url })
        }
        #expect(try Self.visibleFiles(volume) == ["filler"])
    }

    /// exFAT gives ENOTSUP for `renamex_np(RENAME_EXCL)` (probe X1), so the render claims the
    /// path and renames over the claim. A second render to that path changes nothing. An exFAT
    /// volume name has 11 characters or fewer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRenderToExFATClaimsAndRenames() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "exfat.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "ExFAT", "-volname", "DirExFAT", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = try RenderMixTests.package()
        let out = volume.appending(path: "mix.caf")

        _ = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<9600)), options: .render, to: out,
            package: { package.url })
        let bytes = try Data(contentsOf: out)
        for (a, b) in zip(try RenderMixTests.read(out), try package.mix(0..<9600)) { #expect(maxError(a, b) <= 1e-6) }
        #expect(try Self.visibleFiles(volume) == ["mix.caf"])

        #expect(throws: ExportError.exists) {
            try exportMix(
                package.session, source: #require(ExportSource(range: 0..<4800)), options: .render, to: out,
                package: { package.url })
        }
        #expect(try Data(contentsOf: out) == bytes)
        #expect(try Self.visibleFiles(volume) == ["mix.caf"])
    }

    /// On exFAT a new target lands through the claim, and a confirmed target is replaced
    /// (export run criterion 14).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func exportLandsOnExFAT() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "exfat.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "ExFAT", "-volname", "DirExport", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = try ExportTests.package([ExportTests.tone(frames: 96_000)])
        let out = volume.appending(path: "mix.wav")
        let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)

        _ = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<48_000)), options: options, to: out,
            package: { package.url })
        #expect(try ExportTests.read(out).length == 48_000)
        _ = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<96_000)), options: options, to: out,
            replacing: ConfirmedFile(at: out), package: { package.url })

        #expect(try ExportTests.read(out).length == 96_000)
        #expect(try Self.visibleFiles(volume) == ["mix.wav"])
    }

    /// A session with a transcript saves on exFAT, which gives ENOTSUP for `RENAME_EXCL` (0016
    /// X1): each transcript file lands through a plain rename (decision 0055, run transcript-1
    /// criteria T13 and T22).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aTranscriptSessionSavesOnExFAT() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "exfat.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "ExFAT", "-volname", "DirWords", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = volume.appending(path: "E.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.addFile(AudioFile(id: "h", path: "h.wav", layout: .mono, length: 480_000))
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 480_000), on: "host")
        try session.write(to: package)
        let words = #"{"words":[{"word":"Hello","start":1,"end":1.5},{"word":"again","start":2,"end":2.5}]}"#
        try session.importTranscript(TranscriptFile(data: Data(words.utf8)), name: "t.json", track: "host", at: 0)

        let lock = try PackageLock(package)
        try withExtendedLifetime(lock) {
            try session.write(under: lock)
            let late = #"{"words":[{"word":"later","start":5,"end":5.5}]}"#
            try session.importTranscript(TranscriptFile(data: Data(late.utf8)), name: "u.json", track: "host", at: 0)
            try session.write(under: lock)
        }
        #expect(try Session(contentsOf: package).words().map(\.text) == ["Hello", "again", "later"])
        let files = try FileManager.default.contentsOfDirectory(atPath: package.appending(path: "Transcripts").path)
        #expect(files.filter { !$0.hasPrefix(".") }.count == 2, "\(files)")
    }

    /// A 10 s stereo WAV 24 export (2.88 MB) to a volume with 400 KB free throws `.diskFull`
    /// and keeps the old target (export run criterion 15).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFullDiskGivesDiskFullAndKeepsTheTarget() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleExport", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = try ExportTests.package([ExportTests.tone(frames: 480_000)])
        let out = volume.appending(path: "mix.wav")
        try Data("old".utf8).write(to: out)
        try Self.fill(volume, leaving: 400_000, with: volume.appending(path: "filler"))

        #expect(throws: ExportError.diskFull) {
            try exportMix(
                package.session, source: #require(ExportSource(range: 0..<480_000)),
                options: ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session), to: out,
                replacing: ConfirmedFile(at: out), package: { package.url })
        }
        #expect(try Data(contentsOf: out) == Data("old".utf8))
        #expect(try Self.visibleFiles(volume) == ["filler", "mix.wav"])
    }

    /// A 60 s stereo MP3 at 256 kbit/s (about 1.9 MB) to a volume with 400 KB free throws
    /// `.diskFull` and leaves no file (MP3 run criterion 12).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFullDiskGivesDiskFullForAnMP3() throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appending(path: "full.dmg")
        let volume = folder.url.appending(path: "volume")
        try Self.hdiutil("create", "-size", "20m", "-fs", "HFS+", "-volname", "DirigibleMP3", image.path)
        try Self.hdiutil("attach", image.path, "-nobrowse", "-mountpoint", volume.path)
        defer { Self.run(["detach", volume.path, "-force"]) }
        let package = try ExportTests.package([ExportTests.noise(frames: 2_880_000, seed: 9)])
        let out = volume.appending(path: "mix.mp3")
        try Self.fill(volume, leaving: 400_000, with: volume.appending(path: "filler"))

        #expect(throws: ExportError.diskFull, "a full disk gives diskFull for an MP3") {
            try exportMix(
                package.session, source: #require(ExportSource(range: 0..<2_880_000)),
                options: ExportOptions(format: .mp3(.k256), layout: .stereo, rate: .session), to: out,
                package: { package.url })
        }
        #expect(try Self.visibleFiles(volume) == ["filler"])
    }

    /// The files in `volume` with no leading dot (the system adds some), and every `.tmp` file.
    static func visibleFiles(_ volume: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: volume.path).filter {
            !$0.hasPrefix(".") || $0.hasSuffix(".tmp")
        }
        .sorted()
    }

    /// Writes zeros to `file` until the volume has about `bytes` free.
    static func fill(_ volume: URL, leaving bytes: Int, with file: URL) throws {
        let free = try #require(
            try FileManager.default.attributesOfFileSystem(forPath: volume.path)[.systemFreeSize] as? Int)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var left = free - bytes
        let chunk = Data(count: 1 << 20)
        while left > 0 {
            try handle.write(contentsOf: chunk.prefix(left))
            left -= chunk.count
        }
        try handle.synchronize()
    }

    static func hdiutil(_ arguments: String...) throws {
        try #require(run(arguments) == 0, "hdiutil \(arguments.joined(separator: " ")) failed")
    }

    /// Runs hdiutil and returns its exit status.
    @discardableResult
    static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
