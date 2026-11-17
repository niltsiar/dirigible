import AVFoundation
import Accelerate
import DirigibleCore

/// One read of a voice match measure (decision 0074 D5): the file frames `frames` of `file`,
/// times `gain`. A clip gives its file frames and its clip gain, with no fade, envelope, ride,
/// track gain, or match stage.
package struct VoicePart: Hashable, Sendable {
    package let file: FileID
    package let frames: Range<Frames>
    package let gain: Gain

    package init(file: FileID, frames: Range<Frames>, gain: Gain) {
        (self.file, self.frames, self.gain) = (file, frames, gain)
    }
}

/// Why a voice match read stopped. It changes nothing.
package enum MatchReadError: Error, Equatable {
    case cancelled
    /// A source file is missing, short, or unreadable (also a NaN or an infinity in it).
    case fault(FileID, MediaFault)
    /// The process had no free descriptor: the errno.
    case descriptor(Int32)
}

/// The band spectrum of `parts`: one read of each part, with the BS.1770 gates over the blocks of
/// all parts. A Hann frame counts when each 100 ms step that it touches lies in a block that
/// passes both gates; it counts for the noise estimate when each such block passes the absolute
/// gate. `progress` gets the frames done. It reads the disk, so never call it on the main actor.
package func voiceSpectrum(
    _ parts: [VoicePart], in session: Session, package: URL, progress: (Int) -> Void, isCancelled: () -> Bool
) throws(MatchReadError) -> BandSpectrum {
    let analyzer = BandAnalyzer(sampleRate: session.sampleRate)
    var reads: [PartRead] = []
    var done = 0
    for part in parts {
        let before = done
        reads.append(
            try analyzer.read(
                part, in: session, package: package, progress: { progress(before + $0) }, isCancelled: isCancelled))
        done += part.frames.upperBound.count - part.frames.lowerBound.count
    }
    return analyzer.spectrum(reads)
}

/// The steps and the frame band powers of one part.
struct PartRead {
    /// The mean square of each complete 100 ms step, with the gain.
    var steps: [Double] = []
    /// 25 band powers for each Hann frame, frame j at part frame j x `BandAnalyzer.hop`.
    var frames: [Double] = []
}

