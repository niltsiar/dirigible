import AVFoundation
import DirigibleCore
import Foundation

/// Why a clip render changed nothing (decision 0054). Each `file` is a path in `Clips/`.
public enum ClipRenderError: Error, Hashable, Sendable {
    /// The new files and the 1 GB margin need `needed` free bytes, and the volume has `free`.
    case space(needed: Int64, free: Int64)
    /// `Clips/` or a new file cannot be made, written, flushed, or renamed, with the errno or the
    /// status.
    case write(file: String, errno: Int32)
    /// A source WAV does not read, with its errno: EIO when its format is not the format of its
    /// pool file or when it gives fewer frames than its run.
    case sourceUnreadable(file: String, errno: Int32)
    /// A source WAV is not in `Clips/`.
    case sourceMissing(file: String)
    /// The data of a source WAV is not on this Mac.
    case notDownloaded(file: String)
    case cancelled
    /// The session refused the render: for example a transcript that did not load.
    case session(SessionError)
    /// The treatment does not take a clip on a track with this role (`Treatment.accepts`).
    case trackRole(clip: ClipID, role: Track.Role)
    /// The effect unit did not load, with the status of the load: -3000 (`invalidComponentID`)
    /// when no component matches.
    case effectUnavailable(status: Int32)
    /// The engine did not render, with its error code or its manual rendering status.
    case engine(status: Int32)
}

/// The session of a clip render, the WAVs that it renamed, and each moved clip with its new file.
package struct ClipRenderOutcome: Sendable {
    package let session: Session
    package let made: [URL]
    package let clips: [RenderedClip]
}

/// Renders the clips of each group through the effects of its treatment into new WAVs in
/// `Clips/` (decision 0054): one WAV for each run of `clipRuns(of:)`, and `Session.repoint` onto
/// them. It never writes `session.xml`, and it blocks: never call it on the main actor.
///
/// The order: the runs, the role check of each clip (`Treatment.accepts`), the source checks, the
/// unit load, one space check (`freeBytes`), the stems "<source stem> NR" by the stem rule of
/// 0040, `repoint` on a session copy, then each run through a new chain into `.<stem>.wav.tmp`,
/// with a second pass at a scale when its peak is over full scale, the read-back, `setGains` of
/// the scaled clips, the renames, and one flush of `Clips/` (`NewClipFiles`). So a refusal reads
/// no audio and writes no file, and a throw before the renames leaves no new file. A fault in the
/// renames keeps the renamed WAVs as unused files (0040), and a cancel after them removes them
/// (`removeMadeFiles`). `isCancelled` is read before each run, each block, and the renames, and
/// after them. `progress` rises with the frames written, holds during a second pass, and gives 1
/// only after the read-back of the last run. `readFault` runs at the block reads of the run of the
/// new stem that it names (tests and `CaptureEnvironment.clipRenderRead`).
package func renderClips(
    _ groups: [(clips: [ClipID], treatment: Treatment)], of session: Session, in package: URL,
    freeBytes: () -> Int64, component: AudioComponentDescription = .soundIsolation,
    readFault: ReadFault? = nil, isDownloaded: (URL) -> Bool = sourceIsDownloaded,
    progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }
) throws(ClipRenderError) -> ClipRenderOutcome {
    var runs: [(run: ClipRun, source: AudioFile, treatment: Treatment)] = []
    do throws(SessionError) {
        for group in groups {
            for run in try session.clipRuns(of: group.clips) {
                guard let source = session.files[run.file] else { throw .unknownFile(run.file) }
                runs.append((run, source, group.treatment))
            }
        }
    } catch {
        throw .session(error)
    }
    for (run, _, treatment) in runs {
        for clip in run.clips {
            let role = session.clip(clip).flatMap { session.track($0.track)?.role }
            if let role, !treatment.accepts(role) { throw .trackRole(clip: clip, role: role) }
        }
    }
    for (_, source, _) in runs {
        let url = sourceURL(source, in: package)
        guard access(url.path, F_OK) == 0 else {
            let code = errno
            throw code == ENOENT ? .sourceMissing(file: source.path) : .sourceUnreadable(file: source.path, errno: code)
        }
        guard isDownloaded(url) else { throw .notDownloaded(file: source.path) }
    }
    guard let first = runs.first else { return ClipRenderOutcome(session: session, made: [], clips: []) }
    let rate = Double(session.sampleRate)
    var loaded: EffectChain? = try EffectChain(
        first.treatment, scale: 1, rate: rate, channels: first.source.layout.channelCount, component: component)

    let frames = runs.map { Int64(($0.run.span.upperBound - $0.run.span.lowerBound).count) }
    let bytes = zip(runs, frames).reduce(Int64(0)) {
        $0 + wavFileBytes(frames: $1.1, channels: $1.0.source.layout.channelCount)
    }
    var files: NewClipFiles
    do throws(NewClipFault) {
        files = try NewClipFiles(in: package, bytes: bytes, freeBytes: freeBytes)
    } catch {
        throw ClipRenderError(error)
    }
    defer { files.discard() }
    var stems: [String] = []
    var temporaries: [URL] = []
    for (_, source, treatment) in runs {
        let stem = importStems(
            of: URL(filePath: source.path), suffixes: [treatment.suffix], in: session, package: package,
            taken: files.stems)[0]
        do throws(NewClipFault) { temporaries.append(try files.add(stem: stem)) } catch { throw ClipRenderError(error) }
        stems.append(stem)
    }
    var rendered = session
    let clips: [RenderedClip]
    do throws(SessionError) {
        clips = try rendered.repoint(zip(runs, stems).map { RenderedRun(run: $0.run, stem: $1) })
    } catch {
        throw .session(error)
    }

    let total = Double(frames.reduce(0, +))
    var done: Int64 = 0
    var gains: [ClipID: Gain] = [:]
    for (index, (run, source, treatment)) in runs.enumerated() {
        guard !isCancelled() else { throw .cancelled }
        let channels = source.layout.channelCount
        let span = AVAudioFramePosition(run.span.lowerBound.count)..<AVAudioFramePosition(run.span.upperBound.count)
        let opened: (descriptor: Int32, file: AVAudioFile)
        do throws(ImportError) {
            opened = try openAudio(sourceURL(source, in: package))
        } catch {
            throw ClipRenderError(error, source: source.path)
        }
        defer { close(opened.descriptor) }
        let format = opened.file.fileFormat
        guard Int(format.channelCount) == channels, format.sampleRate == rate, opened.file.length >= span.upperBound
        else { throw .sourceUnreadable(file: source.path, errno: EIO) }
        let wav = "\(clipsFolderName)/\(stems[index]).wav"
        func pass(_ scale: Float, progress: (Int) -> Void) throws(ClipRenderError) -> (length: Int, peak: Float) {
            let chain: EffectChain
            if let ready = loaded.take() {
                chain = ready
            } else {
                chain = try EffectChain(treatment, scale: scale, rate: rate, channels: channels, component: component)
            }
            let writer: ClipWriter
            do throws(FinalizeError) {
                writer = try ClipWriter(url: temporaries[index], file: wav, format: opened.file.processingFormat)
            } catch {
                throw ClipRenderError(error, wav: wav)
            }
            return try chain.render(
                opened.file, descriptor: opened.descriptor, span: span, into: writer, file: source.path, wav: wav,
                stem: stems[index], readFault: readFault, isCancelled: isCancelled, rendered: progress)
        }
        let base = Double(done)
        var result = try pass(1) { written in
            let fraction = (base + Double(written)) / total
            if fraction < 1 { progress(fraction) }
        }
        if let scale = fullScaleRepair(result.peak) {
            result = try pass(scale) { _ in }
            for clip in run.clips {
                guard let gain = rendered.clip(clip)?.clip.gain.dB,
                    let scaled = Gain(clamping: gain - 20 * log10(Double(scale)))
                else { continue }
                gains[clip] = scaled
            }
        }
        guard result.length == span.count, try readBack(temporaries[index], wav: wav) == span.count else {
            throw .sourceUnreadable(file: source.path, errno: EIO)
        }
        done += Int64(span.count)
    }
    if !gains.isEmpty {
        do throws(SessionError) { try rendered.setGains(gains) } catch { throw .session(error) }
    }
    progress(1)
    guard !isCancelled() else { throw .cancelled }
    do throws(NewClipFault) { try files.commit() } catch { throw ClipRenderError(error) }
    guard !isCancelled() else {
        removeMadeFiles(files.made)
        throw .cancelled
    }
    return ClipRenderOutcome(session: rendered, made: files.made, clips: clips)
}

