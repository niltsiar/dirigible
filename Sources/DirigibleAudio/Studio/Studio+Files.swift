import DirigibleCore
import Foundation

extension Studio {
    /// The URLs of the pool files in `files` that are on disk, sorted by path, under the package
    /// path that the lock holds now (decision 0014), not a stored copy. It reads the disk off the
    /// main actor and writes nothing. An ID that is not in the pool gives nothing.
    public func clipURLs(_ files: Set<FileID>) async -> [URL] {
        await existingClipURLs(files.compactMap { session.files[$0]?.path }, lock: lock)
    }

    /// The clip files that no clip uses (decision 0047), read off the main actor. The clips of
    /// the undo and redo entries, and of `clipboard` when it is of this package, keep their files.
    /// Throws `.busy` while a take, a finalize, a placement, a level, or an import runs, and
    /// `.unusedFiles` when the scan cannot read the package or a backup.
    public func unusedFiles(clipboard: Clipboard? = nil) async throws(StudioError) -> UnusedFiles {
        try checkIdle()
        return try await scanUnusedFiles(session, keptBy: history.entries, keptFiles: keptFiles(clipboard), lock: lock)
            .get()
    }

    /// Moves to the Trash the files of `confirmed` that a new scan in this turn of the write chain
    /// still lists, so an edit after the list keeps a file that it uses (decision 0047). It removes
    /// saves, then removes their pool entries from the session and from each undo and redo entry
    /// with no new entry, and only then moves the files. Throws `.busy` as `unusedFiles`, also for
    /// a take that starts during the scan. A failed save moves no file, changes no session, and
    /// sets `saveError` as a failed autosave does.
    public func removeUnusedFiles(_ confirmed: UnusedFiles, clipboard: Clipboard? = nil) async throws(StudioError)
        -> PruneReport
    {
        try checkIdle()
        let kept = keptFiles(clipboard)
        let result = await serialized { () async -> Result<PruneReport, StudioError> in
            let scan: UnusedFiles
            switch await scanUnusedFiles(session, keptBy: history.entries, keptFiles: kept, lock: lock) {
            case .success(let value): scan = value
            case .failure(let error): return .failure(error)
            }
            // A take can start during the scan (AGENTS.md, Actors).
            guard isIdle else { return .failure(.busy) }
            let items = confirmed.intersection(scan)
            let before = session
            let ids = Set(items.items.compactMap { if case .pool(let id) = $0.kind { id } else { nil } })
            // The pool change comes after the save, so a failed save leaves memory as the disk.
            let apply = { @MainActor () throws(SessionError) in try self.removePoolEntries(ids) }
            switch await pruneFiles(
                items, of: before, lock: lock, previous: url, recordings: recordings, environment.saveSession, apply)
            {
            case .success(let done):
                (url, backups, saveError) = (done.package, done.backups, nil)
                poolChanged(from: before.files)
                return .success(done.report)
            case .failure(let error):
                // The next save or `settle()` writes the session in memory again.
                if case .unusedFiles(.save(let fault)) = error { saveError = .file(fault) }
                return .failure(error)
            }
        }
        let report = try result.get()
        // A pool entry of a missing file is gone, so its fault goes too.
        await checkMedia()
        return report
    }

    /// The pool paths of `clipboard` when it is of this package (decision 0042): a paste can
    /// still use them.
    private func keptFiles(_ clipboard: Clipboard?) -> [String] {
        guard let clipboard, PackageID.same(clipboard.origin, identity) else { return [] }
        return clipboard.excerpt.files.values.map(\.path)
    }
}

@concurrent nonisolated private func existingClipURLs(_ paths: [String], lock: PackageLock) async -> [URL] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return [] }
    let clips = package.appending(path: clipsFolderName)
    return paths.sorted().map { clips.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
}

/// The scan of decision 0047 in the package that `lock` holds now.
@concurrent nonisolated private func scanUnusedFiles(
    _ session: Session, keptBy entries: [Session], keptFiles: [String], lock: PackageLock
) async -> Result<UnusedFiles, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    do throws(SessionFileError) {
        let package = try lock.package()
        do throws(UnusedFilesError) {
            return .success(try UnusedFiles(scanning: session, keptBy: entries, keptFiles: keptFiles, in: package))
        } catch {
            return .failure(.unusedFiles(error))
        }
    } catch {
        return .failure(.file(error))
    }
}

/// The save and the Trash of `UnusedFiles.prune`, off the main actor. After the save and before
/// the first move, `apply` makes the same pool change in memory; its throw moves no file. Returns
/// the report, the package path in `packageIdentity` form, and the backups after the save.
@concurrent nonisolated private func pruneFiles(
    _ items: UnusedFiles, of session: Session, lock: PackageLock, previous: URL, recordings: ActiveRecordings?,
    _ save: @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL,
    _ apply: @MainActor @Sendable () throws(SessionError) -> Void
) async -> Result<(report: PruneReport, package: URL, backups: [Backup]), StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    var pruned = session
    var written = previous
    let report: PruneReport
    do throws(UnusedFilesError) {
        report = try await items.prune(&pruned) { session throws(SessionFileError) in
            written = try await save(session, lock)
            do throws(SessionError) {
                try await apply()
            } catch {
                throw .invalidSession(error)
            }
            return written
        }
    } catch {
        return .failure(.unusedFiles(error))
    }
    let package = packageIdentity(written)
    if package != previous { recordings?.set(package, active: session.recording != nil, previous: previous) }
    return .success((report, package, Backup.all(in: written)))
}
