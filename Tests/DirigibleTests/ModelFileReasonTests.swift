import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Code gate 2 item 7 (decision 0010): the reason of a model file refusal comes from the language
/// tables, in each language. The CLI and the tools keep the English `ModelFileRefusal.message`.
struct ModelFileReasonTests {
    /// Each refusal with the key of its reason and the arguments of that key.
    static var reasons: [(ModelFileRefusal, key: String, arguments: [any CVarArg])] {
        [
            (.file(.notWhisperModel), "error.transcribe.file.reason.notwhisper", []),
            (.file(.unsupported("n_vocab 10")), "error.transcribe.file.reason.unsupported", ["n_vocab 10"]),
            (.file(.truncated), "error.transcribe.file.reason.truncated", []),
            (
                .file(.damaged("NaN or infinite value in decoder.positional_embedding")),
                "error.transcribe.file.reason.damaged", ["NaN or infinite value in decoder.positional_embedding"]
            ),
            (.file(.unreadable(errno: 5)), "error.transcribe.file.unreadable", [5]),
            (.modelLoad, "error.transcribe.file.reason.load", []),
            (.engine(code: -3), "error.transcribe.file.reason.engine", [-3]),
            (.trialFailed, "error.transcribe.file.reason.trial", []),
        ]
    }

    @Test(arguments: AppLanguage.allCases.map { $0.rawValue })
    func eachReasonOfARefusalComesFromTheTable(language: String) throws {
        let table = try stringsTable(language)
        let text: (L10n) -> String = { table[$0.rawValue] ?? "<\($0.rawValue)>" }
        let prefix = try #require(table["error.transcribe.file.refused"])
        for (reason, key, arguments) in Self.reasons {
            let reasonText = String(format: try #require(table[key], "\(language) has no \(key)"), arguments: arguments)

            let message = L10n.message(for: ModelFileCheckError.refused(reason), text: text)

            #expect(message == String(format: prefix, reasonText), "\(language) \(key): \(message)")
            if language != "en" { #expect(!message.contains(reason.message), "\(language) shows English: \(message)") }
        }
    }

    /// A refusal that the helper gave with no code keeps the line of the helper.
    @Test func aRefusalWithNoCodeShowsTheLineOfTheHelper() {
        let message = L10n.message(
            for: ModelFileCheckError.refused(.unknown("It broke.")), text: { "<\($0.rawValue): %@>" })
        #expect(message == "<error.transcribe.file.refused: It broke.>")
    }
}