/// The scale of the second pass of a run whose peak `peak` is over full scale, or nil at full
/// scale or under. A peak over full scale saturates in 24 bits (A11 of import), so the second pass
/// puts the peak at the import ceiling, two 24-bit steps under full scale, and the clip gain gives
/// the level back.
func fullScaleRepair(_ peak: Float) -> Float? {
    peak > 1 ? Float((1 - 0x1p-22) / Double(peak)) : nil
}

/// Flushes the WAV at `url` and gives its frame count as it reads back.
private func readBack(_ url: URL, wav: String) throws(ClipRenderError) -> Int {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .write(file: wav, errno: errno) }
    defer { close(descriptor) }
    if let code = fullFlush(descriptor) { throw .write(file: wav, errno: code) }
    do {
        return Int(try AVAudioFile(forReading: url).length)
    } catch {
        throw .write(file: wav, errno: ioErrno(of: error, file: descriptor) ?? EIO)
    }
}

/// The URL of the WAV of `file` in `Clips/` of `package`.
private func sourceURL(_ file: AudioFile, in package: URL) -> URL {
    package.appending(path: "\(clipsFolderName)/\(file.path)")
}

extension ClipRenderError {
    /// The render error of an `openAudio` refusal of the source WAV at the pool path `source`.
    init(_ error: ImportError, source: String) {
        switch error {
        case .unreadable(_, let code):
            self = code == ENOENT ? .sourceMissing(file: source) : .sourceUnreadable(file: source, errno: code)
        case .notAudio, .notDownloaded, .tooManyChannels, .space, .cancelled, .write, .session:
            self = .sourceUnreadable(file: source, errno: EIO)
        }
    }
}
