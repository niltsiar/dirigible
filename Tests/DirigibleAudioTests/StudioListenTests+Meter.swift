import Testing

@testable import DirigibleAudio

extension StudioListenTests {
    /// Code gate 1 item 5: the studio meters each listened device track, with no armed request.
    /// The monitor request and the listen request are read at the monitor turn, so an older
    /// request of a window cannot meter a track that is not listened now.
    @Test func aListenedTrackGetsAMeter() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        try await studio.listen(to: ["t1", "t4"])
        try await studio.monitor(armed: [])
        #expect(studio.monitorWriter("duo") != nil, "a listened track has no meter")
        #expect(studio.liveTracks["t1"]?.state == .monitoring, "a listened track has no meter")
        #expect(studio.liveTracks["t4"] == nil, "an app route has no meter")
        try await studio.monitor(armed: ["t1"])
        #expect(studio.monitors["duo"]?.tracks.map(\.id) == ["t1"], "an armed and listened track gets two meters")

        try await studio.listen(to: [])
        try await studio.monitor(armed: [])
        #expect(studio.monitorWriter("duo") == nil, "a track that is not listened keeps its meter")
        #expect(studio.liveTracks["t1"] == nil, "a track that is not listened keeps its meter")
        await studio.settle()
        _ = folder
    }
}
