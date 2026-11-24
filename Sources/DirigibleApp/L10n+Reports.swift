import DirigibleAudio
import DirigibleCore
import Foundation

/// The texts of library reports and results.
extension L10n {
    /// The loudness report of an export with a target (decision 0032): the output loudness, the
    /// true peak, and the gain.
    static func message(for report: LoudnessReport) -> String {
        [
            report.output.map { reportLoudness.format($0.value) } ?? reportLoudnessNone.text,
            report.truePeak.map { reportPeak.format($0) } ?? reportPeakNone.text,
            reportGain.format(report.gain.dB),
        ].joined(separator: ", ")
    }

    /// The sentence after the report of a gain over the auto-level limit. Empty for a usual gain.
    static func largeGainHint(for report: LoudnessReport) -> String {
        report.exceedsLevelLimit ? " " + reportGainLarge.text : ""
    }

    /// The text of `many` filled with `value`, or the text of `one` for a count of 1 (decision 0010,
    /// **Voice**: a count with a noun has one key for each form). `text` gives the value of a key.
    static func counted(_ value: Int, one: L10n, many: L10n, text: (L10n) -> String = { $0.text }) -> String {
        value == 1 ? text(one) : String(format: text(many), locale: .current, value)
    }

    /// The banner text of an Auto Level: the head, the track volume sentence when no clip changed,
    /// then the clips at the limit and the clips with no level. `text` gives the value of a key,
    /// so a test can read the English table.
    static func message(for report: LevelReport, text: (L10n) -> String = { $0.text }) -> String {
        var parts: [String]
        if report.isEmpty {
            parts = [text(.bannerLevelNone)]
        } else if report.changed == 0 {
            parts = [text(.bannerLevelChangedNone)]
        } else {
            parts = [counted(report.changed, one: .bannerLevelChangedOne, many: .bannerLevelChanged, text: text)]
        }
        if report.changed == 0 { parts.append(text(.bannerLevelVolume)) }
        if report.atLimit > 0 {
            parts.append(counted(report.atLimit, one: .bannerLevelLimitOne, many: .bannerLevelLimit, text: text))
        }
        if report.unmeasured > 0 {
            parts.append(
                counted(report.unmeasured, one: .bannerLevelUnmeasuredOne, many: .bannerLevelUnmeasured, text: text))
        }
        return parts.joined(separator: " ")
    }

    /// The result banner of a Reduce Noise run: "Reduced noise in 3 clips by 12 dB.", with one form for
    /// a single clip, and the forms with hum. A treatment with no noise reduction is hum alone. `text`
    /// gives the value of a key, so a test can read a table.
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

    /// The result banner of a Repair Sound run (decision 0064 D4): "Repaired clipped peaks in 2 clips.
    /// The level is up to 4 dB lower." for a de-clip that found runs, "No clipped peaks found." for
    /// a de-clip alone that found none, and "Repaired the sound of 3 clips." for the other repairs.
    /// The drop sentence has no dB value of 0. `text` gives the value of a key.
    static func repairResult(_ result: RepairResult, text: (L10n) -> String = { $0.text }) -> String {
        func fill(_ key: L10n, _ values: Int...) -> String {
            String(format: text(key), locale: .current, arguments: values)
        }
        guard result.clips > 0 else { return text(.denoiseUnchanged) }
        guard result.declip, result.repaired > 0 else {
            if result.declip, !result.others { return text(.repairNone) }
            return result.clips == 1 ? fill(.repairSoundOne) : fill(.repairSoundMany, result.clips)
        }
        let one = result.repaired == 1
        let found = one ? fill(.repairPeaksOne) : fill(.repairPeaksMany, result.repaired)
        guard result.drop > 0 else { return found }
        return found + " " + (one ? fill(.repairDropOne, result.drop) : fill(.repairDropMany, result.drop))
    }

    /// The result banner of a Level Over Time run: "Leveled 2 clips over time, up to +4 dB.", then
    /// "1 clip has no level to measure." when a clip had no reference. A largest gain of 0 dB has no
    /// "up to" part. With no leveled clip, only the second sentence. `text` gives the value of a
    /// key, so a test can read a table.
    static func rideResult(_ result: RideResult, text: (L10n) -> String = { $0.text }) -> String {
        func fill(_ key: L10n, _ values: Int...) -> String {
            String(format: text(key), locale: .current, arguments: values)
        }
        var parts: [String] = []
        let flat = result.gain == 0
        if result.leveled == 1 {
            parts.append(flat ? text(.rideFlatOne) : fill(.rideDoneOne, result.gain))
        } else if result.leveled > 1 {
            parts.append(
                flat ? fill(.rideFlatMany, result.leveled) : fill(.rideDoneMany, result.leveled, result.gain))
        }
        if result.unmeasured == 1 {
            parts.append(text(.rideUnmeasuredOne))
        } else if result.unmeasured > 1 {
            parts.append(fill(.rideUnmeasuredMany, result.unmeasured))
        }
        return parts.joined(separator: " ")
    }

    /// The banner of Import Transcript: one sentence for each count that is not zero ("3 words have
    /// no clip."), then the names of the dropped transcripts. Nil when there is nothing to say.
    /// `text` gives the value of a key, so a test can read a table.
    static func transcriptImportResult(
        skipped: Int, untimed: Int, repeated: Int, dropped: [String], text: (L10n) -> String = { $0.text }
    ) -> String? {
        func count(_ value: Int, one: L10n, many: L10n) -> String? {
            value > 0 ? counted(value, one: one, many: many, text: text) : nil
        }
        var parts = [
            count(skipped, one: .bannerTranscriptSkippedOne, many: .bannerTranscriptSkipped),
            count(untimed, one: .bannerTranscriptUntimedOne, many: .bannerTranscriptUntimed),
            count(repeated, one: .bannerTranscriptRepeatedOne, many: .bannerTranscriptRepeated),
        ].compactMap { $0 }
        if !dropped.isEmpty {
            parts.append(String(format: text(.bannerTranscriptDropped), dropped.joined(separator: ", ")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
