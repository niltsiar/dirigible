import Foundation
import Testing

@testable import DirigibleApp

/// The Voice clause of decision 0010 for the English message texts: no count after a colon, no
/// uncontracted negation, under 100 characters unless the text lists file names, and at most
/// `sentenceBudget` texts with two sentences or more.
extension LocalizationTests {
    @Test func messageTextsFollowTheVoiceClause() throws {
        let english = try stringsTable("en")
        let keys = english.keys.filter { key in
            voiceAreas.contains { key.hasPrefix($0 + ".") } || voiceKeys.contains(key)
        }
        #expect(keys.count >= 130, "the filter found \(keys.count) message keys")
        let values = english.filter { keys.contains($0.key) }
        #expect(voiceProblems(values, nameLists: voiceNameLists) == [])
        let several = severalSentences(english.filter { key, _ in sentenceAreas.contains { key.hasPrefix($0 + ".") } })
        #expect(several.count <= sentenceBudget, "\(several.count) texts have two sentences or more: \(several)")
    }

    /// An error text has no uncontracted negation and does not open with the app name as the subject.
    @Test func errorTextsUseContractions() throws {
        let values = try stringsTable("en").filter { $0.key.hasPrefix("error.") }
        #expect(values.count >= 110, "the filter found \(values.count) error keys")
        #expect(errorProblems(values) == [])
    }

    @Test func errorCheckerFindsAnUncontractedNegationAndAnAppNameOpener() {
        let tells = [
            "error.a": "Dirigible can't render the clips.", "error.b": "The clip cannot move.",
            "error.c": "Dirigible could not save the take. The disk is not mounted.",
        ]
        #expect(
            errorProblems(tells) == [
                "error.a: the app name as the subject", "error.b: an uncontracted negation",
                "error.c: an uncontracted negation", "error.c: the app name as the subject",
            ])
        let voice = [
            "error.a": "There isn't enough space to render the clips.", "error.b": "The clip can't move.",
            "error.c": "The take couldn't be saved. Dirigible keeps the audio.",
        ]
        #expect(errorProblems(voice) == [])
    }

    @Test func sentenceCounterFindsASecondSentenceAndKeepsOneSentence() {
        let values = [
            "alert.a": "The clip moved. Undo it.", "alert.b": "Replace the file in %@?",
            "alert.c": "Some files exported as silence:\n%@", "alert.d": "Close anyway? The changes weren't saved.",
        ]
        #expect(severalSentences(values) == ["alert.a", "alert.d"])
    }

    @Test func voiceCheckerFindsEachTellAndKeepsTheVoice() {
        let tells = [
            "banner.a": "Auto Level is done. Clips changed: %lld.",
            "banner.b": "The clip cannot move.",
            "banner.c": String(repeating: "word ", count: 20),
            "banner.d": "These files did not move: %@.",
            "banner.e": "Clips: %d",
        ]
        #expect(
            voiceProblems(tells, nameLists: []) == [
                "banner.a: a count after a colon", "banner.b: an uncontracted negation",
                "banner.c: 100 characters or more", "banner.d: a count after a colon",
                "banner.d: an uncontracted negation", "banner.e: a count after a colon",
            ])
        let voice = [
            "banner.a": "Changed 3 clips.", "banner.b": "The clip can't move.",
            "banner.c": "Some audio files are missing or damaged: %@. Connect the disk that has them.",
            "banner.d": String(repeating: "a", count: 120),
        ]
        #expect(voiceProblems(voice, nameLists: ["banner.d"]) == [])
    }

    /// The label of a form row keeps its capitals for the first word and for names only: sentence case.
    @Test func formLabelsUseSentenceCase() throws {
        let english = try stringsTable("en")
        #expect(formLabelKeys.allSatisfy { english[$0] != nil }, "a key of the list is not in the table")
        let values = Dictionary(uniqueKeysWithValues: formLabelKeys.map { ($0, english[$0] ?? "") })
        #expect(caseProblems(values) == [])
    }

    @Test func caseCheckerFindsAnInnerCapitalAndKeepsNames() {
        let values = [
            "a": "Fade In", "b": "Let Agents Edit Open Sessions", "c": "Fade in", "d": "Episode URL",
            "e": "Reference track",
        ]
        #expect(caseProblems(values) == ["a: In", "b: Agents Edit Open Sessions"])
    }

    /// A help line of Settings and the Sync note give one fact in one sentence, with no colon and no
    /// word that a track name can hold.
    @Test func settingsHelpAndSyncNotesHoldOneFact() throws {
        let english = try stringsTable("en")
        #expect(noteKeys.allSatisfy { english[$0] != nil }, "a key of the list is not in the table")
        let values = Dictionary(uniqueKeysWithValues: noteKeys.map { ($0, english[$0] ?? "") })
        #expect(noteProblems(values) == [])
    }

    @Test func noteCheckerFindsEachTellAndKeepsOneSentence() {
        let tells = [
            "a": "Off. Agents can edit only closed sessions.", "b": "No call track: the first track is chosen.",
        ]
        #expect(noteProblems(tells) == ["a: a second sentence", "b: a colon", "b: the word call"])
        #expect(noteProblems(["c": "Paste it in Terminal, then start the agent."]) == [])
    }
}

