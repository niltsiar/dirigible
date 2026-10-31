import AVFoundation
import DirigibleCore
import Foundation

/// The engine part of one transcription job (decision 0065 D6): the checked model, the language,
/// the piece count, the journal, the read of piece n as 16 kHz mono samples, the stop flag, and the
/// progress. Nil for a stop.
typealias TranscribeEngine =
    @Sendable (
        CheckedModel, WhisperLanguage, _ pieceCount: Int, DiagnosticLog,
        _ read: (Int) throws(TranscribeError) -> [Float], StopFlag, _ progress: (Double) -> Void
    ) throws(TranscribeError) -> Transcription?

/// One `WhisperEngine` for the job, with the VAD model of `vadModel`.
let liveTranscribe: TranscribeEngine = { model, language, count, log, read, stop, progress throws(TranscribeError) in
    let vad = try vadModel(
        resources: Bundle.main.resourceURL, executable: Bundle.main.executableURL,
        models: WhisperModelStore.folder())
    let engine = try WhisperEngine(model: model, vad: vad, log: log)
    return try engine.transcribe(pieceCount: count, language: language, stop: stop, read: read, progress: progress)
}

/// The file name of the VAD model that `scripts/bundle.sh` copies to `Contents/Resources`.
let vadFileName = "ggml-silero-v6.2.0.bin"
/// The byte count and SHA-256 of `vadFileName`, as `scripts/fetch-whisper-test-model.sh` pins them.
let vadByteCount = 885_098
let vadSHA256 = "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

/// The first VAD model file of: `resources` (the app), `<executable folder>/../Resources` with the
/// links of `executable` resolved (the CLI in `Contents/Helpers`), and `models` (decision 0065 D2).
/// The file in `models` counts only with the pinned byte count and SHA-256: the user can write
/// that folder, and the ggml loader aborts the app on a bad file. The two bundle copies are signed
/// with the app. With none, it throws `.vadModelChecksum` when the file in `models` exists, else
/// `.vadModelMissing` with the paths it tried: a job with no VAD gives words on silence.
func vadModel(resources: URL?, executable: URL?, models: URL) throws(TranscribeError) -> URL {
    let helpers = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
    let folders = [resources, helpers?.deletingLastPathComponent().appending(path: "Resources"), models]
    let tried = folders.compactMap { $0?.appending(path: vadFileName) }
    let inModels = models.appending(path: vadFileName)
    let usable = { (url: URL) in
        url == inModels
            ? fileMatches(url, byteCount: vadByteCount, sha256: vadSHA256)
            : FileManager.default.fileExists(atPath: url.path)
    }
    guard let found = tried.first(where: usable) else {
        if FileManager.default.fileExists(atPath: inModels.path) { throw .vadModelChecksum(file: inModels.path) }
        throw .vadModelMissing(tried: tried.map(\.path))
    }
    return found
}

/// The words of a job in file frames, the untimed count of `SpanMap`, and the language.
public struct TranscribedWords: Sendable {
    public let words: FileWords
    public let untimed: Int
    public let language: String
}

/// Transcribes the clips of `track` from the pool files of `package` with `model`, on the calling
/// thread, with the live engine (decision 0065 D3, D6): the work of `dirigible transcribe` and of
/// the tool `transcribe` on the files. `isCancelled` is read before and after each piece. Nil for
/// a cancel.
public func transcribeTrack(
    _ track: Track, of session: Session, package: URL, language: WhisperLanguage, model: CheckedModel,
    log: DiagnosticLog, isCancelled: @escaping @Sendable () -> Bool = { false },
    progress: @escaping (Double) -> Void = { _ in }
) throws(TranscribeError) -> TranscribedWords? {
    let stop = StopFlag()
    let map = SpanMap(clips: track.clips, session: session)
    return try transcribeSpans(
        map, session: session, package: package, model: model, language: language, engine: liveTranscribe, log: log,
        stop: stop
    ) {
        if isCancelled() { stop.set() }
    } progress: { fraction in
        if isCancelled() { stop.set() }
        progress(fraction)
    }
}

