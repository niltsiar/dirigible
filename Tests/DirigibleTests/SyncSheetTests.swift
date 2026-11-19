import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A package for the sync tests of the app, at 48 kHz: track t1 "Host" holds clip "C" (file `c`, 8 s) at
/// `clipStart` s, and track t2 "Guest" holds clip "R" (file `r`, 40 s of stepped noise). The audio of
/// `c` is `r` from 20 s at half gain, so a sync moves C to 20 s. With `unrelated`, `r` is other noise
/// and no sync matches. With `neighbor`, t1 also holds clip "N" (file `r`, 7 s) at 23 s. Both tracks
/// route to channel 1 of `duo`. Each call makes a new package.
@concurrent nonisolated func syncWindowPackage(
    in folder: URL, clipStart: Int = 5, unrelated: Bool = false, neighbor: Bool = false
) async throws -> URL {
    let rate = 48_000
    func noise(seed: UInt64, seconds: Int) -> [Float] {
        var state = seed
        return (0..<seconds * rate).map { frame in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let level = [0.1, 0.5, 0.9, 0.3][(frame / 24_000) % 4]
            return Float(level * (Double(state >> 11) / Double(1 << 53) * 2 - 1))
        }
    }
    let url = folder.appending(path: "\(UUID().uuidString)/sync.dirigible")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Session.create(at: url, sampleRate: rate)
    let reference = noise(seed: 1, seconds: 40)
    let clip = reference[20 * rate..<28 * rate].map { $0 * 0.5 }
    for (file, samples) in [("r", unrelated ? noise(seed: 9, seconds: 40) : reference), ("c", Array(clip))] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        let writer = try ClipWriter(
            url: url.appending(path: "\(clipsFolderName)/\(file).wav"), file: "\(file).wav", format: format)
        try writer.write(buffer)
        try writer.close()
    }
    var session = Session(sampleRate: rate)
    try session.addFile(AudioFile(id: "r", path: "r.wav", layout: .mono, length: Frames(40 * rate)))
    try session.addFile(AudioFile(id: "c", path: "c.wav", layout: .mono, length: Frames(8 * rate)))
    for (id, name) in [("t1", "Host"), ("t2", "Guest")] {
        try session.addTrack(TrackID(id), name: name, layout: .mono)
        try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: TrackID(id))
    }
    try session.place(
        Clip(id: "C", file: "c", start: Frames(clipStart * rate), offset: 0, length: Frames(8 * rate)), on: "t1")
    try session.place(Clip(id: "R", file: "r", start: 0, offset: 0, length: Frames(40 * rate)), on: "t2")
    if neighbor {
        try session.place(
            Clip(id: "N", file: "r", start: Frames(23 * rate), offset: 0, length: Frames(7 * rate)), on: "t1")
    }
    try session.write(to: url)
    return url
}

