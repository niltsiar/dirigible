import AVFoundation
import Accelerate
import AudioToolbox
import DirigibleCore
import Foundation

public enum BitDepth: Int, Hashable, Sendable, CaseIterable {
    case bits16 = 16
    case bits24 = 24
}

/// The bit rates in kbit/s of a lossy export. AAC takes each for mono and stereo at 44.1 and
/// 48 kHz (probe P5); MP3 at 32, 44.1, and 48 kHz (decision 0034).
public enum BitRate: Int, Hashable, Sendable, CaseIterable {
    case k64 = 64
    case k96 = 96
    case k128 = 128
    case k160 = 160
    case k192 = 192
    case k256 = 256
}

/// A bit depth goes only with WAV or FLAC, a bit rate only with AAC or MP3. `.floatCAF` is the
/// 32-bit float CAF of `dirigible render`; the app does not offer it (decision 0019). MP3 goes
/// through LAME (decision 0034).
public enum ExportFormat: Hashable, Sendable {
    case wav(BitDepth)
    case flac(BitDepth)
    case aac(BitRate)
    case mp3(BitRate)
    case floatCAF
}

public enum ExportRate: Hashable, Sendable, CaseIterable {
    case session, hz44100, hz48000

    /// The file rate in Hz for a session at `sessionRate`.
    func hertz(session sessionRate: Int) -> Int {
        switch self {
        case .session: sessionRate
        case .hz44100: 44_100
        case .hz48000: 48_000
        }
    }
}

/// A loudness target of decision 0008. A mono export is 3 LU lower than a stereo export.
public enum LoudnessTarget: String, CaseIterable, Hashable, Sendable {
    case podcast, speech, ebu, atsc

    public func integrated(for layout: ChannelLayout) -> LUFS {
        let stereo: Double =
            switch self {
            case .podcast: -16
            case .speech: -18
            case .ebu: -23
            case .atsc: -24
            }
        return LUFS(value: layout == .stereo ? stereo : stereo - 3)
    }
}

public struct ExportOptions: Hashable, Sendable {
    public var format: ExportFormat
    public var layout: ChannelLayout
    public var rate: ExportRate
    /// Nil: no gain and no limiter.
    public var loudness: LoudnessTarget?

    public init(format: ExportFormat, layout: ChannelLayout, rate: ExportRate, loudness: LoudnessTarget? = nil) {
        self.format = format
        self.layout = layout
        self.rate = rate
        self.loudness = loudness
    }

    /// The output of `dirigible render`: 32-bit float stereo CAF at the session rate.
    public static let render = ExportOptions(format: .floatCAF, layout: .stereo, rate: .session)
}

/// A range with at least one frame inside `0...Frames.limit`, and nil (every track) or a set
/// with at least one track.
public struct ExportSource: Hashable, Sendable {
    public let range: Range<Frames>
    public let tracks: Set<TrackID>?

    public init?(range: Range<Frames>, tracks: Set<TrackID>? = nil) {
        guard range.lowerBound >= .zero, range.upperBound <= .limit, !range.isEmpty, tracks?.isEmpty != true else {
            return nil
        }
        self.range = range
        self.tracks = tracks
    }
}

/// The loudness of an export with a target (decision 0032). The output values are measured on the
/// processed signal at the session rate, before the encoder.
public struct LoudnessReport: Hashable, Sendable {
    public let target: LUFS
    /// The mix before the gain. Nil when no block passes the gates: then the gain is 0 dB.
    public let measured: LUFS?
    /// `target - measured`, with no limit.
    public let gain: Gain
    /// The output after the gain and the limiter.
    public let output: LUFS?
    /// The true peak of the output in dBTP. Nil only for digital silence: a 16-bit export has
    /// dither, so it is never silent.
    public let truePeak: Double?

    /// The gain is over the ±20 dB limit of auto-level (decision 0008). The export does not
    /// limit it (0032), so the window shows it as a warning.
    public var exceedsLevelLimit: Bool { abs(gain.dB) > Gain.levelLimit }
}

public struct ExportResult: Hashable, Sendable {
    /// The faults of the files that the source read.
    public let faults: [FileID: MediaFault]
    /// Nil for an export with no loudness target.
    public let loudness: LoudnessReport?
}

public enum ExportError: Error, Hashable, Sendable {
    /// An item is at the target. It did not change.
    case exists
    /// AAC at a file rate above 48 kHz (probe P5), or MP3 at a file rate other than 32, 44.1, or
    /// 48 kHz (decision 0034). No file was made.
    case rateNotSupported(Int)
    /// A create, format, write, or close of the file gave this status.
    case writeFailed(OSStatus)
    /// The move to the target gave this errno.
    case moveFailed(Int32)
    /// A write gave -40 with errno ENOSPC (probe P8).
    case diskFull
    /// An audio file did not open because the process had no free descriptor (this errno).
    case openFailed(Int32)
    /// The package source threw: the lock lost the package.
    case packageUnavailable
    /// The cancel check was true at a chunk.
    case cancelled
}

