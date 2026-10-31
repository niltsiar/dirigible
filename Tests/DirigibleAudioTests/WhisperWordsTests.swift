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
}
