import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// The values of the Repair Sound sheet (decision 0064, criterion C13).
struct RepairSheetTests {
    func draft(
        _ clips: [ClipID] = ["c1"], rate: Int = 48_000, defaults: UserDefaults? = nil
    ) -> RepairDraft {
        RepairDraft(clips: clips, sampleRate: rate, defaults: defaults)
    }

    func defaults() throws -> UserDefaults {
        let name = "RepairSheetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// C13 and council D1: the first open has the three boxes off with the standard values; after a
    /// Repair press with boxes on, the next open has every box off and the last slider values. Fail:
    /// a box that starts on, and a slider value that the press forgot.
    @Test func defaultsAndLastValues() throws {
        let defaults = try defaults()
        let first = draft(defaults: defaults)
        #expect(!first.declip && !first.rumble && !first.deess, "\(first)")
        #expect(first.rumbleHertz == 80 && first.deessDecibels == 10 && first.deessHertz == 6_000, "\(first)")

        var changed = first
        (changed.declip, changed.rumble, changed.deess) = (true, true, true)
        (changed.rumbleHertz, changed.deessDecibels, changed.deessHertz) = (120, 15, 7_000)
        changed.remember(in: defaults)

        let second = draft(defaults: defaults)
        #expect(!second.declip && !second.rumble && !second.deess, "\(second)")
        #expect(second.rumbleHertz == 120 && second.deessDecibels == 15 && second.deessHertz == 7_000, "\(second)")
    }

    /// C13: with no box on, Repair is off and the reason is "Turn on at least one repair."; with a
    /// box on, Repair is on with no reason. Fail: a Repair that is always on, and one that is off with
    /// no reason.
    @Test func repairIsOffWithAReasonWithNothingChecked() {
        var draft = draft()
        #expect(!draft.canRepair && draft.reason == .sheetRepairNone && draft.request == nil)
        #expect(L10n.sheetRepairNone.rawValue == "sheet.repair.none")
        draft.declip = true
        #expect(draft.canRepair && draft.reason == nil)
        draft.declip = false
        draft.deess = true
        #expect(draft.canRepair && draft.request?.treatment.deess == DeEss.standard)
    }

    /// C13: the title names the clip count. Fail: a title with no count.
    @Test func titleNamesTheClipCount() throws {
        let table = try stringsTable("en")
        func title(_ clips: [ClipID]) -> String { draft(clips).title { table[$0.rawValue] ?? $0.rawValue } }
        #expect(title(["c1"]) == "Repair Sound for 1 Clip")
        #expect(title(["c1", "c2", "c3"]) == "Repair Sound for 3 Clips")
    }

    /// C13: the rows are in chain order. Fail: rows in the order of the checkboxes of the CLI.
    @Test func rowsAreInChainOrder() {
        #expect(RepairDraft.Row.allCases.map(\.kind) == [.declip, .rumble, .deess])
        #expect(RepairDraft.Row.allCases.map(\.kind.rawValue) == RepairDraft.Row.allCases.map(\.kind.rawValue).sorted())
    }

    /// C13: the More group of the de-ess row starts collapsed. Fail: a group that starts open.
    @Test func moreGroupStartsCollapsed() {
        #expect(!draft().showsMore)
    }

    /// C13 and C19: the frequency max is min(16,000, the highest whole Hz under 0.45 x the rate), and
    /// the start is min(the last or the standard value, the max). Fail: 16,000 Hz at 22,050 Hz,
    /// floor(0.45 x rate) at 32,000 Hz (14,400 Hz), and a start of 6,000 Hz at 11,025 Hz.
    @Test func frequencyMaxFollowsTheSessionRate() throws {
        for (rate, max) in [(22_050, 9_922), (32_000, 14_399), (44_100, 16_000), (48_000, 16_000), (4_445, 2_000)] {
            #expect(draft(rate: rate).frequencyMax == max, "rate \(rate)")
        }
        #expect(draft(rate: 4_444).frequencyMax == nil, "the de-ess row is off at 4,444 Hz")
        #expect(draft(rate: 11_025).deessHertz == 4_961)
        let defaults = try defaults()
        var last = draft()
        (last.deess, last.deessHertz) = (true, 12_000)
        last.remember(in: defaults)
        #expect(draft(rate: 22_050, defaults: defaults).deessHertz == 9_922)
        #expect(!draft(rate: 4_444, defaults: defaults).deess, "a stored box is off where the row is off")
        for rate in [22_050, 32_000, 11_025, 4_445] {
            var edge = draft(rate: rate)
            (edge.deess, edge.deessHertz) = (true, try #require(edge.frequencyMax))
            let treatment = try #require(edge.treatment)
            #expect(throws: Never.self, "the render refuses the top at \(rate) Hz") {
                try RepairSetup.check(treatment, rate: rate)
            }
        }
    }
}
