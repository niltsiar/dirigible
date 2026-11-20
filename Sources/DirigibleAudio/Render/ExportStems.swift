import AVFoundation
import AudioToolbox
import DirigibleCore
import Foundation

/// The format of a stem file. WAV and FLAC only: no encoder delay, no chapters, and no tags.
public enum StemFormat: Hashable, Sendable {
    case wav(BitDepth)
    case flac(BitDepth)

    var exportFormat: ExportFormat {
        switch self {
        case .wav(let bits): .wav(bits)
        case .flac(let bits): .flac(bits)
        }
    }

    var bits: BitDepth {
        switch self {
        case .wav(let bits), .flac(let bits): bits
        }
    }
}

/// The options of each stem file. A stem has no loudness target: one gain for each stem breaks the
/// sum.
public struct StemOptions: Hashable, Sendable {
    public var format: StemFormat
    public var layout: ChannelLayout
    public var rate: ExportRate

    public init(format: StemFormat, layout: ChannelLayout, rate: ExportRate) {
        self.format = format
        self.layout = layout
        self.rate = rate
    }

    var exportOptions: ExportOptions { ExportOptions(format: format.exportFormat, layout: layout, rate: rate) }
}

/// One file of a stem export.
public struct StemFile: Hashable, Sendable {
    /// The file name in the stem folder.
    public let name: String
    public let tracks: Set<TrackID>
    /// `ExportResult.samplePeak` of the file.
    public let samplePeak: Float

    /// The file writer clips a sample over 1.0. A peak of exactly 1.0 does not clip.
    public var isOverFullScale: Bool { samplePeak > 1 }
}

public struct StemsResult: Hashable, Sendable {
    public let plan: StemPlan
    /// In plan order.
    public let files: [StemFile]
    /// The faults of the files that the stems read.
    public let faults: [FileID: MediaFault]
    /// The sample peak of a mix export of the stem tracks in the stem options, at the file rate. Nil
    /// when the stem peaks sum to 1.0 or less: then the mix cannot clip.
    public let mixPeak: Float?
}

public enum ExportStemsError: Error, Hashable, Sendable {
    /// The folder name is over `stemFolderNameLimit`. No job started.
    case folderNameTooLong
    /// No stem has a clip that sounds in the range. No folder was made.
    case noStem
    /// The stem files and `diskMargin` need `need` bytes, and the volume has `free`. No stem was
    /// rendered.
    case notEnoughSpace(need: Int64, free: Int64)
    /// A stop or a failure of a stem, or of the mix peak pass. The staging folder is gone.
    case stopped(ExportError)
    /// The staging folder, an item at the target (`.exists`), the capability check, or the publish.
    case publish(SessionFileError)
}

/// The kind of the staging folder of a stem export.
let stemsKind = "stems"

/// The longest stem folder name in UTF-8 bytes: 206.
public let stemFolderNameLimit = folderNameLimit(kind: stemsKind)

/// The longest stem name with no extension: with `.flac`, the longest stem extension, it fits
/// `exportNameLimit`.
let stemNameLimit = exportNameLimit - ".flac".utf8.count

