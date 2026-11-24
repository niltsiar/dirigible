import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The export of one file for each preset as one Studio job (decision 0080, criteria E9 and E21).
@MainActor
struct StudioExportPresetTests {
    static let range: Range<Frames> = 0..<48_000

    /// Three presets of three extensions, with no loudness target: one chunk of render for each file.
    static func presets() throws -> [(ref: PresetRef, options: PresetOptions)] {
        [
            (.builtIn(.master), BuiltInPreset.master.options),
            (
                .session(try PresetName("Archive")),
                try PresetOptions(format: .flac(.bits24), layout: .stereo, rate: .session, loudness: nil)
            ),
            (
                .session(try PresetName("Web")),
                try PresetOptions(format: .aac(.k128), layout: .stereo, rate: .session, loudness: nil)
            ),
        ]
    }

    static func targets(_ fixture: ExportStudioFixture) -> [URL] {
        ["Ep.wav", "Ep.flac", "Ep.m4a"].map { fixture.package.folder.url.appending(path: $0) }
    }

    static func startSet(
        _ studio: Studio, _ fixture: ExportStudioFixture, _ presets: [(ref: PresetRef, options: PresetOptions)]
    ) -> Task<[ExportedPreset], any Error> {
        let folder = fixture.package.folder.url
        return Task {
            try await studio.export(
                presets: presets, source: ExportSource(range: range)!, folder: folder, prefix: "Ep", replacing: [:])
        }
    }

    /// The names of the set files in the folder of `fixture`.
    static func setFiles(_ fixture: ExportStudioFixture) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixture.package.folder.url.path).filter {
            $0.hasPrefix("Ep")
        }.sorted()
    }

    /// E9: a take in another studio during file 2 of 3 ends the set; file 1 stays. Controls: a
    /// caller loop of `Studio.export` starts file 2 after the take; a stop that removes the finished
    /// files leaves no file 1. The gate holds file 2 at its first cancel read (reads 1 to 3 are
    /// file 1) until the take has set the cancel flag, so no main-actor hold lets the set run on.
    @Test func aTakeInAnotherWindowEndsThePresetSet() async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let b = try await ExportStudioFixture.make()
        let gate = Gate(limit: nil)
        let studioB = try await b.open(seam: ChunkSeam(at: [4: { gate.waitOnce() }]))
        defer { gate.open() }
        let targets = Self.targets(b)
        let export = Self.startSet(studioB, b, try Self.presets())
        await gate.entered()
        await until(limit: .seconds(30), "file 2 did not start") { studioB.exportFile?.number == 2 }
        studioA.otherStudios = { [studioB] }

        let start = Task { try await studioA.startTake(armed: ["t1"], devices: [a.mic], hostTimeNanos: takeStart) }
        await until(limit: .seconds(30), "the take did not end the set") { studioB.exportStop == .take }
        gate.open()
        _ = try await start.value

        let error = await #expect(throws: StudioError.self) { try await export.value }
        guard case .exportPresets(.stopped(let stop))? = error else {
            Issue.record("no preset set stop: \(String(describing: error))")
            return
        }
        #expect(stop.error == .cancelled)
        #expect(stop.written.map(\.url) == [targets[0]])
        #expect(stop.written.map(\.preset) == [.builtIn(.master)])
        #expect(stop.remaining == Array(targets[1...]))
        #expect(studioB.exportStop == .take)
        #expect(studioB.exportProgress == nil)
        #expect(try Self.setFiles(b) == ["Ep.wav"])
        #expect(try b.temporaryFiles() == [])
        try await StudioExportTests().recordAndStop(studioA, hal, from: takeStart)
    }

    /// E21: the job keeps the preset list of the set, so the preset of the file in hand is at
    /// `exportFile.number - 1`. Control: a list of the first preset for each file.
    @Test func theJobKeepsThePresetList() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await fixture.open(seam: ChunkSeam(pause: longChunk))
        let presets = Array(try Self.presets().prefix(2))
        #expect(studio.exportPresetRefs == nil)
        let export = Self.startSet(studio, fixture, presets)
        await until(limit: .seconds(30), "file 2 did not start") { studio.exportFile?.number == 2 }

        let refs = try #require(studio.exportPresetRefs)
        let number = try #require(studio.exportFile?.number)
        #expect(refs[number - 1] == .session(try PresetName("Archive")))
        #expect(studio.exportFile?.count == 2)
        #expect(studio.exportFile?.name == "Ep.flac")

        let files = try await export.value
        #expect(files.map(\.preset) == presets.map(\.ref))
        #expect(studio.exportPresetRefs == nil)
        #expect(studio.exportFile == nil)
    }

    /// The app passes the chapter title of its language, as the Export panel does (`ExportSettings.options`):
    /// an M4A file gets a chapter at the start when its first chapter starts later.
    @Test func aPresetSetGivesTheIntroTitle() async throws {
        let fixture = try await ExportStudioFixture.make { package in
            try package.session.setMarker(Marker(id: "m", name: "Talk", position: 96_000, kind: .chapter))
        }
        let studio = try await fixture.open()
        let web = [
            (
                PresetRef.session(try PresetName("Web")),
                try PresetOptions(format: .aac(.k128), layout: .stereo, rate: .session, loudness: nil)
            )
        ]
        let files = try await studio.export(
            presets: web, source: ExportSource(range: 0..<480_000)!, folder: fixture.package.folder.url,
            prefix: "Ep", replacing: [:], introTitle: "Inicio")
        let url = try #require(files.first?.url)
        let groups = try await AVURLAsset(url: url).loadChapterMetadataGroups(
            withTitleLocale: Locale(identifier: "en"), containingItemsWithCommonKeys: [])
        var titles: [String] = []
        for group in groups {
            for item in group.items { titles.append(try await item.load(.stringValue) ?? "") }
        }
        #expect(titles == ["Inicio", "Talk"])
    }
}
