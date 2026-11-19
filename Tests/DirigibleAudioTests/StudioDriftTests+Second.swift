import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// Criterion D17 of decision 0077 (a second fix reads the first source) and the same-package paste
/// of D12. Clip "T" on track "t" plays "first", a drift-corrected copy of the drift clip "c".
extension StudioDriftTests {
    /// The first link has ratio 1 / 1.0001 and added gain +2 dB on a clip at -1 dB, and the copy
    /// drifts by 2 ppm across 10 min (1.2 ms). The new file links to "c" with the composed ratio, the
    /// clip gain is -3 dB plus the returned gain (0 dB), and "first" is unused.
    @Test func aSecondFixResamplesTheFirstSource() async throws {
        let drift = try DriftPackage(seconds: 600, ppm: 2)
        let first = try Self.link(ratio: 1 / 1.0001, addedGain: Gain(dB: 2)!)
        try Self.addCopy("first", of: drift, drift: first)
        try drift.package.session.setGain(Gain(dB: -1)!, clip: "T")
        let studio = try await Self.open(drift)

        let fix = try Self.fix(try await studio.correctDrift("T", to: "ref"))

        let file = try #require(studio.session.files[fix.files[0]])
        let link = try #require(file.drift)
        let composed = first.ratio.value / (1 + fix.slope)
        #expect(link.source == "c" && abs(link.ratio.value - composed) < 1e-9, "\(link), composed \(composed)")
        #expect(abs(fix.slope - 2e-6) < 0.1e-6, "rate \(fix.slope * 1e6) ppm")
        let gain = try #require(studio.session.clip("T")?.clip.gain)
        #expect(abs(gain.dB + 3) < 1e-9 && link.addedGain == .zero, "gain \(gain.dB) dB, link \(link.addedGain.dB) dB")
        #expect(!studio.session.filesInUse.contains("first") && studio.session.filesInUse.contains("c"))
    }

    /// The played file has a drift link, so a fix that takes the fault of the played file refuses
    /// it; the resample source "c" is a plain file.
    @Test func aSecondFixIsNotRefusedAsATakeFile() async throws {
        let drift = try DriftPackage(seconds: 300, ppm: 5)
        try Self.addCopy("first", of: drift, drift: try Self.link(ratio: 1 / 1.0001))
        let studio = try await Self.open(drift)

        let report = try await studio.correctDrift("T", to: "ref")

        let fix = try Self.fix(report)
        #expect(studio.session.files[fix.files[0]]?.drift?.source == "c")
    }

    /// A first fix of a full-scale clip at +95 dB returns +3.01 dB: the clip gets +96 dB and the link
    /// holds the applied +1 dB. A second fix after such a first fix, of a tone whose true peak is
    /// +0.5 dBFS, gives +95 dB plus the returned +0.5 dB. The reference clip gets the gain of the
    /// clip: the match gives 0 for a reference 40 dB or more under the clip.
    @Test func aSecondFixAfterAClampedFirstFixKeepsTheLevel() async throws {
        let (loud, _) = try Self.tonePackage(seconds: 360, ppm: 100, amplitude: Float(2).squareRoot())
        try loud.package.session.setGain(Gain(dB: 95)!, clip: "C")
        try loud.package.session.setGain(Gain(dB: 95)!, clip: "R")
        let first = try await Self.open(loud)
        let fix = try Self.fix(try await first.correctDrift("C", to: "ref"))
        let applied = try #require(first.session.files[fix.files[0]]?.drift?.addedGain)
        #expect(first.session.clip("C")?.clip.gain == Gain(dB: 96)!, "\(String(describing: first.session.clip("C")))")
        #expect(abs(applied.dB - 1) < 1e-9, "the link holds \(applied.dB) dB")

        let peak = Float(pow(10, 0.5 / 20))
        let (drift, _) = try Self.tonePackage(seconds: 300, ppm: 5, amplitude: peak)
        try Self.addCopy("first", of: drift, drift: try Self.link(ratio: 1 / 1.0001, addedGain: Gain(dB: 1)!))
        try drift.package.session.setGain(Gain(dB: 96)!, clip: "T")
        try drift.package.session.setGain(Gain(dB: 96)!, clip: "R")
        let studio = try await Self.open(drift)

        let second = try Self.fix(try await studio.correctDrift("T", to: "ref"))

        let gain = try #require(studio.session.clip("T")?.clip.gain)
        let link = try #require(studio.session.files[second.files[0]]?.drift)
        #expect(abs(gain.dB - 95.5) < 0.05, "gain \(gain.dB) dB")
        #expect(abs(link.addedGain.dB - (gain.dB - 95)) < 1e-9, "the link holds \(link.addedGain.dB) dB")
    }

