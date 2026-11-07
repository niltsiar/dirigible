import AVFoundation
import Accelerate

/// A gain over the frames of a run: one gain in dB for each 100 ms step, never one for each frame
/// (8 bytes a step: about 576 KB for 2 h). The gain of step i is at its centre, frame
/// (i + 0.5) x `stepFrames`. Before the first centre the curve has the first gain, after the last
/// centre the last gain, so it covers each frame of the run, also after a partial last step.
struct GainCurve: Sendable {
    let dB: [Double]
    let stepFrames: Int

    /// Precondition: at least one step, and `stepFrames` over 0.
    init(dB: [Double], stepFrames: Int) {
        precondition(!dB.isEmpty && stepFrames > 0, "a gain curve has at least one step of at least one frame")
        self.dB = dB
        self.stepFrames = stepFrames
    }

    /// Multiplies each channel of `buffer` by the curve, from run frame `firstFrame`. Between two
    /// centres the amplitude, 10^(dB/20), ramps linearly, so the result does not depend on where
    /// the buffers split. Precondition: deinterleaved Float32.
    func apply(to buffer: AVAudioPCMBuffer, firstFrame: Int) {
        precondition(
            buffer.format.commonFormat == .pcmFormatFloat32 && !buffer.format.isInterleaved,
            "a gain curve takes deinterleaved Float32")
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        var ramp = [Double](repeating: 0, count: frames)
        ramp.withUnsafeMutableBufferPointer { ramp in
            var start = 0
            while start < frames {
                let (end, initial, increment) = segment(at: firstFrame + start, until: firstFrame + frames)
                var part = UnsafeMutableBufferPointer(rebasing: ramp[start..<end - firstFrame])
                vDSP.formRamp(withInitialValue: initial, increment: increment, result: &part)
                start = end - firstFrame
            }
        }
        let amplitudes = vDSP.doubleToFloat(ramp)
        for channel in 0..<Int(buffer.format.channelCount) {
            var samples = UnsafeMutableBufferPointer(start: channels[channel], count: frames)
            vDSP.multiply(samples, amplitudes, result: &samples)
        }
    }

    /// The linear piece of the amplitude that holds run frame `frame`: the run frame where it
    /// ends (at most `limit`), and its amplitude at `frame` and its change for each frame.
    private func segment(at frame: Int, until limit: Int) -> (end: Int, initial: Double, increment: Double) {
        let position = Double(frame) / Double(stepFrames) - 0.5
        let last = dB.count - 1
        if position < 0 {
            let firstCentre = Int((0.5 * Double(stepFrames)).rounded(.up))
            return (min(limit, max(frame + 1, firstCentre)), amplitude(0), 0)
        }
        let step = Int(position.rounded(.down))
        if step >= last { return (limit, amplitude(last), 0) }
        let nextCentre = Int(((Double(step) + 1.5) * Double(stepFrames)).rounded(.up))
        let increment = (amplitude(step + 1) - amplitude(step)) / Double(stepFrames)
        let initial = amplitude(step) + increment * (Double(frame) - (Double(step) + 0.5) * Double(stepFrames))
        return (min(limit, max(frame + 1, nextCentre)), initial, increment)
    }

    private func amplitude(_ step: Int) -> Double { pow(10, dB[step] / 20) }
}
