import DirigibleCore
import Foundation

extension Studio {
    /// The URLs of the pool files in `files` that are on disk, sorted by pool path, under the
    /// package path that the lock holds now (decision 0014), not a stored copy: each at the name
    /// that `poolFileName` gives, so the FLAC of an archived file. It reads the disk off the main
    /// actor and writes nothing. An ID that is not in the pool gives nothing.
    public func clipURLs(_ files: Set<FileID>) async -> [URL] {
        await existingClipURLs(files.compactMap { session.files[$0] }, lock: lock)
    }

    /// The clip files that no clip uses (decision 0047), read off the main actor. The clips of
    /// the undo and redo entries, and of `clipboard` when it is of this package, keep their files.
    /// Throws `.busy` while a take, a finalize, a placement, a level, or an import runs,
    /// `.archived` on an archived studio (the scan runs after the unarchive, decision 0072), and
    /// `.unusedFiles` when the scan cannot read the package or a backup.
    public func unusedFiles(clipboard: Clipboard? = nil) async throws(StudioError) -> UnusedFiles {
        try checkIdle()
        return try await scanUnusedFiles(session, keptBy: history.entries, keptFiles: keptFiles(clipboard), lock: lock)
            .get()
    }

    /// Moves to the Trash the files of `confirmed` that a new scan in this turn of the write chain
    /// still lists, so an edit after the list keeps a file that it uses (decision 0047). It saves,
    /// then removes their pool entries from the session and from each undo and redo entry with no
    /// new entry, and only then moves the files. Throws `.busy` and `.archived` as `unusedFiles`
    /// does, `.busy` also for a take that starts during the scan, and while Save as Template copies
    /// the files (decision 0079). A failed save moves no file, changes no session, and sets
    /// `saveError` as a failed autosave does. It reads `clipboard` in its turn.
    public func removeUnusedFiles(_ confirmed: UnusedFiles, clipboard: @autoclosure () -> Clipboard? = nil)
        async throws(StudioError) -> PruneReport
    {
        try checkIdle()
        guard !savesTemplate else { throw .busy }
        let result = await serialized { () async -> Result<PruneReport, StudioError> in
            let scan: UnusedFiles
            let kept = keptFiles(clipboard())
            switch await scanUnusedFiles(session, keptBy: history.entries, keptFiles: kept, lock: lock) {
            case .success(let value): scan = value
            case .failure(let error): return .failure(error)
            }
            // A take or a template save can start during the scan (AGENTS.md, Actors).
            guard isIdle, !savesTemplate else { return .failure(.busy) }
            let before = session
            // The pool change comes after the save, so a failed save leaves memory as the disk.
            let apply = { @MainActor (files: UnusedFiles, saved: Session) throws(SessionError) in
                try self.removePoolEntries(files, saved: (before, saved))
            }
            let done = await pruneFiles(
                confirmed.intersection(scan), of: before, lock: lock, previous: url, recordings: recordings,
                environment.saveSession, apply)
            // Only a write clears a save error: a prune with no item writes nothing.
            if let written = done.written { (url, backups, saveError) = (written.package, written.backups, nil) }
            switch done.result {
            case .success(let report):
                if done.written != nil { savedRevision = sessionRevision }
                poolChanged(from: before.files)
                // A segment whose CAF or, with its CAF gone, whose sidecar went is no take audio, so it
                // is not unplaced.
                let gone = Set(
                    report.moved.compactMap { moved -> SegmentName? in
                        guard case .capture(let capture) = moved.item.kind else { return nil }
                        return SegmentName(stem: capture.rawValue)
                    })
                segmentsWithAudio.removeAll(where: gone.contains)
                return .success(report)
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
    /// still use them. Also the path of each file of the chain of each record, one origin or drift
    /// link at each level, from the pool now, so Restore Original of a pasted clip finds its
    /// sources (decision 0057) and a pasted drift link keeps its source (decision 0077 D2).
    private func keptFiles(_ clipboard: Clipboard?) -> [String] {
        guard let clipboard, PackageID.same(clipboard.origin, identity) else { return [] }
        var paths: [String] = []
        for record in clipboard.excerpt.files.values {
            paths.append(record.path)
            var next = record.linkedSource
            while let id = next, let source = session.files[id] {
                paths.append(source.path)
                next = source.linkedSource
            }
        }
        return paths
    }
}

@concurrent nonisolated private func existingClipURLs(_ files: [AudioFile], lock: PackageLock) async -> [URL] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return [] }
    return files.sorted { $0.path < $1.path }.map { package.appending(path: poolFileName($0, in: package).name) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
}

/// The scan of decision 0047 in the package that `lock` holds now.
@concurrent nonisolated private func scanUnusedFiles(
    _ session: Session, keptBy entries: [Session], keptFiles: [String], lock: PackageLock
) async -> Result<UnusedFiles, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    do throws(SessionFileError) {
        let package = try lock.package()
        do throws(UnusedFilesError) {
            return .success(
                try UnusedFiles(scanningWithCaptures: session, keptBy: entries, keptFiles: keptFiles, in: package))
        } catch {
            return .failure(.unusedFiles(error))
        }
    } catch {
        return .failure(.file(error))
    }
}

/// The save and the Trash of `UnusedFiles.prune`, off the main actor. After the save and before
/// the first move, `apply` makes the same pool change in memory with the items that move and the
/// saved session; its throw moves no file. Returns the report, and when the save ran, the package
/// path in `packageIdentity` form and the backups.
@concurrent nonisolated private func pruneFiles(
    _ items: UnusedFiles, of session: Session, lock: PackageLock, previous: URL, recordings: ActiveRecordings?,
    _ save: @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL,
    _ apply: @MainActor @Sendable (UnusedFiles, Session) throws(SessionError) -> Void
) async -> (result: Result<PruneReport, StudioError>, written: (package: URL, backups: [Backup])?) {
    dispatchPrecondition(condition: .notOnQueue(.main))
    var pruned = session
    var written: URL?
    let result: Result<PruneReport, StudioError>
    do throws(UnusedFilesError) {
        result = .success(
            try await items.prune(&pruned) { session, moving async throws(SessionFileError) in
                let url = try await save(session, lock)
                written = url
                do throws(SessionError) {
                    try await apply(moving, session)
                } catch {
                    throw .invalidSession(error)
                }
                return url
            })
    } catch {
        // After a good save, only `apply` throws: an edit during the save uses a listed file.
        result = .failure(.unusedFiles(written == nil ? error : .changedDuringPrune))
    }
    guard let written else { return (result, nil) }
    let package = packageIdentity(written)
    if package != previous { recordings?.set(package, active: session.recording != nil, previous: previous) }
    return (result, (package, Backup.all(in: written)))
}
