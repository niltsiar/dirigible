import AVFoundation
import DirigibleCore
import Foundation

/// Where an import puts its clip (decision 0040).
public struct ImportTarget: Hashable, Sendable {
    /// Nil: a new last track, named after the file, with the file layout.
    public var track: TrackID?
    public var start: Frames

    public init(track: TrackID?, start: Frames) {
        self.track = track
        self.start = start
    }
}

/// Why an import changed nothing (decision 0040). Each case that the user can fix holds the file
/// name, so the alert can quote it.
public enum ImportError: Error, Hashable, Sendable {
    /// `AVAudioFile` does not open or read the file, or the file has no frames.
    case notAudio(file: String)
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
/// The order: the source checks, the target checks, the disk check (`freeBytes`, nil: the volume
/// of `package`), the conversion into `.<stem>.wav.tmp`, the session edits, the rename, the flush
/// of `Clips/`, and the level. A throw before the rename leaves no new file. After the rename, a
/// cancel or a flush fault throws and keeps the WAV as an unused file: the caller can have a
/// session that names it. `isCancelled` is read before each block of 65,536 frames, before the
/// read-back, and after the rename. A cancel during the level does not stop it: the caller reads
/// its flag again after the return.
public func importAudio(
    _ source: URL, to target: ImportTarget, of session: Session, in package: URL, level: Bool = true,
    freeBytes: (() -> Int64)? = nil, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }
) throws(ImportError) -> (session: Session, clip: ClipID) {
    let name = source.lastPathComponent
    // Held open, so a read error with no errno can be checked on the same file.
    let descriptor = open(source.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .unreadable(file: name, errno: errno) }
    defer { close(descriptor) }
    let input: AVAudioFile
    do {
        input = try AVAudioFile(forReading: source)
    } catch {
        if let code = ioErrno(of: error, file: descriptor) { throw .unreadable(file: name, errno: code) }
        throw .notAudio(file: name)
    }
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
    // The placement rule (decision 0021): 3 bytes for each sample of the WAV, and the margin.
    let frames = Int64((Double(input.length) * rate / sourceRate).rounded(.up))
    let needed = frames * Int64(layout.channelCount) * 3 + diskMargin
    let free = freeBytes?() ?? volumeFreeBytes(package)
    guard free >= needed else { throw .space(file: name, needed: needed, free: free) }

    let clips = package.appending(path: clipsFolderName)
    let stem = importStem(of: source, in: session, package: package)
    let wav = "\(clipsFolderName)/\(stem).wav"
    let temporary = clips.appending(path: ".\(stem).wav.tmp")
    var renamed = false
    defer { if !renamed { unlink(temporary.path) } }
    let conversion = ClipConversion(
        package: package, wav: wav, blockFrames: 65_536, readFault: nil,
        unreadable: { .readFailed(file: source.path, errno: $0) }, channels: AVAudioChannelCount(layout.channelCount),
        progress: progress, isCancelled: isCancelled)
    let converted: (length: Int, gain: Gain)?
    do {
        converted = try conversion.convert(input, file: descriptor, from: sourceRate, to: rate, into: temporary)
    } catch .readFailed(let file, let code) where file == source.path {
        throw .unreadable(file: name, errno: code)
    } catch {
        throw .write(file: name, error)
    }
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
    guard rename(temporary.path, package.appending(path: wav).path) == 0 else {
        throw .write(file: name, .writeFailed(file: wav, status: errno))
    }
    renamed = true
    if let code = fullFlush(path: clips.path) {
        throw .write(file: name, .writeFailed(file: clipsFolderName, status: code))
    }
    // The level reads the renamed file. A cancel skips it (about 0.4 s for each hour of stereo).
    guard !isCancelled() else { throw .cancelled }
    if level { imported = autoLevel([clip], .eachClip, of: imported, in: package).session }
    return (imported, clip)
}

/// The stem of the WAV and the IDs of an import of `source` (decision 0040): the file name with no
/// extension, with no leading "." and no character that a session or an exFAT volume cannot
/// store, or "Imported" when nothing is left. A stem that a file ID, a clip ID, a pool path, a
/// name in `Clips/`, or a segment stem in `Capture/` uses, in any case, gets " 2", " 3", and so on.
func importStem(of source: URL, in session: Session, package: URL) -> String {
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
    let used = Set(names.map { $0.lowercased() })
    var (stem, number) = (base, 2)
    while used.contains(stem.lowercased()) || used.contains("\(stem).wav".lowercased()) {
        stem = "\(base) \(number)"
        number += 1
    }
    return stem
}

/// The free bytes of the volume of `url` for a normal process, as `PackageLock.freeBytes`. An
/// errno gives 0.
private func volumeFreeBytes(_ url: URL) -> Int64 {
    var info = statfs()
    guard statfs(url.path, &info) == 0 else { return 0 }
    return Int64(info.f_bavail) * Int64(info.f_bsize)
}
