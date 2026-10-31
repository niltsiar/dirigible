import Foundation
import Testing

@testable import DirigibleAudio

struct WhisperWordsTests {
    /// The tokens of a real run of the base model with VAD on the Spanish C14 fixture (S0 probe):
    /// 100 tokens, 6 of them special, with times in steps of 10 ms.
    struct Fixture: Decodable {
        struct Token: Decodable {
            let bytes: [UInt8]
            let t0: Int
            let t1: Int
            let special: Bool
        }
        let text: String
        let tokens: [Token]

        static func load() throws -> Fixture {
            let url = URL(filePath: #filePath).deletingLastPathComponent()
                .appending(path: "Fixtures/whisper-tokens.json")
            return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        }

        var whisperTokens: [WhisperToken] {
            tokens.map { WhisperToken(bytes: $0.bytes, start: $0.t0, end: $0.t1, isSpecial: $0.special) }
        }
    }

    @Test func tokensWithALeadingSpaceStartAWord() throws {
        let fixture = try Fixture.load()
        let words = WhisperWords.join(fixture.whisperTokens)
        #expect(words.map(\.text) == fixture.text.split(separator: " ").map(String.init))
        #expect(words.first == TimedWord(text: "El", start: 0, end: 12))
        // "7," is the token " 7" and the token ",": the word ends at the end of the comma.
        let seven = try #require(words.first { $0.text == "7," })
        #expect(seven.start == 222 && seven.end == 243)
    }

    @Test func aCharacterSplitOverTwoTokensJoins() {
        let bytes = Array(" mañana".utf8)
        let cut = bytes.firstIndex(of: 0xC3)! + 1
        let tokens = [
            WhisperToken(bytes: Array(bytes[..<cut]), start: 100, end: 120, isSpecial: false),
            WhisperToken(bytes: Array(bytes[cut...]), start: 120, end: 150, isSpecial: false),
            WhisperToken(bytes: Array(" sale".utf8), start: 160, end: 190, isSpecial: false),
        ]
        #expect(
            WhisperWords.join(tokens) == [
                TimedWord(text: "mañana", start: 100, end: 150), TimedWord(text: "sale", start: 160, end: 190),
            ])
    }

    @Test func aWordStartsAtItsFirstLetterToken() {
        let tokens = [
            WhisperToken(bytes: Array("[_BEG_]".utf8), start: 0, end: 0, isSpecial: true),
            WhisperToken(bytes: Array(" \"".utf8), start: 10, end: 20, isSpecial: false),
            WhisperToken(bytes: Array("Hola".utf8), start: 20, end: 40, isSpecial: false),
            WhisperToken(bytes: Array(" -".utf8), start: 50, end: 60, isSpecial: false),
            WhisperToken(bytes: Array("[_TT_50]".utf8), start: 60, end: 60, isSpecial: true),
        ]
        #expect(WhisperWords.join(tokens) == [TimedWord(text: "\"Hola", start: 20, end: 40)])
    }

    /// Gate 1 item 1. A control character or U+FFFF inside a word breaks the word, so each text
    /// passes the session text rule. A greedy run can repeat such a token in each run of a track.
    @Test func aControlCharacterInsideAWordBreaksTheWord() {
        let tokens = [
            WhisperToken(bytes: Array(" Hola\nqué".utf8), start: 10, end: 30, isSpecial: false),
            WhisperToken(bytes: Array("\t".utf8), start: 30, end: 35, isSpecial: false),
            WhisperToken(bytes: Array("tal".utf8), start: 35, end: 50, isSpecial: false),
            WhisperToken(bytes: Array(" sí\u{FFFF}no".utf8), start: 60, end: 80, isSpecial: false),
        ]
        let words = WhisperWords.join(tokens)

        #expect(words.map(\.text) == ["Hola", "qué", "tal", "sí", "no"])
        #expect(words.allSatisfy { $0.text.unicodeScalars.allSatisfy(\.isStorableInSession) })
        #expect(words.first { $0.text == "tal" } == TimedWord(text: "tal", start: 35, end: 50))
    }
}
