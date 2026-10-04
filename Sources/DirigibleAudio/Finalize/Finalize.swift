import AVFoundation
import DirigibleCore
import Foundation

/// Only faults that can go away (decision 0012). The take stays pending and a retry can succeed.
public enum FinalizeError: Error, Hashable, Sendable {
    /// `Capture/`, a listed CAF that is gone (ENOENT), a take anchor, or a WAV read-back does not
    /// open or read (for example EACCES, EIO, EMFILE). A read that fails with an errno (from the
    /// error, or else from a POSIX read of the file: `ioErrno`) is this case, not a bad file.
    case readFailed(file: String, errno: Int32)
    /// The CAF or the sidecar of `segment` does not open or read, with an errno other than ENOENT
    /// (decision 0021). The take stays pending, unless the user leaves the unreadable segments
    /// (`leavingUnreadable`); then only this segment stays unplaced.
    case segmentUnreadable(SegmentName, file: String, errno: Int32)
    /// `Clips/` or a WAV cannot be made, written, flushed, closed, or renamed (for example ENOSPC,
    /// EACCES, EISDIR).
    case writeFailed(file: String, status: Int32)
}

/// Why one segment stays unplaced (decision 0021). The take finalize does not throw it: the other
/// segments are placed and the take ends. A placement (`Studio.place`) throws it.
public enum SegmentFault: Error, Hashable, Sendable {
    /// The segment is placed, is in the pending take, or has no CAF with audio.
    case notUnplaced
    /// No take anchor gives the track or the start, and the call does not give them.
    case noAlignment
    /// A newer build of Dirigible wrote the take anchor with format `version` (decision 0024),
    /// and the call does not give the track and the start.
    case newerAnchor(version: Int)
    /// The sidecar is missing or refused, so the timing of the segment is not known.
    case noSidecar
    /// A newer build of Dirigible wrote the sidecar with format `version` (decision 0024). The
    /// sidecar and the CAF do not change, so that build can place the segment.
    case newerSidecar(version: Int)
    /// The CAF has no frames, is not a CAF, does not match its sidecar, or does not convert whole.
    case badAudio
    /// The whole segment is before frame 0 of the timeline.
    case beforeTimeline
    /// This pool file has the path of the WAV of the segment, so the finalize does not write it.
    case wavInUse(FileID)
    /// The session refuses the capture, the file, or the clip.
    case session(SessionError)
}

/// A test seam: `before` runs before the read of block `block` (0-based) of one segment, and an
/// error that it throws is the read error. Only tests pass it; `Studio` and the CLI never do.
struct ReadFault: Sendable {
    var stem: String
    var block: Int
    var before: @Sendable () throws -> Void
}

/// Reads every segment of `session.recording` in `Capture/`, writes each WAV to `Clips/`, and
/// returns the session with the captures, files, and clips added and `recording` removed. It
/// never writes `session.xml`. A second run overwrites the WAVs of the first.
///
/// A fault of one segment skips that segment: its capture, file, and clip are not added, and it
/// stays unplaced. Only a fault that can go away throws, and then nothing is placed. With
/// `leavingUnreadable`, a `.segmentUnreadable` segment is skipped too (decision 0021). Each segment
/// is read and converted in blocks, so the memory does not grow with the take length. Each WAV and
/// then `Clips/` are flushed before it returns, so the save never points to a WAV that is not on
/// the disk; a flush error throws. Last, it writes the take anchor (`TakeAnchor`), the only record
/// of the track and the start of each segment after the save removes `recording`; a fault of that
/// write throws too. An anchor of a newer version keeps its bytes (decision 0024 P4).
func finalizeTake(
    of session: Session, in package: URL, leavingUnreadable: Bool = false, readFault: ReadFault? = nil,
    blockFrames: Int = 65_536
) throws(FinalizeError) -> Session {
    guard let recording = session.recording else { return session }
    // `mkdir Capture/` comes before the save of <recording>, so a missing folder is a package
    // that moved or lost it (decision 0014), not a take with no audio.
    if openErrno(package.appending(path: captureFolderName).path) == ENOENT {
        throw .readFailed(file: captureFolderName, errno: ENOENT)
    }
    // Before the segment loop, so an anchor that does not read stops the take before any WAV.
    let anchor = try TakeAnchor.read(take: recording.take, in: package)
    var result = session
    for name in try captureSegments(in: package)
    where name.take == recording.take && name.arm <= recording.armedTracks.count {
        let segment = SegmentFinalize(
            name: name, target: .aligned(recording, track: recording.armedTracks[name.arm - 1]), package: package,
            readFault: readFault, blockFrames: blockFrames)
        do {
            if case .success(let placed) = try segment.place(on: result) { result = placed }
        } catch .segmentUnreadable where leavingUnreadable {
            continue  // The user chose to end the take without it; it stays unplaced (decision 0021).
        }
    }
    let clips = package.appending(path: clipsFolderName)
    if result.files.count > session.files.count, let code = fullFlush(path: clips.path) {
        throw .writeFailed(file: clipsFolderName, status: code)
    }
    // After every throw of the loop, so a take that stays pending has no anchor (decision 0021).
    switch anchor {
    case .failure?: break  // A newer build wrote it (decision 0024 P4).
    case .success?, nil: try TakeAnchor.write(recording, in: package)
    }
    try? result.setRecording(nil)  // Removing the recording never throws.
    return result
}

