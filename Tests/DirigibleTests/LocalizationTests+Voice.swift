import Foundation
import Testing

@testable import DirigibleApp

/// The Voice clause of decision 0010 for the English message texts: no count after a colon, no
/// uncontracted negation, under 100 characters unless the text lists file names, at most
/// `sentenceBudget` texts with two sentences or more, and in each message no join of two facts and
/// at most `sentenceLimit` sentences.
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

    /// ui-audit A5: no text joins two parts with a hyphen between spaces.
    @Test func noTextHasASpacedHyphen() throws {
        for language in AppLanguage.allCases.map(\.rawValue) {
            let found = try stringsTable(language).filter { $0.value.contains(" - ") }.keys.sorted()
            #expect(found == [], "\(language) has a spaced hyphen")
        }
    }

    /// A banner, an alert, and an error have one fact in each sentence and at most two sentences.
    @Test func messageTextsHoldOneFactInEachSentence() throws {
        let values = try stringsTable("en").filter { isMessageKey($0.key) }
        #expect(values.count >= 350, "the filter found \(values.count) message keys")
        #expect(oneFactKeys.allSatisfy { values[$0] != nil }, "a key of oneFactKeys is not in the table")
        #expect(factProblems(values) == [])
    }

    @Test func factCheckerFindsAJoinAndALongMessageAndKeepsAList() {
        let tells = [
            "error.a": "The disk is full, and the export stopped.", "error.b": "The file moved, which stopped it.",
            "error.c": "The clip is empty, so nothing moved.", "error.d": "The disk is full. Free space. Try again.",
            "error.e": "It is full. The file moved, and the export stopped. Try again.",
        ]
        #expect(
            factProblems(tells) == [
                "error.a: two facts in one sentence", "error.b: two facts in one sentence",
                "error.c: two facts in one sentence", "error.d: 3 sentences",
                "error.e: 3 sentences", "error.e: two facts in one sentence",
            ])
        let voice = [
            "error.a": "The session holds tracks, clips, and markers.", "error.b": "The disk is full. Free some space.",
            "error.c": "Some files exported as silence:\n%@", "error.d": "Close anyway? The changes aren't saved.",
        ]
        #expect(factProblems(voice) == [])
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
            "error.c": "The take couldn't be saved. The audio stays on the disk.",
        ]
        #expect(errorProblems(voice) == [])
    }

    /// Every English text, not only the message and error texts, has no uncontracted negation, no count
    /// after a colon, no "because", and no app name as the subject of a verb. A fact after a colon is for
    /// a label and its value, and `labelColonKeys` lists those keys.
    @Test func everyTextUsesContractionsAndNoCountAfterAColon() throws {
        let english = try stringsTable("en")
        #expect(english.count >= 1000, "the table has \(english.count) values")
        #expect(textProblems(english, labelKeys: labelColonKeys) == [])
        #expect(labelColonKeys.count <= 5, "\(labelColonKeys.count) keys may have a fact after a colon")
        let stale = labelColonKeys.filter { !hasFactAfterColon(english[$0] ?? "") }
        #expect(stale.isEmpty, "keys with no fact after a colon: \(stale.sorted())")
        let staleSubjects = appNameSubjectKeys.filter { !startsWithAppName(english[$0] ?? "") }
        #expect(staleSubjects.isEmpty, "keys with no app name as the subject: \(staleSubjects.sorted())")
    }

    @Test func textCheckerFindsEachTellAndKeepsTheVoice() {
        let tells = [
            "a": "Words selected: %lld", "b": "Option-click: all tracks.", "c": "Stopped because the disk is full.",
            "d": "Dirigible sends nothing.", "e": "The file is not saved.",
            "f": "The clip didn't move. Dirigible doesn't delete it.", "g": "Did not start",
            "h": "Take sync: Cannot read %@",
        ]
        #expect(
            textProblems(tells, labelKeys: []) == [
                "a: a count after a colon", "a: a fact after a colon", "b: a fact after a colon", "c: because",
                "d: the app name as the subject", "e: an uncontracted negation", "f: the app name as the subject",
                "g: an uncontracted negation", "h: an uncontracted negation",
            ])
        let voice = [
            "a": "%lld words selected", "b": "Option-click to apply to all tracks.", "c": "Files: %lld (%@)",
            "d": "The report goes nowhere on its own.",
            "report.saved": "Report saved. Dirigible shows the file in Finder.",
        ]
        #expect(textProblems(voice, labelKeys: ["c"]) == [])
    }

    @Test func sentenceCounterFindsASecondSentenceAndKeepsOneSentence() {
        let values = [
            "alert.a": "The clip moved. Undo it.", "alert.b": "Replace the file in %@?",
            "alert.c": "Some files exported as silence:\n%@", "alert.d": "Close anyway? The changes weren't saved.",
            "alert.e": "%lld files become FLAC; an edit converts them back.",
        ]
        #expect(severalSentences(values) == ["alert.a", "alert.d", "alert.e"])
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

/// The key prefixes that the guard reads, and the single keys that join them. An error text is an
/// alert, so `messageAreas` has `error`; `oneFactKeys` are other texts that a banner or an alert shows.
private let sentenceAreas = ["banner", "alert", "consent", "notice", "empty", "start", "reverted", "window"]
private let messageAreas = sentenceAreas + ["error"]
private let voiceAreas = ["announce"] + messageAreas
private let oneFactKeys: Set = [
    "transport.stop.output.changed", "transport.stop.package.unavailable", "transport.stop.no.descriptor",
    "sheet.duck.note", "sheet.repair.declip.note", "take.late.start", "take.pending.leave.hint",
    "sheet.transcribe.check.take",
]
private let voiceKeys = Set(["media.missing", "inspector.clips"]).union(oneFactKeys)

private func isMessageKey(_ key: String) -> Bool {
    messageAreas.contains { key.hasPrefix($0 + ".") } || oneFactKeys.contains(key)
}

/// The most message texts of `sentenceAreas` with two sentences or more.
private let sentenceBudget = 26

/// A message has at most this many sentences: the fact, and the next step.
private let sentenceLimit = 2

/// One line for each tell of a message: `<key>: <tell>`, sorted by key. A ", and" with an earlier
/// comma in its sentence closes a list ("A, B, and C") and joins no facts.
private func factProblems(_ values: [String: String]) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        let sentences = value.split(separator: /[.?!;][ ]/, omittingEmptySubsequences: true)
        if sentences.count > sentenceLimit { problems.append("\(key): \(sentences.count) sentences") }
        if sentences.contains(where: joinsTwoFacts) { problems.append("\(key): two facts in one sentence") }
    }
    return problems
}