/// Criteria C13, C19, and C22 of decision 0076: Tools > Sync Clip to Track... on a real session window,
/// on the package of `syncWindowPackage`.
@Suite(.serialized) @MainActor struct SyncSheetTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    static let english = Result { try stringsTable("en") }
    static let us = Locale(identifier: "en_US")

    init() throws { folder = try TemporaryFolder() }

    func englishText(_ key: L10n) -> String { (try? Self.english.get())?[key.rawValue] ?? key.rawValue }

    /// Opens the package, with `edit` written to it before the open, so no undo entry has it.
    func open(
        clipStart: Int = 5, edit: (inout Session) throws -> Void = { _ in }
    ) async throws -> (SessionWindow, Studio, TimelineScrollView) {
        let url = try await syncWindowPackage(in: folder.url, clipStart: clipStart)
        var session = try Session(contentsOf: url)
        try edit(&session)
        try session.write(to: url)
        let (model, studio, _, view) = try await openLanes(app, url)
        return (model, studio, view)
    }

    func select(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    /// C13: the item is on only with one clip selected, another track with a clip in the default span,
    /// and an idle studio. Control: with no take guard a running take turns it on; with no clip check a
    /// range or two clips do.
    @Test func theItemIsOnOnlyWithOneClipAndAnotherTrack() async throws {
        let (model, _, _) = try await open()
        model.timeline.selection = select("C")
        #expect(model.isOn(.syncClip), "one clip and another track with a clip")
        model.timeline.selection = .none
        #expect(!model.isOn(.syncClip), "no selection")
        model.timeline.selection = select("C", "R")
        #expect(!model.isOn(.syncClip), "two clips")
        model.timeline.selection = .range(Marks(inPoint: 240_000, outPoint: 480_000, tracks: ["t1"]))
        #expect(!model.isOn(.syncClip), "a range over the clip")
        await model.close()

        let (single, _, _) = try await open { try $0.removeTrack("t2") }
        single.timeline.selection = select("C")
        #expect(!single.isOn(.syncClip), "one track only")
        await single.close()

        let (far, _, _) = try await open { session in
            try session.nudge(["R"], by: Frames(4_000 * 48_000))
        }
        far.timeline.selection = select("C")
        #expect(!far.isOn(.syncClip), "the other track has no clip in the default span")
        await far.close()

        let (taking, running, _) = try await open()
        running.environment = hal.environment
        taking.timeline.selection = select("C")
        await taking.record()
        #expect(running.transport == .recording(take: 1))
        #expect(!taking.isOn(.syncClip), "a take runs")
        taking.run(.syncClip)
        #expect(taking.syncDraft == nil, "a take runs: the key opened the sheet")
        await taking.stop()
        await until("the take finalizes") { running.transport == .idle }
        #expect(taking.isOn(.syncClip), "after the take")
        await taking.close()
    }

    /// C13: the command opens the sheet with the reference of `Session.defaultSyncReference(for:)`.
    @Test func theCommandOpensTheSheetWithTheDefaultReference() async throws {
        let (model, studio, _) = try await open()
        model.timeline.selection = select("C")
        model.run(.syncClip)
        let draft = try #require(model.syncDraft, "the command opened no sheet")
        #expect(draft.clip == "C" && draft.reference == studio.session.defaultSyncReference(for: "C"))
        #expect(draft.reference == "t2")
        await model.close()
    }

    /// C19: a row shows the track name and its role; a track with no role shows its name only.
    @Test func eachRowShowsTheRole() async throws {
        let (model, studio, _) = try await open { session in
            try session.setRole(.dialogue, tracks: ["t2"])
            try session.addTrack("t3", name: "Extra", layout: .mono)
        }
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        let rows = draft.rows(in: studio.session, text: englishText)
        #expect(rows.map(\.id) == ["t2", "t3"] && rows.map(\.text) == ["Guest (Dialogue)", "Extra"], "\(rows)")
        await model.close()
    }

    /// C19: the span line gives the `within` that the sync uses, in whole minutes rounded down. A clip of
    /// 5400 s in a session of 9000 s clamps the search to 1464.3 s.
    @Test func theSpanLineShowsTheWithinThatTheSyncUses() async throws {
        let (model, studio, _) = try await open()
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        #expect(
            draft.spanLine(in: studio.session, locale: Self.us, text: englishText)
                == "Searches 30 minutes before and after the clip.")
        await model.close()

        let (long, longStudio, _) = try await open { session in
            for (id, seconds) in [("long", 5_400), ("big", 9_000)] {
                try session.addFile(
                    AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: Frames(seconds * 48_000)))
            }
            try session.addTrack("t3", name: "Big", layout: .mono)
            try session.place(
                Clip(id: "L", file: "long", start: Frames(1_800 * 48_000), offset: 0, length: Frames(5_400 * 48_000)),
                on: "t1")
            try session.place(Clip(id: "B", file: "big", start: 0, offset: 0, length: Frames(9_000 * 48_000)), on: "t3")
        }
        let clamped = try #require(SyncDraft(clip: "L", in: longStudio.session))
        #expect(
            clamped.spanLine(in: longStudio.session, locale: Self.us, text: englishText)
                == "Searches 24 minutes before and after the clip.")
        await long.close()
    }

    /// C19: a span under 1 minute shows in whole seconds, and a longer span in whole minutes, rounded
    /// down. One unit is singular. A clip at the span cap can get a `within` of 0.
    @Test func theSpanTextGivesSecondsUnderAMinuteAndTheSingularOfOne() throws {
        let spanish = try stringsTable("es")
        let rate = 48_000
        let cases: [(frames: Int, english: String, spanish: String)] = [
            (0, "0 seconds", "0 segundos"),
            (rate, "1 second", "1 segundo"),
            (60 * rate - 1, "59 seconds", "59 segundos"),
            (60 * rate, "1 minute", "1 minuto"),
            (120 * rate - 1, "1 minute", "1 minuto"),
            (120 * rate, "2 minutes", "2 minutos"),
            (1_800 * rate, "30 minutes", "30 minutos"),
        ]
        for (frames, english, spanishSpan) in cases {
            let within = Frames(frames)
            #expect(
                syncSpanText(within: within, rate: rate, locale: Self.us, text: englishText)
                    == "Searches \(english) before and after the clip.")
            #expect(
                syncSpanText(within: within, rate: rate, locale: Locale(identifier: "es_ES")) {
                    spanish[$0.rawValue] ?? $0.rawValue
                } == "Busca \(spanishSpan) antes y después del clip.")
        }
    }

    /// C19: the no-call-track line shows with no app route, and not with one.
    @Test func theNoCallTrackLineShowsOnlyWithNoAppRoute() async throws {
        let (plain, plainStudio, _) = try await open()
        let draft = try #require(SyncDraft(clip: "C", in: plainStudio.session))
        #expect(
            draft.noCallLine(in: plainStudio.session, text: englishText)
                == "No call track: the first track with audio is chosen.")
        await plain.close()

        let (call, callStudio, _) = try await open { session in
            try session.setRoute(Route.app(bundleID: "us.zoom.xos"), track: "t2")
        }
        let preset = try #require(SyncDraft(clip: "C", in: callStudio.session))
        #expect(preset.noCallLine(in: callStudio.session, text: englishText) == nil)
        await call.close()
    }

    /// C13: Sync is off with the reason while the reference track has no clip in the search span.
    @Test func aReferenceWithNoAudioNearTheClipIsRefused() async throws {
        let (model, studio, _) = try await open { session in
            try session.addTrack("t3", name: "Empty", layout: .mono)
        }
        var draft = try #require(SyncDraft(clip: "C", in: studio.session))
        #expect(draft.refusal(in: studio.session) == nil)
        draft.reference = "t3"
        #expect(draft.refusal(in: studio.session) == .noReferenceAudio)
        await model.close()
    }

    /// C22: the view scrolls only when no frame of the new range is in view, then to the new start.
    @Test func theRevealRuleFollowsTheShownFrames() {
        let shown = (origin: 100_000.0, visible: 480_000.0)
        func target(_ range: Range<Frames>) -> Frames? {
            syncRevealFrame(of: range, origin: shown.origin, visibleFrames: shown.visible)
        }
        #expect(target(200_000..<400_000) == nil, "a clip that stays in view")
        #expect(target(50_000..<150_000) == nil, "a clip that overlaps the left edge")
        #expect(target(570_000..<900_000) == nil, "a clip that overlaps the right edge")
        #expect(target(580_000..<900_000) == 580_000, "a clip right of the view")
        #expect(target(0..<100_000) == 0, "a clip that ends at the left edge")
        #expect(target(5_904_000..<6_288_000) == 5_904_000, "a clip 2 min past the right edge")
    }

    /// C22: a sync that keeps the clip in view keeps the view origin; a sync that moves the clip out of
    /// view scrolls to its new start. The selection and the playhead stay in both.
    @Test func theViewScrollsOnlyWhenTheClipLeavesIt() async throws {
        let (model, studio, view) = try await open()
        model.timeline.selection = select("C")
        let origin = view.origin
        #expect(view.visibleFrames > 40 * 48_000.0 - 1, "the fit shows the 40 s session")
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        await model.sync(draft)
        #expect(studio.session.clip("C")?.clip.start == 960_000 && model.alert == nil, "the clip is not at 20 s")
        #expect(view.origin == origin, "the view scrolled for a clip in view: \(view.origin)")
        await model.close()

        let (far, farStudio, farView) = try await open()
        far.timeline.selection = select("C")
        farView.navigate(.zoomTo(Zoom(scale: TimelineScale(framesPerPoint: 100), origin: 0), stroke: .changed))
        #expect(farView.origin == 0 && farView.visibleFrames < 5 * 48_000, "the zoom: \(farView.visibleFrames)")
        let farDraft = try #require(SyncDraft(clip: "C", in: farStudio.session))
        await far.sync(farDraft)
        #expect(farStudio.session.clip("C")?.clip.start == 960_000 && far.alert == nil)
        #expect(
            farView.origin <= 960_000 && 960_000 < farView.origin + farView.visibleFrames,
            "the view did not show the new start: \(farView.origin)")
        await far.close()
    }

    /// C22: after a sync the clip stays selected and the playhead frame does not change.
    @Test func thePlayheadAndTheSelectionStay() async throws {
        let (model, studio, _) = try await open()
        model.timeline.selection = select("C")
        await studio.perform(.seek(.frame(123_456)))
        let playhead = studio.playhead
        let selection = model.timeline.selection
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        await model.sync(draft)
        #expect(studio.session.clip("C")?.clip.start == 960_000)
        #expect(studio.playhead == playhead && playhead == 123_456, "the playhead moved: \(studio.playhead)")
        #expect(model.timeline.selection == selection, "the selection changed")
        await model.close()
    }
}
