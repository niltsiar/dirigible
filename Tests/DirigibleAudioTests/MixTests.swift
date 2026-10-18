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
            fcntl($0, F_GETPATH, &buffer) == 0 && String(cString: &buffer).hasPrefix(prefix)
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
        // Control: the count sees a descriptor that a handle holds.
        let handle = try FileHandle(forReadingFrom: package.url.appending(path: "\(clipsFolderName)/f0.wav"))
        #expect(try openDescriptors(in: package.url) == 1)
        try handle.close()

        let first = try package.render(reader, 0..<4000)
        #expect(try openDescriptors(in: package.url) <= 32)
        let second = try package.render(reader, 0..<4000)

        for out in [first, second] {
            #expect(maxError(out[0], expected) <= 1e-6 && maxError(out[1], expected) <= 1e-6)
        }
        #expect(reader.faults == [:])
        #expect(try openDescriptors(in: package.url) <= 32)
    }

    // MARK: Fades (decision 0035)

    /// Fades C9: the mix follows `Fades.gain` frame by frame, with literal anchors.
    @Test func fadesFollowTheQuarterSine() throws {
        let out = try fadedPackage().mix(0..<7000)
        let expected = try fadedMix(0..<7000)
        for channel in out { #expect(maxError(channel, expected) <= 1e-6, "the mix follows Fades.gain") }
        #expect(abs(out[0][1000] - 0.25) <= 1e-6, "k = 0 gives 0")
        #expect(abs(out[0][1240] - (0.25 + 0.353_553_39)) <= 1e-6, "k = 240 gives 0.35355")
        #expect(abs(out[0][5799] - (0.25 + 0.000_818_12)) <= 1e-6, "k = 4799 gives 0.000818")
    }

    /// Fades C11: clip gain -6 dB, track gain +2 dB, and the fades multiply.
    @Test func fadeAndGainMultiply() throws {
        let package = try fadedPackage()
        try package.session.setGain(#require(Gain(dB: -6)), clip: "c1")
        try package.session.setGain(#require(Gain(dB: 2)), track: "t2")
        let out = try package.mix(0..<7000)
        let expected = try fadedMix(0..<7000, gain: pow(10, -4.0 / 20))
        for channel in out { #expect(maxError(channel, expected) <= 1e-6, "0.5 * fin * fout * 10^(-4/20)") }
    }

    /// Fades C14: the envelope at the end of a clip of 2^30 + 7 frames, with no media, is within the
    /// B1 tolerance of `Fades.gain`.
    @Test func aFadeAtTheEndOfALongClipIsExact() throws {
        let length = Frames((1 << 30) + 7)
        let fades = try #require(Fades(fadeIn: 480, fadeOut: 48_000))
        // A part at the clip end, and one inside the fade-out: a Float start can round to the
        // right value at the end only.
        for from in [length - Frames(4800), length - Frames(30_001)] {
            var envelope = [Float](repeating: 0, count: 4800)
            envelope.withUnsafeMutableBufferPointer {
                fadeEnvelope(fades, curves: .sine, length: length, from: from, gain: 1, into: $0)
            }
            let expected = (0..<4800).map { Float(fades.gain(at: from + Frames($0), length: length, curves: .sine)) }
            #expect(maxError(envelope, expected) <= 1e-6, "the envelope at the end of a long clip")
        }
    }

    /// The two copies of the curve (decisions 0035 and 0036): the vector `fadeEnvelope` equals
    /// `Fades.gain` within the B1 tolerance across a whole clip with both fades, from the clip start
    /// and from a part start inside each fade, for each curve at each edge.
    @Test(arguments: [(Fades.Curve.sine, Fades.Curve.sine), (.linear, .linear), (.linear, .sine), (.sine, .linear)])
    func theEnvelopeEqualsFadesGain(start: Fades.Curve, end: Fades.Curve) throws {
        let (fades, curves) = (try #require(Fades(fadeIn: 480, fadeOut: 960)), Fades.Curves(start: start, end: end))
        for (from, count) in [(0, 4800), (100, 700), (4000, 800)] {
            var envelope = [Float](repeating: 0, count: count)
            envelope.withUnsafeMutableBufferPointer {
                fadeEnvelope(fades, curves: curves, length: 4800, from: Frames(from), gain: 0.5, into: $0)
            }
            let expected = (from..<from + count).map {
                Float(0.5 * fades.gain(at: Frames($0), length: 4800, curves: curves))
            }
            #expect(maxError(envelope, expected) <= 1e-6, "\(curves): the envelope from \(from) equals Fades.gain")
        }
        let half = start == .linear ? 0.5 : sin(Double.pi / 4)
        #expect(abs(fades.gain(at: 240, length: 4800, curves: curves) - half) <= 1e-12, "\(start): k = 240 of 480")
    }

    // MARK: Crossfades (decision 0036)

    /// Crossfades X1: A gives a(i) on the left and B gives b(i) on the right, within 1e-6 of the
    /// Double formula, and left^2 + right^2 is 1 within 1e-6 over the crossfade.
    @Test(arguments: [480, 4_800])
    func aCrossfadeHasEqualPower(length: Int) throws {
        let out = try crossfadedPackage(length).mix(0..<22_000)
        let expected = crossfadedMix(0..<22_000, length: length)
        for channel in 0..<2 {
            let error = maxError(out[channel], expected[channel])
            #expect(error <= 1e-6, "L \(length): channel \(channel) follows the formula, error \(error)")
        }
        let power = (11_000 - length / 2..<11_000 + length / 2).map { t in
            abs(Double(out[0][t]) * Double(out[0][t]) + Double(out[1][t]) * Double(out[1][t]) - 1)
        }.max()!
        #expect(power <= 1e-6, "L \(length): equal power, error \(power)")
    }

    /// Crossfades X1: the envelope of a crossfaded clip, read through `ClipLane.sounding(at:)`,
    /// equals `Fades.gain` of the sounding clip, so the render and the draw read one geometry.
    @Test func theEnvelopeOfACrossfadeEqualsFadesGain() throws {
        let package = try crossfadedPackage(4_800)
        let edges = try #require(package.session.track("t1")?.clips.sounding(at: 0))
        let (sounding, curves) = (edges.clip, edges.curves)
        #expect(sounding.start == 1_000 && sounding.length == 12_400 && sounding.fades.fadeOut == 4_800)
        #expect(curves == .sine, "a butt join keeps equal power")
        var envelope = [Float](repeating: 0, count: 5_000)
        envelope.withUnsafeMutableBufferPointer {
            fadeEnvelope(sounding.fades, curves: curves, length: sounding.length, from: 7_400, gain: 1, into: $0)
        }
        let expected = (7_400..<12_400).map {
            Float(sounding.fades.gain(at: Frames($0), length: sounding.length, curves: curves))
        }
        #expect(maxError(envelope, expected) <= 1e-6, "the envelope of the sounding clip equals Fades.gain")
    }

    /// Seamless crossfade C33: a sine split at J = 24,000, clip gains 0 dB and -12 dB, and a
    /// crossfade of 960 frames at J. Both pieces read one signal s, so the mix is s times the gain
    /// gA x a(i) + gB x b(i) with the linear curve, i = t - (J - 480): it falls from gA to gB and never
    /// rises. With equal gains the mix is s within 2e-7 x |s| (probe P4); equal power is 3 dB over at J.
    @Test func aSeamlessCrossfadeIsAGainRamp() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [sine(seconds: 1, rate: 48_000, frequency: 440)])
        try package.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 48_000)
        let range: Range<Frames> = 20_000..<28_000
        let signal = try package.mix(range)[0].map(Double.init)
        let right = try package.session.split("A", at: 24_000)
        try package.session.setGain(#require(Gain(dB: -12)), clip: right)
        try package.session.setCrossfades(["A": 960])
        let ramp = try package.mix(range)[0]
        try package.session.setGain(.zero, clip: right)
        #expect(package.session.clip("A")?.clip.crossfades.end == 960, "a gain edit keeps the crossfade")
        let flat = try package.mix(range)[0]

        let (gA, gB) = (1.0, pow(10, -12.0 / 20))
        func gain(at t: Int) -> Double {
            let i = Double(min(max(t - 23_520, 0), 960))
            return gA * (960 - i) / 960 + gB * i / 960
        }
        var (rampError, flatError, rises, outside) = (0.0, 0.0, 0, 0)
        var last = gA
        for (k, t) in (20_000..<28_000).enumerated() where signal[k] != 0 {
            let s = signal[k]
            rampError = max(rampError, abs(Double(ramp[k]) - s * gain(at: t)) / abs(s))
            flatError = max(flatError, abs(Double(flat[k]) - s) / abs(s))
            guard abs(s) >= 0.1 else { continue }
            let measured = Double(ramp[k]) / s
            if measured > last + 1e-6 { rises += 1 }
            if measured > gA + 1e-6 || measured < gB - 1e-6 { outside += 1 }
            last = measured
        }
        #expect(signal.contains { abs($0) >= 0.4 }, "the fixture sounds")
        #expect(rampError <= 1e-6, "the mix is s times the linear gain ramp, error \(rampError) x |s|")
        #expect(rises == 0 && outside == 0, "the gain never rises: \(rises) rises, \(outside) outside gB...gA")
        #expect(flatError <= 2e-7, "equal gains: the mix is s, error \(flatError) x |s|")
    }

    /// Mute and solo C2: t1 is 0.25 and t2 is 0.5 over 0 to 48,000. The mix reads only the heard
    /// tracks of its track set.
    @Test func muteAndSoloChooseTheTracksOfTheMix() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [[Float](repeating: 0.25, count: 48_000)])
        try package.addFile("f2", channels: [[Float](repeating: 0.5, count: 48_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 48_000)
        func isLevel(_ value: Float, _ edit: (inout Session) throws -> Void, tracks: Set<TrackID>? = nil) throws
            -> Bool
        {
            var session = package.session
            try edit(&session)
            let out = try package.render(MixReader(package: package.url, session: session, tracks: tracks), 0..<48_000)
            return out.count == 2 && out.allSatisfy { $0.allSatisfy { abs($0 - value) <= 1e-6 } }
        }
        #expect(try isLevel(0.75) { _ in }, "no flag: both tracks")
        #expect(try isLevel(0.5) { try $0.setMuted(true, tracks: ["t1"]) }, "t1 muted")
        #expect(try isLevel(0.5) { try $0.setSoloed(true, tracks: ["t2"]) }, "t2 soloed")
        #expect(try isLevel(0) { try $0.setMuted(true, tracks: ["t1", "t2"]) }, "every track muted: silence")
        #expect(
            try isLevel(0.25, { try $0.setMuted(true, tracks: ["t2"]) }, tracks: ["t1", "t2"]),
            "Export Selection: the selected tracks that are heard")
    }

    /// A clip with a gain and both fades, split twice, renders the same samples after
    /// a heal, over the clips and 1 s on each side. The clip count shows that the heal ran.
    @Test func aHealedClipSoundsTheSame() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 40_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 48_000, offset: 1_000, length: 30_000)
        try package.session.setGain(#require(Gain(dB: -4.5)), clip: "c1")
        try package.session.setFades(["c1": #require(Fades(fadeIn: 480, fadeOut: 960))])
        try package.session.splitClips(at: [60_000, 70_000], on: ["t1"])
        #expect(package.session.track("t1")?.clips.count == 3)
        let range: Range<Frames> = 0..<126_000
        let split = try package.mix(range)

        try package.session.heal()

        #expect(package.session.track("t1")?.clips.count == 1)
        let healed = try package.mix(range)
        #expect(split[0].contains { $0 != 0 }, "the fixture sounds")
        for channel in 0..<2 {
            #expect(maxError(healed[channel], split[channel]) <= 1e-6, "channel \(channel)")
        }
    }

    /// Heal C27: a heal at a seamless join with an equal-gain crossfade drops the crossfade, and the
    /// mix stays within 2e-7 x |s| of the mix before the heal (probe P4).
    @Test func aHealAtAnEqualGainCrossfadeSoundsTheSame() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [sine(seconds: 1, rate: 48_000, frequency: 440)])
        try package.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 48_000)
        let right = try package.session.split("A", at: 24_000)
        try package.session.setGain(#require(Gain(dB: -6)), clip: right)
        try package.session.setCrossfades(["A": 960])
        try package.session.setGain(.zero, clip: right)
        let crossfaded = try package.mix(0..<48_000)[0]

        try package.session.heal()

        #expect(package.session.track("t1")?.clips.count == 1 && package.session.fileVersion == 1, "one clip")
        let healed = try package.mix(0..<48_000)[0]
        #expect(healed.contains { abs($0) >= 0.4 }, "the fixture sounds")
        var error = 0.0
        for (after, before) in zip(healed, crossfaded) where after != 0 {
            error = max(error, abs(Double(before) - Double(after)) / abs(Double(after)))
        }
        #expect(error <= 2e-7, "the healed mix is the mix before, error \(error) x |s|")
    }
}
