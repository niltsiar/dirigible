import Accelerate
import DirigibleCore
import Foundation

/// The filter of a voice match (decision 0074 D2): a linear-phase FIR made from 25 band gains by
/// frequency sampling and a Kaiser window (beta 5), applied by FFT overlap-save. The taps scale
/// with the rate, so each rate keeps the frequency resolution of 16,385 taps at 48 kHz.
/// One owner, not Sendable: `kernel(_:)` and `filter(_:through:into:)` use the scratch of the
/// filter. `kernel(_:)` allocates; `filter(_:through:into:)` does not.
final class MatchFilter {
    let sampleRate: Int
    /// The power of two at or over rate x 16,384 / 48,000, plus 1: 16,385 at 32 to 48 kHz,
    /// 32,769 at 88.2 and 96 kHz.
    let taps: Int
    /// The frames that `filter(_:through:into:)` reads before and after each output frame.
    var contextFrames: Int { (taps - 1) / 2 }

    /// The points of a block and of the design grid. A block gives taps - 1 output frames.
    private let points: Int
    private let log2Points: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let block: UnsafeMutablePointer<Float>

    /// The spectrum of one kernel, scaled for the overlap-save of a filter of the same rate.
    struct Kernel: Sendable {
        fileprivate let sampleRate: Int
        fileprivate let real: [Float]
        fileprivate let imaginary: [Float]
    }

    init(sampleRate: Int) {
        precondition(sampleRate > 0, "A sample rate is positive")
        var power = 2
        while power * 48_000 < sampleRate * 16_384 { power *= 2 }
        self.sampleRate = sampleRate
        taps = power + 1
        points = 2 * power
        log2Points = vDSP_Length(points.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2Points, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("vDSP made no FFT setup of \(points) points")
        }
        self.setup = setup
        let last = Double(power)
        let besselOfBeta = Self.bessel0(5)
        window = (0...power).map { index in
            let position = 2 * Double(index) / last - 1
            return Float(Self.bessel0(5 * (1 - position * position).squareRoot()) / besselOfBeta)
        }
        real = .allocate(capacity: points / 2)
        imaginary = .allocate(capacity: points / 2)
        block = .allocate(capacity: points)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        real.deallocate()
        imaginary.deallocate()
        block.deallocate()
    }

    /// Designs the kernel of `gains`: the zero-phase response of `gain(at:of:)` on a grid of
    /// `points`, shifted to the center tap and windowed.
    func kernel(_ gains: ThirdOctave.Gains) -> Kernel {
        let half = points / 2
        let binWidth = Double(sampleRate) / Double(points)
        for bin in 0..<half {
            real[bin] = Float(pow(10, gain(at: Double(bin) * binWidth, of: gains) / 20))
            imaginary[bin] = 0
        }
        // The packed form of vDSP keeps the Nyquist bin in the imaginary part of bin 0.
        imaginary[0] = Float(pow(10, gain(at: Double(sampleRate) / 2, of: gains) / 20))
        inverse()
        // The DC gain is 0 dB, so the sum of the circular response is the scale of the inverse.
        var scale: Float = 0
        vDSP_sve(block, 1, &scale, vDSP_Length(points))
        let center = contextFrames
        var padded = [Float](repeating: 0, count: points)
        for tap in 0..<taps { padded[tap] = block[(tap - center + points) % points] / scale * window[tap] }
        padded.withUnsafeBufferPointer { forward($0.baseAddress!) }
        // A forward transform scales by 2 and an inverse by points, so a product of two forward
        // transforms comes back 4 x points times too large.
        var factor = Float(1 / (4 * Double(points)))
        var kernelReal = [Float](repeating: 0, count: half)
        var kernelImaginary = [Float](repeating: 0, count: half)
        vDSP_vsmul(real, 1, &factor, &kernelReal, 1, vDSP_Length(half))
        vDSP_vsmul(imaginary, 1, &factor, &kernelImaginary, 1, vDSP_Length(half))
        return Kernel(sampleRate: sampleRate, real: kernelReal, imaginary: kernelImaginary)
    }

