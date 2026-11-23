import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criteria C9 and C25 of decision 0074 on real voices: the package at `DIRIGIBLE_CORPUS`, a clone
/// of `interview-jm-oct.dirigible`. The test reads it and writes nothing.
struct CorpusVoiceMatchTests {
    static let corpus = ProcessInfo.processInfo.environment["DIRIGIBLE_CORPUS"]
    static let host: TrackID = "0EEBEAC3-A069-4533-925C-5F6700B79419"
    static let guest: TrackID = "81676E66-D581-4A24-94C8-8F6A6FC1C1E4"

    /// What the target track gives through `MixReader` over the extent of its clips.
    struct Heard: Sendable {
        var spectrum: BandSpectrum?
        var loudness: Double
        var truePeak: Double
        var samplePeak: Double
    }

    /// The C9 pair (reference clip on the host, target the guest), and the reverse pair of C25
    /// (the clip of the guest at the same time, target the host). C9 asserts on the C9 pair only.
    /// The reads and the renders run in parallel: each one reads about 66 min of audio.
    @Test(
        .enabled(if: corpus != nil, "DIRIGIBLE_CORPUS is not set: C9 needs a clone of interview-jm-oct.dirigible"),
        arguments: [false, true])
    func matchOnRealVoices(reverse: Bool) async throws {
        let package = URL(filePath: try #require(Self.corpus))
        let plain = try Session(contentsOf: package)
        let (reference, target): (ClipID, TrackID) =
            reverse
            ? ("take4-2-1@1415798@7192320", Self.host) : ("take4-1-1@1415798@7192320", Self.guest)
        let name = reverse ? "reverse pair" : "C9 pair"
        let clip = try #require(plain.clip(reference)?.clip)
        let track = try #require(plain.track(target))
        async let referenceRead = Self.learn([VoicePart(clip, clip.offset..<clip.offset + clip.length)], plain, package)
        async let targetRead = Self.learn(
            track.clips.map { VoicePart($0, $0.offset..<$0.offset + $0.length) }, plain, package)
        let (referenceSpectrum, targetSpectrum) = try await (referenceRead, targetRead)
        print(
            "CorpusVoiceMatchTests \(name): gated voice of the reference \(Self.seconds(referenceSpectrum)) s, "
                + "of the target \(Self.seconds(targetSpectrum)) s")
        try #require(referenceSpectrum.voiceFrames >= 10 * 48_000 && targetSpectrum.voiceFrames >= 10 * 48_000)
        let curve = VoiceCurve.curve(reference: referenceSpectrum, target: targetSpectrum, sampleRate: 48_000)
        let match = { (percent: Int) in
            try VoiceMatch(
                amount: VoiceMatch.Amount(percent)!, reference: "reference", curve: curve.decibels,
                targetPowers: targetSpectrum.powers)
        }
        // 0 is the unmatched track.
        let percents = reverse ? [0, 75, 100] : [0, 50, 75, 100]
        let heard = try await withThrowingTaskGroup(of: (Int, Heard).self) { group in
            for percent in percents {
                var session = plain
                if percent > 0 { try session.setMatch([target: try match(percent)]) }
                let spectrum = !reverse && percent != 75
                group.addTask { [session] in
                    (percent, try Self.hear(session, target, package: package, spectrum: spectrum))
                }
            }
            return try await group.reduce(into: [Int: Heard]()) { $0[$1.0] = $1.1 }
        }
        let unmatched = try #require(heard[0])
        if !reverse {
            let (plainSpectrum, half, matched) = (
                try #require(unmatched.spectrum), try #require(heard[50]), try #require(heard[100])
            )
            print("CorpusVoiceMatchTests \(name): gated voice of the unmatched track \(Self.seconds(plainSpectrum)) s")
            try #require(plainSpectrum.voiceFrames >= 10 * 48_000, "the read of the mix has no gated voice")
            Self.expectC9(
                reference: referenceSpectrum.powers, target: targetSpectrum.powers, curve: curve.decibels,
                unmatched: plainSpectrum.powers, half: try #require(half.spectrum).powers,
                matched: try #require(matched.spectrum).powers)
        }
        let filter = MatchFilter(sampleRate: 48_000)
        let full = try match(100)
        for percent in percents.dropFirst() {
            let (amount, matched) = (VoiceMatch.Amount(percent)!, try #require(heard[percent]))
            let change = matched.loudness - unmatched.loudness
            print("CorpusVoiceMatchTests \(name): amount \(percent): loudness change \(Self.format(change)) LU")
            if !reverse && percent == 100 { #expect(abs(change) <= 1.0, "C9: loudness change \(change) LU") }
            guard percent >= 75 else { continue }
            let largest = full.gains(at: amount).decibels.max()!
            let taps = impulseResponse(filter, filter.kernel(full.gains(at: amount)))
            let bound = 20 * log10(taps.reduce(0.0) { $0 + Double(abs($1)) })
            let rise = matched.truePeak - unmatched.truePeak
            print(
                "CorpusVoiceMatchTests \(name): amount \(percent): true peak \(Self.format(unmatched.truePeak)) to "
                    + "\(Self.format(matched.truePeak)) dBTP, rise \(Self.format(rise)) dB, G \(Self.format(largest)) dB; "
                    + "sample peak change \(Self.format(matched.samplePeak - unmatched.samplePeak)) dB; "
                    + "P \(Self.format(bound)) dB, P - G \(Self.format(bound - largest)) dB")
            #expect(rise <= largest, "C25 \(name), amount \(percent): rise \(rise) dB over G \(largest) dB")
        }
    }

    /// The band spectrum of `parts`: the read of Match Voice.
    static func learn(_ parts: [VoicePart], _ session: Session, _ package: URL) throws -> BandSpectrum {
        try voiceSpectrum(parts, in: session, package: package, progress: { _ in }, isCancelled: { false })
    }

    /// C9 in each band that the curve did not cap or guard: the matched track is within 1.5 dB of
    /// the reference shape, its mean error is at most half the unmatched one, and amount 50 moves
    /// each band half the way within 0.75 dB. Each spectrum is scaled to the power of these bands.
    static func expectC9(
        reference: [Double], target: [Double], curve: [Double], unmatched: [Double], half: [Double], matched: [Double]
    ) {
        let inBand = ThirdOctave.centers.indices.filter { ThirdOctave.centers[$0] < 0.45 * 48_000 }
        let scale = inBand.reduce(0) { $0 + target[$1] } / inBand.reduce(0) { $0 + reference[$1] }
        let free = inBand.filter { abs(curve[$0] - 10 * log10(reference[$0] * scale / target[$0])) < 1e-9 }
        let errors = { (heard: [Double]) -> [Double] in
            let shape = free.reduce(0) { $0 + heard[$1] } / free.reduce(0) { $0 + reference[$1] }
            return free.map { 10 * log10(heard[$0] / (reference[$0] * shape)) }
        }
        let (before, after) = (errors(unmatched), errors(matched))
        let moves = free.map { band in
            let move = { (heard: [Double]) in 10 * log10(heard[band] / unmatched[band]) }
            return move(half) - move(matched) / 2
        }
        for (index, band) in free.enumerated() {
            print(
                "CorpusVoiceMatchTests band \(ThirdOctave.centers[band]) Hz: curve \(format(curve[band])) dB, "
                    + "error unmatched \(format(before[index])) dB, at 100 \(format(after[index])) dB, "
                    + "amount 50 off the half way by \(format(moves[index])) dB")
        }
        let mean = { (values: [Double]) in values.map(abs).reduce(0, +) / Double(values.count) }
        print(
            "CorpusVoiceMatchTests C9: \(free.count) of \(inBand.count) bands not capped or guarded; mean error "
                + "unmatched \(format(mean(before))) dB, matched \(format(mean(after))) dB")
        #expect(free.count >= inBand.count / 2, "C9: the curve caps or guards most bands")
        #expect(after.map(abs).max()! <= 1.5, "C9: a band over 1.5 dB from the reference: \(after)")
        #expect(mean(after) <= mean(before) / 2, "C9: mean error \(mean(after)) dB, unmatched \(mean(before)) dB")
        #expect(moves.map(abs).max()! <= 0.75, "C9: amount 50 off the half way: \(moves)")
    }

    /// Reads `track` of `session` through `MixReader` in chunks over the extent of its clips: the
    /// band spectrum when `spectrum`, the loudness, the true peak, and the sample peak.
    static func hear(_ session: Session, _ track: TrackID, package: URL, spectrum: Bool) throws -> Heard {
        let clips = try #require(session.track(track)).clips
        let (start, end) = (clips.map(\.start).min()!.count, clips.map(\.end).max()!.count)
        let mix = MixReader(package: package, session: session, tracks: [track])
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16))
        var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .stereo))
        var truePeak = TruePeakMeter(layout: .stereo)
        var samplePeak: Float = 0
        var position = start
        let fill = { (buffer: AVAudioPCMBuffer) -> Bool in
            guard position < end else { return false }
            let next = min(end, position + (1 << 16))
            mix.render(Frames(position)..<Frames(next), into: buffer)
            meter.feed(buffer)
            truePeak.feed(buffer)
            for channel in 0..<2 {
                var peak: Float = 0
                vDSP_maxmgv(buffer.floatChannelData![channel], 1, &peak, vDSP_Length(next - position))
                samplePeak = max(samplePeak, peak)
            }
            position = next
            return true
        }
        var heard: BandSpectrum?
        if spectrum {
            let analyzer = BandAnalyzer(sampleRate: 48_000)
            heard = analyzer.spectrum([try #require(analyzer.read(buffer, layout: .stereo, fill: fill))])
        } else {
            while fill(buffer) {}
        }
        return Heard(
            spectrum: heard, loudness: try #require(meter.result().integrated).value,
            truePeak: try #require(truePeak.result()), samplePeak: 20 * log10(Double(samplePeak)))
    }

    static func seconds(_ spectrum: BandSpectrum) -> String { format(Double(spectrum.voiceFrames) / 48_000) }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
