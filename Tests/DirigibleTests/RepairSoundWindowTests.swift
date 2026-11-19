import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Repair Sound in the session window (decision 0064, criterion C13). The tracks t1 (no
/// role), t2 (dialogue), t3 (music), and t4 (effects) each hold the clip c<n> of 3 s of the noise
/// file `f1` (`ReduceNoiseWindowTests.rolesPackage`).
@Suite(.serialized) @MainActor struct RepairSoundWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open() async throws -> (SessionWindow, Studio) {
        let (model, studio, _, _) = try await openLanes(
            app, try await ReduceNoiseWindowTests.rolesPackage(in: folder.url))
        return (model, studio)
    }

    func set(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    /// C13: the item is on with an idle studio and a selection that holds a clip of any track role.
    /// Control: no selection, a range past the clips, a take, and an import run turn it off.
    @Test func menuStateForEachStartState() async throws {
        let (model, studio) = try await open()
        let cases: [(String, Selection, Bool)] = [
            ("no selection", .none, false), ("a clip with no role", set("c1"), true),
            ("a dialogue clip", set("c2"), true), ("a music clip", set("c3"), true),
            ("music and effects clips", set("c3", "c4"), true),
            ("a range past the clips", .range(Marks(inPoint: 2_000_000, outPoint: 2_000_010, tracks: ["t1"])), false),
            ("a track", .range(Marks(tracks: ["t2"])), true),
        ]
        for (name, selection, on) in cases {
            model.timeline.selection = selection
            #expect(model.isOn(.repairSound) == on, "\(name)")
        }
        model.timeline.selection = set("c1")
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.repairSound), "a take")
        studio.transport = .importing(ImportRun(name: "x", kind: .file, flags: ImportFlags()))
        #expect(!model.isOn(.repairSound), "an import run")
        studio.transport = .idle
        #expect(model.isOn(.repairSound), "after the run")
        model.run(.reduceNoise)
        #expect(model.denoiseDraft != nil && !model.isOn(.repairSound), "the Reduce Noise sheet shows")
        await model.close()
    }

    /// C13: a selection with no clip beeps and opens no sheet; a selection of music clips opens the
    /// sheet on their clips.
    @Test func theItemOpensTheSheetOnTheSelection() async throws {
        let (model, _) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        model.timeline.selection = .none
        model.run(.repairSound)
        #expect(beeps == 1 && model.repairDraft == nil)
        model.timeline.selection = set("c3", "c4")
        model.run(.repairSound)
        #expect(beeps == 1 && model.repairDraft?.clips == ["c3", "c4"], "\(String(describing: model.repairDraft))")
        await model.close()
    }

    /// C13: Repair renders each selected clip, also on a music track, onto a new file in one undo
    /// entry, and the banner counts the clips. Control: the draft with no box on renders nothing.
    @Test func repairRendersEachClipAndSaysSo() async throws {
        let (model, studio) = try await open()
        let before = studio.session
        model.timeline.selection = set("c1", "c3")
        model.run(.repairSound)
        var draft = try #require(model.repairDraft)
        model.applyRepair(draft)
        #expect(model.importJob == nil && studio.session == before, "a draft with no box rendered")

        draft.rumble = true
        model.applyRepair(draft)
        await until("the render ends") { model.importJob == nil }

        let files = ["c1", "c3"].map { studio.session.clip($0)?.clip.file }
        #expect(files.allSatisfy { $0 != nil && $0 != "f1" } && model.alert == nil, "\(files)")
        await until("the banner shows") { model.shown.banners.contains { $0.key == "repairReport.1" } }
        let banner = try #require(model.shown.banners.first { $0.key == "repairReport.1" })
        #expect(banner.kind == .info && banner.text == L10n.repairSoundMany.format(2), "\(banner.text)")
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo entry")
        await model.close()
    }

    /// Repair on a studio that became busy while the sheet was open (an agent level or an agent clip
    /// render) shows the busy alert, closes the sheet, changes no clip, and leaves the other job running.
    @Test func repairOnABusyStudioShowsTheBusyAlert() async throws {
        let (model, studio) = try await open()
        let before = studio.session
        model.timeline.selection = set("c1", "c3")
        for importing in [false, true] {
            let name = importing ? "an agent clip render" : "an agent level"
            model.run(.repairSound)
            var draft = try #require(model.repairDraft, "\(name): the item opened no sheet")
            draft.rumble = true
            let flags = ImportFlags()
            studio.transport =
                importing ? .importing(ImportRun(name: "agent", kind: .clipRender, flags: flags)) : .leveling

            model.applyRepair(draft)
            await until("the render ends") { model.importJob == nil }

            #expect(model.alert == .error(.busy), "\(name): \(String(describing: model.alert))")
            #expect(model.repairDraft == nil && model.repairReport == nil, "\(name): the sheet or a report shows")
            #expect(studio.session == before, "\(name): the apply changed the session")
            #expect(flags.isCancelled == false, "\(name): the apply cancelled the other job")
            studio.transport = .idle
            model.alert = nil
        }
        await model.close()
    }
}