/// Renders `source` of `session` and writes it in `options` to `url` (decision 0019). It
/// renders `chunk` frames at a time into one reused buffer, so the memory does not grow with
/// the range. A mono export folds each chunk to 0.5 x (L + R) (probe P10). The file rate is the
/// chosen rate; the converter of `ExtAudioFile` resamples (P4), and LAME resamples an MP3.
///
/// With a loudness target it renders the source twice (decision 0032). Pass 1 measures the mix
/// before the temporary file exists. Pass 2 applies the gain `target - measured` and the
/// true-peak limiter at -1 dBTP, and measures the output for the report. A WAV 16 or FLAC 16
/// export gets a seeded TPDF dither, also with no target.
///
/// At each chunk and once after the close it reads `isCancelled()`; at each chunk it reads
/// `package()`, so a package that moves keeps its audio. It calls `progress` when the whole
/// percent changes: pass 1 maps to 0...0.25 and pass 2 to 0.25...1. The call of 1.0
/// comes after the last write and before the close. It writes `.<name>.<UUID>.tmp` in the
/// folder of `url`, closes and flushes it, then moves it: over `replacing` when the target
/// still is that item, else with `moveNew`, which never replaces an item. Then it flushes the
/// folder. Every exit removes the temporary file. It holds an flock on the temporary file while
/// it runs. At the start it removes the leftovers of an export to `url` that died.
public func exportMix(
    _ session: Session, source: ExportSource, options: ExportOptions, to url: URL,
    replacing: ConfirmedFile? = nil, package: () throws(SessionFileError) -> URL,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled },
    chunk: Int = 48_000
) throws(ExportError) -> ExportResult {
    let rate = options.rate.hertz(session: session.sampleRate)
    if case .aac = options.format, rate > 48_000 { throw .rateNotSupported(rate) }
    // The MPEG-1 rates, where LAME keeps each bit rate of `BitRate` (probes U3 and U7).
    if case .mp3 = options.format, ![32_000, 44_100, 48_000].contains(rate) { throw .rateNotSupported(rate) }
    let sessionRate = Double(session.sampleRate)
    let capacity = AVAudioFrameCount(chunk)
    guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sessionRate, channels: 2),
        let mono = AVAudioFormat(standardFormatWithSampleRate: sessionRate, channels: 1),
        let mixBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: capacity),
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity)
    else { throw .writeFailed(kAudio_ParamError) }
    let folded = options.layout == .mono ? monoBuffer : nil
    let first = source.range.lowerBound
    let total = source.range.upperBound.count - first.count
    let mix = MixReader(package: URL(filePath: "/"), session: session, tracks: source.tracks)
    var percent = 0
    func report(_ whole: Int, _ fraction: Double) {
        if whole > percent {
            percent = whole
            progress(fraction)
        }
    }
    /// Renders the source chunk by chunk and gives each chunk and the frames done to `body`.
    func render(_ body: (AVAudioPCMBuffer, Int) throws(ExportError) -> Void) throws(ExportError) {
        var start = first
        while start < source.range.upperBound {
            if isCancelled() { throw .cancelled }
            do { mix.package = try package() } catch { throw .packageUnavailable }
            let end = min(start + Frames(chunk), source.range.upperBound)
            mix.render(start..<end, into: mixBuffer)
            if let error = mix.openError { throw .openFailed(error.code.rawValue) }
            if let folded { fold(mixBuffer, into: folded) }
            start = end
            try body(folded ?? mixBuffer, end.count - first.count)
        }
    }

    var stage: LoudnessStage?
    if let target = options.loudness {
        var meter = LoudnessMeter(sampleRate: session.sampleRate, layout: options.layout)
        if meter != nil {
            try render { buffer, done throws(ExportError) in
                meter?.feed(buffer)
                report(25 * done / total, 0.25 * Double(done) / Double(total))
            }
        }
        stage = LoudnessStage(
            target: target.integrated(for: options.layout), measured: meter?.result().integrated,
            rate: session.sampleRate, layout: options.layout)
    }

    removeExportLeftovers(of: url)
    let folder = url.deletingLastPathComponent()
    let temporary = folder.appending(path: "\(leftoverPrefix(url))\(UUID().uuidString).tmp")
    // The flock tells the sweep of another export to this target that the file is live. It holds
    // on APFS, exFAT, and FAT (probe g1-flock). A volume with no locks gets the file with no lock.
    var held = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_CLOEXEC, 0o644)
    if held < 0, errno == ENOTSUP || errno == EOPNOTSUPP {
        held = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    }
    guard held >= 0 else {
        let code = errno
        throw code == EMFILE || code == ENFILE ? .openFailed(code) : writeFault(status: -40, errno: code)
    }
    // The unlink runs before the close, so no sweep sees the file with no lock.
    defer { close(held) }
    defer { unlink(temporary.path) }
    try writeFile(temporary, format: options.format, rate: rate, client: folded?.format ?? stereo) {
        sink throws(ExportError) in
        var written = 0
        var dither: TPDFDither?
        if options.format == .wav(.bits16) || options.format == .flac(.bits16) {
            dither = TPDFDither(channels: options.layout.channelCount)
        }
        func write(_ buffer: AVAudioPCMBuffer) throws(ExportError) {
            dither?.apply(buffer)
            stage?.measure(buffer)
            guard buffer.frameLength > 0 else { return }
            try sink(buffer)
            written += Int(buffer.frameLength)
            if stage == nil {
                report(100 * written / total, Double(written) / Double(total))
            } else {
                report(25 + 75 * written / total, 0.25 + 0.75 * Double(written) / Double(total))
            }
        }
        try render { buffer, _ throws(ExportError) in
            stage?.process(buffer)
            try write(buffer)
        }
        while let drained = stage?.drain(into: folded ?? mixBuffer), drained { try write(folded ?? mixBuffer) }
    }
    // A cancel after the last chunk skips the flush and the move, so a take start does not
    // wait for them (code gate 1).
    if isCancelled() { throw .cancelled }
    if let code = fullFlush(path: temporary.path) { throw writeFault(status: -40, errno: code) }
    if let replacing {
        try moveOver(temporary, to: url, confirmed: replacing)
    } else {
        try moveNew(temporary, to: url)
    }
    // The file is at the target now. A volume that refuses both flushes does not undo the move.
    _ = fullFlush(path: folder.path)
    return ExportResult(faults: mix.faults, loudness: stage?.report())
}

