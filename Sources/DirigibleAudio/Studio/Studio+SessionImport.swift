import DirigibleCore
import Foundation

extension Studio {
    /// Imports the tracks of the package at `source` with `importSession` (decision 0075), saves
    /// `session.xml`, and records one undo entry named `.importSession`, with `agent` for an MCP
    /// call. The run is a `blockingRun` of kind `.session` named for the source session, so the
    /// banner shows "Importing <name>" with Cancel. It throws `.busy` during a pending take and
    /// during `settle()`. A cancel of the calling task, the banner Cancel, or `settle()` throws
    /// `.sessionImport(.paste(.cancelled), source:)`, and a take in another studio throws
    /// `.sessionImportYielded(source:)`; then the new WAVs go (decision 0049). Another refusal
    /// throws `.sessionImport(_, source:)` and changes nothing.
    public func importSession(
        _ source: URL, at: Int = 0, markers: Bool, agent: AgentName? = nil,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws(StudioError) -> SessionImported {
        let name = source.deletingPathExtension().lastPathComponent
        let environment = environment
        return try await blockingRun(
            name: name, kind: .session, cancelled: .sessionImport(.paste(.cancelled), source: name),
            yielded: .sessionImportYielded(source: name), ripple: false, agent: agent
        ) { session, lock, flags in
            await importSessionOffMain(
                source, into: session, lock: lock, at: at, markers: markers, environment: environment, flags: flags,
                name: name,
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        self?.importProgressed(flags, fraction)
                        progress(fraction)
                    }
                })
        }
    }
}

/// `importSession` on a utility GCD thread, in the package that `lock` holds now, as
/// `convertImport` runs an import.
@concurrent nonisolated private func importSessionOffMain(
    _ source: URL, into session: Session, lock: PackageLock, at: Int, markers: Bool,
    environment: CaptureEnvironment, flags: ImportFlags, name: String,
    progress: @escaping @Sendable (Double) -> Void
) async -> Result<(Session, SessionImported, made: [URL]), StudioError> {
    @Sendable func run() -> Result<(Session, SessionImported, made: [URL]), StudioError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(SessionImportError) {
            let imported = try importSession(
                from: source, into: session, in: package, identity: lock.identity, at: at, markers: markers,
                freeBytes: { environment.freeBytes(lock) }, progress: progress,
                isCancelled: {
                    environment.importStep()
                    return flags.isCancelled
                })
            return .success((imported.session, imported, made: imported.made))
        } catch {
            return .failure(.sessionImport(error, source: name))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