/// Exports one file for each stem of `Session.stemPlan` over `source` into the new folder
/// `folder`, which appears whole or not at all. It computes the plan on `session`, so a check of a
/// caller before the call cannot give a stem of a track that is not heard. A plan with no stem
/// throws `.noStem` before any folder exists. Then, in this order: `stageFolder` (the sweep, the
/// lock file, the empty staging folder), the exists check of `folder`, `checkPublish()`, and the
/// space check; a refusal discards the staging folder. The stems run as the items of one
/// `exportItems` call, each file named by its plan name and the extension. A stop or a failure of
/// a stem removes the staging folder, so `folder` gets no stem. When the stem peaks sum over 1.0,
/// one pass measures the peak of the mix. Then the staging folder is published as `folder`.
/// `progress` maps the n stems to 0...n/(n + 1) and the mix peak pass to the last band, or jumps to
/// 1 when no pass runs. Thread rule: as `exportMix`.
public func exportStems(
    _ session: Session, by grouping: StemGrouping, source: ExportSource, titles: StemTitles, options: StemOptions,
    to folder: URL, package: () throws(SessionFileError) -> URL, progress: (Double) -> Void,
    isCancelled: () -> Bool
) throws(ExportStemsError) -> StemsResult {
    try exportStems(
        session, by: grouping, source: source, titles: titles, options: options, to: folder, package: package,
        progress: progress, isCancelled: isCancelled,
        stage: { url throws(SessionFileError) in try stageFolder(for: url, kind: stemsKind) },
        freeBytes: { parent in
            // A volume that gives no value skips the check; a full disk then stops the write.
            Int64((try? parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? .max)
        })
}

/// `exportStems` with the staging folder of `stage` and the free bytes of the parent folder of
/// `folder` from `freeBytes`.
func exportStems(
    _ session: Session, by grouping: StemGrouping, source: ExportSource, titles: StemTitles, options: StemOptions,
    to folder: URL, package: () throws(SessionFileError) -> URL, progress: (Double) -> Void,
    isCancelled: () -> Bool, stage: (URL) throws(SessionFileError) -> StagingFolder, freeBytes: (URL) -> Int64
) throws(ExportStemsError) -> StemsResult {
    guard
        let plan = session.stemPlan(
            by: grouping, tracks: source.tracks, range: source.range, titles: titles, limit: stemNameLimit)
    else { throw .noStem }
    let staging: StagingFolder
    do { staging = try stage(folder) } catch { throw .publish(error) }
    var info = stat()
    if lstat(folder.path, &info) == 0 {
        staging.discard()
        throw .publish(.exists)
    }
    do { try staging.checkPublish() } catch {
        staging.discard()
        throw .publish(error)
    }
    let need = stemBytes(plan, options: options, sessionRate: session.sampleRate) + diskMargin
    let free = freeBytes(folder.deletingLastPathComponent())
    if free < need {
        staging.discard()
        throw .notEnoughSpace(need: need, free: free)
    }
    let names = plan.stems.map { "\($0.name).\(options.format.exportFormat.pathExtension)" }
    let items = zip(plan.stems, names).enumerated().map { index, pair in
        var options = options.exportOptions
        options.ditherSeed = UInt64(index)
        return ExportItem(
            session: session, source: source.stem(pair.0.tracks), options: options,
            url: staging.url.appending(path: pair.1))
    }
    // The stems map to 0...n/(n + 1), and a mix peak pass to the last band.
    let stemsBand = Double(items.count) / Double(items.count + 1)
    let results: [ExportResult]
    do {
        results = try exportItems(
            items, replacing: [:], package: package, progress: { fraction, _ in progress(fraction * stemsBand) },
            isCancelled: isCancelled)
    } catch {
        staging.discard()
        switch error {
        case .exists: throw .stopped(.exists)
        case .stopped(let stop): throw .stopped(stop.error)
        }
    }
    let peaks = results.map(\.samplePeak)
    var mixPeak: Float?
    if needsMixPeak(stemPeaks: peaks) {
        do {
            mixPeak = try samplePeak(
                session, source: source, options: options, package: package,
                progress: { progress(stemsBand + (1 - stemsBand) * $0) }, isCancelled: isCancelled)
        } catch {
            staging.discard()
            throw .stopped(error)
        }
    } else {
        progress(1)
    }
    do { try staging.publish() } catch { throw .publish(error) }
    let files = zip(zip(plan.stems, names), peaks).map { StemFile(name: $0.1, tracks: $0.0.tracks, samplePeak: $1) }
    let faults = results.reduce(into: [FileID: MediaFault]()) { $0.merge($1.faults) { first, _ in first } }
    return StemsResult(plan: plan, files: files, faults: faults, mixPeak: mixPeak)
}

/// The sum of the stems is at most the sum of the stem peaks, so the mix can clip only when that
/// sum is over 1.0.
func needsMixPeak(stemPeaks: [Float]) -> Bool { stemPeaks.reduce(0, +) > 1 }

/// The bytes of the stem files as WAV, an upper bound for FLAC: the frames at the file rate,
/// rounded up, plus 4096 bytes of header for each file.
private func stemBytes(_ plan: StemPlan, options: StemOptions, sessionRate: Int) -> Int64 {
    let length = Int64((plan.range.upperBound - plan.range.lowerBound).count)
    let (rate, session) = (Int64(options.rate.hertz(session: sessionRate)), Int64(sessionRate))
    let frames = (length * rate + session - 1) / session + 1
    let bytes = frames * Int64(options.layout.channelCount) * Int64(options.format.bits.rawValue / 8)
    return Int64(plan.stems.count) * (bytes + 4096)
}

/// The sample peak of a mix export of `source` in `options`: folded to mono for a mono layout, with
/// the dither of a 16-bit mix export, and at the file rate (`FilePeak`). `progress` gets the
/// fraction of the frames read at each new whole percent.
private func samplePeak(
    _ session: Session, source: ExportSource, options: StemOptions, package: () throws(SessionFileError) -> URL,
    progress: (Double) -> Void, isCancelled: () -> Bool
) throws(ExportError) -> Float {
    let chunk = 48_000
    let rate = Double(session.sampleRate)
    guard let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
        let mixBuffer = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(chunk)),
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(chunk))
    else { throw .writeFailed(kAudio_ParamError) }
    let mix = MixReader(package: URL(filePath: "/"), session: session, tracks: source.tracks, span: chunk)
    let output = options.layout == .mono ? monoBuffer : mixBuffer
    var filePeak = try FilePeak(
        client: output.format, fileRate: options.rate.hertz(session: session.sampleRate),
        fileFormat: options.format.exportFormat)
    var dither = options.format.bits == .bits16 ? TPDFDither(channels: options.layout.channelCount) : nil
    let first = source.range.lowerBound
    let total = Double(source.range.upperBound.count - first.count)
    var percent = 0
    var start = first
    while start < source.range.upperBound {
        if isCancelled() { throw .cancelled }
        do { mix.package = try package() } catch { throw .packageUnavailable }
        let end = min(start + Frames(chunk), source.range.upperBound)
        mix.render(start..<end, into: mixBuffer)
        if let error = mix.openError { throw .openFailed(error.code.rawValue) }
        if options.layout == .mono { fold(mixBuffer, into: monoBuffer) }
        dither?.apply(output)
        try filePeak.feed(output)
        start = end
        let fraction = Double(end.count - first.count) / total
        if Int(fraction * 100) > percent {
            percent = Int(fraction * 100)
            progress(fraction)
        }
    }
    try filePeak.finish()
    return filePeak.value
}
