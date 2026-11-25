import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// C8 of run 2026-11-04-flac-archive: an edit from a pane other than the timeline. The Index list
/// and Copy go through `run(_:)`, so they unarchive first; an inspector commit and a Bins list edit
/// call `edit` and get the archived alert with its Unarchive button.
extension ArchiveWindowTests {
    /// Presses Unarchive in the archived alert of the window.
    func pressUnarchive(_ model: SessionWindow, in window: NSWindow) async throws {
        // SwiftUI first attaches a sheet with untitled buttons, then the alert sheet with its titles.
        await until("the alert shows its buttons") {
            buttons(window.attachedSheet?.contentView).contains { !$0.title.isEmpty }
        }
        let sheet = try #require(window.attachedSheet)
        let titles = buttons(sheet.contentView).map(\.title)
        #expect(titles.contains(L10n.bannerArchiveUnarchive.text), "\(titles)")
        try #require(buttons(sheet.contentView).first { $0.title == L10n.bannerArchiveUnarchive.text }).performClick(
            nil)
        await until("the alert goes") { model.alert == nil }
    }

    /// C8: a commit of the inspector gets the archived alert; its Unarchive button unarchives.
    @Test func anInspectorCommitGetsTheArchivedAlertWithUnarchive() async throws {
        let (model, studio, window) = try await window(archived: true)
        model.inspectorDraft = InspectorDraft(target: .clip(.gain), shown: "0.0", text: "-6", clips: ["c1"])

        model.commitInspector()

        #expect(model.alert == .error(.archived))
        #expect(studio.session.clip("c1")?.clip.gain.dB == 0 && studio.isArchived)
        try await pressUnarchive(model, in: window)
        await until("the unarchive ends") { !studio.isArchived && studio.archiveRun == nil }
        #expect(try clipNames(studio) == ["f1.wav"])
        await model.close()
    }

    /// C8: Delete with the focus in the Bins segment removes no item and gets the archived alert.
    @Test func aBinsListDeleteGetsTheArchivedAlert() async throws {
        let (model, studio, _) = try await window(archived: false)
        try studio.edit(ripple: false) { (session: inout Session) throws(SessionError) in
            _ = try session.addBin("bin1", named: "Music")
            _ = try session.addItem(
                try session.excerpt(of: 0..<48_000, on: ["t1"]), named: "Intro", to: "bin1", id: "i1")
        }
        _ = try await studio.archive { _ in }
        model.leadingPane.selectedBinItem = .session("i1")

        #expect(model.binsCommand(.delete, isKey: true))

        #expect(model.alert == .error(.archived))
        #expect(studio.session.bins.first?.items.map(\.id) == ["i1"] && studio.isArchived)
        model.alert = nil
        await model.close()
    }

    /// C8: Add Marker by its key with the focus in the Index list unarchives first, then adds the
    /// marker.
    @Test func addMarkerInTheIndexListUnarchivesFirst() async throws {
        let (model, studio, _) = try await window(archived: true)

        #expect(model.indexCommand(.addMarker, isKey: true))

        await until("the marker or an alert") { studio.session.markers.count == 1 || model.alert != nil }
        #expect(model.alert == nil, "\(String(describing: model.alert))")
        #expect(!studio.isArchived)
        #expect(try clipNames(studio) == ["f1.wav"])
        await model.close()
    }

    /// C8 (U15): Copy of a clip unarchives first, then copies the clip.
    @Test func copyOfAClipUnarchivesFirst() async throws {
        let (model, studio, _) = try await window(archived: true)
        model.timeline.selection = .clips(try #require(ClipSet(["c1"])))
        app.clipboard = nil

        model.run(.copy)

        await until("the copy or an alert") { app.clipboard != nil || model.alert != nil }
        #expect(model.alert == nil && !studio.isArchived)
        #expect(app.clipboard?.excerpt.lanes.flatMap { $0.clips.map(\.file) } == ["f1"])
        #expect(try clipNames(studio) == ["f1.wav"])
        await model.close()
    }

    /// C8: the replayed Remove Unused Files scans after the unarchive, never during it, so the
    /// sheet lists the WAV of the unused file and no alert shows.
    @Test func aReplayedScanReadsTheDiskAfterTheUnarchive() async throws {
        let (model, studio, _) = try await window(archived: true, second: true)
        let hold = ArchiveHold()
        studio.environment.archiveBlock = { hold.step() }

        model.removeUnusedFiles()
        await until("the unarchive holds") { hold.isHeld }
        hold.release()

        await until("the sheet or an alert shows") { model.unusedFiles != nil || model.alert != nil }
        #expect(model.alert == nil, "\(String(describing: model.alert))")
        #expect(model.unusedFiles?.items.map(\.path) == ["f2.wav"])
        model.unusedFiles = nil
        await model.close()
    }
}
