import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The banners and the record time on a real session window (ui-shell criteria A12 to A18).
@Suite(.serialized) @MainActor struct BannerTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    /// The free bytes that the tests give the disk checks.
    let free = OSAllocatedUnfairLock(initialState: Int64.max)

    init() throws {
        folder = try TemporaryFolder()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A window of `tracks` tracks on channel 1 of `duo` with 10 s clips, the counting HAL, and
    /// free bytes from `free`.
    func open(tracks: Int = 1, seconds: Int = 10, name: String? = nil) async throws
        -> (SessionWindow, Studio, NSWindow, SessionChrome)
    {
        var url = try await timelinePackage(
            in: folder.url, tracks: tracks, seconds: seconds, audio: true, device: "duo")
        if let name {
            let renamed = folder.url.appending(path: "\(name).dirigible")
            try FileManager.default.moveItem(at: url, to: renamed)
            url = renamed
        }
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        studio.environment.playerOutput = .offline
        studio.environment.diskCheckInterval = .milliseconds(50)
        let chrome = try #require(model.chrome)
        await until("the toolbar has its items") { chrome.time != nil }
        let free = free
        try await fixFreeSpace(model) { _ in free.withLock { $0 } }
        return (model, studio, try #require(model.window), chrome)
    }

    /// The free bytes that give `seconds` of record time to one mono track at 48 kHz.
    func setFree(seconds: Int) { free.withLock { $0 = diskMargin + Int64(seconds) * 7 * 48_000 } }

    func lowTime(_ model: SessionWindow) -> Bool { model.shown.banners.contains { $0.key == "lowRecordTime" } }

    /// Sets the free space, reads it again, and waits until the window has the new time.
    func read(seconds: Int, _ model: SessionWindow, _ chrome: SessionChrome) async {
        setFree(seconds: seconds)
        chrome.refreshRecordTime()
        await until(limit: .seconds(10), "the read gives \(seconds) s") {
            model.idleRecordTimeLeft == .seconds(seconds)
        }
    }

    // MARK: A12

    @Test func theWindowSubtitleFollowsTheTracks() async throws {
        let (model, studio, window, _) = try await open()
        await until(limit: .seconds(5), "the subtitle has the track count") {
            window.subtitle.contains("\(L10n.subtitleTracks.text) 1")
        }
        #expect(window.subtitle.hasPrefix("48 kHz · \(L10n.subtitleTracks.text) 1"), "\(window.subtitle)")

        model.addTrack()

        #expect(studio.session.tracks.count == 2)
        await until(limit: .seconds(5), "Add Track changes the count") {
            window.subtitle.contains("\(L10n.subtitleTracks.text) 2")
        }
        #expect(window.subtitle.contains("\(L10n.subtitleTracks.text) 2"), "\(window.subtitle)")
        await model.close()
    }

    /// Phase 7 finding (probe P5): the title bar draws the subtitle. A SwiftUI host that bridges
    /// the scene removes the subtitle field from the title bar, and `window.subtitle` keeps its value.
    @Test func theTitleBarShowsTheSubtitle() async throws {
        let (model, _, window, _) = try await open()
        await until(limit: .seconds(5), "the subtitle has the track count") {
            window.subtitle.contains("\(L10n.subtitleTracks.text) 1")
        }
        let frame = try #require(window.contentView?.superview)
        #expect(
            textFields(under: frame).contains { $0.stringValue == window.subtitle && !$0.isHiddenOrHasHiddenAncestor },
            "the title bar has no field with \(window.subtitle)")
        await model.close()
    }

    func textFields(under view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { textFields(under: $0) }
    }

    // MARK: A13

    /// Code gate 1 item 2, plan gate 2 items 4 and 5: a read that hangs holds one pool thread at
    /// most. The first read waits at an async gate; ten triggers during it start no read. After it
    /// ends, one more read runs, and its 5 min stays over the 90 min of the old read.
    @Test func oneRecordTimeReadRunsAtATime() async throws {
        let (model, _, _, chrome) = try await open()
        // No idle tick reads during the test: in a full suite a tick came during the read after
        // the held read and gave one read more (startedAtEnd 5 against 4).
        chrome.startTicker(every: .seconds(3_600))
        await until(limit: .seconds(10), "the reads before the test end") {
            model.idleRecordTimeLeft != nil && chrome.recordTimeReads == chrome.recordTimeReadsStarted
        }
        let gate = AsyncGate()
        var calls = 0
        chrome.readRecordTime = { _ in
            calls += 1
            if calls == 1 {
                await gate.wait()
                return .seconds(5_400)
            }
            return .seconds(300)
        }
        let (started, reads) = (chrome.recordTimeReadsStarted, chrome.recordTimeReads)

        chrome.refreshRecordTime()
        await gate.entered()
        for _ in 0..<10 { chrome.refreshRecordTime() }

        #expect(chrome.recordTimeReadsStarted == started + 1, "a trigger started a second read")
        gate.open()
        var startedAtEnd = 0
        await until(limit: .seconds(5), "the read after the held read ends") {
            startedAtEnd = chrome.recordTimeReadsStarted
            return chrome.recordTimeReads == reads + 2
        }
        #expect(startedAtEnd == started + 2, "the triggers during the held read gave one more read")
        #expect(calls == 2)
        #expect(model.idleRecordTimeLeft == .seconds(300), "the old read wrote over the new one")
        await until(limit: .seconds(5), "the banner follows the new read") { lowTime(model) }
        #expect(model.shown.banners == [.lowRecordTime(minutes: 6)])
        await model.close()
    }

    @Test func theIdleRecordTimeBannerHasHysteresis() async throws {
        let (model, _, _, chrome) = try await open()
        for (seconds, shows) in [(3_700, false), (3_599, true), (3_630, true), (3_660, false)] {
            await read(seconds: seconds, model, chrome)
            await until(limit: .seconds(5), "\(seconds) s: the banner follows") { lowTime(model) == shows }
            #expect(lowTime(model) == shows, "\(seconds) s")
        }
        setFree(seconds: 3_000)
        model.armed = []
        await until(limit: .seconds(5), "no armed track: no read") { model.idleRecordTimeLeft == nil }
        #expect(!lowTime(model), "a banner with no armed track")

        model.armed = ["t1"]

        await until(limit: .seconds(10), "an arm change reads again") { model.idleRecordTimeLeft == .seconds(3_000) }
        await until(limit: .seconds(5), "the banner shows after the arm") { lowTime(model) }
        #expect(lowTime(model))
        await model.close()
    }

    @Test func theTakeRecordTimeBannerHasHysteresis() async throws {
        let (model, studio, _, _) = try await open()
        setFree(seconds: 700)
        await model.record()
        try #require(model.canStop)
        for (seconds, shows) in [(700, false), (599, true), (659, true), (660, false)] {
            setFree(seconds: seconds)
            await until(limit: .seconds(10), "the disk watch gives \(seconds) s") {
                studio.recordTimeLeft == .seconds(seconds)
            }
            await until(limit: .seconds(5), "\(seconds) s in a take: the banner follows") { lowTime(model) == shows }
            #expect(lowTime(model) == shows, "\(seconds) s in a take")
        }
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the finalize ends") { studio.transport == .idle }
        await model.close()
    }

    // MARK: A14

    /// The row takes a gap over the lanes, and the lanes keep the content width, so the row is
    /// not wider than the window. These are NSView frames. The accessibility tree of the SwiftUI
    /// host is empty in some host states of a test process, also on an unlocked screen, so the
    /// row in that tree is manual check M10.
    @Test func theRecordTimeBannerShowsAtTheMinimumWidthWithALongName() async throws {
        let (model, _, window, chrome) = try await open(name: String(repeating: "Interview ", count: 12))
        try #require(window.title.count == 120)
        window.setContentSize(NSSize(width: 500, height: 600))
        await until(limit: .seconds(10), "the window takes its minimum width") {
            window.layoutIfNeeded()
            return window.contentLayoutRect.width == 720
        }
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let lanes = try #require(model.timelineView)
        let gap = {
            window.contentView?.layoutSubtreeIfNeeded()
            // The pane: the overview strip and the lanes (decision 0025); the loudness strip is
            // below the pane (decision 0033).
            return window.contentLayoutRect.height - (model.showsLoudness ? LoudnessStrip.height : 0)
                - (lanes.superview ?? lanes).frame.height
        }
        await until(limit: .seconds(10), "the lanes fill the content") { gap() == 0 }

        await read(seconds: 300, model, chrome)
        await until(limit: .seconds(5), "the banner shows") { lowTime(model) }
        // The padding of the row is 16 pt, and its text adds one line.
        await until(limit: .seconds(10), "the banner row is over the lanes") { gap() > 16 }

        #expect(lowTime(model))
        #expect(gap() > 16, "no banner row over the lanes: the gap is \(gap()) pt")
        #expect(lanes.frame.width == window.contentLayoutRect.width, "the banner row is wider than the window")
        await model.close()
    }

    // MARK: A16

    /// A new banner is announced once, at its priority; record-over and the time display are not.
    @Test func newBannersAreAnnounced() async throws {
        let (model, studio, _, chrome) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        var heard: [String] = []
        chrome.announce = { text, priority in heard.append("\(priority.rawValue) \(text)") }
        let high = NSAccessibilityPriorityLevel.high.rawValue
        chrome.readRecordTime = { _ in .seconds(300) }
        chrome.refreshRecordTime()
        await until(limit: .seconds(5), "the low time is announced") { heard.count == 1 }
        chrome.readRecordTime = { _ in .seconds(180) }
        chrome.refreshRecordTime()
        await until(limit: .seconds(5), "the banner has 4 min") {
            model.shown.banners.contains(.lowRecordTime(minutes: 4))
        }
        studio.play.playbackStop = .outputChanged
        await until(limit: .seconds(5), "the playback stop is announced") { heard.count == 2 }
        studio.missingMedia = ["f1": .missing]
        await until(limit: .seconds(5), "the missing media is announced") { heard.count == 3 }
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        model.timelineView?.viewWillMove(toWindow: nil)
        model.armed = [TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")]
        await studio.perform(.seek(.frame(100_000)))
        await until(limit: .seconds(5), "the record-over warning shows") { model.shown.recordOver }

        #expect(
            heard == [
                "\(high) \(L10n.bannerLowRecordTime.text)", "\(high) \(L10n.transportStopOutputChanged.text)",
                "\(NSAccessibilityPriorityLevel.medium.rawValue) \(L10n.mediaMissing.text)",
            ])
        await model.close()
    }
}
