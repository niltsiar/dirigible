import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The preset set of decision 0080 (criteria E6, E7, and E8): one file for each preset, each with
/// its own options, and the checks before the first file.
struct ExportPresetSetTests {
    typealias Preset = (ref: PresetRef, options: PresetOptions)

    static let master: Preset = (.builtIn(.master), BuiltInPreset.master.options)
    static let podcast: Preset = (.builtIn(.podcast), BuiltInPreset.podcast.options)

    static func mp3(_ name: String, rate: ExportRate = .hz44100) throws -> Preset {
        (
            .session(try PresetName(name)),
            try PresetOptions(format: .mp3(.k128), layout: .mono, rate: rate, loudness: nil)
        )
    }

    static func run(
        _ package: MixPackage, _ presets: [Preset], prefix: String = "Ep", replacing: [URL: ConfirmedFile] = [:]
    ) throws(ExportPresetsError) -> [ExportedPreset] {
        let source = ExportSource(range: 0..<package.session.end)!
        return try exportPresets(
            package.session, source: source, presets: presets, folder: package.folder.url, prefix: prefix,
            replacing: replacing, package: { package.url }, isCancelled: { false })
    }

    /// The names in the folder of `package` that a set can write: no package, no audio file of it.
    static func names(_ package: MixPackage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).filter {
            !$0.hasSuffix(".dirigible")
        }.sorted()
    }

    /// E6. Controls: one gain for the set; the master with the podcast gain. Each makes the WAV
    /// differ from the export with loudness Off.
    @Test func masterAndPodcastWriteTwoFilesWithTheirOwnLoudness() throws {
        let package = try ExportTests.package(tone([(20, -30)]))

        let files = try Self.run(package, [Self.master, Self.podcast])

        #expect(files.map(\.preset) == [.builtIn(.master), .builtIn(.podcast)])
        #expect(files.map(\.url.lastPathComponent) == ["Ep.wav", "Ep.mp3"])
        #expect(files[0].result.loudness == nil)
        let reference = package.folder.url.appending(path: "reference.wav")
        _ = try exportMix(
            package.session, source: ExportSource(range: 0..<package.session.end)!,
            options: ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session), to: reference,
            package: { package.url })
        let wav = try readAudio(files[0].url)
        let expected = try readAudio(reference)
        #expect(wav.rate == 48_000)
        #expect(wav.bits == 24)
        #expect(wav.samples.count == expected.samples.count)
        // An index, not the arrays: a failed compare of 960_000 samples does not print them.
        let difference = zip(wav.samples, expected.samples).enumerated().first { $1.0 != $1.1 }?.offset
        #expect(difference == nil, "the master WAV is not the export with loudness Off")

        let mp3 = try ExportTests.read(files[1].url)
        #expect(mp3.channels.count == 1)
        #expect(mp3.format.mSampleRate == 44_100)
        let decoded = try #require(try measure(mp3.channels, rate: 44_100).integrated).value
        #expect(abs(decoded - -19) <= 0.2, "the decoded MP3 reads \(decoded) LUFS")
        let report = try #require(files[1].result.loudness)
        expectLUFS(report.output, decoded, tolerance: 0.05, "the report")
    }

    /// E7: two presets of one extension give each file of the set the preset name, the WAV too;
    /// a "/" becomes "-". Control: no preset suffix on a clash.
    @Test func twoMP3PresetsAddThePresetNames() throws {
        let package = try ExportTests.package(tone([(1, -20)]))

        let files = try Self.run(package, [Self.master, try Self.mp3("Feed A/B"), try Self.mp3("Hi")])

        let names = ["Ep-master.wav", "Ep-Feed A-B.mp3", "Ep-Hi.mp3"]
        #expect(files.map(\.url.lastPathComponent) == names)
        #expect(try Self.names(package) == names.sorted())
    }

    /// E7: a built-in gives its fixed ID, not a display name. Control: the display name.
    @Test func aBuiltInFileNameUsesItsID() throws {
        let folder = URL(filePath: "/Volumes/Out")

        let targets = try presetTargets(
            [Self.master, Self.podcast, try Self.mp3("Extra")], folder: folder, prefix: "Ep", sessionRate: 48_000)

        #expect(targets.map(\.url.lastPathComponent) == ["Ep-master.wav", "Ep-podcast.mp3", "Ep-Extra.mp3"])
        #expect(targets.map(\.preset) == [.builtIn(.master), .builtIn(.podcast), .session(try PresetName("Extra"))])
    }

    /// E8: two targets with one name after the character rule, with case and Unicode normalization
    /// folded, or after the byte cut, refuse the set before any file. Control: no duplicate check.
    @Test func twoPresetsOfOneFileNameRefuseTheSet() throws {
        let long = String(repeating: "x", count: 40)
        let prefix = String(repeating: "p", count: 200)
        let cases: [(first: String, second: String, prefix: String)] = [
            ("Show/Feed", "Show-Feed", "Ep"),
            ("Caf\u{E9}", "CAFE\u{301}", "Ep"),
            ("\(long)1", "\(long)2", prefix),
        ]
        for item in cases {
            let package = try ExportTests.package(tone([(1, -20)]))
            let presets = [try Self.mp3(item.first), try Self.mp3(item.second)]
            let urls = try presetTargetsUnchecked(presets, package, item.prefix)

            #expect(throws: ExportPresetsError.duplicateTargets(urls), "\(item.first), \(item.second)") {
                try Self.run(package, presets, prefix: item.prefix)
            }
            #expect(try Self.names(package) == [], "\(item.first), \(item.second)")
        }
    }

    /// The targets of `presets` from the file name rule alone, with no duplicate check.
    func presetTargetsUnchecked(_ presets: [Preset], _ package: MixPackage, _ prefix: String) throws -> [URL] {
        Session.presetFileNames(
            presets.map { ($0.ref, $0.options.format.pathExtension) }, prefix: prefix, limit: exportNameLimit
        ).map { package.folder.url.appending(path: $0) }
    }

    /// E8: an item at the second target that the user did not confirm refuses the set before any
    /// file, and the item keeps its bytes.
    @Test func anUnconfirmedSecondTargetRefusesTheSet() throws {
        let package = try ExportTests.package(tone([(1, -20)]))
        let second = package.folder.url.appending(path: "Ep.mp3")
        try Data("old".utf8).write(to: second)

        #expect(throws: ExportPresetsError.exists([second])) {
            try Self.run(package, [Self.master, Self.podcast])
        }
        #expect(try Self.names(package) == ["Ep.mp3"])
        #expect(try Data(contentsOf: second) == Data("old".utf8))
    }

    /// E8: an MP3 preset at the session rate in a 96000 Hz session refuses the set before any file.
    /// Controls: the rate check inside the loop leaves file 1; the error of `exportMix` with no map
    /// to the preset.
    @Test func aRateThatOnePresetRefusesStopsTheSetBeforeAnyFile() throws {
        let package = try ExportTests.package(tone([(1, -20)], rate: 96_000), rate: 96_000)
        let feed = try Self.mp3("Feed", rate: .session)

        #expect(throws: ExportPresetsError.rateNotSupported(feed.ref, 96_000)) {
            try Self.run(package, [Self.master, feed])
        }
        #expect(try Self.names(package) == [])
    }
}
