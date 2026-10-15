import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-12-autolevel-fader C2, C5, C11, C12: the result banner of Auto Level on a real
/// session window. The tests are in the serialized suite `AutoLevelWindowTests` and use its
/// fixture.
extension AutoLevelWindowTests {
    static let oneSecondOnT1 = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])

    /// The level banner that the window shows now, or nil.
    func levelBanner(_ model: SessionWindow) -> WindowBanner? {
        model.shown.banners.first { $0.key.hasPrefix("levelReport") }
    }

    /// C11: each press announces its banner, also a second press with the same report.
    @Test func eachLevelIsAnnounced() async throws {
        let (model, _, _, _) = try await open()
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        model.timeline.marks = Self.oneSecondOnT1
        for press in 1...3 {
            await model.level(.eachClip)
            await until("press \(press) shows its banner") { levelBanner(model)?.key == "levelReport.\(press)" }
        }
        let none = WindowBanner.levelReport(LevelReport(changed: 0, atLimit: 0, unmeasured: 0), press: 2).text
        #expect(heard.count(where: { $0 == none }) == 2, "announcements: \(heard)")
        #expect(heard.count == 3, "announcements: \(heard)")
        await model.close()
    }

    /// C2: 1 s on t1 changes only c1, and the banner counts 1.
    @Test func theBannerCountsTheChangedClips() async throws {
        let (model, _, _, _) = try await open()
        model.timeline.marks = Self.oneSecondOnT1
        await model.level(.eachClip)
        let banner = WindowBanner.levelReport(LevelReport(changed: 1, atLimit: 0, unmeasured: 0), press: 1)
        await until("the banner shows") { levelBanner(model) != nil }
        #expect(levelBanner(model) == banner, "banner: \(String(describing: levelBanner(model)))")
        #expect(banner.kind == .info)
        await model.close()
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
                == "Auto Level is done. No change: the clips are at the target level. The track volume does not change the clip gain."
        )
    }

    @Test func aSilentClipKeepsTheTrackVolumeSentence() throws {
        #expect(
            try english(LevelReport(changed: 0, atLimit: 0, unmeasured: 1))
                == "Auto Level is done. Clips changed: 0. The track volume does not change the clip gain. Clips with no level to measure: 1. They keep their gain."
        )
    }

    @Test func silentClipsAreNotAtTheTarget() throws {
        #expect(
            try english(LevelReport(changed: 0, atLimit: 0, unmeasured: 2))
                == "Auto Level is done. Clips changed: 0. The track volume does not change the clip gain. Clips with no level to measure: 2. They keep their gain."
        )
    }

    /// Code gate F1: a second level of a clip at the limit changes nothing and repeats the limit
    /// sentence.
    @Test func aKeptClipAtTheLimitGivesAWarning() throws {
        let report = LevelReport(changed: 0, atLimit: 1, unmeasured: 0)
        #expect(
            try english(report)
                == "Auto Level is done. Clips changed: 0. The track volume does not change the clip gain. Clips at the 20 dB limit: 1. Check that they have speech."
        )
        #expect(WindowBanner.levelReport(report, press: 2).kind == .warning)
    }

    @Test func aClipAtTheLimitGivesAWarning() throws {
        let report = LevelReport(changed: 3, atLimit: 1, unmeasured: 0)
        #expect(
            try english(report)
                == "Auto Level is done. Clips changed: 3. Clips at the 20 dB limit: 1. Check that they have speech.")
        #expect(WindowBanner.levelReport(report, press: 1).kind == .warning)
        #expect(WindowBanner.levelReport(LevelReport(changed: 3, atLimit: 0, unmeasured: 0), press: 1).kind == .info)
    }
}