private func joinsTwoFacts(_ sentence: Substring) -> Bool {
    if sentence.contains(", which") || sentence.contains(", so ") { return true }
    guard let join = sentence.firstRange(of: ", and ") else { return false }
    return !sentence[..<join.lowerBound].contains(",")
}

/// The keys of `values` that have a second sentence, sorted. A semicolon and a space is a break too.
private func severalSentences(_ values: [String: String]) -> [String] {
    values.filter { $0.value.firstMatch(of: /[.?!;][ ]/) != nil }.keys.sorted()
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
private let voiceNameLists: Set<String> = []

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
    value.firstMatch(of: /\b(?:cannot|does not|did not|do not|is not|are not|could not)\b/.ignoresCase()) != nil
}

/// A letter, a colon, a space, and a letter or a format specifier: a fact after a colon.
private func hasFactAfterColon(_ value: String) -> Bool {
    value.firstMatch(of: /[a-z]: [a-z%]/) != nil
}

/// The app name and a lowercase word at the start of a sentence: a verb, a contracted form included.
private func startsWithAppName(_ value: String) -> Bool {
    value.firstMatch(of: /(?:^|[.?!] |\n)Dirigible [a-z]/) != nil
}

/// The keys where the app is the right subject: it acts for the user, or it is the one that quit.
private let appNameSubjectKeys: Set = [
    "error.microphone.denied", "report.saved", "notice.unclean.text", "sheet.transcribe.note.download",
]

private func hasAppNameSubject(_ key: String, _ value: String) -> Bool {
    !appNameSubjectKeys.contains(key) && startsWithAppName(value)
}

/// The keys of a label and its value (a take and its sync state), which keep a colon.
private let labelColonKeys: Set = [
    "episode.take.sync.in", "episode.take.sync.broken", "episode.take.sync.fault",
]

/// One line for each tell of a text: `<key>: <tell>`, sorted by key.
private func textProblems(_ values: [String: String], labelKeys: Set<String>) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        if value.firstMatch(of: /: %(?:lld|d|@)\.?$/) != nil { problems.append("\(key): a count after a colon") }
        if hasUncontractedNegation(value) { problems.append("\(key): an uncontracted negation") }
        if value.firstMatch(of: /\bbecause\b/) != nil { problems.append("\(key): because") }
        if hasAppNameSubject(key, value) { problems.append("\(key): the app name as the subject") }
        if hasFactAfterColon(value), !labelKeys.contains(key) {
            problems.append("\(key): a fact after a colon")
        }
    }
    return problems
}

/// One line for each tell of an error text: `<key>: <tell>`, sorted by key.
private func errorProblems(_ values: [String: String]) -> [String] {
    var problems: [String] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        if hasUncontractedNegation(value) { problems.append("\(key): an uncontracted negation") }
        if hasAppNameSubject(key, value) { problems.append("\(key): the app name as the subject") }
    }
    return problems
}
