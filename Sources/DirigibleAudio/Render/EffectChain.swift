import AVFoundation
import Accelerate
import AudioToolbox
import DirigibleCore
import Foundation

/// The description of an effect unit, named here so DirigibleMCP needs no AudioToolbox import (decision 0046).
package typealias EffectUnit = AudioComponentDescription

extension AudioComponentDescription {
    /// AUSoundIsolation of Apple, the unit of the noise effect (decision 0054).
    package static let soundIsolation = AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
}

/// One AVAudioEngine in offline manual rendering at the rate and the channel count of a source
/// (decision 0054): a player node, the hum band-stop when the treatment holds hum, AUSoundIsolation
/// with the Voice model when it holds noise, and the engine output, then one gain stage of a
/// constant `scale`. Stereo is joint: one unit for both channels. Make a new chain for each run
/// and each pass: no engine renders twice.
struct EffectChain {
    /// The frames of each source block. The player node holds at most two blocks that it did not
    /// render, so a run of any length holds the same source memory.
    static let blockFrames = 65_536
    /// The frames of each engine pull. The unit output depends on the pull pattern: a first pull of
    /// 2048 or 3200 frames, or pulls of 8192, change it, so every full pull has this size. A short
    /// last pull gives the same frames as a full one (`shortLastPullKeepsTheTail`).
    static let pullFrames: AVAudioFrameCount = 4096
    /// The widths of the hum bands in octaves: the band at f takes a mains drift of 0.2 Hz (C17 of
    /// decision 0054); the narrow bands at 2f to 4f keep the voice harmonics between them (M1b).
    static let humOctaves: (fundamental: Float, harmonic: Float) = (0.2, 0.015)

    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat
    private let scale: Float
    /// The frames that the stages delay their output, read after the engine starts: the unit
    /// latency depends on the channel count, so no code uses a constant.
    let latency: Int

    init(
        _ treatment: Treatment, scale: Float, rate: Double, channels: Int, component: AudioComponentDescription
    ) throws(ClipRenderError) {
        var (hum, wet): (Hum?, Float?) = (nil, nil)
        for effect in treatment.effects {
            switch effect {
            case .hum(let hertz): hum = hertz
            case .noise(let amount): wet = amount.wetDryMixPercent
            }
        }
        try self.init(hum: hum, wet: wet, scale: scale, rate: rate, channels: channels, component: component)
    }

    /// The chain with a raw wet value and no hum: tests give 0 for the null of the dry path.
    init(
        wetDryMixPercent wet: Float, scale: Float, rate: Double, channels: Int, component: AudioComponentDescription
    ) throws(ClipRenderError) {
        try self.init(hum: nil, wet: wet, scale: scale, rate: rate, channels: channels, component: component)
    }

