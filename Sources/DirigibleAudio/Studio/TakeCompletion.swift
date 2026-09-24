import DirigibleCore
import Foundation

/// The result of `openPackage`. The studio stores the lock for its whole life.
struct OpenedPackage: Sendable {
    let lock: PackageLock
    var session: Session
    var takeError: StudioError?
    var unplaced: [String]
}

/// The result of `completeTake`. On a thrown finalize or save, `session` is the input (it keeps
/// `<recording>`) and `error` is set.
struct TakeOutcome: Sendable {
    var session: Session
    var error: StudioError?
    var unplaced: [String]
}

/// The recovery marker of decision 0004, in the package root.
private func marker(in package: URL) -> URL { package.appending(path: "recovery-attempt") }

/// Opens a package off the main actor: the lock, `Session.removeTemporaryFiles`, the read, the
/// marker rules of decision 0004, `completeTake`, and the unplaced segments. `@concurrent` keeps
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
            lock: lock, session: session, takeError: error, unplaced: unplacedSegments(in: package, session: session))
    }

    guard session.recording != nil else {
        unlink(marker.path)  // A stale marker of a recovery that ended.
        return opened(session)
    }
    // An earlier recovery died: skip finalize, so a crash in it cannot repeat on every open.
    if FileManager.default.fileExists(atPath: marker.path) { return opened(session) }
    let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return opened(session, .file(.writeFailed(step: "recovery-attempt", errno: errno))) }
    close(descriptor)
    let outcome = await completeTake(of: session, in: package)
    return OpenedPackage(lock: lock, session: outcome.session, takeError: outcome.error, unplaced: outcome.unplaced)
}

/// The one step that open, stop, and retry share: finalize, delete the marker, save, and derive
/// the unplaced segments.
@concurrent nonisolated func completeTake(of session: Session, in package: URL) async -> TakeOutcome {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let finalized: Session
    do {
        finalized = try finalizeTake(of: session, in: package)
    } catch {
        unlink(marker(in: package).path)
        return TakeOutcome(
            session: session, error: .finalize(error), unplaced: unplacedSegments(in: package, session: session))
    }
    // A crash between this delete and the save looks like a recovery not yet tried, which is safe
    // to run again.
    unlink(marker(in: package).path)
    do {
        try finalized.write(to: package)
    } catch {
        return TakeOutcome(
            session: session, error: .file(error), unplaced: unplacedSegments(in: package, session: session))
    }
    return TakeOutcome(session: finalized, error: nil, unplaced: unplacedSegments(in: package, session: finalized))
}
