import Foundation

/// A session that `newEpisode()` made. Only that call makes one, so each copy applies the rule.
public struct NewEpisode: Hashable, Sendable {
    public let session: Session

    fileprivate init(session: Session) { self.session = session }

    /// The package-relative path of each file that the new package needs, in copy order: each pool
    /// path in `Clips/` (sorted), the episode artwork, and each marker image in `Artwork/`.
    public var filePaths: [String] {
        let clips = Set(session.files.values.map(\.path)).sorted().map { "\(clipsFolderName)/\($0)" }
        var images: [String] = []
        for name in [session.episode.artwork] + session.sortedMarkers.map(\.image) {
            guard let name, !images.contains(name.name) else { continue }
            images.append(name.name)
        }
        return clips + images.map { "\(artworkFolderName)/\($0)" }
    }
}

extension Session {
    /// The session of a new episode from this session: the same tracks, clips, markers, and show
    /// fields. It removes the transcripts, the episode fields of one episode, each file outside
    /// `filesInUse`, and each capture that no kept file names. A pending take throws `.pendingTake`.
    public func newEpisode() throws(SessionError) -> NewEpisode {
        guard recording == nil else { throw .pendingTake }
        var copy = self
        copy.transcripts = [:]
        var episode = self.episode
        episode.title = nil
        episode.number = nil
        episode.date = nil
        episode.summary = nil
        episode.notes = nil
        episode.episodeURL = nil
        episode.guid = nil
        copy.setEpisode(episode)
        try copy.removeFiles(Set(files.keys).subtracting(filesInUse))
        let named = Set(copy.files.values.compactMap(\.capture))
        for capture in copy.captures.keys where !named.contains(capture) { try copy.removeCapture(capture) }
        return NewEpisode(session: copy)
    }
}
