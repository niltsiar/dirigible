import AVFoundation
import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Run 2026-10-12-autolevel-fader C2, C5, C11, C12: the result banner of Auto Level on a real
/// session window. The tests are in the serialized suite `AutoLevelWindowTests` and use its
/// fixture.
extension AutoLevelWindowTests {
    static let oneSecondOnT1 = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])

    /// The level banner that the window shows now, or nil.
    func levelBanner(_ model: SessionWindow) -> WindowBanner? {
        model.shown.banners.first { $0.key.hasPrefix("levelReport") }
    }

    /// C11: each press is announced, also a second press with the same report. The first press
    /// changes a clip, so VoiceOver hears the count and no banner shows. The next two presses change
    /// nothing, so each shows its banner.
    @Test func eachLevelIsAnnounced() async throws {
        let (model, _, _, _) = try await open()
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        model.timeline.marks = Self.oneSecondOnT1
        for press in 1...3 {
            await model.level(.eachClip)
            if press > 1 {
                await until("press \(press) shows its banner") { levelBanner(model)?.key == "levelReport.\(press)" }
            }
        }
        let none = WindowBanner.levelReport(LevelReport(changed: 0, atLimit: 0, unmeasured: 0), press: 2).text
        #expect(heard.count(where: { $0 == none }) == 2, "announcements: \(heard)")
        #expect(heard.count(where: { $0 == L10n.announceLevelChangedOne.text }) == 1, "announcements: \(heard)")
        #expect(heard.count == 3, "announcements: \(heard)")
        await model.close()
    }

    /// C9 (d): an Auto Level that changes 3 clips, none at the limit, shows no banner, because the
    /// lanes show the new gains. VoiceOver hears the count once.
    @Test func autoLevelWithNoWarningShowsNoBannerAndIsAnnounced() async throws {
        let (model, studio, _, _) = try await open()
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000)

        await model.level(.eachClip)

        let clips: [ClipID] = ["c1", "c2", "c3"]
        let leveled = clips.filter { studio.session.clip($0)?.clip.gain != .zero }
        #expect(leveled == clips, "the level changed \(leveled)")
        let text = L10n.announceLevelChanged.format(3)
        #expect(heard.count(where: { $0 == text }) == 1, "VoiceOver hears the count once: \(heard)")
        let banners = ChromeState.reportBanners(model, studio)
        #expect(!banners.contains { $0.key.hasPrefix("levelReport") }, "a plain change has no banner: \(banners)")
        await model.close()
    }

    /// C9 (d), near input: a clip that needs more than the 20 dB limit gets the limit, so the banner
    /// asks for a check, as a warning. VoiceOver hears the count and then the banner.
    @Test func autoLevelWithAClipAtTheLimitShowsTheWarning() async throws {
        let (model, studio, _, _) = try await openLanes(app, try await Self.quietPackage(in: folder.url))
        var heard: [String] = []
        model.chrome?.announce = { text, _ in heard.append(text) }
        model.timeline.selection = ClipSet(["q"]).map { Selection.clips($0) } ?? .none

        await model.level(.eachClip)

        await until("the banner shows") { levelBanner(model) != nil }
        let banner = try #require(levelBanner(model))
        #expect(banner.kind == .warning && banner.text == L10n.bannerLevelLimitOne.text, "\(banner)")
        #expect((studio.session.clip("q")?.clip.gain.dB ?? 0) > 19, "the gain goes up to the limit")
        #expect(heard.contains(L10n.announceLevelChangedOne.text), "VoiceOver hears the count: \(heard)")
        await model.close()
    }

    /// One 3 s clip `c1` on t1 and a clip `q` on t2 whose file holds a sine of 0.002 peak (about
    /// -57 dBFS). Auto Level needs more than 20 dB for `q`.
    @concurrent nonisolated static func quietPackage(in folder: URL) async throws -> URL {
        let url = try await timelinePackage(in: folder, tracks: 1, seconds: 3, noise: true)
        var session = try Session(contentsOf: url)
        let frames = 48_000 * 3
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let samples = buffer.floatChannelData?[0] {
            for n in 0..<frames { samples[n] = 0.002 * Float(sin(Double(n) * 0.1)) }
        }
        let writer = try ClipWriter(
            url: url.appending(path: "\(clipsFolderName)/f2.wav"), file: "f2.wav", format: format)
        try writer.write(buffer)
        try writer.close()
        try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: Frames(frames)))
        try session.addTrack("t2", name: "T2", layout: .mono)
        try session.place(Clip(id: "q", file: "f2", start: 0, offset: 0, length: Frames(frames)), on: "t2")
        try session.write(to: url)
        return url
    }

    /// C5: a second level of the same clips says that nothing changed, and adds no undo entry.
    @Test func aSecondLevelSaysNoChange() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Self.oneSecondOnT1
        await model.level(.eachClip)
        let leveled = studio.session
        await model.level(.equallyPerTrack)
        let banner = WindowBanner.levelReport(LevelReport(changed: 0, atLimit: 0, unmeasured: 0), press: 2)
        await until("the second banner shows") { levelBanner(model) == banner }
        let same = studio.session == leveled
        #expect(same, "second level: the session changed")
        model.undo()
        #expect(studio.session.clip("c1")?.clip.gain == .zero && !studio.canUndo, "second level: a new undo entry")
        await model.close()
    }

    /// C12: an edit after the level hides the banner.
    @Test func anEditHidesTheBanner() async throws {
        let (model, _, _, _) = try await open()
        model.timeline.marks = Self.oneSecondOnT1
        await model.level(.eachClip)
        await model.level(.eachClip)
        await until("the banner shows") { levelBanner(model) != nil }
        model.edit(ripple: false) { session throws(SessionError) in try session.setGain(Gain(dB: 3)!, clip: "c2") }
        await until("the edit hides the banner") { levelBanner(model) == nil }
        await model.close()
    }

    /// C12: a level whose save fails shows the alert and no level banner, also not the old one.
    @Test func aFailedSaveShowsNoBanner() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Self.oneSecondOnT1
        await model.level(.eachClip)
        await model.level(.eachClip)
        await until("the banner shows") { levelBanner(model) != nil }
        studio.environment.saveSession = { _, _ throws(SessionFileError) in throw .writeFailed(step: "test", errno: EIO)
        }
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t2"])

        await model.level(.eachClip)

        #expect(model.alert != nil, "failed save: no alert")
        #expect(model.levelReport == nil, "failed save: \(String(describing: model.levelReport))")
        await until("the old banner goes") { levelBanner(model) == nil }
        await model.close()
    }

    /// C12, plan gate Q3: Cmd-L during an import changes nothing and removes the old banner.
    @Test func aBusyStudioClearsTheBanner() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Self.oneSecondOnT1
        await model.level(.eachClip)
        await model.level(.eachClip)
        await until("the banner shows") { levelBanner(model) != nil }
        let source = folder.url.appending(path: "Voice.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        try AVAudioFile(forWriting: source, settings: format.settings).write(from: buffer)
        app.chooseImport = { _, done in done(source) }
        let hold = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        studio.environment.importStep = {
            guard !entered.value else { return }
            entered.value = true
            _ = hold.wait(timeout: .now() + 30)
        }
        model.run(TimelineCommand.importAudio)
        await until("the import holds") { entered.value }
        let before = studio.session

        await model.level(.eachClip)

        let same = studio.session == before
        #expect(same && model.alert == nil, "busy studio: the session changed or an alert")
        #expect(model.levelReport == nil, "busy studio: \(String(describing: model.levelReport))")
        hold.signal()
        await until("the import ends") { model.importJob == nil }
        #expect(levelBanner(model) == nil, "busy studio: the old banner shows")
        await model.close()
    }
}

