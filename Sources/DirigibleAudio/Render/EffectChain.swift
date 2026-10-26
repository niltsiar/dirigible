import AVFoundation
import Accelerate
import AudioToolbox
import DirigibleCore
import Foundation

extension AudioComponentDescription {
    /// AUSoundIsolation of Apple, the unit of the noise effect (decision 0054).
    package static let soundIsolation = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
}

/// One AVAudioEngine in offline manual rendering at the rate and the channel count of a source
/// (decision 0054): a player node, AUSoundIsolation with the Voice model, and the engine output,
/// then one gain stage of a constant `scale`. Stereo is joint: one unit for both channels. Make a
/// new chain for each run and each pass: no engine renders twice.
struct EffectChain {
    /// The frames of each source block. The player node holds at most two blocks that it did not
    /// render, so a run of any length holds the same source memory.
    static let blockFrames = 65_536
    /// The frames of each engine pull.
    static let pullFrames: AVAudioFrameCount = 4096

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let scale: Float
    /// The frames that the unit delays its output, read after the engine starts: it depends on the
    /// channel count, so no code uses a constant.
    let latency: Int

    init(
        _ treatment: Treatment, scale: Float, rate: Double, channels: Int, component: AudioComponentDescription
    ) throws(ClipRenderError) {
        var wet: Float = 0
        for effect in treatment.effects {
            switch effect {
            case .noise(let amount): wet = amount.wetDryMixPercent
            }
        }
        try self.init(wetDryMixPercent: wet, scale: scale, rate: rate, channels: channels, component: component)
    }

    /// The chain with a raw wet value: tests give 0 for the null of the dry path.
    init(
        wetDryMixPercent wet: Float, scale: Float, rate: Double, channels: Int, component: AudioComponentDescription
    ) throws(ClipRenderError) {
        var description = component
        // `invalidComponentID` (-3000) of CarbonCore: no component matches the description.
        guard AudioComponentFindNext(nil, &description) != nil else { throw .effectUnavailable(status: -3000) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))
        else { throw .effectUnavailable(status: kAudio_ParamError) }
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        for (parameter, value) in [
            (kAUSoundIsolationParam_SoundToIsolate, Float(kAUSoundIsolationSoundType_Voice)),
            (kAUSoundIsolationParam_WetDryMixPercent, wet),
        ] {
            let status = AudioUnitSetParameter(
                effect.audioUnit, AudioUnitParameterID(parameter), kAudioUnitScope_Global, 0, value, 0)
            guard status == noErr else { throw .effectUnavailable(status: status) }
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.pullFrames)
        } catch {
            throw .engine(status: Int32((error as NSError).code))
        }
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.outputNode, format: format)
        do { try engine.start() } catch { throw .effectUnavailable(status: Int32((error as NSError).code)) }
        player.play()
        (self.engine, self.player, self.format, self.scale) = (engine, player, format, scale)
        latency = Int((effect.latency * rate).rounded())
    }

    /// Renders the frames `span` of `source` (open at `descriptor` too) into `writer`, and closes
    /// it: span + `latency` frames, with the first `latency` frames dropped, each frame times
    /// `scale`. `isCancelled` is read before each block read, and `readFault` runs before block
    /// `block` of the file `stem` (tests only). `rendered` gets the frames written. Returns the
    /// frames written and the peak of all channels after the scale. `file` and `wav` name the
    /// source and the new WAV in errors.
    func render(
        _ source: AVAudioFile, descriptor: Int32, span: Range<AVAudioFramePosition>, into writer: ClipWriter,
        file: String, wav: String, stem: String, readFault: ReadFault?, isCancelled: () -> Bool,
        rendered: (Int) -> Void
    ) throws(ClipRenderError) -> (length: Int, peak: Float) {
        let count = Int(span.upperBound - span.lowerBound)
        let total = count + latency
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.pullFrames),
            let kept = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.pullFrames)
        else { throw .engine(status: kAudio_MemFullError) }
        source.framePosition = span.lowerBound
        var (scheduled, pulled, block, length, peak) = (0, 0, 0, 0, Float(0))
        while pulled < total {
            // The next block goes in when one block or less waits, so at most two wait.
            while scheduled < count, scheduled - pulled <= Self.blockFrames {
                guard !isCancelled() else { throw .cancelled }
                let frames = AVAudioFrameCount(min(Self.blockFrames, count - scheduled))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: frames) else {
                    throw .engine(status: kAudio_MemFullError)
                }
                do {
                    if let readFault, readFault.stem == stem, readFault.block == block { try readFault.before() }
                    try source.read(into: buffer, frameCount: frames)
                } catch {
                    throw .sourceUnreadable(file: file, errno: ioErrno(of: error, file: descriptor) ?? EIO)
                }
                guard buffer.frameLength > 0 else { throw .sourceUnreadable(file: file, errno: EIO) }
                player.scheduleBuffer(buffer)
                scheduled += Int(buffer.frameLength)
                block += 1
            }
            let frames = min(Int(Self.pullFrames), total - pulled)
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(AVAudioFrameCount(frames), to: output)
            } catch {
                throw .engine(status: Int32((error as NSError).code))
            }
            guard status == .success, Int(output.frameLength) == frames else {
                throw .engine(status: Int32(status.rawValue))
            }
            let drop = min(frames, max(0, latency - pulled))
            pulled += frames
            guard drop < frames else { continue }
            peak = max(peak, copy(output, from: drop, into: kept))
            do throws(FinalizeError) { try writer.write(kept) } catch { throw ClipRenderError(error, wav: wav) }
            length += Int(kept.frameLength)
            rendered(length)
        }
        do throws(FinalizeError) { try writer.close() } catch { throw ClipRenderError(error, wav: wav) }
        return (length, peak)
    }

    /// Copies the frames of `output` from `start` into `kept`, times `scale`, and returns their peak.
    private func copy(_ output: AVAudioPCMBuffer, from start: Int, into kept: AVAudioPCMBuffer) -> Float {
        let frames = Int(output.frameLength) - start
        kept.frameLength = AVAudioFrameCount(frames)
        var peak: Float = 0
        for channel in 0..<Int(format.channelCount) {
            let from = output.floatChannelData![channel] + start
            let to = kept.floatChannelData![channel]
            var (factor, level) = (scale, Float(0))
            vDSP_vsmul(from, 1, &factor, to, 1, vDSP_Length(frames))
            vDSP_maxmgv(to, 1, &level, vDSP_Length(frames))
            peak = max(peak, level)
        }
        return peak
    }
}

extension ClipRenderError {
    /// The render error of a fault of the new WAV `wav`.
    init(_ error: FinalizeError, wav: String) {
        switch error {
        case .readFailed(_, let code), .writeFailed(_, let code), .segmentUnreadable(_, _, let code):
            self = .write(file: wav, errno: code)
        }
    }
}
