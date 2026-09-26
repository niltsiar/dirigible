import DirigibleCore
import Foundation

/// The result of `openPackage`. The studio stores the lock for its whole life.
struct OpenedPackage: Sendable {
    let lock: PackageLock
    /// The package path in `packageIdentity` form.
    var package: URL
    var session: Session
    var takeError: StudioError?
    var segmentsWithAudio: [SegmentName]
    /// The pending take that the recovery finalized.
    var recoveredTake: Recording? = nil
    /// The pool files that are not whole (decision 0016).
    var missingMedia: [FileID: MediaFault] = [:]
}

/// The result of `completeTake`. On a thrown finalize or save, `session` is the input (it keeps
/// `<recording>`) and `error` is set.
struct TakeOutcome: Sendable {
    var session: Session
    var error: StudioError?
    var segmentsWithAudio: [SegmentName]
    /// The package path that the lock holds (`packageIdentity` form). Nil when the package left
    /// its volume.
    var package: URL?
    /// Nil when the package left its volume: the check cannot read it.
    var missingMedia: [FileID: MediaFault]? = nil
}

/// The recovery marker of decision 0004, in the package root.
func marker(in package: URL) -> URL { package.appending(path: "recovery-attempt") }

/// Opens a package off the main actor: the lock, `Session.removeTemporaryFiles`, the read, the
/// marker rules of decision 0004, `completeTake`, and the segments with audio. `@concurrent` keeps
/// it off the caller's actor also with `NonisolatedNonsendingByDefault`.
@concurrent nonisolated func openPackage(_ package: URL, recordings: ActiveRecordings?) async throws(StudioError)
    -> OpenedPackage
{
    dispatchPrecondition(condition: .notOnQueue(.main))
    let lock: PackageLock
    let session: Session
    do {
        lock = try PackageLock(package)
        Session.removeTemporaryFiles(in: package)
        session = try Session(contentsOf: package)
    } catch .locked {
        throw .locked
    } catch {
        throw .file(error)
    }
    let marker = marker(in: package)
    let identity = packageIdentity(package)
    // The list follows `session.xml`: a stale entry goes, and a pending take keeps its entry.
    func opened(_ session: Session, _ error: StudioError? = nil) -> OpenedPackage {
        recordings?.set(identity, active: session.recording != nil)
        return OpenedPackage(
            lock: lock, package: identity, session: session, takeError: error,
            segmentsWithAudio: segmentsWithAudio(in: package),
            missingMedia: (try? checkMedia(session, package: package)) ?? [:])
    }

    guard session.recording != nil else {
        unlink(marker.path)  // A stale marker of a recovery that ended.
        return opened(session)
    }
    // An earlier recovery died: skip finalize, so a crash in it cannot repeat on every open.
    if FileManager.default.fileExists(atPath: marker.path) { return opened(session) }
    let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else {
        return opened(session, .file(.writeFailed(step: marker.lastPathComponent, errno: errno)))
    }
    close(descriptor)
    let outcome = await completeTake(of: session, lock: lock, recordings: recordings, previous: identity)
    return OpenedPackage(
        lock: lock, package: outcome.package ?? identity, session: outcome.session, takeError: outcome.error,
        segmentsWithAudio: outcome.segmentsWithAudio, recoveredTake: outcome.error == nil ? session.recording : nil,
        missingMedia: outcome.missingMedia ?? [:])
}

/// The one step that open, stop, and retry share, in the package that `lock` holds now (decision
/// 0014): finalize, delete the marker, save, update the list entry, and read the segments with
/// audio. It resolves the package path once, before the finalize. The entry of `previous`, the
/// path before a move, goes. Only a retry that the user chose passes `leavingUnreadable`.
@concurrent nonisolated func completeTake(
    of session: Session, lock: PackageLock, recordings: ActiveRecordings? = nil, previous: URL? = nil,
    leavingUnreadable: Bool = false
) async -> TakeOutcome {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do {
        package = try lock.package()
    } catch {
        return TakeOutcome(session: session, error: .file(error), segmentsWithAudio: [], package: nil)
    }
    func outcome(_ session: Session, _ error: StudioError?) -> TakeOutcome {
        let identity = packageIdentity(package)
        recordings?.set(identity, active: session.recording != nil, previous: previous)
        return TakeOutcome(
            session: session, error: error, segmentsWithAudio: segmentsWithAudio(in: package), package: identity,
            missingMedia: try? checkMedia(session, package: package))
    }
    let finalized: Session
    do {
        finalized = try finalizeTake(of: session, in: package, leavingUnreadable: leavingUnreadable)
    } catch {
        unlink(marker(in: package).path)
        return outcome(session, .finalize(error))
    }
    // A crash between this delete and the save looks like a recovery not yet tried, which is safe
    // to run again.
    unlink(marker(in: package).path)
    do {
        try finalized.write(under: lock)
    } catch {
        return outcome(session, .file(error))
    }
    return outcome(finalized, nil)
}

/// The placement of decision 0021, off the main actor, in the package that `lock` holds now: the
/// disk check, the anchor read, the target, the per-segment finalize, and the save. A throw or a
/// refusal gives the input session and the error; then `session.xml` does not change and no WAV
/// of the segment is new.
@concurrent nonisolated func completePlacement(
    _ name: SegmentName, track: TrackID?, start: Frames?, of session: Session, lock: PackageLock,
    environment: CaptureEnvironment, recordings: ActiveRecordings?, previous: URL
) async -> TakeOutcome {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do {
        package = try lock.package()
    } catch {
        return TakeOutcome(session: session, error: .file(error), segmentsWithAudio: [], package: nil)
    }
    func outcome(_ session: Session, _ error: StudioError?) -> TakeOutcome {
        let identity = packageIdentity(package)
        if identity != previous { recordings?.set(identity, active: session.recording != nil, previous: previous) }
        return TakeOutcome(
            session: session, error: error, segmentsWithAudio: segmentsWithAudio(in: package), package: identity,
            missingMedia: try? checkMedia(session, package: package))
    }
    // The disk rule of a finalize, for one segment.
    let (needed, free) = (wavBytes(of: [name], in: package) + diskMargin, environment.freeBytes(lock))
    guard free >= needed else { return outcome(session, .placementSpace(needed: needed, free: free)) }
    let placed: Session
    do throws(FinalizeError) {
        let anchor = try TakeAnchor.read(take: name.take, in: package)
        guard let target = Target(name, track: track, start: start, anchor: anchor) else {
            return outcome(session, .segment(name, .noAlignment))
        }
        switch try placeSegment(name, to: target, of: session, in: package, readFault: environment.placeRead) {
        case .success(let session): placed = session
        case .failure(let fault): return outcome(session, .segment(name, fault))
        }
    } catch {
        return outcome(session, .finalize(error))
    }
    do {
        try placed.write(under: lock)
    } catch {
        return outcome(session, .file(error))
    }
    return outcome(placed, nil)
}
