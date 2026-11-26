import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore
@testable import DirigibleMCP

/// The banner and the announcement after Repair Sound (decision 0064 D4, criteria C13 and C9 (f)): the
/// banner holds the level drop of a de-clip in whole dB and "No clipped peaks found."; the
/// announcement holds the count of the repaired clips.
struct RepairBannerTests {
    /// The report of a render of `clips` with `treatment`; `repairs` gives the runs and the drop in
    /// dB of each clip.
    func report(_ treatment: Treatment, _ repairs: [ClipID: (runs: Int, drop: Double)]) -> ClipRenderReport {
        ClipRenderReport(
            clips: repairs.keys.sorted().map { RenderedClip(clip: $0, file: "f2") }, treatment: treatment,
            unchanged: [], repairs: repairs.mapValues { ClipRepair(runs: $0.runs, levelDrop: $0.drop) })
    }

    /// The English banner text of the result of `repairs`.
    func text(_ treatment: Treatment, _ repairs: [ClipID: (runs: Int, drop: Double)]) throws -> String {
        let table = try stringsTable("en")
        return L10n.repairResult(RepairResult(report(treatment, repairs))) { table[$0.rawValue] ?? $0.rawValue }
    }

    /// The English announcement of the result of `repairs`.
    func done(_ treatment: Treatment, _ repairs: [ClipID: (runs: Int, drop: Double)]) throws -> String {
        let table = try stringsTable("en")
        return L10n.repairDone(RepairResult(report(treatment, repairs))) { table[$0.rawValue] ?? $0.rawValue }
    }

    let declip = Treatment(.declip(.standard))

    /// C13: one clip with a drop of 3.6 dB gives "4 dB lower" in whole dB. Fail: no drop sentence,
    /// and a drop of 3 dB cut and not rounded.
    @Test func namesTheLevelDrop() throws {
        #expect(try text(declip, ["c1": (3, 3.6)]) == "The level is 4 dB lower.")
        #expect(try done(declip, ["c1": (3, 3.6)]) == "Repaired clipped peaks in 1 clip.")
        #expect(
            WindowBanner.soundRepaired(RepairResult(report(declip, ["c1": (3, 3.6)])), press: 1).kind == .warning,
            "a level drop is a warning")
    }

    /// C13: clips with drops of 3 and 5 dB give "up to 5 dB lower". Fail: the drop of the first clip.
    @Test func namesTheLargestDropOfTheClips() throws {
        #expect(try text(declip, ["c1": (2, 3.0), "c2": (1, 5.0)]) == "The level is up to 5 dB lower.")
        #expect(try text(declip, ["c1": (2, 5.0), "c2": (1, 3.0)]) == "The level is up to 5 dB lower.")
        #expect(try done(declip, ["c1": (2, 3.0), "c2": (1, 5.0)]) == "Repaired clipped peaks in 2 clips.")
        #expect(try text(declip, ["c1": (2, 0.2)]) == "", "a drop of 0 dB has no banner")
        #expect(try done(declip, ["c1": (2, 0.2)]) == "Repaired clipped peaks in 1 clip.")
    }

    /// Decision 0011 (CLI parity): the lines of `clip repair` and the banner name the same values for
    /// the same clips: the clips that had runs, and the largest level drop in whole dB. Fail: lines
    /// with no runs or no drop (the output of gate 1).
    @Test func commandLinesNameTheValuesOfTheBanner() throws {
        let clips = report(declip, ["c1": (3, 3.6), "c2": (0, 0), "c3": (1, 2.2)])
        let lines = ClipRenderWork.lines(clips.clips, repairs: clips.repairs)
        let banner = RepairResult(clips)

        #expect(
            lines.suffix(3) == [
                "c1: 3 clipped runs repaired, level drop 3.6 dB", "c2: 0 clipped runs repaired, level drop 0.0 dB",
                "c3: 1 clipped run repaired, level drop 2.2 dB",
            ])
        #expect((banner.repaired, banner.drop) == (2, 4), "\(banner)")
    }

    /// C13: a de-clip that found no run says so. Fail: the banner of a render that found runs; and a
    /// run of the other repairs, which says that it repaired the sound.
    @Test func saysNoClippedPeaksFound() throws {
        #expect(try text(declip, ["c1": (0, 0), "c2": (0, 0)]) == "No clipped peaks found.")
        #expect(try done(declip, ["c1": (0, 0), "c2": (0, 0)]) == "", "the banner says the whole result")
        #expect(try text(declip, ["c1": (0, 0), "c2": (4, 6.0)]) == "The level is 6 dB lower.")
        #expect(try done(declip, ["c1": (0, 0), "c2": (4, 6.0)]) == "Repaired clipped peaks in 1 clip.")
        let rumble = Treatment(.rumble(.standard))
        #expect(try text(rumble, ["c1": (0, 0), "c2": (0, 0)]) == "", "a repair with no warning has no banner")
        #expect(try done(rumble, ["c1": (0, 0), "c2": (0, 0)]) == "Repaired the sound of 2 clips.")
        let both = Treatment([.declip(.standard), .rumble(.standard)])!
        #expect(try text(both, ["c1": (0, 0)]) == "")
        #expect(try done(both, ["c1": (0, 0)]) == "Repaired the sound of 1 clip.")
        let table = try stringsTable("en")
        let none = RepairResult(clips: 0, declip: true, others: false, repaired: 0, drop: 0)
        #expect(L10n.repairResult(none) { table[$0.rawValue] ?? $0.rawValue } == "Nothing to change.")
        #expect(L10n.repairDone(none) { table[$0.rawValue] ?? $0.rawValue } == "")
    }

    /// C14 (app part): the error values of a clip render do not name the noise reduction, and the
    /// two that name it keep it. Fail: "noise" in a value of a repair.
    @Test func clipRenderErrorValuesAreNeutral() throws {
        let neutral: [L10n] = [
            .errorDenoiseSpace, .errorDenoiseWrite, .errorDenoiseUnreadable, .errorDenoiseMissing,
            .errorDenoiseNotDownloaded, .errorDenoiseMixed, .errorDenoiseEngine, .errorDenoiseOverFullScale,
            .errorDenoiseCornerLimit, .errorDenoiseCornerRate, .errorDenoiseNonFinite,
        ]
        let table = try stringsTable("en")
        for key in neutral {
            let value = try #require(table[key.rawValue])
            #expect(!value.localizedCaseInsensitiveContains("noise"), "\(key.rawValue): \(value)")
        }
        #expect(try #require(table[L10n.errorDenoiseTrackRole.rawValue]).contains("Reduce Noise"))
        let unavailable = try #require(table[L10n.errorDenoiseUnavailable.rawValue])
        #expect(unavailable.hasPrefix("The noise reduction of macOS didn't load"))
        #expect(try #require(table[L10n.errorDenoiseYielded.rawValue]).hasPrefix("The clip render stopped"))
    }
}
