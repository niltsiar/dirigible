import AVFoundation
import DirigibleCore
import Foundation

/// Why an import changed nothing (decision 0040). Each case that the user can fix holds the file
/// name, so the alert can quote it.
public enum ImportError: Error, Hashable, Sendable {
    /// `AVAudioFile` does not open or read the file, or the file has no frames.
    case notAudio(file: String)
    /// An iCloud or File Provider item whose data is not on this Mac.
    case notDownloaded(file: String)
    /// The file has more than 2 channels.
    case tooManyChannels(file: String, channels: Int)
    /// A read of the file fails with an errno.
    case unreadable(file: String, errno: Int32)
    /// The WAV and the 1 GB margin need `needed` free bytes, and the volume has `free`.
    case space(file: String, needed: Int64, free: Int64)
    case cancelled
    /// `Clips/` or the WAV cannot be made, written, flushed, or renamed.
    case write(file: String, FinalizeError)
    /// The session refuses the target: an unknown track, or a start out of range.
    case session(SessionError)
}

/// Converts `source` into `Clips/<stem>.wav` at the session rate and the target layout, adds the
/// file, the clip, and a new track when `target.track` is nil, and levels the clip with
/// `autoLevel(.eachClip)` when `level` (decision 0040). The clip overwrites the clips under it, as a
/// placement does. It never writes `session.xml`, and it blocks until the end, so never call it on
/// the main actor.
///
/// The order: the download check (`isDownloaded`, before any read), the source checks, the target
/// checks, the disk check (`freeBytes`, the free bytes of the volume of the package lock), the
/// `mkdir` of `Clips/`, the conversion into `.<stem>.wav.tmp`, the session edits, the rename, the
/// flush of `Clips/`, and the level. `NewClipFiles` owns the file steps (decision 0056). The rename
/// never replaces a file: another file at the name throws a write fault with EEXIST and keeps its
/// bytes. A throw before the rename leaves no new file. After the rename, a flush fault throws and
/// keeps the WAV as an unused file: the caller can have a session that names it. A cancel after
/// the rename, also during the level, removes the WAV with `removeMadeFiles` and throws
/// `.cancelled` (decision 0049). `isCancelled` is read before each block of 65,536 frames, before
/// the read-back, after the rename, at each block of the level, and last before the return. A
/// caller that reads its flag again after the return removes the WAV itself. With `level`, the
/// conversion gives 0...0.8 of `progress` and the level 0.8...1.
public func importAudio(
    _ source: URL, to target: ImportTarget, of session: Session, in package: URL, level: Bool = true,
    freeBytes: () -> Int64, isDownloaded: (URL) -> Bool = sourceIsDownloaded,
    progress: @escaping @Sendable (Double) -> Void = { _ in },
    isCancelled: @escaping @Sendable () -> Bool = { false }
) throws(ImportError) -> (session: Session, clip: ClipID) {
    let name = source.lastPathComponent
    guard isDownloaded(source) else { throw .notDownloaded(file: name) }
    let (descriptor, input) = try openAudio(source)
    defer { close(descriptor) }
    let channels = Int(input.fileFormat.channelCount)
    guard channels <= 2 else { throw .tooManyChannels(file: name, channels: channels) }
    guard input.length > 0, let fileLayout = ChannelLayout(channelCount: channels) else {
        throw .notAudio(file: name)
    }
    let layout: ChannelLayout
    if let id = target.track {
        guard let track = session.track(id) else { throw .session(.unknownTrack(id)) }
        layout = track.layout
    } else {
        layout = fileLayout
    }
    guard target.start >= .zero else { throw .session(.frameOutOfRange) }
    let (sourceRate, rate) = (input.fileFormat.sampleRate, Double(session.sampleRate))
    let frames = Int64((Double(input.length) * rate / sourceRate).rounded(.up))
    var files: NewClipFiles
    do throws(NewClipFault) {
        files = try NewClipFiles(
            in: package, bytes: wavFileBytes(frames: frames, channels: layout.channelCount), freeBytes: freeBytes)
    } catch {
        throw ImportError(error, file: name)
    }
    defer { files.discard() }
    let stem: String
    let temporary: URL
    do throws(NewClipFault) {
        (stem, temporary) = try files.add(stemOf: source, in: session)
    } catch {
        throw ImportError(error, file: name)
    }
    let wav = "\(clipsFolderName)/\(stem).wav"
    let share = level ? 0.8 : 1
    let converted = try convertToWAV(
        input, descriptor: descriptor, source: source, package: package, wav: wav, channels: layout.channelCount,
        rate: rate, into: temporary, progress: { progress($0 * share) }, isCancelled: isCancelled)
    guard let (length, gain) = converted else { throw isCancelled() ? .cancelled : .notAudio(file: name) }

    let (track, file, clip) = (target.track ?? TrackID(), FileID(stem), ClipID(stem))
    var imported = session
    do throws(SessionError) {
        if target.track == nil { try imported.addTrack(track, name: stem, layout: layout) }
        try imported.addFile(AudioFile(id: file, path: "\(stem).wav", layout: layout, length: Frames(length)))
        try imported.place(
            Clip(id: clip, file: file, start: target.start, offset: .zero, length: Frames(length), gain: gain),
            on: track)
    } catch {
        throw .session(error)
    }
    do throws(NewClipFault) { try files.commit() } catch { throw ImportError(error, file: name) }
    // The level reads the renamed file, and stops at a cancel (about 0.4 s for each hour of stereo).
    if !isCancelled(), level {
        imported =
            autoLevel(
                [clip], .eachClip, of: imported, in: package, progress: { progress(share + $0 * (1 - share)) },
                isCancelled: isCancelled
            ).session
    }
    guard !isCancelled() else {
        removeMadeFiles([package.appending(path: wav)])
        throw .cancelled
    }
    return (imported, clip)
}

