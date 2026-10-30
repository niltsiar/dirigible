import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// The banner after Repair Sound (decision 0064 D4, criterion C13): the level drop of a de-clip in
/// whole dB, and "No clipped peaks found.".
struct RepairBannerTests {
    /// The report of a render of `clips` with `treatment`; `repairs` gives the runs and the drop in
    /// dB of each clip.
    func report(_ treatment: Treatment, _ repairs: [ClipID: (runs: Int, drop: Double)]) -> ClipRenderReport {
        ClipRenderReport(
            clips: repairs.keys.sorted().map { RenderedClip(clip: $0, file: "f2") }, treatment: treatment,
            unchanged: [], repairs: repairs.mapValues { ClipRepair(runs: $0.runs, levelDrop: $0.drop) })
    }

    /// The English text of the result of `repairs`.
    func text(_ treatment: Treatment, _ repairs: [ClipID: (runs: Int, drop: Double)]) throws -> String {
        let table = try stringsTable("en")
        return L10n.repairResult(RepairResult(report(treatment, repairs))) { table[$0.rawValue] ?? $0.rawValue }
    }

    let declip = Treatment(.declip(.standard))

    /// C13: one clip with a drop of 3.6 dB gives "4 dB lower" in whole dB. Fail: no drop sentence,
    /// and a drop of 3 dB cut and not rounded.
    @Test func namesTheLevelDrop() throws {
        #expect(
            try text(declip, ["c1": (3, 3.6)]) == "Repaired clipped peaks in 1 clip. The level is 4 dB lower.")
    }

    /// C13: clips with drops of 3 and 5 dB give "up to 5 dB lower". Fail: the drop of the first clip.
    @Test func namesTheLargestDropOfTheClips() throws {
        #expect(
            try text(declip, ["c1": (2, 3.0), "c2": (1, 5.0)])
                == "Repaired clipped peaks in 2 clips. The level is up to 5 dB lower.")
        #expect(
            try text(declip, ["c1": (2, 5.0), "c2": (1, 3.0)])
                == "Repaired clipped peaks in 2 clips. The level is up to 5 dB lower.")
        #expect(
            try text(declip, ["c1": (2, 0.2)]) == "Repaired clipped peaks in 1 clip.", "a drop of 0 dB has no sentence")
    }

    /// C13: a de-clip that found no run says so. Fail: the banner of a render that found runs; and a
    /// run of the other repairs, which says that it repaired the sound.
    @Test func saysNoClippedPeaksFound() throws {
        #expect(try text(declip, ["c1": (0, 0), "c2": (0, 0)]) == "No clipped peaks found.")
        #expect(
            try text(declip, ["c1": (0, 0), "c2": (4, 6.0)])
                == "Repaired clipped peaks in 1 clip. The level is 6 dB lower.")
        let rumble = Treatment(.rumble(.standard))
        #expect(try text(rumble, ["c1": (0, 0), "c2": (0, 0)]) == "Repaired the sound of 2 clips.")
        let both = Treatment([.declip(.standard), .rumble(.standard)])!
        #expect(try text(both, ["c1": (0, 0)]) == "Repaired the sound of 1 clip.")
        let table = try stringsTable("en")
        let none = RepairResult(clips: 0, declip: true, others: false, repaired: 0, drop: 0)
        #expect(L10n.repairResult(none) { table[$0.rawValue] ?? $0.rawValue } == "Nothing to change.")
    }

    /// C14 (app part): the error values of a clip render name the clip render in each table, and the
    /// two that name the noise reduction keep it. Fail: "reduce the noise" in a value of a repair.
    @Test func clipRenderErrorValuesAreNeutral() throws {
        let neutral: [L10n] = [
            .errorDenoiseSpace, .errorDenoiseWrite, .errorDenoiseUnreadable, .errorDenoiseMissing,
            .errorDenoiseNotDownloaded, .errorDenoiseMixed, .errorDenoiseEngine, .errorDenoiseOverFullScale,
            .errorDenoiseCornerLimit, .errorDenoiseCornerRate, .errorDenoiseNonFinite,
        ]
        let table = try stringsTable("en")
        for key in neutral {
            let value = try #require(table[key.rawValue])
            #expect(value.hasPrefix("Dirigible cannot render the clips."), "\(key.rawValue): \(value)")
        }
        #expect(try #require(table[L10n.errorDenoiseTrackRole.rawValue]).contains("reduce the noise"))
        #expect(try #require(table[L10n.errorDenoiseUnavailable.rawValue]).contains("reduce the noise"))
        #expect(try #require(table[L10n.errorDenoiseYielded.rawValue]).hasPrefix("The clip render stopped"))
    }
}
