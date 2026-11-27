import DirigibleAudio
import DirigibleCore
import Foundation

/// The texts of library reports and results.
extension L10n {
    /// The loudness part of the exported alert of an export with a target (decision 0032): the output
    /// loudness, then the check after a gain over the auto-level limit. Nil when neither exists.
    static func exportedLoudness(for report: LoudnessReport) -> String? {
        let parts = [
            report.output.map { alertExportedLoudness.format($0.value) },
            report.exceedsLevelLimit ? reportGainLarge.text : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The text of `many` filled with `value`, or the text of `one` for a count of 1 (decision 0010,
    /// **Voice**: a count with a noun has one key for each form). `text` gives the value of a key.
    static func counted(_ value: Int, one: L10n, many: L10n, text: (L10n) -> String = { $0.text }) -> String {
        value == 1 ? text(one) : String(format: text(many), locale: .current, value)
    }

    /// The banner text of an Auto Level: the clips at the limit and the clips with no level, each in its
    /// own row, or, when neither exists and no clip changed, the no-change fact and the gain step. Empty
    /// when clips changed and nothing needs a check: VoiceOver hears the count (`announceLevelChanged`)
    /// and no banner shows. `text` gives the value of a key, so a test can read the English table.
    static func message(for report: LevelReport, text: (L10n) -> String = { $0.text }) -> String {
        var parts: [String] = []
        if report.atLimit > 0 {
            parts.append(counted(report.atLimit, one: .bannerLevelLimitOne, many: .bannerLevelLimit, text: text))
        }
        if report.unmeasured > 0 {
            parts.append(
                counted(report.unmeasured, one: .bannerLevelUnmeasuredOne, many: .bannerLevelUnmeasured, text: text))
        }
        if parts.isEmpty, report.changed == 0 {
            return text(report.isEmpty ? .bannerLevelNone : .bannerLevelChangedNone) + " " + text(.bannerLevelVolume)
        }
        return parts.joined(separator: "\n")
    }

    /// The announcement of a Reduce Noise run that changed clips: "Reduced noise in 3 clips by 12 dB.",
    /// with one form for a single clip, and the forms with hum. A treatment with no noise reduction is
    /// hum alone. `text` gives the value of a key, so a test can read a table.
    static func denoiseResult(
        clips: Int, treatment: Treatment, text: (L10n) -> String = { $0.text }
    ) -> String {
        func fill(_ key: L10n, _ values: Int...) -> String {
            String(format: text(key), locale: .current, arguments: values)
        }
        let one = clips == 1
        switch (treatment.noise?.decibels, treatment.hum != nil) {
        case (nil, _): return one ? fill(.denoiseHumOne) : fill(.denoiseHumMany, clips)
        case (let decibels?, true):
            return one ? fill(.denoiseBothOne, decibels) : fill(.denoiseBothMany, clips, decibels)
        case (let decibels?, false):
            return one ? fill(.denoiseDoneOne, decibels) : fill(.denoiseDoneMany, clips, decibels)
        }
    }

    /// The banner text of a Repair Sound run (decision 0064 D4): "Nothing to change." for clips that the
    /// run did not change, "No clipped peaks found." for a de-clip alone that found none, and the level
    /// drop of a de-clip that found runs ("The level is up to 4 dB lower."). Empty for a repair that
    /// needs no check: `repairDone` is its announcement. The drop sentence has no dB value of 0. `text`
    /// gives the value of a key.
    static func repairResult(_ result: RepairResult, text: (L10n) -> String = { $0.text }) -> String {
        guard result.clips > 0 else { return text(.denoiseUnchanged) }
        guard result.declip, result.repaired > 0 else {
            return result.declip && !result.others ? text(.repairNone) : ""
        }
        guard result.drop > 0 else { return "" }
        return String(
            format: text(result.repaired == 1 ? .repairDropOne : .repairDropMany), locale: .current, result.drop)
    }

    /// The announcement of a Repair Sound run that changed clips: "Repaired clipped peaks in 2 clips."
    /// for a de-clip that found runs and "Repaired the sound of 3 clips." for the other repairs. Empty
    /// when the banner says the whole result. `text` gives the value of a key.
    static func repairDone(_ result: RepairResult, text: (L10n) -> String = { $0.text }) -> String {
        func fill(_ key: L10n, _ values: Int...) -> String {
            String(format: text(key), locale: .current, arguments: values)
        }
        guard result.clips > 0 else { return "" }
        guard result.declip, result.repaired > 0 else {
            if result.declip, !result.others { return "" }
            return result.clips == 1 ? fill(.repairSoundOne) : fill(.repairSoundMany, result.clips)
        }
        return result.repaired == 1 ? fill(.repairPeaksOne) : fill(.repairPeaksMany, result.repaired)
    }

    /// The banner text of a Level Over Time run: "1 clip has no level to measure." for clips with no
    /// reference. Empty when each clip got a level. `text` gives the value of a key, so a test can read
    /// a table.
    static func rideResult(_ result: RideResult, text: (L10n) -> String = { $0.text }) -> String {
        if result.unmeasured == 1 { return text(.rideUnmeasuredOne) }
        guard result.unmeasured > 1 else { return "" }
        return String(format: text(.rideUnmeasuredMany), locale: .current, result.unmeasured)
    }

    /// The announcement of a Level Over Time run that leveled clips: "Leveled 2 clips over time, up to
    /// +4 dB." A largest gain of 0 dB has no "up to" part. Empty with no leveled clip. `text` gives the
    /// value of a key, so a test can read a table.
    static func rideDone(_ result: RideResult, text: (L10n) -> String = { $0.text }) -> String {
        func fill(_ key: L10n, _ values: Int...) -> String {
            String(format: text(key), locale: .current, arguments: values)
        }
        let flat = result.gain == 0
        if result.leveled == 1 { return flat ? text(.rideFlatOne) : fill(.rideDoneOne, result.gain) }
        guard result.leveled > 1 else { return "" }
        return flat ? fill(.rideFlatMany, result.leveled) : fill(.rideDoneMany, result.leveled, result.gain)
    }

    /// The banner of Import Transcript: the first problem only, so the banner keeps one fact and its
    /// step. The dropped transcripts come first, then the first count that is not zero ("3 words have
    /// no clip."). Nil when there is nothing to say. `text` gives the value of a key, so a test can
    /// read a table.
    static func transcriptImportResult(
        skipped: Int, untimed: Int, repeated: Int, dropped: [String], text: (L10n) -> String = { $0.text }
    ) -> String? {
        if !dropped.isEmpty { return String(format: text(.bannerTranscriptDropped), dropped.joined(separator: ", ")) }
        let counts: [(Int, L10n, L10n)] = [
            (skipped, .bannerTranscriptSkippedOne, .bannerTranscriptSkipped),
            (untimed, .bannerTranscriptUntimedOne, .bannerTranscriptUntimed),
            (repeated, .bannerTranscriptRepeatedOne, .bannerTranscriptRepeated),
        ]
        return counts.first { $0.0 > 0 }.map { counted($0.0, one: $0.1, many: $0.2, text: text) }
    }
}
