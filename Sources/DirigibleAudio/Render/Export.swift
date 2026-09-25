import AVFoundation
import Accelerate
import AudioToolbox
import DirigibleCore
import Foundation

public enum BitDepth: Int, Hashable, Sendable, CaseIterable {
    case bits16 = 16
    case bits24 = 24
}

/// The AAC bit rates in kbit/s that the encoder takes for mono and stereo at 44.1 and 48 kHz
/// (probe P5).
public enum AACBitRate: Int, Hashable, Sendable, CaseIterable {
    case k64 = 64
    case k96 = 96
    case k128 = 128
    case k160 = 160
    case k192 = 192
    case k256 = 256
}

/// A bit depth goes only with WAV or FLAC, a bit rate only with AAC. `.floatCAF` is the 32-bit
/// float CAF of `dirigible render`; the app does not offer it (decision 0019).
public enum ExportFormat: Hashable, Sendable {
    case wav(BitDepth)
    case flac(BitDepth)
    case aac(AACBitRate)
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

public struct ExportOptions: Hashable, Sendable {
    public var format: ExportFormat
    public var layout: ChannelLayout
    public var rate: ExportRate

    public init(format: ExportFormat, layout: ChannelLayout, rate: ExportRate) {
        self.format = format
        self.layout = layout
        self.rate = rate
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

public enum ExportError: Error, Hashable, Sendable {
    /// An item is at the target. It did not change.
    case exists
    /// AAC at a file rate above 48 kHz (probe P5). No file was made.
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
/// chosen rate; the converter of `ExtAudioFile` resamples (P4).
///
/// At each chunk it reads `isCancelled()` and `package()`, so a package that moves keeps its
/// audio. After each write it calls `progress` when the whole percent changes; the call of 1.0
/// comes after the last write and before the close. It writes `.<name>.<UUID>.tmp` in the
/// folder of `url`, closes and flushes it, then moves it: over `replacing` when the target
/// still is that item, else with `moveNew`, which never replaces an item. Then it flushes the
/// folder. Every exit removes the temporary file. At the start it removes the leftovers of an
/// export to `url` that died. Returns the faults of the files that the source read.
public func exportMix(
    _ session: Session, source: ExportSource, options: ExportOptions, to url: URL,
    replacing: ConfirmedFile? = nil, package: () throws(SessionFileError) -> URL,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled },
    chunk: Int = 48_000
) throws(ExportError) -> [FileID: MediaFault] {
    let rate = options.rate.hertz(session: session.sampleRate)
    if case .aac = options.format, rate > 48_000 { throw .rateNotSupported(rate) }
    let sessionRate = Double(session.sampleRate)
    let capacity = AVAudioFrameCount(chunk)
    guard let stereo = AVAudioFormat(standardFormatWithSampleRate: sessionRate, channels: 2),
        let mono = AVAudioFormat(standardFormatWithSampleRate: sessionRate, channels: 1),
        let mixBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: capacity),
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity)
    else { throw .writeFailed(kAudio_ParamError) }
    let folded = options.layout == .mono ? monoBuffer : nil
    removeExportLeftovers(of: url)
    let folder = url.deletingLastPathComponent()
    let temporary = folder.appending(path: "\(leftoverPrefix(url))\(UUID().uuidString).tmp")
    defer { unlink(temporary.path) }
    let first = source.range.lowerBound
    let total = source.range.upperBound.count - first.count
    let mix = MixReader(package: URL(filePath: "/"), session: session, tracks: source.tracks)
    try writeFile(temporary, format: options.format, rate: rate, client: folded?.format ?? stereo) {
        file throws(ExportError) in
        var start = first
        var percent = 0
        while start < source.range.upperBound {
            if isCancelled() { throw .cancelled }
            do { mix.package = try package() } catch { throw .packageUnavailable }
            let end = min(start + Frames(chunk), source.range.upperBound)
            mix.render(start..<end, into: mixBuffer)
            if let error = mix.openError { throw .openFailed(error.code.rawValue) }
            if let folded { fold(mixBuffer, into: folded) }
            let buffer = folded ?? mixBuffer
            let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
            guard status == noErr else { throw writeFault(status: status, errno: errno) }
            start = end
            let done = end.count - first.count
            if done * 100 / total > percent {
                percent = done * 100 / total
                progress(Double(done) / Double(total))
            }
        }
    }
    if let code = fullFlush(path: temporary.path) { throw writeFault(status: -40, errno: code) }
    if let replacing {
        try moveOver(temporary, to: url, confirmed: replacing)
    } else {
        try moveNew(temporary, to: url)
    }
    // The file is at the target now. A volume that refuses both flushes does not undo the move.
    _ = fullFlush(path: folder.path)
    return mix.faults
}

/// `mono = 0.5 x (L + R)` of `stereo` (decision 0007).
private func fold(_ stereo: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer) {
    mono.frameLength = stereo.frameLength
    let channels = stereo.floatChannelData!
    var half: Float = 0.5
    vDSP_vasm(channels[0], 1, channels[1], 1, &half, mono.floatChannelData![0], 1, vDSP_Length(stereo.frameLength))
}

/// Removes the temporary files of the exports to `url`: `.<name>.<UUID>.tmp` in the folder of
/// `url`. An export that died (a kill, a crash) leaves one. `dirigible render` also calls it at
/// SIGINT. A name with no UUID stays: the export did not make it.
public func removeExportLeftovers(of url: URL) {
    let folder = url.deletingLastPathComponent()
    let prefix = leftoverPrefix(url)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    where name.hasPrefix(prefix) && name.hasSuffix(".tmp")
        && UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil
    {
        unlink(folder.appending(path: name).path)
    }
}

private func leftoverPrefix(_ url: URL) -> String { ".\(url.lastPathComponent)." }
