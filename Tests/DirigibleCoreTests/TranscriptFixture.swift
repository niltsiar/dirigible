import Foundation

@testable import DirigibleCore

/// A 48 kHz session with the mono tracks "host" and "guest" and the files "h" and "g" of 1 000 000
/// frames each, and no clip.
func transcriptSession() throws -> Session {
    var session = Session(sampleRate: 48_000)
    for (track, file) in [("host", "h"), ("guest", "g")] {
        try session.addTrack(TrackID(track), name: track, layout: .mono)
        try session.addFile(AudioFile(id: FileID(file), path: "\(file).wav", layout: .mono, length: 1_000_000))
    }
    return session
}

extension Session {
    /// Adds the anchors `words` (number, file frames, text) in `file` to transcript `transcript`,
    /// with no check: the store as an import leaves it.
    mutating func addWords(_ words: [(Int, Range<Frames>, String)], file: FileID, transcript: Int = 1) {
        let id = TranscriptID(transcript)
        var stored = transcripts[id] ?? Transcript(id: id, name: "t\(transcript)", words: [:])
        let added = words.map { Anchor(number: $0.0, range: $0.1, text: $0.2) }
        var all = stored.words ?? [:]
        all[file] = Anchors((all[file]?.all ?? []) + added)
        stored.words = all
        transcripts[id] = stored
    }

    /// The word numbers under `clip`, in timeline order.
    func numbers(under clip: ClipID) -> [Int] {
        words().filter { $0.occurrence.clip == clip }.map(\.occurrence.word.number)
    }

    /// The shown occurrences of the word numbers `numbers` of transcript `transcript` on `track`.
    func occurrences(_ numbers: [Int], on track: TrackID = "host", transcript: Int = 1) -> [WordOccurrence] {
        words(on: [track]).map(\.occurrence).filter {
            $0.word.transcript.number == transcript && numbers.contains($0.word.number)
        }
    }
}
