import DirigibleCore
import Foundation

extension Studio {
    /// The clipboard of a Copy or a Cut in this studio: the excerpt, the package path, and the
    /// identity of the package (decision 0042). It holds no studio and no lock.
    public func clipboard(of excerpt: Excerpt) -> Clipboard {
        Clipboard(excerpt, package: url, origin: lock.identity)
    }

    /// The identity of the package of this studio (decision 0042), read once at the open.
    public var identity: PackageID? { lock.identity }

    /// The paste of a clipboard of this package (decision 0042): one `edit` on the main actor, as a
    /// paste of today, with no file I/O. Nil, and no change, for a clipboard of another package:
    /// then the caller runs `pasteAcross`. It owns the origin compare of the app,
    /// `PackageID.same(clipboard.origin, identity)`, on stored values.
    public func pasteInPlace(_ clipboard: Clipboard, at start: Frames, on target: PasteTarget, insert: Bool = false)
        throws(StudioError) -> (clips: [ClipID], tracks: [TrackID])?
    {
        let identity = lock.identity
        guard PackageID.same(clipboard.origin, identity) else { return nil }
        var failure: PasteError?
        let pasted = try edit { session throws(SessionError) in
            do throws(PasteError) {
                let pasted = try pasteClipboard(
                    clipboard, from: clipboard.package, into: session, in: clipboard.package, identity: identity,
                    at: start, on: target, insert: insert, freeBytes: { 0 })
                session = pasted.session
                return (pasted.clips, pasted.tracks)
            } catch {
                // The same package copies no file, so the session refuses; another fault changes
                // nothing and goes to the alert.
                guard case .session(let refusal) = error else {
                    failure = error
                    return ([], [])
                }
                throw refusal
            }
        }
        if let failure { throw .paste(failure, source: clipboard.package.deletingPathExtension().lastPathComponent) }
        return pasted
    }

    /// The paste of a clipboard that `pasteInPlace` refused (another package): a blocking run, as an
    /// import (`blockingRun`). The source path is `lock.package()` of `source`, the open studio of
    /// the source package, read here so the run holds no source lock; else the path at the copy.
    /// Then `pasteClipboard` copies or converts the files off the main actor, and the run saves and
    /// records one undo entry. `insert` runs a ripple insert of the excerpt length on all tracks
    /// first. Returns the pasted IDs and the target tracks. A throw changes nothing in memory; a
    /// renamed WAV stays as an unused file (0040).
    public func pasteAcross(
        _ clipboard: Clipboard, from source: Studio?, at start: Frames, on target: PasteTarget, insert: Bool = false,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> (clips: [ClipID], tracks: [TrackID]) {
        let name = clipboard.package.deletingPathExtension().lastPathComponent
        let path: URL
        do throws(SessionFileError) {
            path = try source?.lock.package() ?? clipboard.package
        } catch {
            throw .paste(.sourceMissing(file: clipboard.package.lastPathComponent), source: name)
        }
        let environment = environment
        return try await blockingRun(
            name: name, kind: .paste, cancelled: .paste(.cancelled, source: name), yielded: .pasteYielded(source: name)
        ) { session, lock, flags in
            await pasteOffMain(
                clipboard, from: path, into: session, lock: lock, at: start, on: target, insert: insert,
                environment: environment, flags: flags, name: name,
                progress: { fraction in Task { @MainActor in progress(fraction) } })
        }
    }
}

/// `pasteClipboard` on a utility GCD thread, in the package that `lock` holds now, as
/// `convertImport` runs an import.
@concurrent nonisolated private func pasteOffMain(
    _ clipboard: Clipboard, from source: URL, into session: Session, lock: PackageLock, at start: Frames,
    on target: PasteTarget, insert: Bool, environment: CaptureEnvironment, flags: ImportFlags, name: String,
    progress: @escaping @Sendable (Double) -> Void
) async -> Result<(Session, (clips: [ClipID], tracks: [TrackID])), StudioError> {
    @Sendable func run() -> Result<(Session, (clips: [ClipID], tracks: [TrackID])), StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(PasteError) {
            let pasted = try pasteClipboard(
                clipboard, from: source, into: session, in: package, identity: lock.identity, at: start, on: target,
                insert: insert, freeBytes: { environment.freeBytes(lock) }, progress: progress,
                isCancelled: {
                    environment.importStep()
                    return flags.isCancelled
                })
            return .success((pasted.session, (pasted.clips, pasted.tracks)))
        } catch {
            if case .session(let refusal) = error { return .failure(.session(refusal)) }
            return .failure(.paste(error, source: name))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
