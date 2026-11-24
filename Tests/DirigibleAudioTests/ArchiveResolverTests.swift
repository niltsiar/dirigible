import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The in-place readers of a pool file open the name that `poolFileName` gives (decision 0072, run
/// criterion C22): on an archived file each reads the FLAC, with the samples of the WAV.
struct ArchiveResolverTests {
    /// What a job of another process does after the resolve and before the open.
    enum Seam: CaseIterable {
        /// The file is archived, and no job runs.
        case none
        /// Both files are there, and the job unlinks the WAV after its rename.
        case unlinkWAV
        /// The file is archived, and the job converts it back.
        case unarchive
    }

    /// C22: Show Clips in Finder on an archived window gives the URL of the FLAC.
    @MainActor @Test func showClipsInFinderGivesTheFLACOfAnArchivedFile() async throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 4_800)])
        try package.addFile("f2", channels: [ramp(frames: 4_800)])
        try package.session.write(to: package.url)
        #expect(try archiveClip(#require(package.session.files["f1"]), in: package.url, rate: 48_000))
        let studio = try await Studio.open(package.url)

        let urls = await studio.clipURLs(["f1", "f2", "gone"])

        #expect(urls.map(\.lastPathComponent) == ["f1.flac", "f2.wav"])
    }

    @Test(arguments: Seam.allCases)
    func aReaderOpensTheOtherNameWhenAJobConvertsTheFile(_ seam: Seam) throws {
        let fixture = try ArchiveFixture()
        let file = try fixture.addWAV("a.wav", seed: 1)
        // A conversion that stops after its rename leaves both files.
        let archived = try archiveClip(
            file, in: fixture.package, rate: ArchiveFixture.rate,
            after: { done, _ in seam != .unlinkWAV || done != .renamed })
        #expect(archived == (seam != .unlinkWAV))

        let opened = try openPoolAudio(file, in: fixture.package) {
            switch seam {
            case .none: break
            case .unlinkWAV: unlink(fixture.url("Clips/a.wav").path)
            case .unarchive: _ = try? unarchiveClip(file, in: fixture.package, rate: ArchiveFixture.rate)
            }
        }
        defer { close(opened.descriptor) }

        #expect(opened.url.lastPathComponent == (seam == .unarchive ? "a.wav" : "a.flac"))
        #expect(opened.file.length == 30_000)
    }

    @Test func aStereoSplitReadsAnArchivedSource() throws {
        let fixture = try SplitFixture(seconds: 1, clips: [("c1", 0, 48_000)])
        let wav = try fixture.split(["c1"]).made.map { try readAudio($0).samples }
        #expect(try archiveClip(#require(fixture.package.session.files["f1"]), in: fixture.package.url, rate: 48_000))

        let flac = try fixture.split(["c1"]).made.map { try readAudio($0).samples }

        #expect(flac.count == 2 && flac == wav)
    }

    @Test func anEffectPreviewReadsAnArchivedSource() throws {
        let fixture = try RenderFixture()
        try fixture.add("f1", [clippedVowel(level: 0.99, seconds: 2)], track: "t1", clips: [("c1", 0, 96_000)])
        let session = fixture.package.session
        let window = try previewWindow(
            of: "c1", among: ["c1"], request: ClipRenderRequest(Treatment(.declip(.standard))), playhead: 0,
            in: session)
        let wav = try renderPreview(window, of: session, in: fixture.package.url, readFault: nil) { false }
        #expect(try archiveClip(#require(session.files["f1"]), in: fixture.package.url, rate: 48_000))

        let flac = try renderPreview(window, of: session, in: fixture.package.url, readFault: nil) { false }

        #expect(flac.result == wav.result && flac.removed == wav.removed)
    }

    @Test func anEffectRenderReadsAnArchivedSource() throws {
        let fixture = try RenderFixture()
        try fixture.add("f1", [clippedVowel(level: 0.99, seconds: 2)], track: "t1", clips: [("c1", 0, 96_000)])
        let session = fixture.package.session
        func render() throws -> [Float] {
            let outcome = try renderClips(
                [(["c1"], Treatment(.declip(.standard)))], of: session, in: fixture.package.url, freeBytes: { .max },
                isDownloaded: { _ in true })
            return try readAudio(#require(outcome.made.first)).samples
        }
        let wav = try render()
        #expect(try archiveClip(#require(session.files["f1"]), in: fixture.package.url, rate: 48_000))

        let flac = try render()

        #expect(!flac.isEmpty && flac == wav)
    }

    @Test func aTranscriptionReadsAnArchivedSource() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 48_000), ramp(frames: 48_000, channel: 1)])
        try package.addTrack("t1", layout: .stereo, clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        let clips = try #require(package.session.track("t1")).clips
        let reader = SpanReader(
            map: SpanMap(clips: clips, session: package.session), session: package.session, package: package.url)
        let wav = try reader.samples(0..<48_000)
        #expect(try archiveClip(#require(package.session.files["f1"]), in: package.url, rate: 48_000))

        let flac = try reader.samples(0..<48_000)

        #expect(!flac.isEmpty && flac == wav)
    }
}
