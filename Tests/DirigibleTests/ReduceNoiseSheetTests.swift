import AppKit
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

extension SessionWindow {
    /// Tools > Reduce Noise..., the edit of the sheet, and its Reduce Noise button. It returns
    /// when the render starts.
    func reduceNoiseFromSheet(edit: (inout DenoiseDraft) -> Void = { _ in }) throws {
        run(.reduceNoise)
        var draft = try #require(denoiseDraft, "the item opened no sheet")
        edit(&draft)
        applyDenoise(draft)
    }
}

extension DenoiseDraft {
    static func edited(_ draft: DenoiseDraft, noise: Bool, decibels: Int, hum: Bool, _ frequency: Hum) -> DenoiseDraft {
        var draft = draft
        (draft.noise, draft.decibels, draft.hum, draft.frequency) = (noise, decibels, hum, frequency)
        return draft
    }
}

/// The Reduce Noise sheet (decision 0054, criteria C13, C18, C19, and C21). The tracks t1 (no
/// role), t2 (dialogue), t3 (music), and t4 (effects) each hold the clip c<n> of the noise file
/// `f1` (`ReduceNoiseWindowTests.rolesPackage`).
@Suite(.serialized) @MainActor struct ReduceNoiseSheetTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open(_ app: AppDelegate? = nil) async throws -> (SessionWindow, Studio) {
        let package = try await ReduceNoiseWindowTests.rolesPackage(in: folder.url)
        let (model, studio, _, _) = try await openLanes(app ?? self.app, package)
        return (model, studio)
    }

    func set(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    func defaults() throws -> UserDefaults {
        let name = "ReduceNoiseSheetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func draft(
        _ ids: Set<ClipID>, in studio: Studio, defaults: UserDefaults? = nil, region: String = "DE"
    ) -> DenoiseDraft {
        DenoiseDraft(clips: ids, in: studio.session, defaults: defaults, region: Locale.Region(region))
    }

    func path(of clip: ClipID, _ studio: Studio) -> String {
        studio.session.clip(clip).flatMap { studio.session.files[$0.clip.file]?.path } ?? "-"
    }

    /// C18: the first open gives 12 dB, noise on, hum off, and 50 Hz for a region of the 50 Hz
    /// list and 60 Hz for a region of the 60 Hz list. A second open gives the last values of the
    /// Reduce Noise button.
    @Test func defaultsAndLastValues() async throws {
        let defaults = try defaults()
        let app = AppDelegate(recordings: nil, defaults: defaults)
        let (model, studio) = try await open(app)

        let first = draft(["c1"], in: studio, defaults: defaults, region: "DE")
        #expect(first.noise && first.decibels == 12 && !first.hum && first.frequency == .hz50, "\(first)")
        #expect(draft(["c1"], in: studio, region: "US").frequency == .hz60, "a 60 Hz region")
        #expect(draft(["c1"], in: studio, region: "JP").frequency == .hz50, "Japan has two grids")

        model.timeline.selection = set("c2")
        try model.reduceNoiseFromSheet { $0 = DenoiseDraft.edited($0, noise: false, decibels: 18, hum: true, .hz60) }
        await until("the render ends") { model.importJob == nil }
        model.timeline.selection = set("c1")
        model.run(.reduceNoise)

        let second = try #require(model.denoiseDraft)
        #expect(!second.noise && second.decibels == 18 && second.hum && second.frequency == .hz60, "\(second)")
        await model.close()
    }

    /// C18: a clip stored at 20 dB opens the dial at 20 (fail: the preference, 12).
    @Test func storedAmountStartsTheDial() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c1", "c2")
        try model.reduceNoiseFromSheet { $0 = DenoiseDraft.edited($0, noise: true, decibels: 20, hum: false, .hz50) }
        await until("the render ends") { model.importJob == nil }

        let draft = draft(["c1", "c2"], in: studio)
        #expect(draft.decibels == 20 && draft.mixedAmounts == nil, "\(draft)")
        await model.close()
    }

    /// C18 and U45: clips stored at 12 and 20 dB open the dial at the preference, 15, and the
    /// sheet gives the range for its line.
    @Test func mixedAmountsStartAtThePreference() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c1")
        try model.reduceNoiseFromSheet()
        await until("the first render ends") { model.importJob == nil }
        model.timeline.selection = set("c2")
        try model.reduceNoiseFromSheet { $0 = DenoiseDraft.edited($0, noise: true, decibels: 20, hum: false, .hz50) }
        await until("the second render ends") { model.importJob == nil }
        let defaults = try defaults()
        defaults.set(15, forKey: "denoise.decibels")

        let draft = draft(["c1", "c2"], in: studio, defaults: defaults)

        #expect(draft.decibels == 15 && draft.mixedAmounts == 12...20, "\(draft)")
        await model.close()
    }

    /// C18 (plan gate 4 item 2): a clip stored at hum 60 with a preference of 50 Hz opens with
    /// Remove hum on at 60 Hz; clips at 50 and 60 Hz open at the preference with the mixed line.
    @Test func storedHumStartsTheSheet() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c1")
        try model.reduceNoiseFromSheet { $0 = DenoiseDraft.edited($0, noise: false, decibels: 12, hum: true, .hz60) }
        await until("the first render ends") { model.importJob == nil }
        let defaults = try defaults()
        defaults.set(50, forKey: "denoise.humHz")

        let stored = draft(["c1"], in: studio, defaults: defaults)
        #expect(stored.hum && stored.frequency == .hz60 && stored.mixedFrequencies.isEmpty, "\(stored)")

        model.timeline.selection = set("c2")
        try model.reduceNoiseFromSheet { $0 = DenoiseDraft.edited($0, noise: false, decibels: 12, hum: true, .hz50) }
        await until("the second render ends") { model.importJob == nil }
        let mixed = draft(["c1", "c2"], in: studio, defaults: defaults)
        #expect(mixed.frequency == .hz50 && mixed.mixedFrequencies == [.hz50, .hz60], "\(mixed)")
        await model.close()
    }

    /// C18: Reduce Noise is off with both check boxes off, and with noise on and music clips
    /// only.
    @Test func applyIsOffWithNothingChecked() async throws {
        let (model, studio) = try await open()
        var voice = draft(["c1"], in: studio)
        #expect(voice.canApply(in: studio.session) && voice.treatment == Treatment(.noise(.standard)))
        voice.noise = false
        #expect(!voice.canApply(in: studio.session) && voice.treatment == nil, "both check boxes off")
        #expect(draft(["c3"], in: studio).canApply(in: studio.session) == false, "noise on, a music clip")
        var music = draft(["c3"], in: studio)
        music.noise = false
        music.hum = true
        #expect(music.canApply(in: studio.session), "hum alone takes a music clip")
        model.timeline.selection = set("c1")
        model.run(.reduceNoise)
        var open = try #require(model.denoiseDraft)
        open.noise = false
        model.applyDenoise(open)
        #expect(
            model.importJob == nil && studio.session.clip("c1")?.clip.file == "f1", "Apply ran with nothing checked")
        await model.close()
    }

    /// C13 and plan gate 3 item 3: a music-only selection opens the sheet, and hum alone moves
    /// the clip to a ` HR` file.
    @Test func musicOnlySelectionRunsHumAlone() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c3")

        try model.reduceNoiseFromSheet { $0 = DenoiseDraft.edited($0, noise: false, decibels: 12, hum: true, .hz50) }
        await until("the render ends") { model.importJob == nil }

        #expect(model.alert == nil)
        #expect(path(of: "c3", studio).hasSuffix(" HR.wav"), "\(path(of: "c3", studio))")
        await model.close()
    }

    /// U46: with noise on, a music clip of the selection is skipped and counted; the dialogue clip
    /// moves, and the music clip keeps its file. With hum on, the same request skips it too.
    @Test func musicIsSkippedWithNoise() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c2", "c3")
        model.run(.reduceNoise)
        let shown = try #require(model.denoiseDraft)
        #expect(shown.skippedCount(in: studio.session) == 1 && shown.accepted(in: studio.session) == ["c2"])

        model.applyDenoise(shown)
        await until("the render ends") { model.importJob == nil }

        #expect(path(of: "c2", studio).hasSuffix(" NR.wav") && path(of: "c3", studio) == "f1.wav")
        #expect(model.denoiseDraft == nil, "Reduce Noise closes the sheet")
        await model.close()
    }

    /// C19: Preview is off when the treatment accepts no clip. It loops the first accepted clip,
    /// and Cancel and Reduce Noise stop it and close the sheet.
    @Test func previewStops() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = set("c3")
        model.run(.reduceNoise)
        let musicOnly = try #require(model.denoiseDraft)
        #expect(musicOnly.previewClip(in: studio.session) == nil, "noise on, a music clip")
        await model.previewDenoise(musicOnly, listen: .result)
        #expect(studio.effectPreviewState == .stopped, "a preview of no clip")
        model.cancelDenoise()

        model.timeline.selection = set("c3", "c2")
        model.run(.reduceNoise)
        let draft = try #require(model.denoiseDraft)
        #expect(draft.previewClip(in: studio.session) == "c2")
        await model.previewDenoise(draft, listen: .removedSound)
        #expect(studio.effectPreviewState == .playing, "\(studio.effectPreviewState)")
        model.cancelDenoise()
        #expect(studio.effectPreviewState == .stopped && model.denoiseDraft == nil, "Cancel")

        model.run(.reduceNoise)
        await model.previewDenoise(try #require(model.denoiseDraft), listen: .result)
        #expect(studio.effectPreviewState == .playing)
        model.applyDenoise(try #require(model.denoiseDraft))
        #expect(studio.effectPreviewState == .stopped && model.denoiseDraft == nil, "Reduce Noise")
        await until("the render ends") { model.importJob == nil }
        await model.close()
    }

    /// C21: the accessibility value of the dial in English and Spanish.
    @Test func dialAccessibilityValue() throws {
        let tables = try ["en", "es"].map { try stringsTable($0) }
        let key = L10n.sheetDenoiseValue.rawValue
        #expect(String(format: try #require(tables[0][key]), 12) == "12 decibels")
        #expect(String(format: try #require(tables[1][key]), 12) == "12 decibelios")
    }

    /// C21: hum alone gives a banner and a report with the hum and no decibels. The texts of the
    /// four forms in English and Spanish.
    @Test func humResultBanner() async throws {
        let (model, _) = try await open()
        model.timeline.selection = set("c3", "c4")
        try model.reduceNoiseFromSheet { $0 = DenoiseDraft.edited($0, noise: false, decibels: 12, hum: true, .hz50) }
        await until("the render ends") { model.importJob == nil }

        let report = try #require(model.denoiseReport)
        #expect(report.clips == 2 && report.decibels == nil && report.hum, "\(report)")
        await until("the banner shows") { model.shown.banners.contains { $0.key.hasPrefix("denoiseReport") } }
        let banner = try #require(model.shown.banners.first { $0.key.hasPrefix("denoiseReport") })
        #expect(banner.text == L10n.denoiseResult(clips: 2, decibels: nil, hum: true), "\(banner.text)")

        let tables = try ["en", "es"].map { try stringsTable($0) }
        func text(_ clips: Int, _ decibels: Int?, _ language: Int) -> String {
            L10n.denoiseResult(clips: clips, decibels: decibels, hum: true) {
                tables[language][$0.rawValue] ?? $0.rawValue
            }
        }
        #expect(text(3, nil, 0) == "Removed hum in 3 clips." && text(1, nil, 0) == "Removed hum in 1 clip.")
        #expect(text(3, 12, 0) == "Reduced noise in 3 clips by 12 dB and removed hum.")
        #expect(text(1, 12, 0) == "Reduced noise in 1 clip by 12 dB and removed hum.")
        #expect(text(3, nil, 1) == "Zumbido eliminado en 3 clips." && text(1, nil, 1) == "Zumbido eliminado en 1 clip.")
        #expect(text(3, 12, 1) == "Ruido reducido en 3 clips, 12 dB, y zumbido eliminado.")
        await model.close()
    }
}
