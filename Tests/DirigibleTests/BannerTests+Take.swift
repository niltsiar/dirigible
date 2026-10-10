import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The record-over overlay, the transport warnings, and Use headphones (ui-shell A17, A18, B2c).
extension BannerTests {
    // MARK: A17, A18

    /// The frame check comes after a body run of the overlay that shows the warning, so it sees
    /// the lanes with the overlay. The count is read before the arm, so no run is missed.
    @Test func theRecordOverBannerDoesNotMoveTheLanes() async throws {
        let (model, studio, window, _) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let view = try #require(model.timelineView)
        view.viewWillMove(toWindow: nil)
        model.armed = []
        await studio.perform(.seek(.frame(100_000)))
        // No row above the lanes: the lanes take the whole content height less the loudness strip
        // (decision 0033). The read at open can show a low-time row that SwiftUI removes later.
        await until(limit: .seconds(10), "the lanes fill the content") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.shown.banners.isEmpty
                && (view.superview ?? view).frame.height
                    == window.contentLayoutRect.height - (model.showsLoudness ? LoudnessStrip.height : 0)
        }
        let before = view.convert(view.bounds, to: nil)
        let shows = model.overlayShows

        model.armed = [TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")]
        await until(limit: .seconds(10), "the overlay body shows the warning") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.overlayShows > shows
        }

