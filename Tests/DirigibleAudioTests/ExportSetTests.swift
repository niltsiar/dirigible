import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Criterion C23 of the stem export: `exportItems` runs a list of export items as one job.
struct ExportSetTests {
    static let wav24 = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)
    static let flac16 = ExportOptions(format: .flac(.bits16), layout: .stereo, rate: .session)

    /// Two mono tracks of 3 s of seeded noise: "a" and "b".
    static func package() throws -> MixPackage {
        let package = try MixPackage()
        try package.addFile("na", channels: [ExportStemsTests.noise(144_000, peak: 0.3, seed: 11)])
        try package.addFile("nb", channels: [ExportStemsTests.noise(144_000, peak: 0.3, seed: 12)])
        try package.addTrack("a", clip: "ca", file: "na", start: 0, offset: 0, length: 144_000)
        try package.addTrack("b", clip: "cb", file: "nb", start: 0, offset: 0, length: 144_000)
        return package
    }

    static func item(
        _ package: MixPackage, _ name: String, range: Range<Frames>, tracks: Set<TrackID>?,
        options: ExportOptions = wav24
    ) throws -> ExportItem {
        ExportItem(
            session: package.session, source: try #require(ExportSource(range: range, tracks: tracks)),
            options: options, url: package.folder.url.appending(path: name))
    }

    static func run(
        _ package: MixPackage, _ items: [ExportItem], progress: (Double, Int) -> Void = { _, _ in },
        isCancelled: () -> Bool = { false }
    ) throws(ExportItemsError) -> [ExportResult] {
        try exportItems(
            items, replacing: [:], package: { package.url }, progress: progress, isCancelled: isCancelled)
    }

    /// Pass value: each file equals the `exportMix` of its own item. Control: the options of item 1
    /// for each item make item 2 a 24-bit WAV.
    @Test func eachItemIsItsOwnExport() throws {
        let package = try Self.package()
        let items = [
            try Self.item(package, "1.wav", range: 0..<96_000, tracks: ["a"]),
            try Self.item(package, "2.flac", range: 0..<96_000, tracks: ["b"], options: Self.flac16),
            try Self.item(package, "3.wav", range: 0..<96_000, tracks: ["a", "b"]),
        ]
        let results = try Self.run(package, items)
        #expect(results.count == 3)
        #expect(try Data(contentsOf: items[1].url).prefix(4) == Data("fLaC".utf8))
        for (index, item) in items.enumerated() {
            let reference = package.folder.url.appending(path: "reference-\(index + 1).\(item.url.pathExtension)")
            _ = try exportMix(
                item.session, source: item.source, options: item.options, to: reference, package: { package.url })
            let written = try readAudio(item.url)
            let expected = try readAudio(reference)
            #expect(written.samples.count == expected.samples.count, "item \(index + 1)")
            #expect(written.samples == expected.samples, "item \(index + 1)")
        }
    }

    /// A cancel at the start of item 2 of 3. Control: a stop that removes the written files.
    @Test func aStopAtItemTwoKeepsItemOneAndNamesTheRest() throws {
        let package = try Self.package()
        let items = try (1...3).map { try Self.item(package, "\($0).wav", range: 0..<48_000, tracks: nil) }
        var item = 0
        let error = #expect(throws: ExportItemsError.self) {
            try Self.run(package, items, progress: { _, index in item = index }, isCancelled: { item >= 1 })
        }
        guard case .stopped(let stop)? = error else {
            Issue.record("no stop: \(String(describing: error))")
            return
        }
        #expect(stop.error == .cancelled)
        #expect(stop.written.count == 1)
        #expect(stop.remaining == [items[1].url, items[2].url])
        let names = try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path)
        #expect(names.contains("1.wav"))
        #expect(!names.contains("2.wav"))
        #expect(!names.contains { $0.hasSuffix(".tmp") }, "\(names)")
    }

    /// Items of 1 s and 3 s: 0.25 at the start of item 2. Control: an even share gives 0.5.
    @Test func theProgressWeighsEachItemByItsFrames() throws {
        let package = try Self.package()
        let items = [
            try Self.item(package, "1.wav", range: 0..<48_000, tracks: nil),
            try Self.item(package, "2.wav", range: 0..<144_000, tracks: nil),
        ]
        var reports: [(fraction: Double, index: Int)] = []
        _ = try Self.run(package, items, progress: { reports.append(($0, $1)) })
        let start = try #require(reports.first { $0.index == 1 })
        #expect(start.fraction == 0.25)
        #expect(reports.first?.fraction == 0)
        #expect(reports.map(\.fraction) == reports.map(\.fraction).sorted())
    }
}
