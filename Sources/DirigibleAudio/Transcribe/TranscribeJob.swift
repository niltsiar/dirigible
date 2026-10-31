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

/// One `WhisperEngine` for the job, with the VAD model of the app bundle (`Contents/Resources`).
/// With no bundle file, as in `swift run`, the engine runs with no VAD.
let liveTranscribe: TranscribeEngine = { model, language, count, log, read, stop, progress throws(TranscribeError) in
    let vad = Bundle.main.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin")
    let engine = try WhisperEngine(model: model, vad: vad, log: log)
    return try engine.transcribe(pieceCount: count, language: language, stop: stop, read: read, progress: progress)
}

/// The words of a job in file frames, the untimed count of `SpanMap`, and the language.
struct TranscribedWords: Sendable {
    let words: FileWords
    let untimed: Int
    let language: String
}

/// The work of a job off the main actor (decision 0065 D5): the leftover sweep and the download
/// when the model file is missing, with the stop check of `run`; then, on one `.userInitiated` GCD
/// thread, the model check, a read of the flags, and the engine. Nil for a stop.
@concurrent nonisolated func transcribeWork(
    _ map: SpanMap, session: Session, lock: PackageLock, language: WhisperLanguage, model: WhisperModel,
    environment: CaptureEnvironment, run: ReadRun, progress: @escaping @Sendable (TranscribeProgress) -> Void
) async -> Result<TranscribedWords?, StudioError> {
    let store = environment.modelStore
    let stopped: @Sendable () -> Bool = { run.cancelled.withLock { $0 } }
    do {
        try store.removeLeftovers()
        if !FileManager.default.fileExists(atPath: store.folder.appending(path: model.fileName).path) {
            try await store.download(model, stop: stopped) { progress(.download($0)) }
        }
    } catch {
        if stopped() { return .success(nil) }
        return .failure(
            .transcription(error as? WhisperModelStoreError == .checksumMismatch ? .modelChecksum : .modelDownload))
    }
    @Sendable func engineWork() -> Result<TranscribedWords?, StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let checked = environment.checkModel(model, store.folder) else {
            return .failure(.transcription(.modelChecksum))
        }
        guard !stopped() else { return .success(nil) }
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        let reader = SpanReader(map: map, session: session, package: package)
        let pieces = map.pieces { at, window in reader.cut(at: at, window: window) }
        do throws(TranscribeError) {
            guard
                let result = try environment.transcribe(
                    checked, language, pieces.count, environment.log,
                    { n throws(TranscribeError) in try reader.samples(pieces[n]) }, run.stop,
                    { progress(.transcribe($0)) })
            else { return .success(nil) }
            let mapped = map.fileWords(result.pieces, in: pieces)
            return .success(TranscribedWords(words: mapped.words, untimed: mapped.untimed, language: result.language))
        } catch {
            return .failure(.transcription(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: engineWork()) }
    }
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
        do { try audio.read(into: buffer, frameCount: AVAudioFrameCount(count)) } catch {
            throw .audioRead(file: file.path, errno: EIO)
        }
        guard Int(buffer.frameLength) == count, let data = buffer.floatChannelData else {
            throw .audioRead(file: file.path, errno: EIO)
        }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            for index in 0..<count { mono[index] += data[channel][index] }
        }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for index in 0..<count { mono[index] *= scale }
        }
        return mono
    }
}
