import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The raw CAF removal at the take end (decision 0071, C3): the sweep job that the stop starts
/// removes the CAF of each placed segment that passes the gate, and keeps the sidecar, the
/// anchor, and the WAV.
@MainActor
struct RawRemovalStopTests {
    let folder: TemporaryFolder
    let url: URL
    var capture: URL { url.appending(path: "Capture") }
    var clips: URL { url.appending(path: "Clips") }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 48)!
    let box = InputDevice(
        uid: "box", name: "Box", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 48)!
    static let passing = SegmentName(stem: "take1-1-1")!
    /// The segment of `box`, whose host times have a bow of 1.07 ms.
    static let bowed = SegmentName(stem: "take1-2-1")!

    /// Track `t1` on `mic` and track `t2` on `box`, both mono.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(Route.device(uid: "box", channels: .mono(1)), track: "t2")
        try session.write(to: url)
    }

    /// The steps of the sweep job that the seam saw, and a hold of the job at `.first`.
    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [RawSweepStep] = []
        let first = AsyncGate()

        var seen: [RawSweepStep] { lock.withLock { steps } }

        func step(_ step: RawSweepStep) async {
            lock.withLock { steps.append(step) }
            if step == .first { await first.wait() }
        }
    }

    /// `records` with a parabola added to the host times: 0 at both ends and `bow` seconds at
    /// the middle, as `RawRemovalGateTests.bowed`.
    static func bowed(_ records: [InputRecord], bow: Double) -> [InputRecord] {
        let last = Double(records.count - 1)
        return records.enumerated().map { index, record in
            let u = Double(index) / last
            return InputRecord(
                sampleTime: record.sampleTime,
                hostTimeNanos: record.hostTimeNanos + UInt64((bow * 1e9 * 4 * u * (1 - u)).rounded()),
                frameCount: record.frameCount, nominalRate: record.nominalRate, buffers: record.buffers)!
        }
    }

    /// Records take 1 for 2 s with the job seam of `steps` and the journal `log`, and stops it.
    /// `beforeFinalize` runs in the stop before the finalize.
    func recordAndStop(
        _ studio: Studio, steps: Steps, log: DiagnosticLog = .disabled,
        beforeFinalize: @escaping @Sendable () async -> Void = {}
    ) async throws {
        let hal = TestHAL([mic, box])
        studio.environment = .test(hal)
        studio.environment.log = log
        studio.environment.beforeRawStep = { await steps.step($0) }
        studio.environment.beforeFinalize = beforeFinalize
        _ = try await studio.startTake(
            armed: ["t1", "t2"], devices: [mic, box], playhead: 0, hostTimeNanos: takeStart)
        let micInput = SyntheticInput(hal, "mic")
        let boxInput = SyntheticInput(hal, "box")
        let tone = sine(seconds: 2, rate: 48_000)
        micInput.play(records([tone], layout: [1], rate: 48_000, hostStart: takeStart + 1_000_000))
        boxInput.play(
            Self.bowed(records([tone], layout: [1], rate: 48_000, hostStart: takeStart + 1_000_000), bow: 1.07e-3))
        await micInput.wait()
        await boxInput.wait()
        try await studio.stopRecording()
    }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url.appending(path: path).path) }

    func bytes(_ path: String) throws -> Data { try Data(contentsOf: url.appending(path: path)) }

    func sidecar(_ name: SegmentName) throws -> Sidecar? { try Sidecar.decode(bytes("Capture/\(name.stem).sidecar")) }

    @Test func aPassingSegmentLosesItsCAFAfterTheSweep() async throws {
        let studio = try await Studio.open(url)
        let steps = Steps()
        defer { steps.first.open() }
        try await recordAndStop(studio, steps: steps)
        for name in [Self.passing, Self.bowed] {
            #expect(exists("Capture/\(name.stem).caf"), "\(name) keeps its CAF while the job is held")
            #expect(try sidecar(name)?.finalized != nil, "\(name) has a finalize record")
        }
        let verdicts = rawCaptures(of: studio.session, in: url)
        try #require(verdicts[Self.passing] == .removable, "verdicts: \(verdicts)")
        if case .alignment(let error)? = verdicts[Self.bowed] {
            #expect(error > 1e-3)
        } else {
            Issue.record("the bowed segment is not kept for its alignment: \(verdicts)")
        }
        let kept = [
            "Capture/take1-1-1.sidecar", "Capture/take1-2-1.sidecar", "Capture/take1.anchor", "Clips/take1-1-1.wav",
            "Clips/take1-2-1.wav",
        ]
        let before = try kept.map(bytes)

        steps.first.open()
        await studio.rawSweep

        #expect(!exists("Capture/take1-1-1.caf"), "the passing segment loses its CAF")
        #expect(exists("Capture/take1-2-1.caf"), "the bowed segment keeps its CAF")
        #expect(try kept.map(bytes) == before, "the sidecars, the anchor, and the WAVs do not change")
        #expect(steps.seen.contains(.first))
        #expect(!steps.seen.contains { if case .block = $0 { true } else { false } }, "no audio block read")
        #expect(studio.unplacedSegments == [])
        await studio.settle()
    }

    /// C3: the mix after the sweep has the samples of the mix while the job is held, before any
    /// CAF went.
    @Test func aSweptTakeExportsTheMixOfTheHeldTake() async throws {
        let studio = try await Studio.open(url)
        let steps = Steps()
        defer { steps.first.open() }
        try await recordAndStop(studio, steps: steps)
        let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)
        let source = try #require(ExportSource(range: 0..<144_000))
        let (held, swept) = (folder.url.appending(path: "held.wav"), folder.url.appending(path: "swept.wav"))
        _ = try exportMix(studio.session, source: source, options: options, to: held, package: { url })

        steps.first.open()
        await studio.rawSweep

        try #require(!exists("Capture/take1-1-1.caf"), "the sweep removed the passing CAF")
        _ = try exportMix(studio.session, source: source, options: options, to: swept, package: { url })
        let (before, after) = (try readAudio(held).samples, try readAudio(swept).samples)
        #expect(before.contains { $0 != 0 }, "the held mix has the take")
        #expect(after == before)
        await studio.settle()
    }

    /// C2e: the CAF of a segment whose clip an edit deleted stays: no clip uses its pool file.
    @Test func aDeletedTakeClipKeepsItsCAF() async throws {
        let studio = try await Studio.open(url)
        let steps = Steps()
        defer { steps.first.open() }
        try await recordAndStop(studio, steps: steps)
        let delete = { (session: inout Session) throws(StudioError) in
            do throws(SessionError) { try session.removeClips(["take1-1-1"]) } catch { throw .session(error) }
        }
        try studio.edit(agent: nil, refused: { $0 }, delete)
        await studio.serialized {}
        try #require(studio.saveError == nil && studio.sessionRevision == studio.savedRevision)

        steps.first.open()
        await studio.rawSweep

        #expect(exists("Capture/take1-1-1.caf"), "the segment of the deleted clip keeps its CAF")
        await studio.settle()
    }

    /// C11: a `Capture/` that refuses the unlink keeps the CAF, and the journal has one `raw` line
    /// with the errno.
    @Test func aCaptureFolderThatRefusesTheUnlinkKeepsTheCAF() async throws {
        let logs = folder.url.appending(path: "logs")
        let log = startLog(in: logs)
        let studio = try await Studio.open(url, log: log)
        let steps = Steps()
        defer { steps.first.open() }
        try await recordAndStop(studio, steps: steps, log: log)
        #expect(studio.takeError == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: capture.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: capture.path) }

        steps.first.open()
        await studio.rawSweep

        #expect(exists("Capture/take1-1-1.caf"))
        let raw = TakeLogTests.lines(log, in: logs).filter { $0.contains("\traw\t") }
        #expect(raw.count == 1, "raw lines: \(raw)")
        #expect(raw.first?.contains("errno=\(EACCES)") == true, "raw lines: \(raw)")
        await studio.settle()
    }

    /// A `settle()` that begins while a take start waits for a held job returns only after that
    /// take stopped: the start takes its turn before the settle reads the transport.
    @Test func aSettleDuringAStartThatWaitsForTheJobStopsTheTake() async throws {
        let studio = try await Studio.open(url)
        let steps = Steps()
        defer { steps.first.open() }
        try await recordAndStop(studio, steps: steps)
        await steps.first.entered()
        let start = Task {
            try await studio.startTake(
                armed: ["t1", "t2"], devices: [mic, box], playhead: 0, hostTimeNanos: takeStart)
        }
        await until(limit: .seconds(10), "the take start does not begin") { studio.isStarting }
        let settle = Task { await studio.settle() }
        await until(limit: .seconds(10), "the settle does not begin") { studio.settling }

        steps.first.open()
        await settle.value
        _ = try? await start.value

        #expect(studio.transport == .idle)
        #expect(studio.session.recording == nil, "the settle stopped the take")
    }
}
