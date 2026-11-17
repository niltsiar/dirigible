import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Match Voice in the session window: the states of the mark, the reference, the menu rules, the
/// banners, and the one undo entry of each change (decision 0074, criteria C11, C17, C20 to C24).
/// The tracks t1 and t2 each hold the clip c<n> of 20 s of the file `f1` (name "f1").
@Suite(.serialized) @MainActor struct MatchVoiceWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open(seconds: Int = 20) async throws -> (SessionWindow, Studio) {
        let package = try await timelinePackage(in: folder.url, tracks: 2, seconds: seconds, noise: true)
        let (model, studio, _, _) = try await openLanes(app, package)
        return (model, studio)
    }

    /// A match with a curve that has +8.4 dB and -6.2 dB, as C24 states.
    func match(_ percent: Int = 75, reference: String = "Dani", bypassed: Bool = false) throws -> VoiceMatch {
        var curve = Array(repeating: 0.0, count: 25)
        (curve[10], curve[20]) = (8.4, -6.2)
        let amount = try #require(VoiceMatch.Amount(percent))
        return try VoiceMatch(
            amount: amount, isBypassed: bypassed, reference: reference, curve: curve,
            targetPowers: Array(repeating: 1, count: 25))
    }

    func give(_ match: VoiceMatch, to track: TrackID, _ studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setMatch([track: match]) }
    }

    func amount(_ track: TrackID, _ studio: Studio) -> Int? { studio.session.track(track)?.match?.amount.percent }

    /// C21: the five states of the mark and the values that VoiceOver reads, in English and Spanish.
    /// No match and no read: no mark.
    @Test func statesAndValues() throws {
        let tables = try ["en", "es"].map { try stringsTable($0) }
        func value(_ state: MatchMarkState?, _ table: [String: String]) -> String? {
            state?.value { table[$0.rawValue] ?? $0.rawValue }
        }
        #expect(MatchMarkState(nil, learning: false) == nil, "no match: no mark")
        let on = MatchMarkState(try match(75), learning: false)
        let off = MatchMarkState(try match(75, bypassed: true), learning: false)
        let learning = MatchMarkState(try match(75), learning: true)
        #expect(on == .matched(try #require(VoiceMatch.Amount(75))) && off == .bypassed && learning == .learning)
        #expect(MatchMarkState(nil, learning: true) == .learning, "a first match shows the read")
        #expect(value(on, tables[0]) == "Matched, 75%" && value(off, tables[0]) == "Matched, off")
        #expect(value(learning, tables[0]) == "Learning the voice")
        #expect(value(on, tables[1]) == "Igualada, 75%", "the percent is in the format of the locale")
        #expect(value(off, tables[1]) == "Igualada, desactivada")
        func help(_ state: MatchMarkState?, _ table: [String: String]) -> String? {
            state?.help(reference: "Dani") { table[$0.rawValue] ?? $0.rawValue }
        }
        #expect(
            help(on, tables[0]) == "Voice matched to Dani, 75%" && help(off, tables[0]) == "Voice matched to Dani, off")
    }

    /// C24: the popover line gives the largest boost and cut of the stored curve at the amount, to
    /// 0.1 dB, with no loudness offset. The near input, 49, rounds each value on its own. A curve
    /// with no cut shows 0.0 dB.
    @Test func popoverShowsTheStoredCurve() throws {
        let en = try stringsTable("en")
        func title(_ match: VoiceMatch) -> String {
            match.title(locale: Locale(identifier: "en_US")) { en[$0.rawValue] ?? $0.rawValue }
        }
        #expect(title(try match(50)) == "Matched to Dani (+4.2 dB, -3.1 dB)")
        #expect(title(try match(49)) == "Matched to Dani (+4.1 dB, -3.0 dB)")
        let flat = try VoiceMatch(
            amount: try #require(.init(100)), reference: "Dani", curve: Array(repeating: 3.0, count: 25),
            targetPowers: Array(repeating: 1, count: 25))
        #expect(title(flat) == "Matched to Dani (+3.0 dB, 0.0 dB)")
    }

    /// C20 and C17: a clip set of one clip, and a range on one track inside one clip, give a
    /// reference. A range keeps its frames. Two clips, a range over two clips, and a gap give none.
    @Test func referenceKeepsTheRange() async throws {
        let (model, studio) = try await open()
        func reference(_ selection: Selection) -> VoiceReference? {
            VoiceReference(selection, in: studio.session)
        }
        let clip = ClipSet(["c1"]).map { Selection.clips($0) } ?? .none
        #expect(reference(clip) == VoiceReference(clip: "c1", span: nil, name: "f1"))
        let inside = Selection.range(Marks(inPoint: 48_000, outPoint: 480_000, tracks: ["t1"]))
        #expect(
            reference(inside)
                == VoiceReference(clip: "c1", span: .init(file: "f1", frames: 48_000..<480_000), name: "f1"))
        let two = ClipSet(["c1", "c2"]).map { Selection.clips($0) } ?? .none
        #expect(reference(two) == nil, "two clips")
        #expect(reference(.range(Marks(inPoint: 0, outPoint: 100, tracks: ["t1", "t2"]))) == nil, "two tracks")
        #expect(reference(.range(Marks(inPoint: 0, outPoint: 100))) == nil, "no track")
        #expect(
            reference(
                .range(Marks(inPoint: Frames(20 * 48_000 - 10), outPoint: Frames(20 * 48_000 + 10), tracks: ["t1"])))
                == nil)
        #expect(reference(.range(Marks(tracks: ["t1"]))) == nil, "a track only")

        model.timeline.selection = inside
        model.useAsVoiceReference()
        model.timeline.selection = clip
        #expect(model.voiceReference?.span?.frames == 48_000..<480_000, "a later selection keeps the range")
        await model.close()
    }

    /// C17: Use as Voice Reference is on for one clip and off for two clips; Match Voice to the
    /// reference is off with no reference, with a take, and when the reference clip is gone. Bypass
    /// and Remove are off for a track with no match.
    @Test func menuStates() async throws {
        let (model, studio) = try await open()
        let clip = ClipSet(["c1"]).map { Selection.clips($0) } ?? .none
        model.timeline.selection = clip
        #expect(model.isOn(.useAsVoiceReference))
        model.timeline.selection = ClipSet(["c1", "c2"]).map { Selection.clips($0) } ?? .none
        #expect(!model.isOn(.useAsVoiceReference))
        model.timeline.selection = .none
        #expect(!model.isOn(.useAsVoiceReference))

        #expect(model.activeVoiceReference == nil && !model.canMatchVoice(tracks: ["t2"]), "no reference")
        model.timeline.selection = clip
        model.run(.useAsVoiceReference)
        #expect(model.activeVoiceReference?.name == "f1" && model.canMatchVoice(tracks: ["t2"]))
        #expect(!model.canMatchVoice(tracks: []), "no track")
        #expect(!model.canChangeMatch(tracks: ["t2"]), "Bypass and Remove need a match")
        try give(try match(), to: "t2", studio)
        #expect(model.canChangeMatch(tracks: ["t2"]) && !model.canChangeMatch(tracks: ["t1"]))
        studio.transport = .recording(take: 1)
        #expect(!model.canMatchVoice(tracks: ["t2"]) && !model.canChangeMatch(tracks: ["t2"]), "a take")
        studio.transport = .idle
        try studio.edit(ripple: false) { session throws(SessionError) in try session.removeClips(["c1"]) }
        #expect(model.activeVoiceReference == nil, "the reference clip is gone")
        await model.close()
    }

    /// C11 and C17: a match from the window takes amount 75, is one undo entry, gives a banner with
    /// the count and the extremes, and a second match keeps the amount of the track.
    @Test func matchIsOneEntryWithABanner() async throws {
        let (model, studio) = try await open()
        let before = studio.session
        model.timeline.selection = ClipSet(["c1"]).map { Selection.clips($0) } ?? .none
        model.useAsVoiceReference()

        await model.matchVoice(tracks: ["t2"])

        let first = studio.session
        #expect(model.alert == nil && amount("t2", studio) == 75, "\(String(describing: model.alert))")
        #expect(first.track("t2")?.match?.reference == "f1" && first.track("t1")?.match == nil)
        #expect(model.matchingTracks.isEmpty && model.matchProgress == nil, "the read ends")
        await until("the banner shows") { model.shown.banners.contains { $0.key == "voiceMatch.1" } }
        let banner = try #require(model.shown.banners.first { $0.key == "voiceMatch.1" })
        #expect(banner.kind == .info && banner.announcement == .medium)
        try studio.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo step")
        try studio.redo()
        #expect(studio.session == first, "redo")

        let forty = try #require(VoiceMatch.Amount(40))
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMatchAmount(forty, tracks: ["t2"])
        }
        await model.matchVoice(tracks: ["t2"])
        #expect(amount("t2", studio) == 40, "a replace keeps the amount")
        await model.close()
    }

    /// C21: during the read, only the target tracks show the learn mark. The track of the reference
    /// clip and a music track of the selection are no target.
    @Test func onlyTargetTracksShowTheLearnMark() async throws {
        let (model, studio) = try await open()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addTrack("t3", name: "Music", layout: .mono)
        }
        model.setRole(.music, tracks: ["t3"])
        model.timeline.selection = ClipSet(["c1"]).map { Selection.clips($0) } ?? .none
        model.useAsVoiceReference()
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }

        let matching = Task { await model.matchVoice(tracks: ["t1", "t2", "t3"]) }
        await gate.entered()
        #expect(model.matchingTracks == ["t2"], "the read: \(model.matchingTracks)")
        gate.open()
        await matching.value
        studio.environment.beforeFinalize = {}

        #expect(studio.session.track("t2")?.match != nil && model.matchingTracks.isEmpty, "the read ends")
        await model.close()
    }

    /// C23: a reference range with too little voice shows a warning banner that names the reference,
    /// and nothing is stored. A track with no clip shows the banner that names the track.
    @Test func refusalNamesTheFailingSide() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 96_000, tracks: ["t1"]))
        model.useAsVoiceReference()
        let before = studio.session
        let revision = studio.sessionRevision

        await model.matchVoice(tracks: ["t2"])

        #expect(studio.session == before && studio.sessionRevision == revision, "nothing stored")
        await until("the banner shows") { model.shown.banners.contains { $0.key == "voiceMatchRefused.1" } }
        let banner = try #require(model.shown.banners.first { $0.key.hasPrefix("voiceMatchRefused") })
        #expect(banner.kind == .warning && banner.announcement == .medium)
        #expect(banner.text == L10n.matchRefusedReference.text, "the reference side: \(banner.text)")
        #expect(model.alert == nil)

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addTrack("t3", name: "Guest", layout: .mono)
        }
        model.timeline.selection = ClipSet(["c1"]).map { Selection.clips($0) } ?? .none
        model.useAsVoiceReference()
        await model.matchVoice(tracks: ["t3"])
        await until("the track banner shows") { model.shown.banners.contains { $0.key == "voiceMatchRefused.2" } }
        let track = try #require(model.shown.banners.last { $0.key.hasPrefix("voiceMatchRefused") })
        #expect(track.text == L10n.matchRefusedTrack.text, "the track side: \(track.text)")
        #expect(track.text != banner.text)
        await model.close()
    }

    /// C23: the refusal texts of the reference and of a track, in English and Spanish. The track text
    /// has the quote marks of the table. The seconds are the whole seconds of the studio.
    @Test func refusalTextsNameTheSide() throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        func text(_ key: L10n, _ table: [String: String], _ values: CVarArg...) -> String {
            String(format: table[key.rawValue] ?? key.rawValue, arguments: values)
        }
        #expect(
            text(.matchRefusedReference, en, 6, 10)
                == "The reference clip has 6 s of voice. Match Voice needs 10 s. "
                + "Choose a longer clip or a longer range.")
        #expect(
            text(.matchRefusedReference, es, 6, 10)
                == "El clip de referencia tiene 6 s de voz. Igualar voz necesita 10 s. "
                + "Elige un clip m\u{E1}s largo o un intervalo m\u{E1}s largo.")
        #expect(
            text(.matchRefusedTrack, en, "Guest", 6, 10)
                == "The track \u{201C}Guest\u{201D} has 6 s of voice. Match Voice needs 10 s.")
    }

    /// C11: a slider drag from 75 to 40 through 20 preview values makes one entry at the mouse-up.
    /// The preview changes no revision. A drag that ends at its start value makes no entry.
    @Test func amountDragIsOneUndoStep() async throws {
        let (model, studio) = try await open()
        try give(try match(75), to: "t2", studio)
        let before = studio.session
        let revision = studio.sessionRevision

        for step in 0..<20 { model.previewMatchAmount(75 - (step + 1) * 35 / 20, track: "t2") }
        #expect(studio.sessionRevision == revision, "no edit while the drag runs")
        #expect(model.commitMatchAmount(40, track: "t2"))

        #expect(amount("t2", studio) == 40 && studio.sessionRevision == revision + 1)
        try studio.undo()
        #expect(studio.session == before, "one undo gives 75")
        let undone = studio.sessionRevision
        #expect(!model.commitMatchAmount(75, track: "t2"), "a drag that ends at its start")
        #expect(studio.sessionRevision == undone, "no entry")
        await model.close()
    }

    /// C11 and C24: a double-click on the slider sets 75. It joins the edit of its first click, so
    /// the two clicks are one undo step. After another edit, it is an edit of its own.
    @Test func doubleClickResetJoinsTheEdit() async throws {
        let (model, studio) = try await open()
        try give(try match(50), to: "t2", studio)
        let before = studio.session

        #expect(model.commitMatchAmount(60, track: "t2"))
        model.resetMatchAmount("t2", joining: studio.sessionRevision)
        #expect(amount("t2", studio) == 75)
        try studio.undo()
        #expect(studio.session == before && amount("t2", studio) == 50, "one undo step")

        model.resetMatchAmount("t2", joining: studio.sessionRevision - 1)
        #expect(amount("t2", studio) == 75, "an edit of its own")
        try studio.undo()
        #expect(amount("t2", studio) == 50)
        await model.close()
    }

    /// C11 and C24: `MatchSlider.mouseDown` with a click count of 2 sets 75 as one undo step. The
    /// Option-click does the same with a click count of 1. A mouse-down with a click count of 2 or
    /// with Option returns before the modal drag loop, so the test sends real events.
    @Test func aDoubleClickOnTheSliderResetsTheAmount() async throws {
        let (model, studio) = try await open()
        try give(try match(40), to: "t2", studio)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let view = MatchAmountView()
        window.contentView?.addSubview(view)
        func click(count: Int, flags: NSEvent.ModifierFlags = []) throws {
            view.update(model: model, track: "t2", percent: amount("t2", studio) ?? 0, enabled: true)
            let point = view.slider.convert(NSPoint(x: 10, y: view.slider.bounds.midY), to: nil)
            view.slider.mouseDown(
                with: try #require(
                    NSEvent.mouseEvent(
                        with: .leftMouseDown, location: point, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: count, pressure: 1)))
        }
        let before = studio.session
        let revision = studio.sessionRevision

        try click(count: 2)
        #expect(amount("t2", studio) == 75 && studio.sessionRevision == revision + 1, "one edit")
        try studio.undo()
        #expect(studio.session == before, "one undo gives 40")

        try click(count: 1, flags: .option)
        #expect(amount("t2", studio) == 75, "an Option-click sets 75")
        try studio.undo()
        #expect(studio.session == before, "one undo gives 40")
        window.close()
        await model.close()
    }

    /// A press off the thumb places the knob under the click with no `NSSliderCell` animation, which
    /// wrote the click value about 0.5 s after a double-click reset. The amount at a point is the
    /// inverse of the knob placement, at each value, so the knob lands under the click. The tracking
    /// loop needs real events (a posted mouse-up ends the test process), so the double-click is
    /// checked on screen.
    @Test func aClickOffTheThumbPlacesTheKnobUnderTheClick() throws {
        let slider = MatchAmountView().slider
        let cell = try #require(slider.cell as? NSSliderCell)
        for percent in [1.0, 2.0, 25.0, 50.0, 75.0, 99.0, 100.0] {
            slider.doubleValue = percent
            let center = cell.knobRect(flipped: slider.isFlipped).midX
            #expect(abs(slider.amount(atX: center) - percent) < 0.6, "the knob of \(percent) % is at \(center)")
        }
        #expect(
            slider.amount(atX: -30) == 1 && slider.amount(atX: 500) == 100, "a drag outside the slider stops at an end")
    }

    /// C11 and C17: Bypass on, Bypass off, and Remove are one undo entry each, over the tracks that
    /// have a match. The bypass of a mix of matched and plain tracks changes only the matched ones,
    /// and a change of plain tracks only makes no entry.
    @Test func bypassAndRemoveAreOneEntryEach() async throws {
        let (model, studio) = try await open()
        try give(try match(), to: "t2", studio)
        let matched = studio.session
        var revision = studio.sessionRevision

        model.setMatchBypassed(true, tracks: ["t1", "t2"])
        #expect(studio.session.track("t2")?.match?.isBypassed == true && model.alert == nil)
        #expect(studio.sessionRevision == revision + 1)
        try studio.undo()
        #expect(studio.session == matched, "one undo")
        try studio.redo()
        revision = studio.sessionRevision
        model.setMatchBypassed(false, tracks: ["t2"])
        #expect(studio.session.track("t2")?.match?.isBypassed == false && studio.sessionRevision == revision + 1)

        revision = studio.sessionRevision
        model.removeMatch(tracks: ["t2"])
        #expect(studio.session.track("t2")?.match == nil && studio.sessionRevision == revision + 1)
        try studio.undo()
        #expect(studio.session == matched, "undo brings the match back")
        revision = studio.sessionRevision
        model.setMatchBypassed(true, tracks: ["t1"])
        model.removeMatch(tracks: ["t1"])
        #expect(studio.sessionRevision == revision && model.alert == nil, "no entry for a track with no match")
        await model.close()
    }
}
