import DirigibleCore
import Foundation

extension Studio {
    /// Copies the image at `source` into `Artwork/` and sets it as the episode artwork: a blocking
    /// run, as an import (`blockingRun`), with one undo entry. A throw changes nothing in memory;
    /// a copied file stays as an unused file (decision 0040).
    public func setArtwork(from source: URL) async throws(StudioError) {
        try await setImage(from: source) { session, name throws(SessionError) in
            var episode = session.episode
            episode.artwork = name
            session.setEpisode(episode)
        }
    }

    /// Copies the image at `source` into `Artwork/` and sets it as the image of marker `id`, as
    /// `setArtwork` (run 2026-10-11-chapters-in-file, C8).
    public func setMarkerImage(_ id: MarkerID, from source: URL) async throws(StudioError) {
        guard session.markers[id] != nil else { throw .session(.unknownMarker(id)) }
        try await setImage(from: source) { session, name throws(SessionError) in
            guard var marker = session.markers[id] else { throw .unknownMarker(id) }
            marker.image = name
            try session.setMarker(marker)
        }
    }

    /// The blocking run of an image import: `apply` puts the new name into the session.
    private func setImage(
        from source: URL, apply: @escaping @Sendable (inout Session, ArtworkName) throws(SessionError) -> Void
    ) async throws(StudioError) {
        let name = source.lastPathComponent
        try await blockingRun(
            name: name, kind: .file, cancelled: .audioImport(.cancelled), yielded: .importYielded(file: name)
        ) { session, lock, _ in
            await imageOffMain(source, into: session, lock: lock, apply: apply).map { ($0.0, $0.1, made: []) }
        }
    }
}

/// `importArtwork` on a utility GCD thread, in the package that `lock` holds now, then `apply`.
@concurrent nonisolated private func imageOffMain(
    _ source: URL, into session: Session, lock: PackageLock,
    apply: @escaping @Sendable (inout Session, ArtworkName) throws(SessionError) -> Void
) async -> Result<(Session, Void), StudioError> {
    @Sendable func run() -> Result<(Session, Void), StudioError> {
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        let name: ArtworkName
        do throws(ArtworkError) { name = try importArtwork(source, into: package) } catch {
            return .failure(.artwork(error))
        }
        var session = session
        do throws(SessionError) { try apply(&session, name) } catch { return .failure(.session(error)) }
        return .success((session, ()))
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
