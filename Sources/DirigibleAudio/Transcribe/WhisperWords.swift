import Foundation

/// Joins whisper.cpp tokens into words (decision 0065, D7): whisper.cpp has no word API.
enum WhisperWords {
    /// A token that starts with a space starts a new word, and a special token drops. A word starts
    /// at its first token with a letter or a digit and ends at the end of its last token, so a
    /// leading quote does not move the start and a trailing comma moves the end. A word with no
    /// letter or digit drops. The bytes of a word decode as one string, so a character split over
    /// two tokens joins.
    static func join(_ tokens: [WhisperToken]) -> [TimedWord] {
        var words: [TimedWord] = []
        var bytes: [UInt8] = []
        var start: Int?
        var end = 0
        func flush() {
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let start { words.append(TimedWord(text: text, start: start, end: end)) }
            bytes = []
            start = nil
        }
        for token in tokens where !token.isSpecial {
            if token.bytes.first == 0x20 && bytes.contains(where: { $0 != 0x20 }) { flush() }
            bytes += token.bytes
            if start == nil && hasLetterOrDigit(token.bytes) { start = token.start }
            if start != nil { end = token.end }
        }
        flush()
        return words
    }

    /// An incomplete UTF-8 sequence decodes as U+FFFD, which is neither.
    private static func hasLetterOrDigit(_ bytes: [UInt8]) -> Bool {
        String(decoding: bytes, as: UTF8.self).unicodeScalars.contains {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }
    }
}
