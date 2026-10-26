import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// `Studio.splitStereo` (decision 0053): one undo entry that keeps the WAVs, the refusals before
/// any write, the level, and the capture of the pair files after a prune.
@MainActor
struct StudioSplitTests {
    /// The split fixture of 30 s with clip c1 at 20 s for 5 s, saved. `extra` changes the package
    /// before the save.
    @concurrent nonisolated static func make(
        _ extra: @Sendable (MixPackage) throws -> Void = { _ in }
    ) async throws -> sending SplitFixture {
        let fixture = try SplitFixture(seconds: 30, clips: [("c1", 960_000, 240_000)])
        try extra(fixture.package)
        try fixture.package.session.write(to: fixture.package.url)
        return fixture
    }

    func open(_ package: MixPackage) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        return studio
    }

    func xml(_ package: MixPackage) -> Data? {
        FileManager.default.contents(atPath: package.url.appending(path: "session.xml").path)
    }

    /// C7: one undo entry. Undo restores the source clip and removes the new tracks, the WAVs stay,
    /// and Redo writes nothing.
    @Test func undoKeepsFiles() async throws {
        let fixture = try await Self.make()
        let studio = try await open(fixture.package)
        let before = studio.session

        let parts = try await studio.splitStereo(["c1"], names: ("L", "R")) { _ in }

        let saved = try Session(contentsOf: fixture.package.url)
        #expect(parts.count == 1 && saved == studio.session, "session.xml has the split")
        #expect(studio.session.tracks.map(\.name) == ["Host", "Host L", "Host R"])
        let files = ["f1 L.wav", "f1 R.wav", "f1.wav"]
        #expect(try fixture.listing() == files)
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "Undo restores the source clip")
        #expect(try fixture.listing() == files, "the WAVs stay after Undo")
        try studio.redo()
        let afterRedo = try fixture.listing()
        #expect(studio.session == saved && afterRedo == files, "Redo writes nothing")
        await studio.settle()
    }

    /// C7: a split during a take is busy and writes nothing; the take goes on.
    @Test func busyDuringTake() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            try package.addFile("s1", channels: [ramp(frames: 48_000), ramp(frames: 48_000, channel: 1)])
            try package.addTrack("t2", layout: .stereo, clip: "s", file: "s1", start: 0, offset: 0, length: 48_000)
        }
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal)
        let clips = fixture.package.url.appending(path: clipsFolderName)
        let before = try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted()
        _ = try await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)

        await #expect(throws: StudioError.busy) { try await studio.splitStereo(["s"], names: ("L", "R")) { _ in } }

        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() == before)
        #expect(studio.transport == .recording(take: 1), "the take goes on")
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.25, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()
        try await studio.stopRecording()
    }

    /// C7: a source clip with no WAV refuses and writes nothing.
    @Test func missingSourceRefused() async throws {
        let fixture = try await Self.make()
        try FileManager.default.removeItem(at: fixture.package.url.appending(path: "\(clipsFolderName)/f1.wav"))
        let studio = try await open(fixture.package)
        let before = (studio.session, xml(fixture.package))

        await #expect(throws: StudioError.split(.sourceMissing(file: "f1.wav"))) {
            try await studio.splitStereo(["c1"], names: ("L", "R")) { _ in }
        }

        #expect(studio.session == before.0 && xml(fixture.package) == before.1 && !studio.canUndo)
        #expect(try fixture.listing() == [] && studio.transport == .idle)
        await studio.settle()
    }

    /// C7: a transcript that did not load refuses before the first write.
    @Test func transcriptUnloadedRefused() async throws {
        let fixture = try await Self.make { package in
            let words = #"{"words":[{"word":"one","start":20.5,"end":20.75}]}"#
            try package.session.importTranscript(
                TranscriptFile(data: Data(words.utf8)), name: "t", track: "t1", at: 0)
        }
        try FileManager.default.removeItem(at: fixture.package.url.appending(path: transcriptsFolderName))
        let studio = try await open(fixture.package)
        try #require(studio.session.transcriptsNotLoaded.map(\.id) == [TranscriptID(1)])
        let before = (studio.session, xml(fixture.package), try fixture.hashes())

        await #expect(throws: StudioError.split(.session(.transcriptNotLoaded([TranscriptID(1)])))) {
            try await studio.splitStereo(["c1"], names: ("L", "R")) { _ in }
        }

        #expect(studio.session == before.0 && xml(fixture.package) == before.1 && !studio.canUndo)
        #expect(try fixture.hashes() == before.2, "no new file and no temp file")
        await studio.settle()
    }

    /// C9: a voice on the left only keeps its left channel in a stereo export, and the mono export
    /// rises by 6.02 dB (0.5 L before, L after).
    @Test func levelAfterSplit() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            let tone = ExportTests.tone(frames: 480_000)
            try package.addFile("s1", channels: [tone, [Float](repeating: 0, count: 480_000)])
            try package.addTrack("t2", layout: .stereo, clip: "s", file: "s1", start: 0, offset: 0, length: 480_000)
            try package.session.removeTrack("t1")
        }
        let studio = try await fixture.open()
        let folder = fixture.package.folder.url
        func export(_ name: String, _ layout: ChannelLayout) async throws -> [[Float]] {
            let url = folder.appending(path: name)
            let options = ExportOptions(format: .wav(.bits24), layout: layout, rate: .session)
            _ = try await studio.export(fixture.source, options, to: url, replacing: nil)
            return try ExportTests.read(url).channels
        }
        let (stereoBefore, monoBefore) = (try await export("s1.wav", .stereo), try await export("m1.wav", .mono))

        _ = try await studio.splitStereo(["s"], names: ("L", "R")) { _ in }

        let (stereoAfter, monoAfter) = (try await export("s2.wav", .stereo), try await export("m2.wav", .mono))
        #expect(maxError(stereoBefore[0], stereoAfter[0]) <= 1e-6, "the left channel is the same")
        let rise = ExportTests.rmsDB(monoAfter[0]) - ExportTests.rmsDB(monoBefore[0])
        #expect(abs(rise - 6.02) <= 0.01, "the mono export rises \(rise) dB")
        await studio.settle()
    }

    /// A saved package with the stereo file "f1" of take 1 (capture "take1-1-1", with its segment in
    /// `Capture/`) and clip c1 at 20 s for 5 s on the stereo track "t1".
    @concurrent nonisolated static func takePackage(_ segment: SegmentName) async throws -> sending MixPackage {
        let package = try MixPackage()
        let frames = 1_440_000
        try package.addFile("f1", channels: [ramp(frames: frames), ramp(frames: frames, channel: 1)])
        try package.session.removeFile("f1")
        try package.session.addCapture(
            Capture(
                id: CaptureID(segment.stem), deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 1, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try package.session.addFile(
            AudioFile(
                id: "f1", path: "f1.wav", layout: .stereo, length: Frames(frames), capture: CaptureID(segment.stem)))
        try package.addTrack(
            "t1", layout: .stereo, clip: "c1", file: "f1", start: 960_000, offset: 960_000, length: 240_000)
        let capture = package.url.appending(path: captureFolderName)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = TakePackage.header(channels: 2)
        let writer = try SegmentWriter(folder: capture, name: segment, header: header)
        for checkpoint in TakePackage.checkpoints(frames: 4_800, header: header) { try writer.checkpoint(checkpoint) }
        let samples = sine(seconds: 0.1, rate: 48_000, channels: 2)
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: 4_800) }
        try writer.close()
        try package.session.write(to: package.url)
        return package
    }

    /// C3b: the pair files keep the capture of the take, so after a prune of the source WAV the
    /// take is not offered for Place.
    @Test func pruneAfterSplitKeepsTakePlaced() async throws {
        let segment = SegmentName(take: 1, arm: 1, segment: 1)
        let package = try await Self.takePackage(segment)
        var first: Studio? = try await open(package)
        _ = try await first?.splitStereo(["c1"], names: ("L", "R")) { _ in }
        await first?.settle()
        first = nil  // The close: the next open takes the lock.
        // The backup of the save before the split names f1, so the prune keeps f1 until it goes.
        try FileManager.default.removeItem(at: package.url.appending(path: backupsFolderName))
        let studio = try await open(package)
        #expect(segmentsWithAudio(in: package.url) == [segment])
        #expect(unplacedSegments([segment], session: Session(sampleRate: 48_000)) == [segment], "control")

        let scan = try await studio.unusedFiles()
        try #require(scan.items.map(\.path) == ["f1.wav"])
        let report = try await studio.removeUnusedFiles(scan)
        defer { for moved in report.moved { try? FileManager.default.removeItem(at: moved.trashURL) } }

        #expect(report.moved.map(\.item.path) == ["f1.wav"] && studio.session.files["f1"] == nil)
        #expect(studio.unplacedSegments == [], "the take is not offered for Place")
        await studio.settle()
    }
}