/// Pass 2 of an export with a loudness target: the gain, the limiter, and the meters of the
/// report.
private struct LoudnessStage {
    let target: LUFS
    let measured: LUFS?
    let gain: Gain
    private let factor: Float
    private var limiter: TruePeakLimiter
    private var loudness: LoudnessMeter?
    private var truePeak: TruePeakMeter

    init(target: LUFS, measured: LUFS?, rate: Int, layout: ChannelLayout) {
        self.target = target
        self.measured = measured
        // Gain(dB:) is nil only for a value that is not finite.
        gain = measured.flatMap { Gain(dB: target.value - $0.value) } ?? .zero
        factor = Float(pow(10, gain.dB / 20))
        limiter = TruePeakLimiter(ceiling: -1, rate: rate, layout: layout)
        loudness = LoudnessMeter(sampleRate: rate, layout: layout)
        truePeak = TruePeakMeter(layout: layout)
    }

    /// The gain and the limiter, in place. The frame count can go down (the look-ahead).
    mutating func process(_ buffer: AVAudioPCMBuffer) {
        var scale = factor
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(buffer.frameLength))
        }
        limiter.process(buffer)
    }

    /// The last frames of the limiter into `buffer`. False when it has none left.
    mutating func drain(into buffer: AVAudioPCMBuffer) -> Bool { limiter.drain(into: buffer) }

    mutating func measure(_ buffer: AVAudioPCMBuffer) {
        loudness?.feed(buffer)
        truePeak.feed(buffer)
    }

    func report() -> LoudnessReport {
        LoudnessReport(
            target: target, measured: measured, gain: gain, output: loudness?.result().integrated,
            truePeak: truePeak.result())
    }
}

/// `mono = 0.5 x (L + R)` of `stereo` (decision 0007).
private func fold(_ stereo: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer) {
    mono.frameLength = stereo.frameLength
    let channels = stereo.floatChannelData!
    var half: Float = 0.5
    vDSP_vasm(channels[0], 1, channels[1], 1, &half, mono.floatChannelData![0], 1, vDSP_Length(stereo.frameLength))
}

/// Removes the temporary files of the exports to `url` that died (a kill, a crash):
/// `.<name>.<UUID>.tmp` in the folder of `url` that no export holds an flock on. A live export
/// holds one, so its file stays. A name with no UUID stays: the export did not make it.
private func removeExportLeftovers(of url: URL) {
    let folder = url.deletingLastPathComponent()
    let prefix = leftoverPrefix(url)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    where name.hasPrefix(prefix) && name.hasSuffix(".tmp")
        && UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil
    {
        let path = folder.appending(path: name).path
        let dead = open(path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        guard dead >= 0 else { continue }
        unlink(path)
        close(dead)
    }
}

private func leftoverPrefix(_ url: URL) -> String { ".\(url.lastPathComponent)." }
