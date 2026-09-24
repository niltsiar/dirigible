import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The session mix of decision 0016 (timeline-playback criteria 1 to 4): clips at their frames,
/// silence elsewhere. Tolerance: ± 1e-6 per sample with no gain (a 24-bit WAV read into float32
/// is exact).
struct MixTests {
    /// A mono track with one clip: file frames 500..<5300 at timeline 1000.
    func monoClip() throws -> (MixPackage, [Float]) {
        let package = try MixPackage()
        let samples = ramp(frames: 6000)
        try package.addFile("f1", channels: [samples])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 1000, offset: 500, length: 4800)
        return (package, samples)
    }

    @Test func aMonoClipPlaysOnBothChannelsAtItsFrame() throws {
        let (package, samples) = try monoClip()
        let out = try package.mix(0..<6000)
        let clip = Array(samples[500..<5300])
        for channel in out {
            #expect(maxError(Array(channel[1000..<5800]), clip) <= 1e-6)
            #expect(channel[0..<1000].allSatisfy { $0 == 0 })
            #expect(channel[5800..<6000].allSatisfy { $0 == 0 })
        }
    }

    @Test func aRangeWithNoClipIsSilent() throws {
        let (package, _) = try monoClip()
        let out = try package.mix(6000..<9000)
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.count == 3000 && $0.allSatisfy { $0 == 0 } })
    }

    @Test func clipGainAndTrackGainMultiply() throws {
        let (package, samples) = try monoClip()
        let unity = try package.mix(1000..<5800)
        #expect(maxError(unity[0], Array(samples[500..<5300])) <= 1e-6, "0 dB gives 1.0 x")
        let half = try #require(Gain(dB: -6.0206))
        try package.session.setGain(half, track: "t1")
        try package.session.setGain(half, clip: "c1")
        let quarter = try package.mix(1000..<5800)
        for channel in quarter {
            #expect(maxError(channel, samples[500..<5300].map { $0 * 0.25 }) <= 1e-4, "-12.04 dB gives 0.25 x")
        }
    }

    @Test func aStereoTrackKeepsItsChannelsAndTracksSum() throws {
        let package = try MixPackage()
        let (left, right, mono) = (ramp(frames: 4000), ramp(frames: 4000, channel: 1), ramp(frames: 4000, channel: 2))
        try package.addFile("s", channels: [left, right])
        try package.addFile("m", channels: [mono])
        try package.addTrack("t1", layout: .stereo, clip: "c1", file: "s", start: 0, offset: 0, length: 4000)
        try package.addTrack("t2", clip: "c2", file: "m", start: 0, offset: 0, length: 4000)
        let out = try package.mix(0..<4000)
        #expect(maxError(out[0], zip(left, mono).map { $0 + $1 }) <= 1e-6, "left is stereo left plus mono")
        #expect(maxError(out[1], zip(right, mono).map { $0 + $1 }) <= 1e-6, "right is stereo right plus mono")
    }

    @Test func aMonoTrackAloneGivesTheSameLeftAndRight() throws {
        let (package, _) = try monoClip()
        let out = try package.mix(0..<6000)
        #expect(out[0] == out[1] && out[0].contains { $0 != 0 })
    }

    @Test func missingMediaRendersSilenceAndKeepsOtherTracks() throws {
        let package = try MixPackage()
        let (gone, kept) = (ramp(frames: 3000), ramp(frames: 3000, channel: 1))
        try package.addFile("gone", channels: [gone])
        try package.addFile("kept", channels: [kept])
        try package.addTrack("t1", clip: "c1", file: "gone", start: 0, offset: 0, length: 3000)
        try package.addTrack("t2", clip: "c2", file: "kept", start: 0, offset: 0, length: 3000)
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/gone.wav"))
        let reader = package.reader()
        let out = try package.render(reader, 0..<3000)
        #expect(out.allSatisfy { maxError($0, kept) <= 1e-6 }, "only the kept track sounds")
        #expect(reader.faults == ["gone": .missing])
    }

    @Test func aShortFilePlaysItsRealFramesThenSilence() throws {
        let package = try MixPackage()
        let samples = ramp(frames: 6000)
        try package.addFile("f1", channels: [samples])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 6000)
        let real = try package.truncate("f1", toBytes: 9000)
        #expect(real > 0 && real < 3000)
        // Two chunks, as the Player reads: the second starts past the real end (probe E6c).
        let reader = package.reader()
        let first = try package.render(reader, 0..<3000)
        let second = try package.render(reader, 3000..<6000)
        let out = zip(first, second).map { $0 + $1 }
        for channel in out {
            #expect(maxError(Array(channel[0..<real]), Array(samples[0..<real])) <= 1e-6, "the real frames")
            #expect(channel[real...].allSatisfy { $0 == 0 }, "silence after the real frames")
        }
        #expect(reader.faults == ["f1": .short(Frames(real))])
    }

    /// The descriptors of this process whose path is in `folder`. `F_GETPATH` gives the real path
    /// (/private/var, not /var).
    func openDescriptors(in folder: URL) throws -> Int {
        let real = try #require(realpath(folder.path, nil))
        defer { free(real) }
        let prefix = String(cString: real) + "/"
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return (0..<getdtablesize()).filter {
            fcntl($0, F_GETPATH, &buffer) == 0 && String(cString: buffer).hasPrefix(prefix)
        }
        .count
    }

    /// 40 pool files, one clip each, 100 frames apart. The reader keeps at most 32 files open,
    /// and a file that it closed opens again with the same frames. Control: the first render
    /// opens each file (the ramp of file k is at frame 100 k). Found by the code gate.
    @Test func theReaderKeepsAtMost32FilesOpen() throws {
        let package = try MixPackage()
        for k in 0..<40 {
            try package.addFile(FileID("f\(k)"), channels: [ramp(frames: 100, channel: k)])
            try package.addTrack(
                TrackID("t\(k)"), clip: ClipID("c\(k)"), file: FileID("f\(k)"), start: Frames(100 * k), offset: 0,
                length: 100)
        }
        let expected = (0..<40).flatMap { ramp(frames: 100, channel: $0) }
        let reader = package.reader()

        let first = try package.render(reader, 0..<4000)
        #expect(try openDescriptors(in: package.url) <= 32)
        let second = try package.render(reader, 0..<4000)

        for out in [first, second] {
            #expect(maxError(out[0], expected) <= 1e-6 && maxError(out[1], expected) <= 1e-6)
        }
        #expect(reader.faults == [:])
        #expect(try openDescriptors(in: package.url) <= 32)
    }
}