        #expect(model.shown.recordOver)
        #expect(view.convert(view.bounds, to: nil) == before, "the overlay moved the lanes")
        await model.close()
    }

    /// Code gate 1 item 1: the overlay covers the ruler, where the user acts on the warning. A
    /// mouse-down there goes through the window to the ruler and moves the playhead.
    @Test func aRulerClickUnderTheRecordOverOverlaySeeks() async throws {
        let (model, studio, window, _) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let view = try #require(model.timelineView)
        view.viewWillMove(toWindow: nil)
        model.armed = [TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")]
        await studio.perform(.seek(.frame(100_000)))
        await until(limit: .seconds(10), "the overlay body shows the warning") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.shown.recordOver && model.overlayShows > 0
        }
        let geometry = try #require(view.ruler.inputs?.geometry)
        let x = Double(view.shown.minX) + 100
        let target = geometry.frame(at: x)
        try #require(target != studio.playhead)

        // As `NSWindow.sendEvent` does in a key window: the hit view of the frame view gets the
        // events. The test process has no key window, so the window would take the first click.
        let down = try rulerMouse(.leftMouseDown, x, 10, in: view)
        let hit = try #require(window.contentView?.superview?.hitTest(down.locationInWindow))
        hit.mouseDown(with: down)
        hit.mouseUp(with: try rulerMouse(.leftMouseUp, x, 10, in: view))

        await until(limit: .seconds(5), "the ruler click seeks") { studio.playhead == target }
        #expect(studio.playhead == target, "the overlay took the ruler click")
        await model.close()
    }

    /// Code gate 1 item 1 (round 2 of the timeline-navigation gate): the warning covers the ruler,
    /// not the overview strip above it. The strip pixels stay when the warning shows, and the
    /// ruler pixels change in the same captures. A click on the strip still moves the view.
    @Test func theRecordOverOverlayLeavesTheOverviewFree() async throws {
        let (model, studio, window, _) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let view = try #require(model.timelineView)
        let strip = try #require(view.overview)
        view.viewWillMove(toWindow: nil)
        model.armed = []
        await studio.perform(.seek(.frame(100_000)))
        model.run(.zoomIn)
        func pixels(_ area: NSView) async throws -> [UInt32] {
            window.contentView?.layoutSubtreeIfNeeded()
            drawNow(window)
            try await Task.sleep(for: .milliseconds(200))
            let rect = area.convert(area.bounds, to: nil)
            return try await TimelineRulerTests.pixels(of: rect, TimelineColorTests.capture(window), window)
        }
        let (stripBefore, rulerBefore) = (try await pixels(strip), try await pixels(view.ruler))

        model.armed = [TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")]
        await until(limit: .seconds(10), "the overlay body shows the warning") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.shown.recordOver && model.overlayShows > 0
        }
        let (stripAfter, rulerAfter) = (try await pixels(strip), try await pixels(view.ruler))
        #expect(rulerAfter != rulerBefore, "the warning shows over the ruler")
        let covered = zip(stripBefore, stripAfter).filter { $0 != $1 }.count
        #expect(covered == 0, "the warning covers \(covered) pixels of the overview strip")

        let origin = view.origin
        let point = strip.convert(NSPoint(x: strip.bounds.midX + 300, y: strip.bounds.midY), to: nil)
        func click(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        // As `NSWindow.sendEvent` does in a key window: the hit view of the frame view gets the events.
        let hit = try #require(window.contentView?.superview?.hitTest(point))
        #expect(hit === strip, "the strip gets the click")
        hit.mouseDown(with: try click(.leftMouseDown))
        hit.mouseUp(with: try click(.leftMouseUp))
        #expect(view.origin != origin, "a click on the strip moves the view")
        await model.close()
    }

    /// The labels are the ones that `BannerRow` gives SwiftUI. The accessibility tree of the
    /// SwiftUI host is empty in some host states of a test process, so the rows in that tree are
    /// manual check M10. A check box is an AppKit button in every state.
    @Test func theTransportWarningsAreBanners() async throws {
        let (model, studio, window, _) = try await open()
        studio.play.playbackStop = .outputChanged
        studio.missingMedia = ["f1": .missing]
        await until(limit: .seconds(5), "the banner list has both") { model.shown.banners.count == 2 }

        #expect(
            model.shown.banners.map { $0.kind.label($0.text) } == [
                "\(L10n.bannerKindWarning.text): \(L10n.transportStopOutputChanged.text)",
                "\(L10n.bannerKindError.text): \(L10n.mediaMissing.text)",
            ])
        // No check box: no Monitor Inputs box, and arm is a button (run 2026-10-10-arm-toggle-button).
        let content = try #require(window.contentView)
        #expect(checkBoxes(under: content).isEmpty, "a check box in the window")
        await model.close()
    }

    // MARK: B2c, Use headphones

    func headphones(_ model: SessionWindow) -> Bool { model.shown.banners.contains { $0 == .useHeadphones } }

    /// A list with no device and the speaker flag of `speakers`.
    func speakerList(_ speakers: OSAllocatedUnfairLock<Bool>) async -> DeviceList {
        let list = DeviceList(read: { [] }, defaults: { AudioDefaults(speakers: speakers.withLock { $0 }) })
        await until("no device read") { list.reads >= 1 }
        return list
    }

    /// The banner shows for the speakers and an armed app track, and Record stays enabled. Not
    /// armed, or only device tracks: it hides. Each hide comes after a show, so the loop ran.
    @Test func useHeadphonesShowsOnlyForSpeakersAndAnArmedAppTrack() async throws {
        let (model, studio, _, chrome) = try await open(tracks: 2)
        model.deviceList = await speakerList(OSAllocatedUnfairLock(initialState: true))
        let (first, second) = (studio.session.tracks[0].id, studio.session.tracks[1].id)
        let duo = InputDevice.placeholder(uid: "duo", channels: 2)
        // The F43 case: an armed app track next to an armed device track.
        model.setRoute(.mono(2), device: duo, track: second)
        model.setAppRoute("us.zoom.xos", track: first)
        #expect(model.armed.isSuperset(of: [first, second]), "both tracks are armed")
        await until(limit: .seconds(5), "the banner shows for an armed app track") { headphones(model) }
        let banner = try #require(model.shown.banners.first { $0 == .useHeadphones })
        #expect(banner.kind == .warning && banner.announcement == .high)
        #expect(banner.text == L10n.bannerUseHeadphones.text)
        let record = try #require(chrome.toolbar.items.first { $0.itemIdentifier == ToolbarItemID.record.identifier })
        #expect(((record.view as? NSButton)?.isEnabled ?? record.isEnabled) && model.canRecord, "Record is enabled")

        model.armed.remove(first)
        await until(limit: .seconds(5), "the banner hides when the app track is not armed") { !headphones(model) }
        model.armed.insert(first)
        await until(limit: .seconds(5), "the banner shows again") { headphones(model) }
        model.setRoute(.mono(1), device: duo, track: first)
        #expect(model.armed.isSuperset(of: [first, second]), "both device tracks are armed")
        await until(limit: .seconds(5), "the banner hides with only device tracks") { !headphones(model) }
        await model.close()
    }

    /// A change of the speaker flag (a headphone plug, or a USB or Bluetooth output) hides it.
    @Test func useHeadphonesHidesWhenTheFlagChanges() async throws {
        let (model, studio, _, _) = try await open()
        let speakers = OSAllocatedUnfairLock(initialState: true)
        let list = await speakerList(speakers)
        model.deviceList = list
        model.setAppRoute("us.zoom.xos", track: studio.session.tracks[0].id)
        await until(limit: .seconds(5), "the banner shows") { headphones(model) }
        speakers.withLock { $0 = false }
        list.changed()
        await until(limit: .seconds(5), "the banner hides when the flag changes") { !headphones(model) }
        speakers.withLock { $0 = true }
        list.changed()
        await until(limit: .seconds(5), "the banner shows again") { headphones(model) }
        await model.close()
    }

    /// The buttons under `view` that are not pop-up buttons. SwiftUI puts a check box in an
    /// NSButton with no title.
    func checkBoxes(under view: NSView) -> [NSButton] {
        let own = (view as? NSButton).flatMap { $0 is NSPopUpButton ? nil : $0 }
        return (own.map { [$0] } ?? []) + view.subviews.flatMap { checkBoxes(under: $0) }
    }
}
