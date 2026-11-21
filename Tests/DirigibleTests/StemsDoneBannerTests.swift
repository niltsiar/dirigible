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

        #expect(
            banners == [
                .stemsClipped(["02 Guest.wav"]),
                .exportSetDone(files: files.map { folder.appending(path: $0.name) }, low: nil, high: nil, old: []),
            ], "the clip warning is line 1 and the folder line follows; a peak of 1.0 gives no warning")
        #expect(shown([file("01 Host.wav", peak: 1)]).banners.count == 1, "no clip: the folder line only")
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
