import CryptoKit
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// A package with the stereo file "f1" at 48 kHz, a ramp on each side (`ramp(frames:channel:)`, so
/// a swapped or shifted side shows), and the stereo track "t1" with `clips` (ID, offset, length),
/// each at the timeline frame of its offset.
struct SplitFixture {
    let package: MixPackage
    let frames: Int

    init(seconds: Int, clips: [(ClipID, Int, Int)]) throws {
        package = try MixPackage()
        frames = seconds * 48_000
        try package.addFile("f1", channels: [ramp(frames: frames), ramp(frames: frames, channel: 1)])
        try package.session.addTrack("t1", name: "Host", layout: .stereo)
        for (id, offset, length) in clips {
            try package.session.place(
                Clip(id: id, file: "f1", start: Frames(offset), offset: Frames(offset), length: Frames(length)),
                on: "t1")
        }
    }

    func split(
        _ clips: [ClipID], of session: Session? = nil, freeBytes: Int64 = .max,
        progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }
    ) throws(SplitError) -> (session: Session, parts: [SplitPart], made: [URL]) {
        try splitStereo(
            clips, names: ("L", "R"), of: session ?? package.session, in: package.url, freeBytes: { freeBytes },
            progress: progress, isCancelled: isCancelled)
    }

    /// The names in `Clips/`, temp files too.
    func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: clipsFolderName).path).sorted()
    }

    func has(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: package.url.appending(path: "\(clipsFolderName)/\(name)").path)
    }

    /// The SHA-256 of each item in `Clips/`, temp files too, by name.
    func hashes() throws -> [String: SHA256.Digest] {
        let clips = package.url.appending(path: clipsFolderName)
        var hashes: [String: SHA256.Digest] = [:]
        for name in try listing() {
            hashes[name] = SHA256.hash(
                data: FileManager.default.contents(atPath: clips.appending(path: name).path) ?? Data())
        }
        return hashes
    }

    /// The samples of the WAV of `file` in `session`.
    func samples(_ file: FileID, in session: Session) throws -> [Float] {
        let path = try #require(session.files[file]?.path)
        return try readAudio(package.url.appending(path: "\(clipsFolderName)/\(path)")).samples
    }
}

/// The mono files of a stereo split (decision 0053): the sides, the spans, the stems, the space
/// check, the cleanup of each fault, and the progress.
struct StereoSplitTests {
    /// C4: the left file is channel 0 and the right file channel 1 of the written span, sample for
    /// sample.
    @Test func sidesMatchTheSource() throws {
        let fixture = try SplitFixture(seconds: 30, clips: [("c1", 960_000, 240_000)])

        let (session, parts, _) = try fixture.split(["c1"])

        let part = try #require(parts.first)
        let left = try #require(session.clip(part.left)?.clip.file)
        let right = try #require(session.clip(part.right)?.clip.file)
        let span = 480_000..<1_440_000
        let leftMatches = try fixture.samples(left, in: session) == Array(ramp(frames: fixture.frames)[span])
        let rightMatches =
            try fixture.samples(right, in: session) == Array(ramp(frames: fixture.frames, channel: 1)[span])
        #expect(leftMatches, "the left file is channel 0 of the span")
        #expect(rightMatches, "the right file is channel 1 of the span")
    }

    /// C4b: one 10 s clip at 25 s of a 60 s file writes 30 s from 15 s on each side, not the whole
    /// file, and the new clip offset is 10 s. At offset 0 the handle stops at the file start.
    @Test func writesTheClipSpanWithHandles() throws {
        let fixture = try SplitFixture(seconds: 60, clips: [("c1", 1_200_000, 480_000)])
        let (session, parts, made) = try fixture.split(["c1"])
        let part = try #require(parts.first)
        let left = try #require(session.clip(part.left)?.clip)
        #expect(try fixture.samples(left.file, in: session).count == 1_440_000, "30 s, not 2,880,000 frames")
        #expect(made.count == 2 && session.files[left.file]?.length == 1_440_000)
        #expect(left.offset == 480_000 && session.clip(part.right)?.clip.offset == 480_000)

        let capped = try SplitFixture(seconds: 60, clips: [("c1", 0, 480_000)])
        let (cappedSession, cappedParts, _) = try capped.split(["c1"])
        let cappedPart = try #require(cappedParts.first)
        let file = try #require(cappedSession.clip(cappedPart.right)?.clip.file)
        #expect(try capped.samples(file, in: cappedSession).count == 960_000, "10 s clip + 10 s handle")
    }