    /// The chain with the band-stop of `hum` when it is set, then the voice unit at `wet` when it
    /// is set. Only the voice unit loads `component`.
    private init(
        hum: Hum?, wet: Float?, scale: Float, rate: Double, channels: Int, component: AudioComponentDescription
    ) throws(ClipRenderError) {
        var stages: [AVAudioUnit] = []
        if let hum { stages.append(try Self.humFilter(hum)) }
        if let wet { stages.append(try Self.voiceUnit(wet: wet, component: component)) }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))
        else { throw .effectUnavailable(status: kAudio_ParamError) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.pullFrames)
        } catch {
            throw .engine(status: Int32((error as NSError).code))
        }
        engine.attach(player)
        var last: AVAudioNode = player
        for stage in stages {
            engine.attach(stage)
            engine.connect(last, to: stage, format: format)
            last = stage
        }
        engine.connect(last, to: engine.outputNode, format: format)
        do { try engine.start() } catch { throw .effectUnavailable(status: Int32((error as NSError).code)) }
        player.play()
        (self.engine, self.player, self.format, self.scale) = (engine, player, format, scale)
        latency = Int((stages.reduce(0) { $0 + $1.latency } * rate).rounded())
    }

    /// The band-stop of `hum`: one `bandStop` band at f, 2f, 3f, and 4f, with the widths of
    /// `humOctaves`. The writes go to the unit: a write through `bands` passes the parameter tree of
    /// the AU bridge, and a tree rebuild on another thread can drop it.
    static func humFilter(_ hum: Hum) throws(ClipRenderError) -> AVAudioUnitEQ {
        let filter = AVAudioUnitEQ(numberOfBands: 4)
        for band in 0..<4 {
            for (parameter, value) in [
                (kAUNBandEQParam_FilterType, Float(kAUNBandEQFilterType_BandStop)),
                (kAUNBandEQParam_Frequency, Float(hum.rawValue * (band + 1))),
                (kAUNBandEQParam_Bandwidth, band == 0 ? humOctaves.fundamental : humOctaves.harmonic),
                // A band of `AVAudioUnitEQ` starts bypassed.
                (kAUNBandEQParam_BypassBand, 0),
            ] {
                let status = AudioUnitSetParameter(
                    filter.audioUnit, parameter + AudioUnitParameterID(band), kAudioUnitScope_Global, 0, value, 0)
                guard status == noErr else { throw .effectUnavailable(status: status) }
            }
        }
        return filter
    }

    /// AUSoundIsolation of `component` with the Voice model at `wet`.
    static func voiceUnit(wet: Float, component: AudioComponentDescription) throws(ClipRenderError)
        -> AVAudioUnitEffect
    {
        var description = component
        // `invalidComponentID` (-3000) of CarbonCore: no component matches the description.
        guard AudioComponentFindNext(nil, &description) != nil else { throw .effectUnavailable(status: -3000) }
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        for (parameter, value) in [
            (kAUSoundIsolationParam_SoundToIsolate, Float(kAUSoundIsolationSoundType_Voice)),
            (kAUSoundIsolationParam_WetDryMixPercent, wet),
        ] {
            let status = AudioUnitSetParameter(
                effect.audioUnit, AudioUnitParameterID(parameter), kAudioUnitScope_Global, 0, value, 0)
            guard status == noErr else { throw .effectUnavailable(status: status) }
        }
        return effect
    }

    /// Renders the frames `span` of `source` (open at `descriptor` too) into `sink`: span +
    /// `latency` frames, with the first `latency` frames dropped, each frame times `scale`. `sink`
    /// gets each pull in one reused buffer, valid only during the call. `isCancelled` is read
    /// before each block read, and `readFault` runs before block `block` of the file `stem` (tests
    /// only). `rendered` gets the frames given to `sink`. Returns those frames and the peak of all
    /// channels after the scale. `file` names the source in errors.
    func render(
        _ source: AVAudioFile, descriptor: Int32, span: Range<AVAudioFramePosition>,
        into sink: (AVAudioPCMBuffer) throws(ClipRenderError) -> Void, file: String, stem: String,
        readFault: ReadFault?, isCancelled: () -> Bool, rendered: (Int) -> Void
    ) throws(ClipRenderError) -> (length: Int, peak: Float) {
        source.framePosition = span.lowerBound
        var block = 0
        return try render(count: Int(span.upperBound - span.lowerBound), into: sink, rendered: rendered) {
            frames throws(ClipRenderError) in
            guard !isCancelled() else { throw .cancelled }
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
            block += 1
            return buffer
        }
    }

    /// Renders each frame of `input`, in the format of the chain, into `sink`, as the file render
    /// does. `isCancelled` is read before each block.
    func render(
        _ input: AVAudioPCMBuffer, into sink: (AVAudioPCMBuffer) throws(ClipRenderError) -> Void,
        isCancelled: () -> Bool
    ) throws(ClipRenderError) -> (length: Int, peak: Float) {
        var start = 0
        return try render(count: Int(input.frameLength), into: sink) {
            frames throws(ClipRenderError) in
            guard !isCancelled() else { throw .cancelled }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw .engine(status: kAudio_MemFullError)
            }
            buffer.frameLength = frames
            for channel in 0..<Int(format.channelCount) {
                buffer.floatChannelData![channel].update(
                    from: input.floatChannelData![channel] + start, count: Int(frames))
            }
            start += Int(frames)
            return buffer
        }
    }

    /// The pull loop of a render of `count` frames: `next` gives the next source block of at most
    /// the frames that it gets.
    private func render(
        count: Int, into sink: (AVAudioPCMBuffer) throws(ClipRenderError) -> Void, rendered: (Int) -> Void = { _ in },
        next: (AVAudioFrameCount) throws(ClipRenderError) -> AVAudioPCMBuffer
    ) throws(ClipRenderError) -> (length: Int, peak: Float) {
        let total = count + latency
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.pullFrames),
            let kept = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.pullFrames)
        else { throw .engine(status: kAudio_MemFullError) }
        var (scheduled, pulled, length, peak) = (0, 0, 0, Float(0))
        while pulled < total {
            // The next block goes in when one block or less waits, so at most two wait.
            while scheduled < count, scheduled - pulled <= Self.blockFrames {
                let buffer = try next(AVAudioFrameCount(min(Self.blockFrames, count - scheduled)))
                player.scheduleBuffer(buffer)
                scheduled += Int(buffer.frameLength)
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
            try sink(kept)
            length += Int(kept.frameLength)
            rendered(length)
        }
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
