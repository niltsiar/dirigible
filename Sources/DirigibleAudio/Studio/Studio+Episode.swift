import DirigibleCore
import Foundation

extension Studio {
    /// Copies the image at `source` into `Artwork/` and sets it as the episode artwork: a blocking
    /// run, as an import (`blockingRun`), with one undo entry. A throw changes nothing in memory;
    /// a copied file stays as an unused file (decision 0040).
    public func setArtwork(from source: URL) async throws(StudioError) {
        let name = source.lastPathComponent
        _ = try await blockingRun(
            name: name, kind: .file, cancelled: .audioImport(.cancelled), yielded: .importYielded(file: name)
        ) { session, lock, _ in
            await artworkOffMain(source, into: session, lock: lock)
        }
    }
}

/// `importArtwork` on a utility GCD thread, in the package that `lock` holds now.
@concurrent nonisolated private func artworkOffMain(
    _ source: URL, into session: Session, lock: PackageLock
) async -> Result<(Session, Bool), StudioError> {
    @Sendable func run() -> Result<(Session, Bool), StudioError> {
        let package: URL
        do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
        do throws(ArtworkError) {
            var episode = session.episode
            episode.artwork = try importArtwork(source, into: package)
            var session = session
            session.setEpisode(episode)
            return .success((session, true))
        } catch {
            return .failure(.artwork(error))
        }
    }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(returning: run()) }
    }
}