/// The WAV that `importAudio` made for `clip`: the clip, its file, and its WAV share the stem.
public func importedWAV(_ clip: ClipID, in package: URL) -> URL {
    package.appending(path: clipsFolderName).appending(path: "\(clip.rawValue).wav")
}

/// Removes the files that a cancelled run made after their rename (decision 0049): the WAV of an
/// import. A failed save, a flush fault, and Undo keep them (decision 0040). Each owner of the
/// last cancel read of a run calls it: `importAudio`, the cancel branch of `blockingTurn`, and the
/// work on the files of the `import` tool.
public func removeMadeFiles(_ files: [URL]) {
    for file in files { unlink(file.path) }
}

/// `removeMadeFiles` off the main actor, for a caller that awaits it.
@concurrent nonisolated func removeMadeFilesOffMain(_ files: [URL]) async { removeMadeFiles(files) }

/// Opens `source` for a conversion: a descriptor, held open so that a read error with no errno can
/// be checked on the same file, and the `AVAudioFile`. The caller closes the descriptor.
func openAudio(_ source: URL) throws(ImportError) -> (descriptor: Int32, file: AVAudioFile) {
    let name = source.lastPathComponent
    let descriptor = open(source.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .unreadable(file: name, errno: errno) }
    do {
        return (descriptor, try AVAudioFile(forReading: source))
    } catch {
        let code = ioErrno(of: error, file: descriptor)
        close(descriptor)
        if let code { throw .unreadable(file: name, errno: code) }
        throw .notAudio(file: name)
    }
}

/// Converts `input` into the temporary WAV at `temporary`, `channels` channels at `rate`, with
/// `ClipConversion` (decision 0040): the one conversion of import and of a paste from a package of
/// another rate (decision 0042). Returns the frame count and the clip gain of A11, or nil for a bad
/// input or a cancel. `wav` is the package-relative path of the WAV, for errors.
func convertToWAV(
    _ input: AVAudioFile, descriptor: Int32, source: URL, package: URL, wav: String, channels: Int, rate: Double,
    into temporary: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool
) throws(ImportError) -> (length: Int, gain: Gain)? {
    let conversion = ClipConversion(
        package: package, wav: wav, blockFrames: 65_536, readFault: nil,
        unreadable: { .readFailed(file: source.path, errno: $0) }, channels: AVAudioChannelCount(channels),
        progress: progress, isCancelled: isCancelled)
    do {
        return try conversion.convert(
            input, file: descriptor, from: input.fileFormat.sampleRate, to: rate, into: temporary)
    } catch .readFailed(let file, let code) where file == source.path {
        throw .unreadable(file: source.lastPathComponent, errno: code)
    } catch {
        throw .write(file: source.lastPathComponent, error)
    }
}

/// The stem of the WAV and the IDs of an import of `source` (decision 0040): the file name with no
/// extension, with no leading "." and no character that a session or an exFAT volume cannot
/// store, or "Imported" when nothing is left. A stem that a file ID, a clip ID, a pool path, a
/// name in `Clips/`, a segment stem in `Capture/`, or a stem in `taken` uses, in any case, gets
/// " 2", " 3", and so on.
func importStem(of source: URL, in session: Session, package: URL, taken: Set<String>) -> String {
    var base = String(
        String.UnicodeScalarView(
            source.deletingPathExtension().lastPathComponent.unicodeScalars.filter {
                !"/:?*<>|\"\\".unicodeScalars.contains($0) && $0.isStorableInSession
            }))
    while base.hasPrefix(".") { base.removeFirst() }
    if base.isEmpty { base = "Imported" }
    func listing(_ folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: package.appending(path: folder).path)) ?? []
    }
    let segments: [String] = listing(captureFolderName).map { ($0 as NSString).deletingPathExtension }
    let pool: [String] = session.files.values.flatMap { [$0.id.rawValue, $0.path] }
    let names: [String] =
        pool + session.tracks.flatMap(\.clips).map(\.id.rawValue) + listing(clipsFolderName) + segments
    let used = Set((names + taken).map { $0.lowercased() })
    var (stem, number) = (base, 2)
    while used.contains(stem.lowercased()) || used.contains("\(stem).wav".lowercased()) {
        stem = "\(base) \(number)"
        number += 1
    }
    return stem
}

/// True unless `url` is an iCloud or File Provider item whose data is not on this Mac
/// (decision 0040). A read of such an item can wait for the network with no end.
public func sourceIsDownloaded(_ url: URL) -> Bool {
    let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
    return isDownloaded(ubiquitous: values?.isUbiquitousItem, status: values?.ubiquitousItemDownloadingStatus)
}

/// The rule of `sourceIsDownloaded`. An unknown status passes, so no local file is refused.
func isDownloaded(ubiquitous: Bool?, status: URLUbiquitousItemDownloadingStatus?) -> Bool {
    ubiquitous != true || status != .notDownloaded
}