/// The key prefixes that the guard reads, and the single keys that join them.
private let sentenceAreas = ["banner", "alert", "consent", "notice", "empty", "start", "reverted", "window"]
private let voiceAreas = ["announce"] + sentenceAreas
private let voiceKeys: Set = ["media.missing", "inspector.clips"]

/// The most message texts of `sentenceAreas` with two sentences or more.
private let sentenceBudget = 10

/// The keys of `values` that have a second sentence, sorted.
private func severalSentences(_ values: [String: String]) -> [String] {
    values.filter { $0.value.firstMatch(of: /[.?!][ ]/) != nil }.keys.sorted()
}

/// The label of each form row: the Clip form, Settings, and the sheets. A button, a menu item, a tab,
/// and a sheet title keep title case, so none is here.
private let formLabelKeys = [
    "inspector.gain", "inspector.fade.in", "inspector.fade.out", "inspector.gain.playhead",
    "settings.language", "settings.pre.roll", "settings.waveform.range", "settings.agents",
    "sheet.sync.reference", "sheet.sync.drift", "sheet.duck.speech", "sheet.duck.music", "sheet.duck.depth",
    "sheet.take.time.take", "sheet.take.time.field", "panel.stems.group", "panel.export.format",
    "panel.export.bits", "panel.export.rate", "panel.export.bitrate", "episode.url", "episode.feed.url",
]

/// The help lines of Settings and the note of the Sync sheet.
private let noteKeys = [
    "settings.language.restart", "settings.agents.on", "settings.agents.off", "settings.agents.elsewhere",
    "settings.agents.failed", "settings.agents.copy.hint", "settings.agents.move.first", "sheet.sync.no.call",
]

/// One line for each value with a capital after its first word, unless the word is a name in capitals
/// (URL): `<key>: <the words>`, sorted by key.
private func caseProblems(_ values: [String: String]) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        let capitals = value.split(separator: " ").dropFirst().filter { word in
            word.first?.isUppercase == true && word.dropFirst().contains { $0.isLowercase }
        }
        if !capitals.isEmpty { problems.append("\(key): " + capitals.joined(separator: " ")) }
    }
    return problems
}

/// One line for each tell of a note: a second sentence, a colon, or the word call.
private func noteProblems(_ values: [String: String]) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        if value.firstMatch(of: /[.!?] +\p{Lu}/) != nil { problems.append("\(key): a second sentence") }
        if value.contains(":") { problems.append("\(key): a colon") }
        if value.lowercased().contains("call") { problems.append("\(key): the word call") }
    }
    return problems
}

/// The keys that list file names, so they may hold 100 characters or more.
private let voiceNameLists: Set = ["media.missing", "banner.export.chapter.dropped"]

/// One line for each tell of a value: `<key>: <tell>`, sorted by key.
private func voiceProblems(_ values: [String: String], nameLists: Set<String>) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        if value.firstMatch(of: /: %(?:lld|d|@)\.?$/) != nil { problems.append("\(key): a count after a colon") }
        if hasUncontractedNegation(value) { problems.append("\(key): an uncontracted negation") }
        if value.count >= 100, !nameLists.contains(key) { problems.append("\(key): 100 characters or more") }
    }
    return problems
}

private func hasUncontractedNegation(_ value: String) -> Bool {
    value.firstMatch(of: /\b(?:cannot|does not|did not|do not|is not|are not|could not)\b/) != nil
}

/// One line for each tell of an error text: `<key>: <tell>`, sorted by key.
private func errorProblems(_ values: [String: String]) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        if hasUncontractedNegation(value) { problems.append("\(key): an uncontracted negation") }
        if value.firstMatch(of: /^Dirigible (?:cannot|can|could|did|does)(?![A-Za-z])/) != nil {
            problems.append("\(key): the app name as the subject")
        }
    }
    return problems
}
