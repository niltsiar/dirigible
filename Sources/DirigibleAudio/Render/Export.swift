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
/// With a loudness target it renders the source at least twice (decision 0032). Pass 1 measures
/// the loudness and the true peak of the mix before the temporary file exists. When the limiter
/// would act, trial passes with no file search the gain, so that the limited output reaches the
/// target. The write pass applies the gain and the true-peak limiter at -1 dBTP, and measures the
/// output. A file that the encoder or the resampler changes (see `LoudnessReport`) is then decoded
/// as macOS decodes it and measured again; the report is that decode, and a true peak over -1 dBTP
/// or a loudness 0.2 LU off the target starts another write of the same temporary file, up to 2
/// times. A WAV 16 or FLAC 16 export gets a seeded TPDF dither, also with no target.
///
/// Before each chapter image, at each chunk, and once after the close it reads `isCancelled()`. An
/// MP3 with chapter images also reads it once before the tag. At each chunk it reads
/// `package()`, so a package that moves keeps its audio. It calls `progress` when the whole
/// percent changes: pass 1 maps to 0...0.15, the trial passes to 0.15...0.3, and the write to
/// 0.3...0.75 (0.15...0.75 with no trial pass, and up to 1 with no read-back). The read-back and
/// each retry round share 0.75...1 in equal bands. The call of 1.0 comes after the last
/// write and before the close, or after the read-back. It writes `.<name>.<UUID>.tmp` in the
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
    try exportMix(
        session, source: source, options: options, to: url, replacing: replacing, package: package,
        progress: progress, isCancelled: isCancelled, chunk: chunk, flush: flush, tuning: ExportTuning())
}

