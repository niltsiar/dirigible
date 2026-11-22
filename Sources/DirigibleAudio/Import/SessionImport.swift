import DirigibleCore
import Foundation

/// Why a session import changed nothing (decision 0075).
public enum SessionImportError: Error, Hashable, Sendable {
    /// `at` outside -2^40...2^40, refused before any read or arithmetic.
    case offsetOutOfRange(Int)
    /// A target session rate outside 8000...384000 Hz.
    case targetSampleRateOutOfRange(Int)
    /// A source rate outside 8000...384000 Hz.
    case sampleRateOutOfRange(Int)
    case sameSession
    case takeNotFinalized
    case nothingToImport
    /// The read of the source package fails.
    case source(SessionFileError)
    /// A named source file in `Clips/` with a link at a component of its path, or not a regular file.
    case unsafeFile(String)
    case paste(PasteError)
}

/// The result of `importSession`.
public struct SessionImported: Sendable {
    /// The edited copy of the session; the caller saves it.
    public let session: Session
    /// The new tracks, in source order.
    public let tracks: [TrackID]
    public let markers: [MarkerID]
    /// The source markers under frame 0 or over 2^40 after the offset.
    public let leftOutMarkers: Int
    /// The new tracks of a source track with an `.app` route, which the import mutes.
    public let mutedCallTracks: Int
    /// The renamed WAVs: the caller removes them at a cancel before the save (0049).
    public let made: [URL]
}

/// The session rates that an import takes. With |`at`| and each frame at most 2^40, each scale
/// product stays under about 8.4e17, so no scale step can overflow `Int`.
let importRates = 8_000...384_000

/// Checks `at`, reads `source`, cuts its head for a negative `at`, checks the named files and the
/// marker list, pastes one excerpt of all its tracks into new last tracks at max(0, at), then runs
/// only setters that cannot fail: the names, the track gain, role, mute, follow flag, and voice
/// match (decision 0075). A source track with an `.app` route imports muted. It never writes
/// `session.xml` and writes nothing in `source`. It blocks: never call it on the main actor.
public func importSession(
    from source: URL, into session: Session, in package: URL, identity: PackageID?, at: Int, markers: Bool,
    freeBytes: () -> Int64, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }
) throws(SessionImportError) -> SessionImported {
    try importSession(
        from: source, into: session, in: package, identity: identity, at: at, markers: markers, freeBytes: freeBytes,
        progress: progress, isCancelled: isCancelled, isDownloaded: sourceIsDownloaded)
}

