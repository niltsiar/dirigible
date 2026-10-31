import Foundation

/// The words of one transcription in the frames of their audio files, in the order of the
/// concatenated file spans of the job (decision 0065 D4). The list position gives the number, so
/// a word has no number field.
public struct FileWords: Hashable, Sendable {
    /// One word: its file, its file frame range, and its text.
    public struct Word: Hashable, Sendable {
        public let file: FileID
        public let range: Range<Frames>
        public let text: String

        /// Nil for an empty range: a word of no frame drops out of a cut (decision 0055).
        public init?(file: FileID, range: Range<Frames>, text: String) {
            guard !range.isEmpty else { return nil }
            self.file = file
            self.range = range
            self.text = text
        }
    }

    public let words: [Word]

    public init(_ words: [Word]) { self.words = words }
}

extension Session {
    /// Adds the transcript `name` of `words` (decision 0065 D4). Word n of the list gets number n.
    /// A word of a file that is not in the pool is skipped and uses up its number. A word of a
    /// rendered file goes to the root of its chain, in root frames (decision 0057 D11). Each entry
    /// of `derived` whose derived file is in the pool and has no origin, in list order, gives that
    /// file the new words of `span` of the source with the numbers of their source words, as
    /// `addDerivedFile` copies words. Then, as for an import (decision 0055), each transcript that
    /// did not load goes, and for each file of the new words, the old words of the other
    /// transcripts whose midpoint is in the span of the new words go. No kept word changes nothing
    /// and gives no ID. A word that breaks a rule of the import (`checkWords`) throws and changes
    /// nothing.
    @discardableResult
    public mutating func addTranscript(
        _ words: FileWords, name: String, derived: [(source: FileID, derived: FileID, span: Range<Frames>)]
    ) throws(SessionError) -> (id: TranscriptID?, kept: Int, skipped: Int, dropped: [String]) {
        try Self.checkText(name)
        var added: [FileID: [Anchor]] = [:]
        var skipped = 0
        for (index, word) in words.words.enumerated() {
            guard files[word.file] != nil else {
                skipped += 1
                continue
            }
            let root = self.root(of: word.file)
            let range = (word.range.lowerBound + root.offset)..<(word.range.upperBound + root.offset)
            added[root.file, default: []].append(Anchor(number: index + 1, range: range, text: word.text))
        }
        guard !added.isEmpty else { return (nil, 0, skipped, []) }
        try checkWords(added.mapValues(Anchors.init))
        let (id, dropped) = try storeTranscript(added, name: name, derived: derived)
        return (id, words.words.count - skipped, skipped, dropped)
    }
}