/// The per-segment finalize of one segment to `target`, then the flush of `Clips/` (decision
/// 0021). Returns the session with the capture, the file, and the clip of the segment added, or
/// the fault that keeps it unplaced. It never writes `session.xml`.
func placeSegment(
    _ name: SegmentName, to target: Target, of session: Session, in package: URL, readFault: ReadFault? = nil
) throws(FinalizeError) -> Result<Session, SegmentFault> {
    let result = try SegmentFinalize(
        name: name, target: target, package: package, readFault: readFault, blockFrames: 65_536
    ).place(on: session)
    if case .success = result, let code = fullFlush(path: package.appending(path: clipsFolderName).path) {
        throw .writeFailed(file: clipsFolderName, status: code)
    }
    return result
}

/// The format version of the sidecar of `segment` when a newer build of Dirigible wrote it
/// (decision 0024), else nil. The `take finalize` warning gives it.
public func newerSidecarVersion(of segment: SegmentName, in package: URL) -> Int? {
    guard let data = try? readPackageFile("\(captureFolderName)/\(segment.stem).sidecar", in: package) else {
        return nil
    }
    do {
        _ = try Sidecar.decode(data)
        return nil
    } catch {
        return error.version
    }
}

/// The segments of the CAFs in `Capture/` that have frames or do not open: the disk fact under
/// the unplaced list (decision 0012). In name order. It reads files, so call it off the main actor.
func segmentsWithAudio(in package: URL) -> [SegmentName] {
    ((try? captureSegments(in: package)) ?? []).filter { name in
        let file = try? AVAudioFile(forReading: package.appending(path: "\(captureFolderName)/\(name.stem).caf"))
        return (file?.length ?? 1) > 0
    }
}

/// The `segments` whose take is not the pending take and that no file of the session refers to.
/// In the order of `segments`. No file I/O, so a caller can derive it on each read.
func unplacedSegments(_ segments: [SegmentName], session: Session) -> [SegmentName] {
    let referenced = Set(session.files.values.compactMap(\.capture))
    return segments.filter { $0.take != session.recording?.take && !referenced.contains(CaptureID($0.stem)) }
}

/// True when a ripple must not move the timeline (decision 0037): the session has a pending
/// take, or a take is split. A take is split when one of its `segments` is unplaced and a file of
/// the session refers to another segment of that take. A pending take places at its take anchor,
/// and a split take places its rest at its old frames, so a ripple breaks their sync. A wholly
/// unplaced take moves as one unit, so it does not block. No file I/O.
public func rippleBlocked(segments: [SegmentName], session: Session) -> Bool {
    if session.recording != nil { return true }
    let placedTakes = Set(
        session.files.values.compactMap { $0.capture.flatMap { SegmentName(stem: $0.rawValue)?.take } })
    return unplacedSegments(segments, session: session).contains { placedTakes.contains($0.take) }
}

/// `rippleBlocked(segments:session:)` with the segments in `Capture/` of `package`. It reads
/// files, so call it off the main actor.
public func rippleBlocked(in package: URL, session: Session) -> Bool {
    rippleBlocked(segments: segmentsWithAudio(in: package), session: session)
}

/// The segment names of the CAFs in `Capture/`, in name order. A missing folder has none.
func captureSegments(in package: URL) throws(FinalizeError) -> [SegmentName] {
    let folder = package.appending(path: captureFolderName)
    if let code = openErrno(folder.path) {
        if code == ENOENT { return [] }
        throw .readFailed(file: captureFolderName, errno: code)
    }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
        throw .readFailed(file: captureFolderName, errno: EIO)
    }
    return names.filter { $0.hasSuffix(".caf") }.compactMap(SegmentName.init(fileName:)).sorted()
}

/// The bytes of the package file at `file` (package-relative). Nil when it is missing (ENOENT);
/// another errno throws `.readFailed`, a fault that can go away.
func readPackageFile(_ file: String, in package: URL) throws(FinalizeError) -> Data? {
    let url = package.appending(path: file)
    if let code = openErrno(url.path) {
        if code == ENOENT { return nil }
        throw .readFailed(file: file, errno: code)
    }
    do {
        return try Data(contentsOf: url)
    } catch {
        throw .readFailed(file: file, errno: posixCode(of: error) ?? EIO)
    }
}

/// The errno of `open(path, O_RDONLY)`, or nil when the file opens.
func openErrno(_ path: String) -> Int32? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return errno }
    close(descriptor)
    return nil
}

/// The errno of an I/O fault under an AVAudioFile error on the file at `descriptor`, or nil when
/// the file is bad, not the disk. A real I/O fault reaches AVAudioFile with no errno (probe
/// 2026-09-24, probe-read-error.swift: -40 on a block read, 'wht?' on an open), and an empty CAF
/// also gives 'wht?'. So with no errno in the error, a POSIX read of every byte decides.
func ioErrno(of error: any Error, file descriptor: Int32) -> Int32? {
    if let code = posixCode(of: error) { return code }
    var bytes = [UInt8](repeating: 0, count: 1 << 20)
    var offset: off_t = 0
    while true {
        let count = pread(descriptor, &bytes, bytes.count, offset)
        if count == 0 { return nil }
        if count > 0 {
            offset += off_t(count)
        } else if errno != EINTR {
            return errno
        }
    }
}

/// The POSIX code under a Foundation or AVFoundation error, or nil when there is none.
func posixCode(of error: any Error) -> Int32? {
    var current: NSError? = error as NSError
    while let error = current {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return nil
}

/// `mkdir` of `Clips/` only: a package path that moved gives ENOENT and no new package folder
/// (decision 0014). A folder that exists is fine.
func createClipsFolder(in package: URL) throws(FinalizeError) {
    guard mkdir(package.appending(path: clipsFolderName).path, 0o755) == 0 || errno == EEXIST else {
        throw .writeFailed(file: clipsFolderName, status: errno)
    }
}
