import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

extension SilencesInspectorTests {
    /// C36 window part (decision 0073): Apply with a follow track `t2` that the cut of silence A would
    /// move over its first clip sets the follow alert of `t2` at the start of the second clip, and
    /// changes nothing. Clip p of `t2` is 60 000 ..< 110 000 and clip q 150 000 ..< 250 000; the cut
    /// 108 000 ..< 204 000 puts q at 108 000.
    @Test func applyShowsTheFollowAlert() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = try await package(tracks: [Self.voice, [.quiet(10)]])
        try await Task.detached {
            var session = try Session(contentsOf: url)
            try session.removeClips(["c2"])
            try session.place(Clip(id: "p", file: "f2", start: 60_000, offset: 0, length: 50_000), on: "t2")
            try session.place(Clip(id: "q", file: "f2", start: 150_000, offset: 100_000, length: 100_000), on: "t2")
            try session.setFollowTrack(true, tracks: ["t2"])
            try session.write(to: url)
        }.value
        let (model, studio) = try await open(url)
        let before = studio.session
        await model.scanSilences()
        try #require(model.canApplySilences, "a list to apply: \(rows(model))")

        model.applySilences()

        #expect(
            model.alert == .followOverlap(FollowOverlap(track: "t2", trackName: "T2", start: 150_000, rate: 48_000)))
        #expect(studio.session == before && !studio.canUndo)
        await model.close()
    }
}