    /// C4b: two clips 65 s apart get two pairs, each with its own span of the source.
    @Test func farClipsWriteTwoPairs() throws {
        let fixture = try SplitFixture(seconds: 90, clips: [("c1", 240_000, 240_000), ("c2", 3_360_000, 240_000)])
        let (session, parts, made) = try fixture.split(["c1", "c2"])
        #expect(made.count == 4 && session.files.count == 5)
        let second = try #require(session.clip(parts[1].left)?.clip.file)
        let matches =
            try fixture.samples(second, in: session) == Array(ramp(frames: fixture.frames)[2_880_000..<4_080_000])
        #expect(matches, "the second pair holds 60 s to 85 s")
        #expect(session.clip(parts[0].left)?.clip.file != second)
    }

    /// C4b: two clips 5 s apart share one pair.
    @Test func nearClipsShareAPair() throws {
        let fixture = try SplitFixture(seconds: 60, clips: [("c1", 480_000, 240_000), ("c2", 960_000, 240_000)])
        let (session, parts, made) = try fixture.split(["c1", "c2"])
        #expect(made.count == 2 && parts.count == 2)
        #expect(session.clip(parts[0].left)?.clip.file == session.clip(parts[1].left)?.clip.file)
        let file = try #require(session.clip(parts[0].left)?.clip.file)
        #expect(session.files[file]?.length == 1_680_000, "0 s to 35 s: the two spans and their handles")
    }

