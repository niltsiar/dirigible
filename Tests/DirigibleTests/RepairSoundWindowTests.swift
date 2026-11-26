import AppKit
import DirigibleTimeline
import Foundation
import SwiftUI
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

    /// C13 and C9 (f): Repair renders each selected clip, also on a music track, onto a new file in one
    /// undo entry. The lanes show the new files, so no banner opens, and VoiceOver hears the count once.
    /// Control: the draft with no box on renders nothing.
    @Test func repairSoundShowsNoBannerAndIsAnnounced() async throws {
        let (model, studio) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
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
        let text = L10n.repairSoundMany.format(2)
        #expect(heard.count(where: { $0 == text }) == 1, "VoiceOver hears the count once: \(heard)")
        let banners = ChromeState.reportBanners(model, studio)
        #expect(!banners.contains { $0.key.hasPrefix("repairReport") }, "a repair with no warning: \(banners)")
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

    /// ui-audit G8: a slider with a step of 1 over the 14000 hertz of the de-ess frequency draws
    /// 14000 tick marks, which merge into one black bar. No slider of the sheet draws a tick mark.
    @Test func noSliderDrawsTickMarks() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c1")
        model.run(.repairSound)
        var draft = try #require(model.repairDraft)
        (draft.rumble, draft.deess, draft.showsMore) = (true, true, true)
        let host = NSHostingView(rootView: RepairSheet(model: model, studio: studio, draft: draft))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)

        func sliders(_ view: NSView) -> [NSSlider] {
            ((view as? NSSlider).map { [$0] } ?? []) + view.subviews.flatMap(sliders)
        }
        await until("the sheet has its sliders") {
            host.layoutSubtreeIfNeeded()
            return sliders(host).count == 3
        }
        #expect(sliders(host).map(\.numberOfTickMarks) == [0, 0, 0])
        window.close()
        await model.close()
    }

    /// ui-audit A8: each of the three sliders has a visible label on its line, left of it, and the
    /// three labels end at one edge, so they sit in one column. Fail: a slider with only a
    /// VoiceOver label. The check reads the drawn pixels, because a hosted SwiftUI sheet gives
    /// no accessibility tree to a test.
    @Test func eachSliderHasAVisibleLabelInOneColumn() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c1")
        model.run(.repairSound)
        var draft = try #require(model.repairDraft)
        (draft.rumble, draft.deess, draft.showsMore) = (true, true, true)
        let host = NSHostingView(rootView: RepairSheet(model: model, studio: studio, draft: draft))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)

        func sliders(_ view: NSView) -> [NSSlider] {
            ((view as? NSSlider).map { [$0] } ?? []) + view.subviews.flatMap(sliders)
        }
        await until("the sheet has its sliders") {
            host.layoutSubtreeIfNeeded()
            return sliders(host).count == 3
        }
        drawNow(window)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        let background = try #require(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            let gap =
                abs(color.redComponent - background.redComponent)
                + abs(color.greenComponent - background.greenComponent)
            return gap + abs(color.blueComponent - background.blueComponent) > 0.6
        }
        let all = sliders(host)
        try #require(all.count == 3, "the three sliders")
        let edges: [Int] = try all.map { slider in
            let rect = slider.convert(slider.bounds, to: host)
            let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            let rows = Int((top + rect.height * 0.25) * scale)..<Int((top + rect.height * 0.75) * scale)
            let columns = 0..<Int((rect.minX - 4) * scale)
            let inked = columns.filter { x in rows.contains { isInk(x, $0) } }
            try #require(inked.count > 8, "a visible label left of the slider at \(rect): \(inked.count) columns")
            return try #require(inked.max())
        }
        let spread = (edges.max() ?? 0) - (edges.min() ?? 0)
        #expect(Double(spread) <= 2 * scale, "one label column: right edges \(edges)")
        window.close()
        await model.close()
    }
}