/// The pieces of `map`, the engine part `engine` on them, and the file words of its result. Nil
/// for a stop. `beforeRead` runs before the read of each piece.
func transcribeSpans(
    _ map: SpanMap, session: Session, package: URL, model: CheckedModel, language: WhisperLanguage,
    engine: TranscribeEngine, log: DiagnosticLog, stop: StopFlag, beforeRead: @escaping () -> Void = {},
    progress: @escaping (Double) -> Void
) throws(TranscribeError) -> TranscribedWords? {
    let reader = SpanReader(map: map, session: session, package: package)
    let pieces = map.pieces { at, window in reader.cut(at: at, window: window) }
    guard
        let result = try engine(
            model, language, pieces.count, log,
            { n throws(TranscribeError) in
                beforeRead()
                return try reader.samples(pieces[n])
            },
            stop, progress)
    else { return nil }
    let mapped = map.fileWords(result.pieces, in: pieces)
    return TranscribedWords(words: mapped.words, untimed: mapped.untimed, language: result.language)
}

/// The work of a job off the main actor (decision 0065 D5): the model check, and when it fails,
/// the leftover sweep, the removal of a catalog file that fails the check, and the download, with
/// the stop check of `run`; then a read of the flags and the engine. The model check and the engine
/// run on a `.userInitiated` GCD thread. Nil for a stop.
@concurrent nonisolated func transcribeWork(
    _ map: SpanMap, session: Session, lock: PackageLock, language: WhisperLanguage, model: WhisperModel,
    environment: CaptureEnvironment, run: ReadRun, progress: @escaping @Sendable (TranscribeProgress) -> Void
) async -> Result<TranscribedWords?, StudioError> {
    let store = environment.modelStore
    let stopped: @Sendable () -> Bool = { run.cancelled.withLock { $0 } }
    let file = store.folder.appending(path: model.fileName)
    let check = { await onJobThread { environment.checkModel(model, store.folder) } }
    var checked = FileManager.default.fileExists(atPath: file.path) ? await check() : nil
    if checked == nil {
        do {
            try store.removeLeftovers()
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try await store.download(model, stop: stopped) { progress(.download($0)) }
        } catch {
            if stopped() { return .success(nil) }
            return .failure(.transcription(modelError(error, folder: store.folder)))
        }
        checked = await check()
    }
    guard let checked else { return .failure(.transcription(.modelChecksum)) }
    return await onJobThread { () -> Result<TranscribedWords?, StudioError> in
        guard !stopped() else { return .success(nil) }
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(TranscribeError) {
            return .success(
                try transcribeSpans(
                    map, session: session, package: package, model: checked, language: language,
                    engine: environment.transcribe, log: environment.log, stop: run.stop
                ) { progress(.transcribe($0)) })
        } catch {
            return .failure(.transcription(error))
        }
    }
}

/// `body` on a `.userInitiated` GCD thread: the model hash and the engine block for seconds, so
/// they stay off the cooperative pool.
private func onJobThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            continuation.resume(returning: body())
        }
    }
}

/// The error of the model download step of a job in `folder`: a `URLError` is the network, a
/// download that fails the catalog check has its own case, and each other error is a file step in
/// `folder`, with the POSIX code under it, else EIO.
func modelError(_ error: any Error, folder: URL) -> TranscribeError {
    if error as? WhisperModelStoreError == .checksumMismatch { return .modelDownloadChecksum }
    if error is URLError { return .modelDownload }
    if let code = posixCode(of: error) { return .modelWrite(folder: folder.path, errno: code) }
    let full = (error as? CocoaError)?.code == .fileWriteOutOfSpace
    return .modelWrite(folder: folder.path, errno: full ? ENOSPC : EIO)
}

/// Reads the concatenated audio of a `SpanMap` from the pool files of `package` (decision 0065 D3).
struct SpanReader {
    let map: SpanMap
    let session: Session
    let package: URL

    /// The engine rate of whisper.cpp.
    static let engineRate = 16_000

