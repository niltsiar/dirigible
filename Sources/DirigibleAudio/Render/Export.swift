import AVFoundation
import Accelerate
import AudioToolbox
import DirigibleCore
import Foundation

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
/// Before each chapter image, at each chunk, and once after the close it reads `isCancelled()`. An
/// MP3 with chapter images also reads it once before the tag. At each chunk it reads
/// `package()`, so a package that moves keeps its audio. It calls `progress` when the whole
/// percent changes: pass 1 maps to 0...0.25 and pass 2 to 0.25...1. The call of 1.0
/// comes after the last write and before the close. It writes `.<name>.<UUID>.tmp` in the
/// folder of `url` and closes it. An AAC export of a session with episode fields or chapters then
/// copies it to `.<name>.<UUID>.tag.tmp` with the iTunes atoms and the chapter tracks (decision
/// 0045): the encode maps to 0...0.95, the call of 1.0 comes after the copy, and the copy reads
/// `isCancelled()` too. It
/// flushes the file of the last step through `flush`, then moves it: over `replacing` when the
/// target still is that item, else with `moveNew`, which never replaces an item. Then it flushes
/// the folder. Every exit removes the temporary files. It holds an flock on the `.tmp` file while
/// it runs. At the start it removes the leftovers of an export to `url` that died. A test passes
/// `flush` to see the order of the flushes; nil is `fullFlush`.
///
/// Thread rule: call it off the main actor. The call blocks its thread until it returns, and the
/// M4A chapter copy waits on semaphores for up to 10 s for each wait. The app calls it on a GCD
/// utility queue, so that it holds no thread of the Swift concurrency pool.
public func exportMix(
    _ session: Session, source: ExportSource, options: ExportOptions, to url: URL,
    replacing: ConfirmedFile? = nil, package: () throws(SessionFileError) -> URL,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled },
    chunk: Int = 48_000, flush: ((String) -> Int32?)? = nil
) throws(ExportError) -> ExportResult {
    let flush = flush ?? { fullFlush(path: $0) }
    let rate = options.rate.hertz(session: session.sampleRate)
    if case .aac = options.format, rate > 48_000 { throw .rateNotSupported(rate) }
    // The MPEG-1 rates, where LAME keeps each bit rate of `BitRate` (probes U3 and U7).
    if case .mp3 = options.format, ![32_000, 44_100, 48_000].contains(rate) { throw .rateNotSupported(rate) }
    let artwork = try readArtwork(of: session.episode, format: options.format, package: package)
    let aac = if case .aac = options.format { true } else { false }
    let mp3 = if case .mp3 = options.format { true } else { false }
    let list = session.chapterList(in: source.range)
    // Only an M4A has chapter tracks. The chapter images are read before any file exists.
    let chapters = aac ? list.chapters : []
    let images = try readChapterImages(
        aac ? m4aKept(list, in: session, range: source.range, outputRate: rate) : mp3 ? list.chapters : [],
        rate: session.sampleRate, package: package, isCancelled: isCancelled)
    // The writer of the M4A image track takes only JPEG (probe P1). The image stage reads the
    // cancel before each image and before the tag, so a take start does not wait for it (D3).
    var jpegs: [MarkerID: Data] = [:]
    for marker in chapters {
        guard let name = marker.image, let data = images[marker.id] else { continue }
        if isCancelled() { throw .cancelled }
        do { jpegs[marker.id] = try m4aJPEG(data, of: name) } catch {
            throw .chapterImageMissing(marker, rate: session.sampleRate)
        }
    }
    var chapterArtwork: Data?
    if !jpegs.isEmpty, let artwork, let name = session.episode.artwork {
        chapterArtwork = try m4aJPEG(artwork, of: name)
    }
    // Only an MP3 file takes the ID3 tag. It is built before any file exists, so a refused tag
    // leaves no file. Its chapter images keep their bytes and their type.
    if mp3, !images.isEmpty, isCancelled() { throw .cancelled }
    let id3 =
        mp3
        ? try id3Tag(
            session.episode, artwork: artwork,
            chapters: id3Chapters(list.chapters, in: session, range: source.range, images: images))
        : []
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
    let tags = aac && (!session.episode.isEmpty || !chapters.isEmpty)
    func report(_ whole: Int, _ fraction: Double) {
        if whole > percent {
            percent = whole
            progress(tags ? 0.95 * fraction : fraction)
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
    let name = "\(leftoverPrefix(url))\(UUID().uuidString)"
    let temporary = folder.appending(path: "\(name).tmp")
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
    let tagged = tags ? folder.appending(path: "\(name).tag.tmp") : nil
    // This unlink runs before the unlink of the `.tmp` file, so no sweep removes a live file.
    defer { if let tagged { unlink(tagged.path) } }
    try writeFile(
        temporary, format: options.format, rate: rate, client: folded?.format ?? stereo, tag: id3
    ) {
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
    var m4a = M4AChapters(chapters: [], dropped: [])
    var imagesOmitted = false
    if let tagged {
        let frames = chapters.isEmpty ? 0 : try validFrames(temporary)
        if !chapters.isEmpty {
            m4a = m4aChapters(
                list, in: session, range: source.range, outputRate: rate, outputFrames: frames,
                introTitle: options.introTitle, images: jpegs)
        }
        imagesOmitted = try tagM4A(
            temporary, episode: session.episode, artwork: artwork, chapters: m4a.chapters,
            chapterArtwork: chapterArtwork, rate: rate, frames: frames, to: tagged, isCancelled: isCancelled)
        progress(1)
        if isCancelled() { throw .cancelled }
    }
    let last = tagged ?? temporary
    if let code = flush(last.path) { throw writeFault(status: -40, errno: code) }
    if let replacing {
        try moveOver(last, to: url, confirmed: replacing)
    } else {
        try moveNew(last, to: url)
    }
    // The file is at the target now. A volume that refuses both flushes does not undo the move.
    _ = flush(folder.path)
    return ExportResult(
        faults: mix.faults, loudness: stage?.report(), droppedChapters: mp3 ? list.dropped : m4a.dropped,
        chapterImagesOmitted: imagesOmitted)
}

/// The bytes of the episode artwork for an MP3 or an AAC export, read once before any file
/// exists. Nil for another format and for no artwork.
private func readArtwork(
    of episode: Episode, format: ExportFormat, package: () throws(SessionFileError) -> URL
) throws(ExportError) -> Data? {
    switch format {
    case .mp3, .aac: break
    case .wav, .flac, .floatCAF: return nil
    }
    guard let name = episode.artwork else { return nil }
    let root: URL
    do { root = try package() } catch { throw .packageUnavailable }
    guard let data = try? Data(contentsOf: root.appending(path: name.path)) else {
        throw .artworkMissing(name.path)
    }
    return data
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
        // Nil only for a value that is not finite. The -70 LUFS gate keeps the gain under +60 dB.
        gain = measured.flatMap { Gain(clamping: target.value - $0.value) } ?? .zero
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

/// Removes the temporary files of the exports to `url` that died (a kill, a crash). First it
/// removes each `.<name>.<UUID>.tmp` in the folder of `url` that no export holds an flock on. A
/// live export holds one, so its file stays. Then it removes each `.<name>.<UUID>.tag.tmp` with no
/// `.tmp` file of the same UUID: a live export makes its `.tag.tmp` file after its `.tmp` file
/// and removes it first. A name with no UUID stays: the export did not make it.
private func removeExportLeftovers(of url: URL) {
    let folder = url.deletingLastPathComponent()
    let prefix = leftoverPrefix(url)
    func names(_ suffix: String) -> [String] {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return all.filter {
            $0.hasPrefix(prefix) && $0.hasSuffix(suffix)
                && UUID(uuidString: String($0.dropFirst(prefix.count).dropLast(suffix.count))) != nil
        }
    }
    for name in names(".tmp") {
        let path = folder.appending(path: name).path
        let dead = open(path, O_RDONLY | O_EXLOCK | O_NONBLOCK | O_CLOEXEC)
        guard dead >= 0 else { continue }
        unlink(path)
        close(dead)
    }
    for name in names(".tag.tmp")
    where !FileManager.default.fileExists(
        atPath: folder.appending(path: "\(name.dropLast(8)).tmp").path)
    {
        unlink(folder.appending(path: name).path)
    }
}

private func leftoverPrefix(_ url: URL) -> String { ".\(url.lastPathComponent)." }
