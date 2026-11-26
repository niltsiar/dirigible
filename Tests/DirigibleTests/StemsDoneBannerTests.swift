import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The banners of a stem export (decision 0078): the clip warning comes first, each stem over 0 dBFS
/// is named, and a stop says that no stem was written.
struct StemsDoneBannerTests {
    let folder = URL(filePath: "/Exports/Show Stems", directoryHint: .isDirectory)

    func file(_ name: String, peak: Float) -> StemFile { StemFile(name: name, tracks: ["t1"], samplePeak: peak) }

    func shown(_ files: [StemFile], mixPeak: Float? = nil) -> StemsShown {
        StemsShown(outcome: .done(folder: folder, files: files, mixPeak: mixPeak), revision: 3)
    }

    @Test func theClipWarningComesFirst() {
        let files = [file("01 Host.wav", peak: 1), file("02 Guest.wav", peak: Float(1).nextUp)]

        let banners = shown(files).banners

        #expect(banners == [.stemsClipped(["02 Guest.wav"])], "a peak of 1.0 gives no warning")
        #expect(shown([file("01 Host.wav", peak: 1)]).banners == [.stemsDone(folder: folder, count: 1)], "no clip")
    }

    /// C9: the folder is outside the window, so a clean finish shows one info banner with the stem count
    /// and the folder name. Its text has a form for 1 stem, so 1 does not read "1 stems".
    @Test func aCleanFinishShowsOneInfoBannerNamingTheFolder() throws {
        let files = [file("01 Host.wav", peak: 0.5), file("02 Guest.wav", peak: 0.5)]

        let banners = shown(files).banners

        #expect(banners == [.stemsDone(folder: folder, count: 2)])
        #expect(banners.first?.kind == .info)
        #expect(banners.first?.text == stemsDoneText(2, folder: "Show Stems"), "the text names the folder")
        #expect(banners.first?.announcement == nil, "the end of the run announces its own text once")
        let en = try stringsTable("en")
        #expect(stemsDoneText(2, folder: "Show Stems") { en[$0.rawValue] ?? "" } == "Exported 2 stems to Show Stems.")
        #expect(stemsDoneText(1, folder: "Show Stems") { en[$0.rawValue] ?? "" } == "Exported 1 stem to Show Stems.")
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            let one = try #require(table["banner.stems.done.one"], "\(language)")
            let many = try #require(table["banner.stems.done"], "\(language)")
            #expect(!one.contains("%lld") && one.contains("%@"), "\(language): \(one)")
            #expect(many.contains("%1$lld") && many.contains("%2$@"), "\(language): \(many)")
        }
    }

    /// A warning is the result of the run: it stays as it was and the done banner does not add a second line.
    @Test func aWarningWinsOverTheDoneBanner() {
        let clipped = shown([file("01 Host.wav", peak: 1.2)], mixPeak: 1.3).banners
        #expect(clipped == [.stemsClipped(["01 Host.wav"]), .stemsMixClipped])
        #expect(clipped.allSatisfy { $0.kind == .warning })
        #expect(shown([file("01 Host.wav", peak: 0.5)], mixPeak: 1.3).banners == [.stemsMixClipped])
    }

    /// A stem that rendered as silence gives the alert of Export: the alert is the result.
    @Test func aStemWithAFaultGivesNoDoneBanner() {
        let faulty = StemsShown(
            outcome: .done(folder: folder, files: [file("01 Host.wav", peak: 0.5)], mixPeak: nil), revision: 3,
            faulty: true)

        #expect(faulty.banners.isEmpty)
    }

    @Test func aStopSaysNoStemWasWritten() throws {
        let banners = StemsShown(outcome: .stopped, revision: 3).banners

        #expect(banners == [.stemsStopped])
        #expect(try stringsTable("en")["banner.stems.stopped"] == "No stem was written.")
        #expect(try stringsTable("es")["banner.stems.stopped"] == "No se escribió ningún stem.")
        #expect(banners != [.exportSetStopped(written: 0, count: 0)], "not the stop text of the split export")
    }

    @Test func theBannerNamesEachClippedStem() throws {
        let files = [file("01 Host.wav", peak: 1.4), file("02 Guest.wav", peak: 1.1), file("03 Bed.wav", peak: 0.5)]

        let banners = shown(files, mixPeak: 1.3).banners

        #expect(banners.prefix(2) == [.stemsClipped(["01 Host.wav", "02 Guest.wav"]), .stemsMixClipped])
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        for table in [en, es] {
            let text = stemsClippedText(["01 Host.wav", "02 Guest.wav"]) { table[$0.rawValue] ?? $0.rawValue }
            #expect(text.contains("01 Host.wav") && text.contains("02 Guest.wav"), Comment(rawValue: text))
        }
        #expect(shown(files, mixPeak: 1).banners.contains(.stemsMixClipped) == false, "a mix peak of 1.0 gives no line")
        #expect(shown([file("01 Host.wav", peak: 0.5)], mixPeak: 1.3).banners.first == .stemsMixClipped)
    }
}
