import Foundation

/// The number of a transcript in a session, from 1 (decision 0055). Only the session gives one.
public struct TranscriptID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let number: Int

    init(_ number: Int) { self.number = number }

    public static func < (a: Self, b: Self) -> Bool { a.number < b.number }
    public var description: String { String(number) }
}

/// One word of a transcript. Its number never changes, so an edit never makes it name another word.
public struct WordID: Hashable, Comparable, Sendable {
    public let transcript: TranscriptID
    public let number: Int

    public static func < (a: Self, b: Self) -> Bool { (a.transcript, a.number) < (b.transcript, b.number) }
}

/// A word under one clip: one place on the timeline. Its text is
/// "<transcript>.<number>.<file start>@<clip id>". `fileStart` is the start of the anchor that
/// `Session.words` showed, so `Session.cutWords` refuses a token from before a replace that gave
/// the number again.
public struct WordOccurrence: Hashable, Sendable, LosslessStringConvertible {
    public let word: WordID
    public let fileStart: Frames
    public let clip: ClipID

    init(word: WordID, fileStart: Frames, clip: ClipID) {
        self.word = word
        self.fileStart = fileStart
        self.clip = clip
    }

    /// Splits at the first two "." and the first "@" after them, so a clip ID can hold both.
    public init?(_ description: String) {
        guard let at = description.firstIndex(of: "@") else { return nil }
        let head = description[..<at].split(separator: ".", omittingEmptySubsequences: false)
        let clip = description[description.index(after: at)...]
        guard head.count == 3, let transcript = Int(head[0]), let number = Int(head[1]), let start = Int(head[2]),
            transcript >= 1, number >= 1, Frames(start).isInRange, !clip.isEmpty
        else { return nil }
        self.init(
            word: WordID(transcript: TranscriptID(transcript), number: number), fileStart: Frames(start),
            clip: ClipID(String(clip)))
    }

    public var description: String { "\(word.transcript).\(word.number).\(fileStart)@\(clip)" }
}

/// One row of `Session.words`.
public struct SpokenWord: Hashable, Sendable {
    public let occurrence: WordOccurrence
    public let track: TrackID
    public let text: String
    /// The timeline range, clamped to the clip.
    public let range: Range<Frames>
}

/// A word in the frames of one audio file.
struct Anchor: Hashable, Sendable {
    let number: Int
    let range: Range<Frames>
    let text: String

    /// The frame that picks the clip of the word (decision 0055).
    var midpoint: Frames { Frames((range.lowerBound.count + range.upperBound.count) / 2) }
}

/// The anchors of one file, by midpoint, then number. The only init sorts, so each edit keeps the
/// order that the writer and the read-back of `checkedData` rely on.
struct Anchors: Hashable, Sendable {
    let all: [Anchor]

    init(_ anchors: [Anchor]) {
        all = anchors.sorted { ($0.midpoint, $0.number) < ($1.midpoint, $1.number) }
    }

    /// The anchors whose midpoint is in `range`.
    func anchors(midpointIn range: Range<Frames>) -> ArraySlice<Anchor> {
        func first(_ frame: Frames) -> Int {
            var (low, high) = (0, all.count)
            while low < high {
                let middle = (low + high) / 2
                if all[middle].midpoint < frame { low = middle + 1 } else { high = middle }
            }
            return low
        }
        return all[first(range.lowerBound)..<first(range.upperBound)]
    }
}

/// An imported transcript: its anchors by file (decision 0055).
struct Transcript: Hashable, Sendable {
    let id: TranscriptID
    var name: String
    var words: [FileID: Anchors]
}
