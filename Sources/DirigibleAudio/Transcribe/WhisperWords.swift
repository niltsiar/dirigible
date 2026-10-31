import Foundation

/// Joins whisper.cpp tokens into words (decision 0065, D7): whisper.cpp has no word API.
enum WhisperWords {
    /// A token that starts with a space starts a new word, and a special token drops. A word starts
    /// at its first token with a letter or a digit and ends at the end of its last token, so a
    /// leading quote does not move the start and a trailing comma moves the end. A word with no
    /// letter or digit drops. The bytes of a word decode as one string, so a character split over
    /// two tokens joins. A scalar that `isStorableInSession` refuses is a word break: a control
    /// byte breaks inside its token, and the part after it starts at the token start; U+FFFE and
    /// U+FFFF can span two tokens, so they break the decoded word, and each part keeps its times.
    static func join(_ tokens: [WhisperToken]) -> [TimedWord] {
        var words: [TimedWord] = []
        var bytes: [UInt8] = []
        var start: Int?
        var end = 0
        func flush() {
            if let start {
                let text = String(decoding: bytes, as: UTF8.self)
                for part in text.unicodeScalars.split(whereSeparator: { !$0.isStorableInSession }) {
                    let word = String(String.UnicodeScalarView(part)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if hasLetterOrDigit(word) { words.append(TimedWord(text: word, start: start, end: end)) }
                }
            }
            bytes = []
            start = nil
        }
        for token in tokens where !token.isSpecial {
            // UTF-8 never uses a byte under 0x20 inside a longer sequence.
            let parts = token.bytes.split(omittingEmptySubsequences: false) { $0 < 0x20 }
            for (index, part) in parts.enumerated() {
                if index > 0 { flush() }
                guard !part.isEmpty else { continue }
                if part.first == 0x20 && bytes.contains(where: { $0 != 0x20 }) { flush() }
                bytes += part
                if start == nil && hasLetterOrDigit(String(decoding: part, as: UTF8.self)) { start = token.start }
                if start != nil { end = token.end }
            }
        }
        flush()
        return words
    }

    /// An incomplete UTF-8 sequence decodes as U+FFFD, which is neither.
    private static func hasLetterOrDigit(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }
    }
}
