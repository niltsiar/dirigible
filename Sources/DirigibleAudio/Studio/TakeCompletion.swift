import DirigibleCore
import Foundation

/// The result of `openPackage`. The studio stores the lock for its whole life.
struct OpenedPackage: Sendable {
    let lock: PackageLock
    var session: Session
    var takeError: StudioError?
    var segmentsWithAudio: [SegmentName]
    /// The pending take that the recovery finalized.
    var recoveredTake: Recording? = nil
}

/// The result of `completeTake`. On a thrown finalize or save, `session` is the input (it keeps
/// `<recording>`) and `error` is set.
struct TakeOutcome: Sendable {
    var session: Session
    var error: StudioError?
    var segmentsWithAudio: [SegmentName]
}

/// The recovery marker of decision 0004, in the package root.
func marker(in package: URL) -> URL { package.appending(path: "recovery-attempt") }

/// Opens a package off the main actor: the lock, `Session.removeTemporaryFiles`, the read, the
/// marker rules of decision 0004, `completeTake`, and the segments with audio. `@concurrent` keeps
/// it off the caller's actor also with `NonisolatedNonsendingByDefault`.
@concurrent nonisolated func openPackage(_ package: URL) async throws(StudioError) -> OpenedPackage {
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
    func opened(_ session: Session, _ error: StudioError? = nil) -> OpenedPackage {
        OpenedPackage(
            lock: lock, session: session, takeError: error, segmentsWithAudio: segmentsWithAudio(in: package))
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
    let outcome = await completeTake(of: session, in: package)
    return OpenedPackage(
        lock: lock, session: outcome.session, takeError: outcome.error, segmentsWithAudio: outcome.segmentsWithAudio,
        recoveredTake: outcome.error == nil ? session.recording : nil)
}

/// The one step that open, stop, and retry share: finalize, delete the marker, save, and read
/// the segments with audio.
@concurrent nonisolated func completeTake(of session: Session, in package: URL) async -> TakeOutcome {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let finalized: Session
    do {
        finalized = try finalizeTake(of: session, in: package)
    } catch {
        unlink(marker(in: package).path)
        return TakeOutcome(session: session, error: .finalize(error), segmentsWithAudio: segmentsWithAudio(in: package))
    }
    // A crash between this delete and the save looks like a recovery not yet tried, which is safe
    // to run again.
    unlink(marker(in: package).path)
    do {
        try finalized.write(to: package)
    } catch {
        return TakeOutcome(session: session, error: .file(error), segmentsWithAudio: segmentsWithAudio(in: package))
    }
    return TakeOutcome(session: finalized, error: nil, segmentsWithAudio: segmentsWithAudio(in: package))
}