    /// C4d: two runs of one file get two stems, and no new file takes a name in `Clips/`. The two
    /// files of a pair share one number, the first that is free for both names.
    @Test func twoRunsOfOneFileGetTwoStems() throws {
        let fixture = try SplitFixture(seconds: 90, clips: [("c1", 240_000, 240_000), ("c2", 3_360_000, 240_000)])
        let stray = fixture.package.url.appending(path: "\(clipsFolderName)/f1 L.wav")
        try Data([1, 2, 3]).write(to: stray)

        let (session, parts, _) = try fixture.split(["c1", "c2"])

        let files = parts.flatMap { [session.clip($0.left)?.clip.file, session.clip($0.right)?.clip.file] }
        #expect(files == ["f1 L 2", "f1 R 2", "f1 L 3", "f1 R 3"])
        #expect(FileManager.default.contents(atPath: stray.path) == Data([1, 2, 3]), "the stray file keeps its bytes")
        #expect(
            try fixture.listing() == ["f1 L 2.wav", "f1 L 3.wav", "f1 L.wav", "f1 R 2.wav", "f1 R 3.wav", "f1.wav"])
    }

    /// C5: the need is 2 x 3 bytes for each frame of the spans, plus the margin, checked before any
    /// write. A dense edit of 500 clips needs the file length, not the sum of the clip spans.
    @Test func spaceCheckBeforeWrite() throws {
        let fixture = try SplitFixture(seconds: 30, clips: [("c1", 960_000, 240_000)])
        let need: Int64 = 960_000 * 2 * 3 + diskMargin
        let before = try fixture.listing()
        #expect(throws: SplitError.space(needed: need, free: need - 1)) {
            try fixture.split(["c1"], freeBytes: need - 1)
        }
        #expect(try fixture.listing() == before, "no file and no temp file")
        #expect(try fixture.split(["c1"], freeBytes: need).made.count == 2)

        let dense = (0..<500).map { (ClipID("c\($0)"), $0 * 5_000, 1_000) }
        let denseFixture = try SplitFixture(seconds: 60, clips: dense)
        let denseNeed: Int64 = 2_880_000 * 2 * 3 + diskMargin
        #expect(throws: SplitError.space(needed: denseNeed, free: denseNeed - 1)) {
            try denseFixture.split(dense.map(\.0), freeBytes: denseNeed - 1)
        }
    }

    /// C6: a cancel while the right temp file is written, or after the renames, leaves `Clips/` as
    /// it was.
    @Test(arguments: [".f1 R.wav.tmp", "f1 L.wav"]) func cancelLeavesNoFile(when name: String) throws {
        let fixture = try SplitFixture(seconds: 30, clips: [("c1", 960_000, 240_000)])
        let before = try fixture.hashes()
        var cancelled = false

        do throws(SplitError) {
            _ = try fixture.split(["c1"], isCancelled: { fixture.has(name) })
        } catch {
            cancelled = error == .cancelled
        }

        #expect(cancelled, "the cancel came when \(name) was there")
        #expect(try fixture.hashes() == before, "no new file, no temp file, and the source keeps its bytes")
    }

    /// C6: a fault of the right WAV unlinks the left temp file.
    @Test func writeFaultLeavesNoFile() throws {
        let fixture = try SplitFixture(seconds: 30, clips: [("c1", 960_000, 240_000)])
        let blocked = fixture.package.url.appending(path: "\(clipsFolderName)/.f1 R.wav.tmp")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        let before = try fixture.listing()
        var leftTempSeen = false
        var fault: SplitError?

        do throws(SplitError) {
            _ = try fixture.split(
                ["c1"], progress: { _ in leftTempSeen = leftTempSeen || fixture.has(".f1 L.wav.tmp") })
        } catch {
            fault = error
        }

        guard case .write(let file, _) = fault else {
            Issue.record("not a write fault: \(String(describing: fault))")
            return
        }
        #expect(file == "\(clipsFolderName)/f1 R.wav" && leftTempSeen)
        #expect(try fixture.listing() == before, "the left temp file is gone")
    }

    /// C6: a session refusal comes before the first write. A list with a mono clip, and a
    /// transcript that did not load, leave `Clips/` as it was; the same split with no refusal writes.
    /// The mono refusal comes before the space check.
    @Test func sessionRefusalLeavesNoFile() throws {
        let fixture = try SplitFixture(seconds: 30, clips: [("c1", 960_000, 240_000)])
        try fixture.package.addFile("m1", channels: [ramp(frames: 48_000)])
        try fixture.package.addTrack("t2", clip: "m", file: "m1", start: 0, offset: 0, length: 48_000)
        var unloaded = fixture.package.session
        unloaded.transcripts[TranscriptID(1)] = Transcript(id: TranscriptID(1), name: "t1", words: nil)
        let before = try fixture.hashes()

        #expect(throws: SplitError.session(.notStereo("m"))) { try fixture.split(["c1", "m"]) }
        #expect(throws: SplitError.session(.notStereo("m")), "a full disk") {
            try fixture.split(["c1", "m"], freeBytes: 0)
        }
        #expect(try fixture.hashes() == before)
        #expect(throws: SplitError.session(.transcriptNotLoaded([TranscriptID(1)]))) {
            try fixture.split(["c1"], of: unloaded)
        }
        #expect(try fixture.hashes() == before)
        #expect(try fixture.split(["c1"]).made.count == 2, "the split with no refusal writes")
    }

    /// C6b: over two runs the fractions never fall, and only the end of the last side gives 1.
    @Test func progressRisesUntilTheLastSide() throws {
        let fixture = try SplitFixture(seconds: 90, clips: [("c1", 240_000, 240_000), ("c2", 3_360_000, 240_000)])
        var fractions: [Double] = []

        _ = try fixture.split(["c1", "c2"], progress: { fractions.append($0) })

        #expect(fractions.count > 8 && fractions == fractions.sorted(), "\(fractions)")
        #expect(fractions.last == 1 && fractions.dropLast().allSatisfy { $0 < 1 }, "\(fractions)")
        #expect(fractions.contains { $0 > 0.2 && $0 < 0.5 }, "the sides between the first and the last")

        // One run of 960,000 frames: 15 blocks of 65,536 frames on each side, so the 8th block of
        // the left side ends near 0.25, and no step is over the share of one block.
        let one = try SplitFixture(seconds: 30, clips: [("c1", 960_000, 240_000)])
        var single: [Double] = []
        _ = try one.split(["c1"], progress: { single.append($0) })
        let block = 65_536.0 / (2 * 960_000)
        try #require(single.count > 7, "\(single)")
        #expect(abs(single[7] - 0.25) < block, "the middle of the left side: \(single)")
        #expect(zip(single.dropFirst(), single).allSatisfy { $0 - $1 <= block + 1e-9 }, "\(single)")
    }
}