/// Run 2026-10-12-autolevel-fader C5, C6, C7: the text and the kind of the level banner, in
/// English from the app table.
struct LevelReportBannerTests {
    func english(_ report: LevelReport) throws -> String {
        let table = try stringsTable("en")
        return L10n.message(for: report) { table[$0.rawValue] ?? "" }
    }

    @Test func theNoChangeTextHasTheTrackVolumeSentence() throws {
        #expect(
            try english(LevelReport(changed: 0, atLimit: 0, unmeasured: 0))
                == "The clips are already at the target level. The track volume doesn't change the clip gain."
        )
    }

    @Test func aSilentClipKeepsTheTrackVolumeSentence() throws {
        #expect(
            try english(LevelReport(changed: 0, atLimit: 0, unmeasured: 1))
                == "No clips changed. The track volume doesn't change the clip gain. 1 clip with no level keeps its gain."
        )
    }

    @Test func silentClipsAreNotAtTheTarget() throws {
        #expect(
            try english(LevelReport(changed: 0, atLimit: 0, unmeasured: 2))
                == "No clips changed. The track volume doesn't change the clip gain. "
                + "2 clips with no level keep their gain."
        )
    }

    /// Code gate F1: a second level of a clip at the limit changes nothing and repeats the limit
    /// sentence.
    @Test func aKeptClipAtTheLimitGivesAWarning() throws {
        let report = LevelReport(changed: 0, atLimit: 1, unmeasured: 0)
        #expect(
            try english(report)
                == "No clips changed. The track volume doesn't change the clip gain. Check that the clip at the 20 dB limit has speech."
        )
        #expect(WindowBanner.levelReport(report, press: 2).kind == .warning)
    }

    @Test func aClipAtTheLimitGivesAWarning() throws {
        let report = LevelReport(changed: 3, atLimit: 1, unmeasured: 0)
        #expect(try english(report) == "Check that the clip at the 20 dB limit has speech.")
        #expect(WindowBanner.levelReport(report, press: 1).kind == .warning)
        #expect(WindowBanner.levelReport(LevelReport(changed: 0, atLimit: 0, unmeasured: 0), press: 1).kind == .info)
    }

    /// C9 (d): a clip with no level to measure gives a warning banner next to a changed clip.
    @Test func aClipWithNoLevelGivesAWarning() throws {
        let report = LevelReport(changed: 2, atLimit: 0, unmeasured: 1)
        #expect(try english(report) == "1 clip with no level keeps its gain.")
        #expect(WindowBanner.levelReport(report, press: 1).kind == .warning)
    }

    /// C9 (d): the changed clips have no banner text: VoiceOver hears the count.
    @Test func changedClipsWithNoWarningHaveNoBannerText() throws {
        #expect(try english(LevelReport(changed: 3, atLimit: 0, unmeasured: 0)) == "")
        #expect(try english(LevelReport(changed: 1, atLimit: 0, unmeasured: 0)) == "")
    }
}