    /// Writes output frame i from input frames i to i + taps - 1, centered on input frame
    /// i + `contextFrames`. The input holds the output count plus taps - 1 frames.
    func filter(
        _ input: UnsafeBufferPointer<Float>, through kernel: Kernel, into output: UnsafeMutableBufferPointer<Float>
    ) {
        precondition(kernel.sampleRate == sampleRate, "the kernel is of a filter of another rate")
        precondition(input.count == output.count + taps - 1, "the input holds the context on each side")
        guard let source = input.baseAddress, let target = output.baseAddress else { return }
        let half = points / 2
        var done = 0
        while done < output.count {
            let count = min(taps - 1, output.count - done)
            let available = input.count - done
            if available >= points {
                forward(source + done)
            } else {
                block.update(from: source + done, count: available)
                (block + available).update(repeating: 0, count: points - available)
                forward(block)
            }
            let dc = real[0] * kernel.real[0]
            let nyquist = imaginary[0] * kernel.imaginary[0]
            kernel.real.withUnsafeBufferPointer { kernelReal in
                kernel.imaginary.withUnsafeBufferPointer { kernelImaginary in
                    var spectrum = DSPSplitComplex(realp: real, imagp: imaginary)
                    var response = DSPSplitComplex(
                        realp: UnsafeMutablePointer(mutating: kernelReal.baseAddress!),
                        imagp: UnsafeMutablePointer(mutating: kernelImaginary.baseAddress!))
                    vDSP_zvmul(&spectrum, 1, &response, 1, &spectrum, 1, vDSP_Length(half), 1)
                }
            }
            real[0] = dc
            imaginary[0] = nyquist
            inverse()
            (target + done).update(from: block + taps - 1, count: count)
            done += count
        }
    }

    /// The gain in dB of the kernel at `frequency`: dB linear on log f between the band centers.
    /// Past the end bands, a boost goes to 0 dB at the band edge, a cut at 63 Hz holds to the band
    /// edge and goes to 0 dB one octave lower (28.1 Hz), and a cut at 16 kHz goes to 0 dB at the
    /// band edge. DC and each frequency at and over 0.45 x the rate get 0 dB.
    private func gain(at frequency: Double, of gains: ThirdOctave.Gains) -> Double {
        let decibels = gains.decibels
        let centers = ThirdOctave.centers
        let last = ThirdOctave.bandCount - 1
        guard frequency > 0, frequency < 0.45 * Double(sampleRate) else { return 0 }
        if frequency < centers[0] {
            let edge = ThirdOctave.edges(of: 0).lower
            if decibels[0] > 0 {
                return frequency <= edge ? 0 : decibels[0] * log2(frequency / edge) / log2(centers[0] / edge)
            }
            if frequency >= edge { return decibels[0] }
            return frequency <= edge / 2 ? 0 : decibels[0] * log2(frequency / (edge / 2))
        }
        if frequency > centers[last] {
            let edge = ThirdOctave.edges(of: last).upper
            return frequency >= edge ? 0 : decibels[last] * log2(edge / frequency) / log2(edge / centers[last])
        }
        var band = 0
        while band < last - 1 && frequency > centers[band + 1] { band += 1 }
        let position = log(frequency / centers[band]) / log(centers[band + 1] / centers[band])
        return decibels[band] + position * (decibels[band + 1] - decibels[band])
    }

    /// Packs `source` (`points` frames) into the split scratch and transforms it in place.
    private func forward(_ source: UnsafePointer<Float>) {
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        source.withMemoryRebound(to: DSPComplex.self, capacity: points / 2) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(points / 2))
        }
        vDSP_fft_zrip(setup, &split, 1, log2Points, FFTDirection(kFFTDirection_Forward))
    }

    /// Transforms the split scratch back in place and unpacks it into `block`.
    private func inverse() {
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        vDSP_fft_zrip(setup, &split, 1, log2Points, FFTDirection(kFFTDirection_Inverse))
        block.withMemoryRebound(to: DSPComplex.self, capacity: points / 2) {
            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(points / 2))
        }
    }

    /// The modified Bessel function of the first kind, order 0, by its power series.
    private static func bessel0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        var k = 1.0
        while term > 1e-12 * sum {
            term *= (x / (2 * k)) * (x / (2 * k))
            sum += term
            k += 1
        }
        return sum
    }
}
