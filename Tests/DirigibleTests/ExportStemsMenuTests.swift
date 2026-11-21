import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// File > Export Stems... (decision 0078) on a real session window: the scope of the selected tracks
/// and the Marks, the media question, the export sheet, and the no-stem alert. The save panels are
/// stubs that keep their answer until the test gives it, as a panel waits for the click.
@Suite(.serialized) @MainActor struct ExportStemsMenuTests {
    /// The calls of the stem save panel and the count of calls of the mix save panel.
    @MainActor final class Panels {
        var stems: [(message: String, done: @MainActor (StemsTarget?) -> Void)] = []
        var mix = 0
    }

    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    let panels = Panels()

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
        let panels = panels
        app.chooseStemsExport = { _, _, _, _, message, done in panels.stems.append((message, done)) }
        app.chooseExport = { _, _, _, _, _, done in
            panels.mix += 1
            done(nil)
        }
    }

    /// A window of a package with tracks `t1`... of 10 s each (`T1`... by name).
    func window(tracks: Int = 3, audio: Bool = true) async throws -> (SessionWindow, Studio, NSWindow) {
        let package = try await timelinePackage(in: folder.url, tracks: tracks, seconds: 10, audio: audio)
        let model = await app.open(package)
        let studio = try #require(await model.opened() ? model.studio : nil)
        return (model, studio, try #require(model.window))
    }

    func target(_ name: String) -> StemsTarget {
        StemsTarget(
            folder: folder.url.appending(path: name), grouping: .track,
            options: StemOptions(format: .wav(.bits16), layout: .mono, rate: .session))
    }

    func mute(_ muted: Bool, _ tracks: [TrackID], in studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMuted(muted, tracks: tracks)
        }
    }

    /// The names in the folder `name` after a run that the test answered at the stem panel.
    func run(_ model: SessionWindow, _ studio: Studio, into name: String) async throws -> (
        message: String, files: [String]
    ) {
        let before = panels.stems.count
        await model.exportStems()
        try #require(panels.stems.count == before + 1, "the stem panel did not open")
        let call = panels.stems[before]
        call.done(target(name))
        await until("the run ends") {
            guard studio.exportProgress == nil, case .done(let done, _, _)? = model.stemsShown?.outcome else {
                return false
            }
            return done.lastPathComponent == name
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.appending(path: name).path)
        return (call.message, files.sorted())
    }

    @Test func theCommandIsOnOnlyWhenTheScopeHasAStem() async throws {
        let (model, studio, _) = try await window()
        #expect(model.isOn(.exportStems), "no selected track: every track, and each has a clip")

        model.timeline.marks = Marks(inPoint: 960_000, outPoint: 1_200_000, tracks: ["t1"])
        #expect(!model.isOn(.exportStems), "the Marks range has no clip on the selected tracks")
        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 240_000, tracks: ["t1"])
        #expect(model.isOn(.exportStems), "one selected track with a clip in the Marks range")

        try mute(true, ["t1"], in: studio)
        #expect(!model.isOn(.exportStems), "each track of the scope is muted, and t2 and t3 sound")
        model.timeline.marks = Marks()
        #expect(model.isOn(.exportStems), "no selected track: t2 and t3 are heard")
        try mute(true, ["t2", "t3"], in: studio)
        #expect(!model.isOn(.exportStems), "no track is heard")
        try mute(false, ["t1", "t2", "t3"], in: studio)
        #expect(model.isOn(.exportStems))

        model.exportStep = .choosing
        #expect(!model.isOn(.exportStems), "a dialog shows")
        model.exportStep = nil

        studio.environment = hal.environment
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
        }
        await model.record()
        #expect(!model.isOn(.exportStems), "a take records")
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }

        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.removeClips(session.tracks.flatMap { $0.clips.map(\.id) })
        }
        #expect(!model.isOn(.exportStems), "no clip")
        await model.close()
    }

    @Test func theSelectedTracksApplyWithOrWithoutMarks() async throws {
        let (model, studio, _) = try await window(tracks: 5)
        let three: Set<TrackID> = ["t1", "t2", "t3"]
        let names = ["01 T1.wav", "02 T2.wav", "03 T3.wav"]

        model.timeline.marks = Marks(tracks: three)
        let whole = try await run(model, studio, into: "whole")
        #expect(whole.message == L10n.panelStemsScopeWhole.format(3, 5), "3 of 5 selected, no Marks")
        #expect(whole.files == names)
        let wholeFile = try AVAudioFile(forReading: folder.url.appending(path: "whole/01 T1.wav"))
        #expect(wholeFile.length == 480_000, "the whole session")

        model.timeline.marks = Marks(inPoint: 96_000, outPoint: 240_000, tracks: three)
        let marked = try await run(model, studio, into: "marked")
        #expect(marked.message == L10n.panelStemsScopeRange.format(3, 5, "0:02", "0:05"), "with Marks")
        #expect(marked.files == names)
        let markedFile = try AVAudioFile(forReading: folder.url.appending(path: "marked/01 T1.wav"))
        #expect(markedFile.length == 144_000, "the Marks range")

        model.timeline.marks = Marks()
        let all = try await run(model, studio, into: "all")
        #expect(all.message == L10n.panelStemsScopeWhole.format(5, 5), "no selected track")
        #expect(all.files.count == 5)
        await model.close()
    }

    @Test func theRunShowsTheExportSheet() async throws {
        let (model, studio, window) = try await window()
        let hold = FirstChunkHold()
        studio.environment.exportChunk = { hold.step() }
        await model.exportStems()
        try #require(panels.stems.count == 1)
        panels.stems[0].done(target("stems"))

        await until("the export sheet shows") { studio.exportProgress != nil && window.attachedSheet != nil }
        #expect(studio.exportProgress != nil)
        model.cancelExport()
        hold.release()
        await until("the run ends") { studio.exportProgress == nil && model.stemsShown != nil }

        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "stems").path), "no folder")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names == ["timeline.dirigible"], "no staging folder: \(names)")
        #expect(model.alert == nil)
        #expect(ChromeState.reportBanners(model, studio).contains(.stemsStopped), "the stop banner")
        await model.close()
    }

    @Test func anEditThatLeavesNoStemGivesTheNoStemAlert() async throws {
        let (model, studio, _) = try await window()
        let missing = ["t1", "t2", "t3"] as [TrackID]
        let alert = WindowAlert.error(.exportStems(.noStem))
        #expect(L10n.message(for: .exportStems(.noStem)) == L10n.errorExportNoStem.text, "its own text")

        await model.exportStems()
        try #require(panels.stems.count == 1)
        try mute(true, missing, in: studio)
        panels.stems[0].done(target("late"))
        await until("the alert shows") { model.alert != nil }
        #expect(model.alert == alert, "an edit while the panel shows gives the alert after the panel")
        #expect(!FileManager.default.fileExists(atPath: folder.url.appending(path: "late").path))

        model.alert = nil
        try mute(false, missing, in: studio)
        let gate = AsyncGate()
        studio.environment.beforeMediaCheck = { await gate.wait() }
        let check = Task { await model.exportStems() }
        await gate.entered()
        try mute(true, missing, in: studio)
        gate.open()
        await check.value

        #expect(model.alert == alert, "an edit during the media check gives the alert in place of the panel")
        #expect(panels.stems.count == 1, "the stem panel did not open again")
        #expect(model.exportStep == nil)
        await model.close()
    }

    @Test func aMediaFaultAsksThenOpensTheStemPanel() async throws {
        let (model, _, _) = try await window(audio: false)

        await model.exportStems()

        guard case .asking(_, let faults, let panel) = model.exportStep else {
            Issue.record("No question: \(String(describing: model.exportStep))")
            return
        }
        #expect(faults == ["f1": .missing] && panel == .stems)
        #expect(model.isAskingExportQuestion && model.exportQuestionPaths == ["f1.wav"])
        #expect(panels.stems.isEmpty && panels.mix == 0)
        model.answerExportQuestion(export: true)
        #expect(panels.stems.count == 1 && panels.mix == 0, "the Export answer opens the stem panel")
        await model.close()
    }

    @Test func aCancelOfTheStemQuestionKeepsExportOnTheMixPanel() async throws {
        let (model, _, _) = try await window(audio: false)

        await model.exportStems()
        model.answerExportQuestion(export: false)
        #expect(model.exportStep == nil && panels.stems.isEmpty && panels.mix == 0)

        await model.export(.session)
        guard case .asking(_, _, let panel) = model.exportStep else {
            Issue.record("No question: \(String(describing: model.exportStep))")
            return
        }
        #expect(panel == .mix)
        model.answerExportQuestion(export: true)
        #expect(panels.mix == 1 && panels.stems.isEmpty, "the mix panel opens, not the stem panel")
        await model.close()
    }
}