    /// The frames `range` of the concatenated audio as 16 kHz mono samples: the mean of the
    /// channels, then a rate conversion.
    func samples(_ range: Range<Frames>) throws(TranscribeError) -> [Float] {
        let mono = try sessionRate(range)
        guard map.sampleRate != Self.engineRate, !mono.isEmpty else { return mono }
        guard let input = AVAudioFormat(standardFormatWithSampleRate: Double(map.sampleRate), channels: 1),
            let output = AVAudioFormat(standardFormatWithSampleRate: Double(Self.engineRate), channels: 1),
            let converter = AVAudioConverter(from: input, to: output),
            let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(mono.count)),
            let target = AVAudioPCMBuffer(
                pcmFormat: output,
                frameCapacity: AVAudioFrameCount(mono.count * Self.engineRate / map.sampleRate + 1024))
        else { throw .audioRead(file: "", errno: ENOMEM) }
        mono.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        source.frameLength = AVAudioFrameCount(mono.count)
        // The converter calls the block on this thread, inside `convert`.
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = source
        var failure: NSError?
        _ = converter.convert(to: target, error: &failure) { _, status in
            defer { pending = nil }
            status.pointee = pending == nil ? .endOfStream : .haveData
            return pending
        }
        if failure != nil { throw .audioRead(file: "", errno: EIO) }
        return Array(UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength)))
    }

    /// The cut of `SpanMap.pieces`: the nearest pause of decision 0062 to `at` in `window` frames
    /// at each side, with the 0062 defaults (-40 dBFS, 200 ms). A read that fails cuts at `at`, and
    /// the piece read then throws.
    func cut(at: Frames, window: Frames) -> Frames {
        let step = LevelSeries.window(rate: map.sampleRate).count
        let low = (at - window).count / step * step
        let high = min((at + window).count, map.length.count)
        guard low < high, let mono = try? sessionRate(Frames(low)..<Frames(high)) else { return at }
        let levels = stride(from: 0, to: mono.count, by: step).map { start in
            let part = mono[start..<min(start + step, mono.count)]
            return WindowLevel(
                meanSquare: part.reduce(0) { $0 + $1 * $1 } / Float(part.count),
                peak: part.reduce(0) { max($0, abs($1)) })
        }
        guard let series = LevelSeries(range: Frames(low)..<Frames(high), window: Frames(step), levels: levels),
            let threshold = Gain(dB: -40)
        else { return at }
        switch series.nearestPause(
            at: at, window: window, threshold: threshold, minLength: Frames(map.sampleRate / 5))
        {
        case .pause(_, let cut), .noPause(let cut, _): return cut
        }
    }

    /// The frames `range` of the concatenated audio at the session rate, as the mean of the
    /// channels of each file.
    private func sessionRate(_ range: Range<Frames>) throws(TranscribeError) -> [Float] {
        var mono: [Float] = []
        mono.reserveCapacity(range.upperBound.count - range.lowerBound.count)
        for span in map.spans {
            let length = span.frames.upperBound - span.frames.lowerBound
            let low = max(range.lowerBound, span.time)
            let high = min(range.upperBound, span.time + length)
            guard low < high, let file = session.files[span.file] else { continue }
            let start = span.frames.lowerBound.count + (low - span.time).count
            mono += try read(file, from: start, count: (high - low).count)
        }
        return mono
    }

    private func read(_ file: AudioFile, from start: Int, count: Int) throws(TranscribeError) -> [Float] {
        let url = package.appending(path: "\(clipsFolderName)/\(file.path)")
        let audio: AVAudioFile
        do {
            audio = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw .audioRead(file: file.path, errno: access(url.path, R_OK) == 0 ? EIO : errno)
        }
        let channels = Int(audio.processingFormat.channelCount)
        guard audio.length >= AVAudioFramePosition(start + count),
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(count))
        else { throw .audioRead(file: file.path, errno: EIO) }
        audio.framePosition = AVAudioFramePosition(start)
        var mono = [Float](repeating: 0, count: count)
        var done = 0
        // A large read can give fewer frames than it asks for (4,319,232 of 4,320,000), so it reads
        // again until it has `count`.
        while done < count {
            do { try audio.read(into: buffer, frameCount: AVAudioFrameCount(count - done)) } catch {
                throw .audioRead(file: file.path, errno: EIO)
            }
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else { throw .audioRead(file: file.path, errno: EIO) }
            for channel in 0..<channels {
                for index in 0..<got { mono[done + index] += data[channel][index] }
            }
            done += got
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for index in 0..<count { mono[index] *= scale }
        }
        return mono
    }
}