    /// Words that Transcribe stored on "first" are on the new file at the same audio, through new
    /// file frame to source frame to "first" frame, and they stay when "first" leaves the pool.
    @Test func aSecondFixKeepsTheWordsOfTheFirstFile() async throws {
        let drift = try DriftPackage(seconds: 300, ppm: 5)
        let first = try Self.link(ratio: 1 / 1.0001)
        try Self.addCopy("first", of: drift, drift: first)
        let words: [(Int, Range<Int>)] = [
            (1, 48_000..<52_800), (2, 7_200_000..<7_204_800), (3, 14_000_000..<14_004_800),
        ]
        let anchors = words.map {
            Anchor(number: $0.0, range: Frames($0.1.lowerBound)..<Frames($0.1.upperBound), text: "w")
        }
        drift.package.session.transcripts[TranscriptID(1)] = Transcript(
            id: TranscriptID(1), name: "t1", words: ["first": Anchors(anchors)])
        let studio = try await Self.open(drift)

        let fix = try Self.fix(try await studio.correctDrift("T", to: "ref"))

        let new = fix.files[0]
        let link = try #require(studio.session.files[new]?.drift)
        var pruned = studio.session
        try pruned.removeFiles(["first"])
        let moved = pruned.transcripts[TranscriptID(1)]?.words?[new]?.all ?? []
        #expect(moved.map(\.number) == [1, 2, 3], "\(moved)")
        for (word, (_, range)) in zip(moved, words) {
            let expected = [range.lowerBound, range.upperBound].map {
                (first.sourceFrame(of: Frames($0)) - Double(link.offset.count)) / link.ratio.value
            }
            let ends = [word.range.lowerBound.count, word.range.upperBound.count]
            #expect(zip(ends, expected).allSatisfy { abs(Double($0) - $1) <= 1 }, "\(word), expected \(expected)")
        }
    }

    /// D12: only a clipboard of this package holds a clip on a drift-corrected file. Remove Unused
    /// Files keeps the file and its source, and the paste, the save, and the open give the clip on
    /// the file with its link.
    @Test func aSamePackagePasteAfterRemoveUnusedFilesKeepsTheLink() async throws {
        let package = try MixPackage()
        let source = FileID("guest-\(UUID().uuidString)")
        let corrected = FileID("guest drift-\(UUID().uuidString)")
        let link = DriftOrigin(source: source, offset: 0, ratio: try #require(DriftRatio(1 / 1.0001)), addedGain: .zero)
        try package.addFile("used", channels: [sine(seconds: 1, rate: 48_000)])
        try package.addFile(source, channels: [sine(seconds: 1, rate: 48_000)])
        try package.addFile(corrected, channels: [sine(seconds: 1, rate: 48_000)], drift: link)
        try package.addTrack("t1", clip: "A", file: "used", start: 0, offset: 0, length: 48_000)
        try package.session.write(to: package.url)
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        var copied = studio.session
        try copied.place(Clip(id: "B", file: corrected, start: 96_000, offset: 0, length: 48_000), on: "t1")
        let clipboard = studio.clipboard(of: try copied.excerpt(of: ["B"]))

        let listed = try await studio.unusedFiles()
        let report = try await studio.removeUnusedFiles(listed, clipboard: clipboard)
        defer { for moved in report.moved { try? FileManager.default.removeItem(at: moved.trashURL) } }
        let pasted = try #require(try studio.pasteInPlace(clipboard, mode: .over(at: 96_000), on: .tracks(["t1"])))
        await studio.settle()

        #expect(listed.items.count == 2 && report.moved.isEmpty, "\(report.moved.map(\.item.path))")
        let reopened = try Session(contentsOf: package.url)
        let clip = try #require(pasted.clips.first.flatMap { reopened.clip($0)?.clip })
        #expect(clip.file == corrected && reopened.files[corrected]?.drift == link && reopened.files[source] != nil)
    }
}
