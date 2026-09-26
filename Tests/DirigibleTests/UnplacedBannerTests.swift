import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The take banner of decision 0021 (criteria 21 and 22) on a real Studio with the counting HAL:
/// the Place rows of the unplaced segments, and the finish of a take without unreadable audio.
@Suite(.serialized) @MainActor struct UnplacedBannerTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    static let first = SegmentName(stem: "take1-1-1")!
    static let second = SegmentName(stem: "take1-2-1")!

    init() throws { folder = try TemporaryFolder() }

    /// Tracks t1 and t2 on channels 1 and 2 of `duo`, with no clip. The write runs off the main
    /// actor.
    func open() async throws -> (SessionWindow, Studio) {
        let url = folder.url.appending(path: "place.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            for (n, channel) in [(1, 1), (2, 2)] {
                let track = TrackID("t\(n)")
                try session.addTrack(track, name: "T\(n)", layout: .mono)
                try session.setRoute(Route(deviceUID: "duo", channels: .mono(channel)), track: track)
            }
            try session.write(to: url)
        }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        model.armed = ["t1", "t2"]
        return (model, studio)
    }

    /// Records 0.5 s on both tracks. `beforeStop` runs when both CAFs exist, before the stop.
    func take(_ model: SessionWindow, _ studio: Studio, beforeStop: () -> Void = {}) async {
        await model.record()
        await hal.feed(seconds: 0.5)
        let capture = model.url.appending(path: captureFolderName)
        await until("both CAFs exist") {
            [Self.first, Self.second].allSatisfy {
                FileManager.default.fileExists(atPath: capture.appending(path: "\($0.stem).caf").path)
            }
        }
        beforeStop()
        await model.stop()
        await until("the finalize ends") { studio.transport == .idle }
    }

    /// A finished take, then an undo past it and a new edit, so both segments are unplaced and
    /// Redo is not available. Returns the clips of the take.
    func unplacedTake(_ model: SessionWindow, _ studio: Studio) async throws -> [Clip] {
        await take(model, studio)
        let clips = studio.session.tracks.flatMap(\.clips)
        try #require(clips.map(\.id) == ["take1-1-1", "take1-2-1"])
        model.undo()
        model.addTrack()
        try #require(studio.unplacedSegments == [Self.first, Self.second])
        return clips
    }

    // MARK: Criterion 21

    @Test func aPlaceFromTheBannerPutsTheClipAtItsRecordedTime() async throws {
        let (model, studio) = try await open()
        let clips = try await unplacedTake(model, studio)
        #expect(model.canPlace)

        await model.place(Self.first, atPlayhead: false)

        #expect(studio.session.track("t1")?.clips.map { $0 } == [clips[0]])
        #expect(studio.unplacedSegments == [Self.second])
        #expect(model.alert == nil)
        await model.close()
    }

    /// Code gate 1 item 1: a take from a build before decision 0021 has no anchor file, so the
    /// default Place fails. The alert names the way out in both languages.
    @Test func aPlaceWithNoAnchorNamesPlaceAtPlayhead() async throws {
        let (model, studio) = try await open()
        _ = try await unplacedTake(model, studio)
        try FileManager.default.removeItem(at: model.url.appending(path: "\(captureFolderName)/take1.anchor"))

        await model.place(Self.first, atPlayhead: false)

        #expect(model.alert == .error(.segment(Self.first, .noAlignment)))
        #expect(studio.unplacedSegments == [Self.first, Self.second])
        for language in ["en", "es"] {
            let table = try stringsTable(language)
            let placeAtPlayhead = try #require(table[L10n.menuUnplacedPlacePlayhead.rawValue])
            let text = try #require(table[L10n.errorSegmentNoAlignment.rawValue])
            #expect(text.contains(placeAtPlayhead), "\(language): \(text)")
        }
        await model.close()
    }

    @Test func placeAtPlayheadNeedsOneSelectedTrack() async throws {
        let (model, studio) = try await open()
        await take(model, studio)
        await studio.perform(.seek(.frame(12_000)))
        model.undo()
        model.addTrack()
        try #require(studio.playhead == 12_000)

        for tracks: Set<TrackID> in [[], ["t1", "t2"]] {
            model.timeline.marks = Marks(tracks: tracks)
            #expect(!model.canPlaceAtPlayhead, "\(tracks)")
            await model.place(Self.first, atPlayhead: true)
            #expect(studio.unplacedSegments == [Self.first, Self.second], "\(tracks)")
        }
        model.timeline.marks = Marks(tracks: ["t2"])
        #expect(model.canPlaceAtPlayhead)

        await model.place(Self.first, atPlayhead: true)

        #expect(studio.session.track("t2")?.clips.map(\.id) == ["take1-1-1"])
        #expect(studio.session.track("t2")?.clips.first?.start == 12_000)
        #expect(studio.unplacedSegments == [Self.second])
        await model.close()
    }

    /// Plan gate 1 item 1: a placement clears the redo stack, so the rows wait while Redo is
    /// available. The refused Place keeps the redo stack.
    @Test func anUndoPastATakeDisablesPlaceUntilRedo() async throws {
        let (model, studio) = try await open()
        await take(model, studio)

        model.undo()
        #expect(studio.unplacedSegments == [Self.first, Self.second])
        #expect(!model.canPlace)
        #expect(model.placeWaitsForRedo)
        await model.place(Self.first, atPlayhead: false)
        #expect(studio.canRedo, "the refused Place keeps the redo stack")
        #expect(studio.unplacedSegments == [Self.first, Self.second])

        model.redo()
        #expect(studio.unplacedSegments == [])

        model.undo()
        model.addTrack()
        #expect(model.canPlace)
        #expect(!model.placeWaitsForRedo)
        await model.close()
    }

    // MARK: Criterion 22

    enum Pending: String, CaseIterable, CustomTestStringConvertible {
        case unreadable, writeFailed, none
        var testDescription: String { rawValue }
    }

    @Test(arguments: Pending.allCases)
    func theFinishButtonShowsOnlyForAnUnreadableSegment(pending: Pending) async throws {
        let (model, studio) = try await open()
        let caf = model.url.appending(path: "\(captureFolderName)/take1-1-1.caf")
        let clips = model.url.appending(path: clipsFolderName)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        defer { chmod(caf.path, 0o644) }
        defer { chmod(clips.path, 0o755) }

        await take(model, studio) {
            switch pending {
            case .unreadable: chmod(caf.path, 0o000)
            case .writeFailed: chmod(clips.path, 0o500)
            case .none: break
            }
        }

        switch pending {
        case .unreadable:
            #expect(
                studio.takeError
                    == .finalize(.segmentUnreadable(Self.first, file: "Capture/take1-1-1.caf", errno: EACCES)))
            #expect(model.canFinishLeavingUnreadable)
        case .writeFailed:
            #expect(studio.pendingTake != nil)
            #expect(!model.canFinishLeavingUnreadable)
        case .none:
            #expect(studio.takeError == nil)
            #expect(!model.canFinishLeavingUnreadable)
        }
        await model.close()
    }

    @Test func finishLeavingUnreadableEndsTheTake() async throws {
        let (model, studio) = try await open()
        let caf = model.url.appending(path: "\(captureFolderName)/take1-1-1.caf")
        defer { chmod(caf.path, 0o644) }
        await take(model, studio) { chmod(caf.path, 0o000) }
        try #require(studio.pendingTake != nil)

        await model.finishLeavingUnreadable()

        #expect(studio.pendingTake == nil)
        #expect(studio.takeError == nil)
        #expect(studio.session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(studio.unplacedSegments == [Self.first])
        await model.close()
    }
}
