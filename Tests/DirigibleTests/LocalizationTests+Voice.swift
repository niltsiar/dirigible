import Foundation
import Testing

@testable import DirigibleApp

/// The Voice clause of decision 0010 for the English message texts: no count after a colon, no
/// uncontracted negation, and under 100 characters unless the text lists file names.
extension LocalizationTests {
    @Test func messageTextsFollowTheVoiceClause() throws {
        let english = try stringsTable("en")
        let keys = english.keys.filter { key in
            voiceAreas.contains { key.hasPrefix($0 + ".") } || voiceKeys.contains(key)
        }
        #expect(keys.count >= 70, "the filter found \(keys.count) message keys")
        let values = english.filter { keys.contains($0.key) }
        #expect(voiceProblems(values, nameLists: voiceNameLists) == [])
    }

    @Test func voiceCheckerFindsEachTellAndKeepsTheVoice() {
        let tells = [
            "banner.a": "Auto Level is done. Clips changed: %lld.",
            "banner.b": "The clip cannot move.",
            "banner.c": String(repeating: "word ", count: 20),
            "banner.d": "These files did not move: %@.",
        ]
        #expect(
            voiceProblems(tells, nameLists: []) == [
                "banner.a: a count after a colon", "banner.b: an uncontracted negation",
                "banner.c: 100 characters or more", "banner.d: a count after a colon",
                "banner.d: an uncontracted negation",
            ])
        let voice = [
            "banner.a": "Changed 3 clips.", "banner.b": "The clip can't move.",
            "banner.c": "Some audio files are missing or damaged: %@. Connect the disk that has them.",
            "banner.d": String(repeating: "a", count: 120),
        ]
        #expect(voiceProblems(voice, nameLists: ["banner.d"]) == [])
    }
}

/// The key prefixes that the guard reads, and the single keys that join them.
private let voiceAreas = ["banner", "notice", "reverted", "window"]
private let voiceKeys: Set = ["media.missing"]

/// The keys that list file names, so they may hold 100 characters or more.
private let voiceNameLists: Set = ["media.missing", "banner.export.chapter.dropped"]

/// One line for each tell of a value: `<key>: <tell>`, sorted by key.
private func voiceProblems(_ values: [String: String], nameLists: Set<String>) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        if value.firstMatch(of: /: %(?:lld|@)\.?$/) != nil { problems.append("\(key): a count after a colon") }
        if value.firstMatch(of: /\b(?:cannot|does not|did not|do not|is not|are not|could not)\b/) != nil {
            problems.append("\(key): an uncontracted negation")
        }
        if value.count >= 100, !nameLists.contains(key) { problems.append("\(key): 100 characters or more") }
    }
    return problems
}