/// The Hann frames of a voice match read and their one-third-octave band powers. One owner.
final class BandAnalyzer {
    static let length = 8_192
    static let hop = 4_096
    private static let log2Length = vDSP_Length(13)
    let sampleRate: Int
    let stepFrames: Int
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: length)
    /// The bins of each band, each with the part of its width inside the band.
    private let bands: [[(bin: Int, weight: Double)]]
    private var windowed = [Float](repeating: 0, count: length)
    private var real = [Float](repeating: 0, count: length / 2)
    private var imaginary = [Float](repeating: 0, count: length / 2)
    private var magnitudes = [Float](repeating: 0, count: length / 2)

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
        stepFrames = Int((Double(sampleRate) / 10).rounded())
        guard let setup = vDSP_create_fftsetup(Self.log2Length, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP has no FFT setup of 8,192 points")
        }
        self.setup = setup
        vDSP_hann_window(&window, vDSP_Length(Self.length), Int32(vDSP_HANN_NORM))
        let width = Double(sampleRate) / Double(Self.length)
        bands = (0..<ThirdOctave.bandCount).map { band in
            let (lower, upper) = ThirdOctave.edges(of: band)
            return (1..<Self.length / 2).compactMap { bin in
                let overlap = min(upper, (Double(bin) + 0.5) * width) - max(lower, (Double(bin) - 0.5) * width)
                return overlap > 0 ? (bin, overlap / width) : nil
            }
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Reads `part` in blocks of 65,536 frames with its gain: the meter steps and the frames.
    func read(
        _ part: VoicePart, in session: Session, package: URL, progress: (Int) -> Void, isCancelled: () -> Bool
    ) throws(MatchReadError) -> PartRead {
        guard let entry = session.files[part.file] else { throw .fault(part.file, .missing) }
        let opened: (file: AVAudioFile?, fault: MediaFault?, stamp: FileStamp?)
        do throws(POSIXError) {
            opened = try openMedia(entry, in: package.appending(path: clipsFolderName), rate: sampleRate)
        } catch {
            throw .descriptor(error.code.rawValue)
        }
        if let fault = opened.fault { throw .fault(part.file, fault) }
        guard let audio = opened.file,
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 65_536),
            let data = buffer.floatChannelData
        else { return PartRead() }
        var factor = Float(pow(10, part.gain.dB / 20))
        let (start, end) = (part.frames.lowerBound.count, part.frames.upperBound.count)
        var position = start
        audio.framePosition = AVAudioFramePosition(position)
        let frames = try read(buffer, layout: entry.layout) { buffer throws(MatchReadError) in
            guard position < end else { return false }
            if isCancelled() { throw .cancelled }
            do { try audio.read(into: buffer, frameCount: AVAudioFrameCount(min(65_536, end - position))) } catch {
                throw .fault(part.file, .unreadable)
            }
            let count = Int(buffer.frameLength)
            guard count > 0 else { throw .fault(part.file, .unreadable) }
            for channel in 0..<Int(buffer.format.channelCount) {
                vDSP_vsmul(data[channel], 1, &factor, data[channel], 1, vDSP_Length(count))
            }
            position += count
            progress(position - start)
            return true
        }
        guard let frames else { throw .fault(part.file, .unreadable) }
        return frames
    }

    /// The meter steps and the frames of the audio that `fill` puts in `buffer`, one block after
    /// the other, until it returns false: the file read above, or a mix render. Nil when a sample is
    /// not finite.
    func read<Failure: Error>(
        _ buffer: AVAudioPCMBuffer, layout: ChannelLayout, fill: (AVAudioPCMBuffer) throws(Failure) -> Bool
    ) throws(Failure) -> PartRead? {
        guard var meter = LoudnessMeter(sampleRate: sampleRate, layout: layout, keepsSteps: true),
            let data = buffer.floatChannelData
        else { return PartRead() }
        var pending = [[Float]](repeating: [], count: Int(buffer.format.channelCount))
        var result = PartRead()
        while try fill(buffer) {
            for channel in pending.indices {
                pending[channel].append(
                    contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
            }
            meter.feed(buffer)
            var offset = 0
            while pending[0].count - offset >= Self.length {
                var powers = [Double](repeating: 0, count: ThirdOctave.bandCount)
                for channel in pending.indices {
                    pending[channel].withUnsafeBufferPointer { add($0.baseAddress! + offset, to: &powers) }
                }
                result.frames += powers
                offset += Self.hop
            }
            for channel in pending.indices { pending[channel].removeFirst(offset) }
        }
        if meter.nonFinite { return nil }
        result.steps = meter.stepMeanSquares ?? []
        return result
    }

    /// Adds the band powers of the Hann frame of `length` samples at `samples` to `powers`.
    private func add(_ samples: UnsafePointer<Float>, to powers: inout [Double]) {
        let half = Self.length / 2
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(Self.length))
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                windowed.withUnsafeBufferPointer {
                    $0.withMemoryRebound(to: DSPComplex.self) {
                        vDSP_ctoz($0.baseAddress!, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, Self.log2Length, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }
        for (band, bins) in bands.enumerated() {
            powers[band] += bins.reduce(0) { $0 + Double(magnitudes[$1.bin]) * $1.weight }
        }
    }

    /// The gates over the blocks of all `reads`, then the mean band powers of the gated frames,
    /// the noise estimate, and the covered frames.
    func spectrum(_ reads: [PartRead]) -> BandSpectrum {
        let blockSteps = LoudnessMeter.blockSteps
        let blocks = reads.map { read in
            read.steps.count < blockSteps
                ? []
                : (0...read.steps.count - blockSteps).map {
                    read.steps[$0..<$0 + blockSteps].reduce(0, +) / Double(blockSteps)
                }
        }
        let absolute = Loudness.meanSquare(Loudness.absoluteGate)
        let loud = blocks.joined().filter { $0 > absolute }
        let relative =
            loud.isEmpty
            ? .infinity : max(absolute, loud.reduce(0, +) / Double(loud.count) * pow(10, Loudness.relativeGate / 10))
        var (sum, count, voiceSteps) = ([Double](repeating: 0, count: ThirdOctave.bandCount), 0, 0)
        var noise = [[Double]](repeating: [], count: ThirdOctave.bandCount)
        for (read, blocks) in zip(reads, blocks) {
            // The steps that a block over each gate covers.
            var (gated, overAbsolute) = (
                [Bool](repeating: false, count: read.steps.count), [Bool](repeating: false, count: read.steps.count)
            )
            for (index, block) in blocks.enumerated() {
                for step in index..<index + blockSteps {
                    gated[step] = gated[step] || block > relative
                    overAbsolute[step] = overAbsolute[step] || block > absolute
                }
            }
            voiceSteps += gated.count { $0 }
            for frame in 0..<read.frames.count / ThirdOctave.bandCount {
                let first = frame * Self.hop / stepFrames
                let last = (frame * Self.hop + Self.length - 1) / stepFrames
                guard last < read.steps.count else { break }
                let powers = read.frames[frame * ThirdOctave.bandCount..<(frame + 1) * ThirdOctave.bandCount]
                if overAbsolute[first...last].allSatisfy({ $0 }) {
                    for (band, power) in zip(0..., powers) { noise[band].append(power) }
                }
                guard gated[first...last].allSatisfy({ $0 }) else { continue }
                for (band, power) in zip(0..., powers) { sum[band] += power }
                count += 1
            }
        }
        return BandSpectrum(
            powers: sum.map { count == 0 ? 0 : $0 / Double(count) },
            noise: noise.map { $0.isEmpty ? 0 : $0.sorted()[Int(0.1 * Double($0.count - 1))] },
            voiceFrames: voiceSteps * stepFrames)
    }
}
