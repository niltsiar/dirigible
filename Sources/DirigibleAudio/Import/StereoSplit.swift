import AVFoundation
import DirigibleCore
import Foundation

/// Why a stereo split changed nothing (decision 0053). Each `file` is a path in `Clips/`.
public enum SplitError: Error, Hashable, Sendable {
    /// The mono files and the 1 GB margin need `needed` free bytes, and the volume has `free`.
    case space(needed: Int64, free: Int64)
    /// `Clips/` or a mono file cannot be made, written, flushed, or renamed, with the errno or the
    /// status (ENOSPC too).
    case write(file: String, errno: Int32)
    /// A source WAV does not read, with its errno: EIO when it is not stereo audio or gives fewer
    /// frames than its run.
    case sourceUnreadable(file: String, errno: Int32)
    /// A source WAV is not in `Clips/`.
    case sourceMissing(file: String)
    case cancelled
    /// The session refused the split: for example a mono clip, or a transcript that did not load.
    case session(SessionError)
}

/// Splits the stereo clips `clips` of `session` (decision 0053): for each run of `clipRuns(of:)`,
/// one left and one right mono WAV of the run span in `Clips/`, and `Session.splitStereo` with
/// their stems and the track suffixes `names`. Returns the split session, its parts, and the WAVs
/// that it renamed. It never writes `session.xml`, and it blocks: never call it on the main actor.
///
/// The order: the source checks, one space check (`freeBytes`, 2 x 3 bytes for each frame of the
/// spans), the stems "<source stem> L" and "<source stem> R" by the stem rule of 0040, the session
/// split on a copy, the conversions into `.<stem>.wav.tmp`, a check that each WAV has the frames of
/// its span, the renames, and one flush of `Clips/` (`NewClipFiles`). So a session refusal writes
/// no file, and a throw before the renames leaves no new file. After the renames, a flush fault
/// keeps the WAVs as unused files, and a cancel removes them (`removeMadeFiles`). `isCancelled` is
/// read before each side, before each block, before the renames, and after them. `progress` rises
/// with the frames written and gives 1 only at the end of the last side.
///
/// shortcut: two reads of each source span, one for each side; write a one-pass deinterleave when
/// the bench shows the split of a long file too slow.
public func splitStereo(
    _ clips: [ClipID], names: (left: String, right: String), of session: Session, in package: URL,
    freeBytes: () -> Int64, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }
) throws(SplitError) -> (session: Session, parts: [SplitPart], made: [URL]) {
    let runs: [(run: ClipRun, source: AudioFile)]
    do throws(SessionError) {
        runs = try session.clipRuns(of: clips).map { run throws(SessionError) in
            guard let source = session.files[run.file] else { throw .unknownFile(run.file) }
            return (run, source)
        }
    } catch {
        throw .session(error)
    }
    for (_, source) in runs where access(sourceURL(source, in: package).path, F_OK) != 0 {
        throw errno == ENOENT ? .sourceMissing(file: source.path) : .sourceUnreadable(file: source.path, errno: errno)
    }
    let frames = runs.reduce(Int64(0)) { $0 + Int64(($1.run.span.upperBound - $1.run.span.lowerBound).count) }
    var files: NewClipFiles
    do throws(NewClipFault) {
        files = try NewClipFiles(in: package, bytes: wavFileBytes(frames: frames, channels: 2), freeBytes: freeBytes)
    } catch {
        throw SplitError(error)
    }
    defer { files.discard() }
    var pairs: [MonoPair] = []
    var temporaries: [(left: URL, right: URL)] = []
    for (run, source) in runs {
        let base = URL(filePath: source.path).deletingPathExtension().lastPathComponent
        do throws(NewClipFault) {
            let left = try files.add(stemOf: URL(filePath: "\(base) L.wav"), in: session)
            let right = try files.add(stemOf: URL(filePath: "\(base) R.wav"), in: session)
            pairs.append(MonoPair(run: run, leftStem: left.stem, rightStem: right.stem))
            temporaries.append((left.temporary, right.temporary))
        } catch {
            throw SplitError(error)
        }
    }
    var split = session
    let parts: [SplitPart]
    do throws(SessionError) { parts = try split.splitStereo(pairs, names: names) } catch { throw .session(error) }

    let total = Double(2 * frames)
    var done: Int64 = 0
    for (index, (run, source)) in runs.enumerated() {
        let span = AVAudioFramePosition(run.span.lowerBound.count)..<AVAudioFramePosition(run.span.upperBound.count)
        let count = span.upperBound - span.lowerBound
        let url = sourceURL(source, in: package)
        let opened: (descriptor: Int32, file: AVAudioFile)
        do throws(ImportError) { opened = try openAudio(url) } catch { throw SplitError(error, source: source.path) }
        defer { close(opened.descriptor) }
        guard opened.file.fileFormat.channelCount == 2, opened.file.length >= span.upperBound else {
            throw .sourceUnreadable(file: source.path, errno: EIO)
        }
        let sides = [
            (Side.left, pairs[index].leftStem, temporaries[index].left),
            (.right, pairs[index].rightStem, temporaries[index].right),
        ]
        for (side, stem, temporary) in sides {
            guard !isCancelled() else { throw .cancelled }
            let base = done
            let wav = "\(clipsFolderName)/\(stem).wav"
            let conversion = ClipConversion(
                package: package, wav: wav, blockFrames: 65_536, readFault: nil,
                unreadable: { .readFailed(file: url.path, errno: $0) }, channels: 1,
                progress: { progress((Double(base) + $0 * Double(count)) / total) }, isCancelled: isCancelled,
                pick: side, span: span)
            let written: (length: Int, gain: Gain)?
            do throws(FinalizeError) {
                let rate = opened.file.fileFormat.sampleRate
                written = try conversion.convert(
                    opened.file, file: opened.descriptor, from: rate, to: rate, into: temporary)
            } catch {
                throw SplitError(error, source: url.path, record: source.path, wav: wav)
            }
            guard let written else {
                throw isCancelled() ? .cancelled : .sourceUnreadable(file: source.path, errno: EIO)
            }
            guard AVAudioFramePosition(written.length) == count else {
                throw .sourceUnreadable(file: source.path, errno: EIO)
            }
            done += count
        }
    }
    guard !isCancelled() else { throw .cancelled }
    do throws(NewClipFault) { try files.commit() } catch { throw SplitError(error) }
    guard !isCancelled() else {
        removeMadeFiles(files.made)
        throw .cancelled
    }
    return (split, parts, files.made)
}

/// The URL of the WAV of `file` in `Clips/` of `package`.
private func sourceURL(_ file: AudioFile, in package: URL) -> URL {
    package.appending(path: "\(clipsFolderName)/\(file.path)")
}

extension SplitError {
    /// The split error of an `openAudio` refusal of the source WAV at the pool path `source`.
    init(_ error: ImportError, source: String) {
        switch error {
        case .unreadable(_, let code):
            self = code == ENOENT ? .sourceMissing(file: source) : .sourceUnreadable(file: source, errno: code)
        case .notAudio, .notDownloaded, .tooManyChannels, .space, .cancelled, .write, .session:
            self = .sourceUnreadable(file: source, errno: EIO)
        }
    }

    /// The split error of a conversion fault: a read of the source at `source` (`record` in the
    /// pool), else a fault of the mono WAV `wav`.
    init(_ error: FinalizeError, source: String, record: String, wav: String) {
        switch error {
        case .readFailed(let file, let code) where file == source: self = .sourceUnreadable(file: record, errno: code)
        case .readFailed(_, let code), .writeFailed(_, let code): self = .write(file: wav, errno: code)
        case .segmentUnreadable(_, _, let code): self = .sourceUnreadable(file: record, errno: code)
        }
    }
}
