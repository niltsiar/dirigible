import Foundation

extension Session {
    /// Gives each track of `matches` its match, and replaces an old one. An unknown track throws and
    /// changes nothing.
    public mutating func setMatch(_ matches: [TrackID: VoiceMatch]) throws(SessionError) {
        let indices = try matches.map { id, match throws(SessionError) in (try trackIndex(id), match) }
        for (index, match) in indices { tracks[index].match = match }
    }

    /// Sets the amount of the match of each track. A track with no match throws `noMatch` and
    /// changes nothing.
    public mutating func setMatchAmount(_ amount: VoiceMatch.Amount, tracks ids: [TrackID]) throws(SessionError) {
        for (index, match) in try matches(of: ids) { tracks[index].match = match.with(amount: amount) }
    }

    /// Turns the bypass of the match of each track on or off. A track with no match throws `noMatch`
    /// and changes nothing.
    public mutating func setMatchBypassed(_ on: Bool, tracks ids: [TrackID]) throws(SessionError) {
        for (index, match) in try matches(of: ids) { tracks[index].match = match.with(isBypassed: on) }
    }

    /// Removes the match of each track. A track with no match stays as it is. An unknown track
    /// throws and changes nothing.
    public mutating func removeMatch(tracks ids: [TrackID]) throws(SessionError) {
        for index in try ids.map(trackIndex) { tracks[index].match = nil }
    }

    /// The name of a clip: the path of its file without ".wav", else the file ID. The clip label of
    /// the lanes and the reference name of a match.
    public func name(of clip: Clip) -> String {
        let path = files[clip.file]?.path ?? clip.file.rawValue
        return path.hasSuffix(".wav") ? String(path.dropLast(4)) : path
    }

    private func matches(of ids: [TrackID]) throws(SessionError) -> [(Int, VoiceMatch)] {
        try ids.map { id throws(SessionError) in
            let index = try trackIndex(id)
            guard let match = tracks[index].match else { throw .noMatch(id) }
            return (index, match)
        }
    }
}