func importSession(
    from source: URL, into session: Session, in package: URL, identity: PackageID?, at: Int, markers: Bool,
    freeBytes: () -> Int64, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }, isDownloaded: (URL) -> Bool
) throws(SessionImportError) -> SessionImported {
    guard (-Frames.limit.count...Frames.limit.count).contains(at) else { throw .offsetOutOfRange(at) }
    let rate = session.sampleRate
    guard importRates.contains(rate) else { throw .targetSampleRateOutOfRange(rate) }
    // The only read of the source XML and items: the guards of the open (0003 Rules), with no lock.
    let read: Session
    do { read = try Session(contentsOf: source) } catch { throw .source(error) }
    let origin = PackageID(lockFileOf: source)
    if PackageID.same(origin, identity)
        || source.resolvingSymlinksInPath().standardizedFileURL.path
            == package.resolvingSymlinksInPath().standardizedFileURL.path
    {
        throw .sameSession
    }
    guard read.recording == nil else { throw .takeNotFinalized }
    let sourceRate = read.sampleRate
    guard importRates.contains(sourceRate) else { throw .sampleRateOutOfRange(sourceRate) }
    let cut = at < 0 ? (2 * -at * sourceRate + rate) / (2 * rate) : 0
    guard cut < read.end.count else { throw .nothingToImport }
    let excerpt: Excerpt
    do { excerpt = try read.excerpt(of: Frames(cut)..<read.end, on: read.tracks.map(\.id)) } catch {
        throw .paste(.session(error))
    }
    try checkFiles(excerpt, in: source, isCancelled: isCancelled, isDownloaded: isDownloaded)
    let names = trackNames(excerpt, source: source, into: session)
    var marked = session
    var added: [MarkerID] = []
    var leftOut = 0
    if markers {
        for marker in read.sortedMarkers {
            let position = (2 * marker.position.count * rate + sourceRate) / (2 * sourceRate) + at
            guard (0...Frames.limit.count).contains(position) else {
                leftOut += 1
                continue
            }
            let copy = Marker(
                id: MarkerID(), name: marker.name, position: Frames(position), kind: marker.kind, url: marker.url)
            do { try marked.setMarker(copy) } catch { throw .paste(.session(error)) }
            added.append(copy.id)
        }
    }
    let pasted: (session: Session, clips: [ClipID], tracks: [TrackID])
    do {
        pasted = try pasteClipboard(
            Clipboard(excerpt, package: source, origin: origin), from: source, into: marked, in: package,
            identity: identity, mode: .over(at: Frames(max(0, at))), on: .unselected, freeBytes: freeBytes,
            progress: progress, isCancelled: isCancelled)
    } catch {
        throw .paste(error)
    }
    var result = pasted.session
    var muted = 0
    // Each setter throws only for an unknown track, and each track of `pasted.tracks` is there.
    do throws(SessionError) {
        for (lane, id) in zip(excerpt.lanes, pasted.tracks) {
            guard let track = read.track(lane.source) else { continue }
            let call = if case .app = track.route { true } else { false }
            if call { muted += 1 }
            try result.renameTrack(id, to: names[lane.source] ?? lane.name)
            try result.setGain(track.gain, track: id)
            try result.setRole(track.role, tracks: [id])
            try result.setMuted(track.isMuted || call, tracks: [id])
            try result.setFollowTrack(track.isFollowTrack, tracks: [id])
            if let match = track.match { try result.setMatch([id: match]) }
        }
    } catch {
        throw .paste(.session(error))
    }
    let made = result.files.values.filter { session.files[$0.id] == nil }.map(\.path).sorted().map {
        package.appending(path: "\(clipsFolderName)/\($0)")
    }
    return SessionImported(
        session: result, tracks: pasted.tracks, markers: added, leftOutMarkers: leftOut, mutedCallTracks: muted,
        made: made)
}

/// For each file that `excerpt` names: the cancel flag, the download state, then `openChecked`. An
/// open of a file that is not downloaded can block in the kernel, so it comes last.
private func checkFiles(
    _ excerpt: Excerpt, in source: URL, isCancelled: () -> Bool, isDownloaded: (URL) -> Bool
) throws(SessionImportError) {
    let folder = open(source.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard folder >= 0 else { throw .source(.readFailed(errno: errno)) }
    defer { close(folder) }
    for path in excerpt.files.values.map(\.path).sorted() {
        guard !isCancelled() else { throw .paste(.cancelled) }
        let item = "\(clipsFolderName)/\(path)"
        guard isDownloaded(source.appending(path: item)) else { throw .paste(.notDownloaded(file: path)) }
        do { close(try openChecked(item, in: folder).descriptor) } catch {
            switch error {
            case .missing: throw .paste(.sourceMissing(file: path))
            case .notRegularFile: throw .unsafeFile(path)
            case .unreadable(let code): throw .source(.unreadableItem(item, errno: code))
            }
        }
    }
}

/// The name of each new track by source track: the source name, or on a clash with a target track
/// or an earlier new track, "<name> (<source session>)", or "<name> (<n>)" with the smallest free
/// n from 2 when no storable scalar of the session name is left or that name is taken too.
private func trackNames(_ excerpt: Excerpt, source: URL, into session: Session) -> [TrackID: String] {
    let scalars = source.deletingPathExtension().lastPathComponent.unicodeScalars.filter(\.isStorableInSession)
    let suffix = String(String.UnicodeScalarView(scalars))
    var taken = Set(session.tracks.map(\.name))
    var names: [TrackID: String] = [:]
    for lane in excerpt.lanes {
        var name = lane.name
        if taken.contains(name) {
            if !suffix.isEmpty, !taken.contains("\(lane.name) (\(suffix))") {
                name = "\(lane.name) (\(suffix))"
            } else {
                var number = 2
                while taken.contains("\(lane.name) (\(number))") { number += 1 }
                name = "\(lane.name) (\(number))"
            }
        }
        taken.insert(name)
        names[lane.source] = name
    }
    return names
}
