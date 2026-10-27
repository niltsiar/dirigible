import AudioToolbox
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The files of a clip render (decision 0054): the refusals before the first write, the cleanup
/// of each fault and cancel, and the progress.
struct EffectRenderFileTests {
    /// A package with the 30 s mono noise file "f1" and the clip "c1" of 5 s at 10 s on "t1".
    func fixture(role: Track.Role? = nil) throws -> RenderFixture {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 1_440_000, level: 0.01, seed: 11)], track: "t1", role: role,
            clips: [("c1", 480_000, 240_000)])
        return fixture
    }

    /// C6: free bytes equal to the new file and the margin render; one byte less refuses and writes
    /// nothing. The span is 25 s: 1,200,000 frames of 3 bytes.
    @Test func spaceCheckBeforeWrite() throws {
        let fixture = try fixture()
        let needed = 1_200_000 * 3 + diskMargin
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.space(needed: needed, free: needed - 1)) {
            try fixture.render(["c1"], freeBytes: needed - 1)
        }
        #expect(try fixture.hashes() == before)
        #expect(try fixture.render(["c1"], freeBytes: needed).made.count == 1)
    }

    /// Groups render as the runs of all their clips: a clip in two groups, and two groups whose
    /// clips 5 s apart share one handle, give one file. Two treatments in one run refuse before any
    /// write.
    @Test func groupsRenderTheRunsOfAllTheirClips() throws {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 2_400_000, level: 0.01, seed: 16)], track: "t1",
            clips: [("a", 720_000, 48_000), ("b", 1_008_000, 48_000)])
        let (twelve, six) = (Treatment(.noise(.standard)), Treatment(.noise(try #require(NoiseReduction(decibels: 6)))))
        func render(_ groups: [(clips: [ClipID], treatment: Treatment)]) throws(ClipRenderError) -> ClipRenderOutcome {
            try renderClips(
                groups, of: fixture.package.session, in: fixture.package.url, freeBytes: { .max },
                isDownloaded: { _ in true })
        }
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.mixedTreatments(clips: ["a", "b"])) {
            try render([(["a"], twelve), (["b"], six)])
        }
        #expect(try fixture.hashes() == before)
        let outcome = try render([(["a"], twelve), (["b", "a"], twelve)])
        #expect(outcome.made.map(\.lastPathComponent) == ["f1 NR.wav"], "fail value: .frameOutOfRange")
        #expect(outcome.clips.map(\.clip) == ["a", "b"])
    }

    /// C7: a cancel before the first run and a cancel between two runs leave `Clips/` as it was.
    @Test func cancelLeavesNoFile() throws {
        let fixture = try fixture()
        try fixture.add(
            "f2", [seededNoise(frames: 480_000, level: 0.01, seed: 12)], track: "t2", clips: [("c2", 0, 96_000)])
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.cancelled) { try fixture.render(["c1", "c2"], isCancelled: { true }) }
        #expect(try fixture.hashes() == before)

        var late = false
        #expect(throws: ClipRenderError.cancelled) {
            try fixture.render(
                ["c1", "c2"], progress: { if $0 >= 1_200_000.0 / 1_680_000 { late = true } }, isCancelled: { late })
        }
        #expect(late, "the cancel came after the first run")
        #expect(try fixture.hashes() == before)
    }

    /// C7, 0040: a move fault in the renames keeps the renamed WAV of the first run, leaves no temp
    /// file, and replaces no file. An item at the name of the second run, made at the first block
    /// read of the first run, makes the second move fail.
    @Test func writeFaultKeepsNoSessionChange() throws {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 4_800_000, level: 0.01, seed: 13)], track: "t1",
            clips: [("a", 528_000, 48_000), ("b", 3_408_000, 48_000)])
        let planted = fixture.package.url.appending(path: "\(clipsFolderName)/f1 NR 2.wav")
        let before = try fixture.listing()
        let session = fixture.package.session

        #expect(throws: ClipRenderError.write(file: "f1 NR 2.wav", errno: EEXIST)) {
            try fixture.render(
                ["a", "b"],
                readFault: ReadFault(stem: "f1 NR", block: 0) {
                    FileManager.default.createFile(atPath: planted.path, contents: Data("planted".utf8))
                })
        }

        #expect(try fixture.listing() == (before + ["f1 NR.wav", "f1 NR 2.wav"]).sorted(), "no temp file stays")
        #expect(FileManager.default.contents(atPath: planted.path) == Data("planted".utf8))
        #expect(fixture.package.session == session)
    }

    /// C7c: a Core refusal comes before the first read and the first write: a transcript that did
    /// not load and an unknown clip leave `Clips/` as it was and call no progress.
    @Test func sessionRefusalLeavesNoFile() throws {
        let fixture = try fixture()
        var unloaded = fixture.package.session
        unloaded.transcripts[TranscriptID(1)] = Transcript(id: TranscriptID(1), name: "t1", words: nil)
        let before = try fixture.hashes()
        var reads = 0

        #expect(throws: ClipRenderError.session(.transcriptNotLoaded([TranscriptID(1)]))) {
            try fixture.render(["c1"], of: unloaded, progress: { _ in reads += 1 })
        }
        #expect(throws: ClipRenderError.session(.unknownClip("nope"))) {
            try fixture.render(["c1", "nope"], progress: { _ in reads += 1 })
        }
        #expect(try fixture.hashes() == before)
        #expect(reads == 0, "a refused render writes no frame")
    }

    /// C13: a clip on a music or an effects track refuses before any read or write; a clip on a
    /// dialogue track and one on a track with no role render.
    @Test(arguments: [Track.Role.music, .effects])
    func musicClipRefused(role: Track.Role) throws {
        let fixture = try fixture(role: role)
        try fixture.add(
            "f2", [seededNoise(frames: 480_000, level: 0.01, seed: 14)], track: "t2", role: .dialogue,
            clips: [("d", 0, 96_000)])
        try fixture.add(
            "f3", [seededNoise(frames: 480_000, level: 0.01, seed: 15)], track: "t3", clips: [("n", 0, 96_000)])
        let before = try fixture.hashes()
        var reads = 0

        #expect(throws: ClipRenderError.trackRole(clip: "c1", role: role)) {
            try fixture.render(["d", "c1", "n"], progress: { _ in reads += 1 })
        }
        #expect(try fixture.hashes() == before)
        #expect(reads == 0)
        #expect(try fixture.render(["d", "n"]).made.count == 2)
    }

    /// C7d: over two runs, the last a hot voice that renders a second pass, the fractions never
    /// fall, each is under 1 before the last, the last is 1, and no step is over one block share.
    @Test func progressRisesUntilTheLastRun() throws {
        let fixture = try fixture()
        let voice = try hotVoice(in: fixture.package.folder.url)
        try fixture.add("hot", [voice], track: "t2", clips: [("h", 0, voice.count)])
        var fractions: [Double] = []

        let outcome = try fixture.render(["c1", "h"], progress: { fractions.append($0) })

        let total = Double(1_200_000 + voice.count)
        #expect(fractions.count > 8 && fractions == fractions.sorted(), "\(fractions)")
        #expect(fractions.last == 1 && fractions.dropLast().allSatisfy { $0 < 1 }, "\(fractions)")
        #expect(zip(fractions.dropFirst(), fractions).allSatisfy { $0 - $1 <= 65_536 / total + 1e-9 })
        #expect(try #require(outcome.session.clip("h")?.clip).gain.dB > 0, "the hot run renders a second pass")
    }

    /// C2b: a second pass that still peaks at a 24-bit end code, as from a unit that renders louder
    /// the second time, throws, and no file stays. The probe gate1-a4-a7 found two instances equal.
    @Test func secondPassOverFullScaleFails() throws {
        let fixture = try RenderFixture()
        let voice = try hotVoice(in: fixture.package.folder.url)
        try fixture.add("f1", [voice], track: "t1", clips: [("c1", 0, voice.count)])
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.stillOverFullScale(file: "Clips/f1 NR.wav")) {
            try renderClips(
                [(["c1"], Treatment(.noise(.standard)))], of: fixture.package.session, in: fixture.package.url,
                freeBytes: { .max }, isDownloaded: { _ in true }, secondPassGain: 1.001)
        }
        #expect(try fixture.hashes() == before)
    }

    /// C7b: a block read that throws stops the render with the errno, and no file stays.
    @Test func sourceReadFaultFails() throws {
        let fixture = try fixture()
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.sourceUnreadable(file: "f1.wav", errno: EIO)) {
            try fixture.render(["c1"], readFault: ReadFault(stem: "f1 NR", block: 2) { throw POSIXError(.EIO) })
        }
        #expect(try fixture.hashes() == before)
    }

    /// C7b: a missing source refuses before the first write.
    @Test func missingSourceRefused() throws {
        let fixture = try fixture()
        unlink(fixture.package.url.appending(path: "\(clipsFolderName)/f1.wav").path)

        #expect(throws: ClipRenderError.sourceMissing(file: "f1.wav")) { try fixture.render(["c1"]) }
        #expect(try fixture.listing() == [])
    }

    /// C7b: a source whose data is not on this Mac refuses before the first write.
    @Test func notDownloadedRefused() throws {
        let fixture = try fixture()
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.notDownloaded(file: "f1.wav")) {
            try fixture.render(["c1"], isDownloaded: { _ in false })
        }
        #expect(try fixture.hashes() == before)
    }

    /// A component that no unit matches.
    static let noUnit = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: 0x6E6F_6E65, componentManufacturer: 0,
        componentFlags: 0, componentFlagsMask: 0)

    /// C10: a unit that does not load refuses with its status before the first write.
    @Test func unitLoadFailure() throws {
        let fixture = try fixture()
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.effectUnavailable(status: -3000)) {
            try fixture.render(["c1"], component: { _ in Self.noUnit })
        }
        #expect(try fixture.hashes() == before)
    }

    /// C10, the 0054 order: the unit loads for each channel count before the first write, so a
    /// stereo load failure after a mono run renders no frame.
    @Test func stereoLoadFailureRendersNothing() throws {
        let fixture = try fixture()
        let noise = seededNoise(frames: 480_000, level: 0.01, seed: 18)
        try fixture.add("s1", [noise, noise], track: "t2", clips: [("s", 0, 96_000)])
        let before = try fixture.hashes()
        var written = 0

        #expect(throws: ClipRenderError.effectUnavailable(status: -3000)) {
            try fixture.render(
                ["c1", "s"], component: { $0 == 2 ? Self.noUnit : .soundIsolation }, progress: { _ in written += 1 })
        }
        #expect(written == 0, "the mono run rendered first")
        #expect(try fixture.hashes() == before)
    }
}

/// The amount of a noise reduction (C16).
struct NoiseReductionTests {
    @Test func range() {
        #expect(NoiseReduction(decibels: 1)?.decibels == 1)
        #expect(NoiseReduction(decibels: 30)?.decibels == 30)
        #expect(NoiseReduction(decibels: 0) == nil)
        #expect(NoiseReduction(decibels: 31) == nil)
    }

    @Test func wet() {
        #expect(abs(NoiseReduction.standard.wetDryMixPercent - 74.88) < 0.01)
    }
}

/// The effects of a treatment and the roles that it takes (C13, C16).
struct TreatmentTests {
    @Test func emptyRefused() { #expect(Treatment([]) == nil) }

    @Test func repeatedKindRefused() {
        let twelve = Effect.noise(.standard)
        #expect(Treatment([twelve, .noise(NoiseReduction(decibels: 6)!)]) == nil)
        #expect(Treatment([twelve])?.effects == [twelve])
    }

    @Test func noiseRefusesMusicAndEffects() {
        let noise = Treatment(.noise(.standard))
        #expect(noise.accepts(nil) && noise.accepts(.dialogue))
        #expect(!noise.accepts(.music) && !noise.accepts(.effects))
    }
}