/// `exportMix` with the caps, the start margin, and the hooks of `ExportTuning`.
func exportMix(
    _ session: Session, source: ExportSource, options: ExportOptions, to url: URL,
    replacing: ConfirmedFile? = nil, package: () throws(SessionFileError) -> URL,
    progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled },
    chunk: Int = 48_000, flush: ((String) -> Int32?)? = nil, tuning: ExportTuning
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
    let mix = MixReader(package: URL(filePath: "/"), session: session, tracks: source.tracks, span: chunk)
    var percent = 0
    let tags = aac && (!session.episode.isEmpty || !chapters.isEmpty)
    func report(_ fraction: Double) {
        let whole = Int(fraction * 100)
        if whole > percent {
            percent = whole
            progress(tags ? 0.95 * fraction : fraction)
        }
    }
    /// Reports `done` of `total` frames inside `band`.
    func advance(_ band: ClosedRange<Double>, _ done: Int) {
        report(
            done >= total
                ? band.upperBound : band.lowerBound + (band.upperBound - band.lowerBound) * Double(done) / Double(total)
        )
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

    var searchStart = LoudnessSearch.Start(format: options.format, fileRate: rate, sessionRate: session.sampleRate)
    if let margin = tuning.startMargin { searchStart.margin = margin }
    let bands = ProgressBands(readsBack: searchStart.readsBack, limits: tuning.limits)
    var measured: LUFS?
    var search: LoudnessSearch?
    var step = LoudnessSearch.Step.done
    if let target = options.loudness {
        var meter = LoudnessMeter(sampleRate: session.sampleRate, layout: options.layout)
        var peak = TruePeakMeter(layout: options.layout)
        if meter != nil {
            try render { buffer, done throws(ExportError) in
                meter?.feed(buffer)
                peak.feed(buffer)
                advance(bands.measure, done)
            }
        }
        measured = meter?.result().integrated
        var started = LoudnessSearch(
            target: target.integrated(for: options.layout), start: searchStart, limits: tuning.limits)
        step = started.next(after: .mix(loudness: measured, truePeak: meter == nil ? nil : peak.result()))
        search = started
    }

    removeExportLeftovers(of: url)
    let folder = url.deletingLastPathComponent()
    let name = "\(leftoverPrefix(url))\(UUID().uuidString)"
    let temporary = folder.appending(path: "\(name).tmp")
    // The flock tells the sweep of another export to this target that the file is live. It holds
    // on APFS, exFAT, and FAT (probe g1-flock). A volume with no locks gets the file with no lock.
    var held = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_CLOEXEC, 0o644)
    if held < 0, lacksFlock(errno) {
        held = open(temporary.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    }
    guard held >= 0 else {
        let code = errno
        throw code == EMFILE || code == ENFILE ? .openFailed(code) : writeFault(status: -40, errno: code)
    }
    // The unlink runs before the close, so no sweep sees the file with no lock.
    defer { close(held) }
    defer { unlink(temporary.path) }
    let tagged = tags ? folder.appending(path: "\(name)\(tagSuffix)") : nil
    // This unlink runs before the unlink of the `.tmp` file, so no sweep removes a live file.
    defer { if let tagged { unlink(tagged.path) } }
    var current: LoudnessStage?
    var decoded: FileMeasure?
    var samplePeak: Float = 0
    /// Writes the file once. `current` is the gain stage, nil for no target.
    func writeRound(_ band: ClosedRange<Double>) throws(ExportError) {
        samplePeak = 0
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
                current?.measure(buffer)
                guard buffer.frameLength > 0 else { return }
                samplePeak = max(samplePeak, peak(of: buffer))
                try sink(buffer)
                written += Int(buffer.frameLength)
                advance(band, written)
            }
            try render { buffer, _ throws(ExportError) in
                current?.process(buffer)
                try write(buffer)
            }
            while let drained = current?.drain(into: folded ?? mixBuffer), drained { try write(folded ?? mixBuffer) }
        }
    }
    if var active = search {
        var trialsInRound = 0
        loop: while true {
            tuning.onStep?(step)
            switch step {
            case .trial(let gain, let ceiling):
                var trial = LoudnessStage(
                    gain: gain, ceiling: ceiling, rate: session.sampleRate, layout: options.layout,
                    measuresTruePeak: false)
                let band = bands.trial(round: active.writes, index: trialsInRound)
                trialsInRound += 1
                try render { buffer, done throws(ExportError) in
                    trial.process(buffer)
                    trial.measure(buffer)
                    advance(band, done)
                }
                while trial.drain(into: folded ?? mixBuffer) { trial.measure(folded ?? mixBuffer) }
                step = active.next(after: .trial(output: trial.output))
            case .write(let gain, let ceiling):
                current = LoudnessStage(
                    gain: gain, ceiling: ceiling, rate: session.sampleRate, layout: options.layout,
                    measuresTruePeak: true)
                try writeRound(bands.write(round: active.writes - 1, afterTrials: trialsInRound > 0))
                trialsInRound = 0
                tuning.afterWrite?(temporary)
                step = active.next(after: .written(output: current?.output, truePeak: current?.truePeak))
            case .readBack:
                let band = bands.readBack(round: active.writes - 1)
                // The converter can round the length of a resampled file by one frame.
                let frames = max(total * rate / session.sampleRate - 1, 0)
                let measure = try measureDecodedFile(
                    temporary, layout: options.layout, frames: frames, isCancelled: isCancelled
                ) {
                    report(band.lowerBound + (band.upperBound - band.lowerBound) * $0)
                }
                decoded = measure
                step = active.next(after: .readBack(loudness: measure.loudness, truePeak: measure.truePeak))
            case .done:
                break loop
            }
        }
    } else {
        try writeRound(0...1)
    }
    if !tags { report(1) }
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
    let loudness = options.loudness.flatMap { target in
        current.map { stage in
            let file = decoded ?? FileMeasure(loudness: stage.output, truePeak: stage.truePeak)
            return LoudnessReport(
                target: target.integrated(for: options.layout), measured: measured, gain: stage.gain,
                output: file.loudness, truePeak: file.truePeak)
        }
    }
    return ExportResult(
        faults: mix.faults, loudness: loudness, droppedChapters: mp3 ? list.dropped : m4a.dropped,
        chapterImagesOmitted: imagesOmitted, samplePeak: samplePeak)
}

/// The largest sample magnitude of the frames of `buffer`, over its channels.
func peak(of buffer: AVAudioPCMBuffer) -> Float {
    let channels = buffer.floatChannelData!
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
        var value: Float = 0
        vDSP_maxmgv(channels[channel], 1, &value, vDSP_Length(buffer.frameLength))
        peak = max(peak, value)
    }
    return peak
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

/// `mono = 0.5 x (L + R)` of `stereo` (decision 0007).
func fold(_ stereo: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer) {
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
    for name in names(tagSuffix)
    where !FileManager.default.fileExists(
        atPath: folder.appending(path: "\(name.dropLast(tagSuffix.count)).tmp").path)
    {
        unlink(folder.appending(path: name).path)
    }
}

private func leftoverPrefix(_ url: URL) -> String { ".\(url.lastPathComponent)." }

/// The suffix of the tagged copy of an M4A export.
private let tagSuffix = ".tag.tmp"

/// The longest target name in UTF-8 bytes whose `.<name>.<UUID>.tag.tmp` name fits the 255 bytes
/// of a file name on APFS: 209.
let exportNameLimit =
    255 - (leftoverPrefix(URL(filePath: "/x")).utf8.count - 1) - UUID().uuidString.utf8.count - tagSuffix.utf8.count
