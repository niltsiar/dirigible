import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 9b criteria 13 and 21: the short-term loudness of each armed track during record and
/// monitor. The unit cases drive `TrackSegments` of a monitor with records of 0.1 s and read
/// `takeLevels` after each one, as each drain of the writer does. The Studio cases send a burst
/// of 4 s and read the value after the window fills (plan gate 2, V3).
@MainActor
struct RecordLoudnessTests {
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [24_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    /// Interleaved records of 0.1 s of a 1 kHz tone at -23 dBFS at `rate`, the same in each of
    /// `channels` channels.
    func toneRecords(seconds: Double, rate: Double, sampleStart: Double = 0, channels: Int = 2) -> [InputRecord] {
        let signal = tone([(seconds, -23)], rate: Int(rate), layout: .mono)[0]
        let interleaved = signal.flatMap { Array(repeating: $0, count: channels) }
        return records(
            [interleaved], layout: [channels], rate: rate, frames: Int(rate / 10), sampleStart: sampleStart,
            hostStart: takeStart + UInt64(sampleStart / rate * 1e9))
    }

    /// A monitor of `tracks` on `duo`.
    func monitor(_ tracks: [Route.Channels]) -> TrackSegments {
        TrackSegments(
            device: duo, tracks: tracks.enumerated().map { (arm: $0 + 1, channels: $1) }, files: nil, report: { _ in })
    }

    /// The short-term value of `arm` after each record.
    func shortTerms(_ segments: inout TrackSegments, _ records: [InputRecord], arm: Int = 1) -> [LUFS?] {
        records.map { record in
            _ = segments.write(record)
            return segments.takeLevels()[arm]?.shortTerm
        }
    }

    /// The stereo arm fed as mono reads -26.0.
    @Test func anArmedTrackHasItsShortTerm() {
        var segments = monitor([.stereo(1, 2), .mono(1)])
        let records = toneRecords(seconds: 4, rate: 48_000)
        var stereo: [LUFS?] = []
        var mono: [LUFS?] = []
        for record in records {
            _ = segments.write(record)
            let levels = segments.takeLevels()
            stereo.append(levels[1]?.shortTerm)
            mono.append(levels[2]?.shortTerm)
        }
        #expect(stereo[0..<29].allSatisfy { $0 == nil }, "S of the stereo arm before 3 s")
        for index in 29..<40 {
            expectLUFS(stereo[index], -23, "stereo arm at \(Double(index + 1) / 10) s")
            expectLUFS(mono[index], -26, "mono arm at \(Double(index + 1) / 10) s")
        }
    }

    /// The 48 kHz filter on 24 kHz input reads more than 0.1 LU off. A new meter at each record
    /// never fills its window.
    @Test(arguments: ["reattach", "in place"])
    func aRateChangeRebuildsTheMeter(_ change: String) {
        var segments = monitor([.stereo(1, 2)])
        _ = shortTerms(&segments, toneRecords(seconds: 4, rate: 48_000))
        if change == "reattach" {
            segments.use(
                InputDevice(
                    uid: "duo", name: "Duo", nominalRate: 24_000, availableRates: [24_000...48_000],
                    channelsPerBuffer: [2], latency: 0)!)
        }
        let after = shortTerms(&segments, toneRecords(seconds: 4, rate: 24_000, sampleStart: 4 * 48_000))
        for index in 29..<40 { expectLUFS(after[index], -23, "\(change): S \(Double(index + 1) / 10) s after") }
    }

    /// The record meters keep no 400 ms blocks: a long take would keep 36 000 an hour.
    @Test func takeLevelsClearsTheBlocks() {
        var segments = monitor([.stereo(1, 2)])
        _ = shortTerms(&segments, toneRecords(seconds: 1, rate: 48_000))
        #expect(segments.loudnessBlocks == 0, "blocks after takeLevels: \(segments.loudnessBlocks)")
    }

    /// A package with the stereo track `t1` on channels 1 and 2 of `trio`, and the mono track
    /// `t2` on channel 3: a take refuses two tracks on one channel.
    func studio() async throws -> (folder: TemporaryFolder, studio: Studio, hal: TestHAL) {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Show.dirigible")
        try await offMainActor {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .stereo)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.setRoute(Route.device(uid: "trio", channels: .stereo(1, 2)), track: "t1")
            try session.setRoute(Route.device(uid: "trio", channels: .mono(3)), track: "t2")
            try session.write(to: url)
        }
        let trio = try #require(
            InputDevice(
                uid: "trio", name: "Trio", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [3], latency: 0))
        let hal = TestHAL([trio])
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        return (folder, studio, hal)
    }

    /// The take and the monitor give each armed track its short-term value; a lost device
    /// clears it at once.
    @Test(arguments: ["take", "monitor"])
    func eachArmedTrackShowsItsShortTerm(_ path: String) async throws {
        let (folder, studio, hal) = try await studio()
        if path == "take" {
            try await studio.startRecording(armed: ["t1", "t2"])
        } else {
            try await studio.monitor(armed: ["t1", "t2"])
        }
        SyntheticInput(hal, "trio").play(
            toneRecords(seconds: 4, rate: 48_000, channels: 3), takeStartIn: path == "take" ? studio.url : nil)
        // A hang guard, as for the monitor peaks of MonitorTests.
        await until(limit: .seconds(20), "\(path): no short-term value") {
            studio.liveTracks["t1"]?.shortTerm != nil && studio.liveTracks["t2"]?.shortTerm != nil
        }
        expectLUFS(studio.liveTracks["t1"]?.shortTerm, -23, "\(path): the stereo track")
        expectLUFS(studio.liveTracks["t2"]?.shortTerm, -26, "\(path): the mono track")

        if case .recording(let take) = studio.transport {
            studio.apply(.state(take: take, arm: 1, .deviceLost, status: nil), generation: studio.generation)
            #expect(studio.liveTracks["t1"]?.shortTerm == nil, "take: S after deviceLost")
            try await studio.stopRecording()
        } else {
            let number = try #require(studio.monitors["trio"]?.number)
            studio.applyMonitor(.state(take: 0, arm: 1, .deviceLost, status: nil), number: number, uid: "trio")
            studio.applyMonitor(.state(take: 0, arm: 2, .retryStopped, status: nil), number: number, uid: "trio")
            #expect(studio.liveTracks["t1"]?.shortTerm == nil, "monitor: S after deviceLost")
            #expect(studio.liveTracks["t2"]?.shortTerm == nil, "monitor: S after retryStopped")
            try await studio.monitor(armed: [])
        }
        await studio.settle()
        _ = folder
    }
}
