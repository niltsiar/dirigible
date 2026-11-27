import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The A3 rule of the ui-audit skill for the banners that join several keys: a banner row has at most two
/// sentences and under 100 characters, with one fact in each sentence and a step as the second sentence.
extension BannerValueTests {
    /// The sentences of a text: a full stop, a question mark, an exclamation mark, or a semicolon, then a space.
    private func sentenceCount(_ text: String) -> Int {
        text.split(separator: "\n").map { line in
            zip(line, line.dropFirst()).filter { ".?!;".contains($0) && $1 == " " }.count + 1
        }.max() ?? 0
    }

    /// The most numbers in one sentence: a count and its measure ("Shortened 2 silences by 3.5 s"). A clock
    /// time is one number.
    private static let numberLimit = 2

    private func rowProblems(_ rows: [(String, String)]) -> [String] {
        rows.flatMap { name, text -> [String] in
            var problems: [String] = []
            if sentenceCount(text) > 2 { problems.append("\(name): \(sentenceCount(text)) sentences: \(text)") }
            for line in text.split(separator: "\n") {
                let sentences = line.split(separator: /[.?!;][ ]/)
                if sentences.count == 2, line.firstMatch(of: /[.?!;][ ]/)?.output.first != "?", !isStep(sentences[1]) {
                    problems.append("\(name): a second sentence that is no step: \(line)")
                }
            }
            if text.count >= 100 { problems.append("\(name): \(text.count) characters: \(text)") }
            if text.firstMatch(of: /[a-z]: [a-z%0-9]/) != nil {
                problems.append("\(name): a fact after a colon: \(text)")
            }
            let numbers = text.split(separator: "\n").flatMap { $0.split(separator: /[.?!;][ ]/) }.map {
                $0.matches(of: /\d+(?::\d+)+|\d+(?:[.,]\d+)?/).count
            }
            if (numbers.max() ?? 0) > Self.numberLimit { problems.append("\(name): several measurements: \(text)") }
            return problems
        }
    }

    /// The worst case of each builder that joins keys: each row of the banner column and each alert that
    /// builds its text from a prefix and an inner message.
    @Test func eachBannerBuilderGivesTwoSentencesUnder100Characters() async throws {
        try await HeaderStateLineTests().withStrings("en") { try worstCaseRows() }
    }

    private func worstCaseRows() throws {
        let large = LoudnessReport(
            target: LUFS(value: -16), measured: LUFS(value: -41), gain: try #require(Gain(dB: 25)),
            output: LUFS(value: -16), truePeak: -1)
        let url = URL(filePath: "/a.wav")
        let importCheck = L10n.sessionImportCheck(muted: 3, leftOut: 3)
        let cut = SyncMoved(
            lag: 5_904_000, drift: .onePartMatched, headCut: Frames(5_904_000), replaced: ["a.wav"], rate: 48_000,
            outcome: .notCorrected(.noFit(.rateOutOfRange)))
        let causes: [DriftCause] = [
            .clipTooShort, .renderedFile, .takeFile, .transcriptNotLoaded, .noFit(.tooFewPoints),
            .noFit(.twoLines), .noFit(.rateOutOfRange), .composedRateOutOfRange, .underOneMillisecond,
        ]
        var rows: [(String, String)] = [
            ("missingMedia", WindowBanner.missingMedia(["a.wav"]).text),
            ("duckNoSpeech", WindowBanner.duckNoSpeech(threshold: -40, unread: ["a.wav"], press: 1).text),
            ("exportReport", WindowBanner.exportReport(large, file: "a.wav", url: url).text),
            ("archiveSaved", WindowBanner.archiveSaved(net: 123_456_789).text),
            ("syncMoved", WindowBanner.syncMoved(cut, revision: 2, press: 1).text),
            ("syncCut", WindowBanner.syncCut(cut, press: 1).text),
            ("sessionImported", WindowBanner.sessionImported(importCheck, press: 1).text),
            ("saveError", L10n.bannerSaveError.text),
        ]
        let take = TakeResult(
            take: 3, end: .diskLow, gaps: ["t1": .deviceLost, "t2": .writeFailed], droppedFrames: ["t1": 512],
            lateStarts: ["t2"])
        rows += take.bannerLines { $0.rawValue }.map { ("takeResult", $0) }
        let unchanged = SyncMoved(lag: 0, drift: .onePartMatched, headCut: 0, replaced: [], rate: 48_000)
        rows.append(("syncMoved unchanged", WindowBanner.syncMoved(unchanged, revision: 2, press: 1).text))
        for (changed, atLimit, unmeasured) in [(0, 3, 3), (0, 0, 3), (0, 0, 0), (0, 3, 0), (2, 3, 3)] {
            let report = LevelReport(changed: changed, atLimit: atLimit, unmeasured: unmeasured)
            rows.append(("levelReport \(changed) \(atLimit) \(unmeasured)", L10n.message(for: report)))
        }
        for cause in causes {
            let moved = SyncMoved(
                lag: 5_904_000, drift: .onePartMatched, headCut: 0, replaced: [], rate: 48_000,
                outcome: .notCorrected(cause))
            rows.append(("syncMoved \(cause)", WindowBanner.syncMoved(moved, revision: 2, press: 1).text))
        }
        let split = DriftSplit(clipFrame: Frames(89_383_200), pause: 960_000)
        let fix = DriftFix(
            slope: 100e-6, across: 2_880, worstResidual: 19.2, splits: [split], clips: ["C", "C-2"],
            files: ["c drift", "c drift"])
        let fixed = SyncMoved(
            lag: 5_904_000, drift: .spread(2_880), headCut: Frames(5_904_000), replaced: ["a.wav"], rate: 48_000,
            outcome: .corrected(fix))
        rows.append(("syncMoved corrected with a cut", WindowBanner.syncMoved(fixed, revision: 2, press: 1).text))
        rows.append(("syncCut corrected", WindowBanner.syncCut(fixed, press: 1).text))
        let usual = LoudnessReport(
            target: LUFS(value: -16), measured: LUFS(value: -20), gain: try #require(Gain(dB: 4)),
            output: LUFS(value: -16), truePeak: -1)
        rows.append(("exportReport usual", WindowBanner.exportReport(usual, file: "a.wav", url: url).text))
        rows.append(("exported alert", L10n.exportedLoudness(for: large) ?? ""))
        let transcript = L10n.transcriptImportResult(skipped: 3, untimed: 2, repeated: 1, dropped: ["a.json"])
        rows.append(("transcriptImport", transcript ?? ""))
        rows.append(("silenceNote", SilenceNote(shortened: 3, removed: 201_600, rate: 48_000).text()))
        let fault = FinalizeError.readFailed(file: "Capture/take3.anchor", errno: EIO)
        let takes = takeSyncLines(
            [3: .broken(from: 2_976_000, shifts: 4), 2: .inSync(offset: 240_000)], faults: [fault], sampleRate: 48_000)
        rows += takes.map { ("takeSync", $0) }
        let refused = StudioError.sessionImport(.source(.unsupportedVersion(99)), source: "Guest")
        let notDownloaded = StudioError.sessionImport(.paste(.notDownloaded(file: "a.wav")), source: "Guest")
        for (name, error) in [("refused", refused), ("not downloaded", notDownloaded)] {
            let alert = WindowAlert.error(error)
            rows.append(("alert \(name) title", alert.text))
            rows.append(("alert \(name) message", alert.message ?? ""))
        }
        #expect(rowProblems(rows) == [])
        #expect(!L10n.bannerSaveError.text.contains("%"), "the inner message of a save error goes to the detail line")
    }
}
