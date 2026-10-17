import DirigibleCore
import Foundation

/// The reason of the latency activity of a monitor.
let monitorReason = "Dirigible monitors inputs"
/// The kept inputs of one monitor writer: about 200 bytes each (decision 0015).
let monitorKeepLimit = 64

/// One device of the monitor: its writer, its tracks in arm order, and the number of its reports.
struct Monitor {
    let writer: DeviceWriter
    let tracks: [MonitoredTrack]
    let number: Int
}

struct MonitoredTrack: Hashable, Sendable {
    let id: TrackID
    let channels: Route.Channels
}

extension Studio {
    /// Meters `armed` and the listened tracks while no take writer exists (decision 0015). Each
    /// of these tracks with a route gets an entry in `liveTracks`: `.monitoring`, `.deviceLost`
    /// while its device is gone, or `.retryStopped` at the keep limit.
    /// It writes no file. An empty request (or no routed track) releases every monitor device
    /// before it returns. It runs in the monitor order, not in the package write chain, so it
    /// never waits for an autosave, a start save, or a finalize. While take writers exist, it
    /// only stores the request. The last call wins. Throws `.microphoneAccess` when the access
    /// is not granted; then it holds no device. A listened track keeps its meter until
    /// `listen(to:)` releases it and the next call of this function runs.
    public func monitor(armed: [TrackID]) async throws(StudioError) {
        monitorRequest = armed
        if !monitorPlan().isEmpty {
            let access = await microphoneAccess(of: environment)
            // A later call owns the request now.
            guard monitorRequest == armed else { return }
            if let access {
                monitorRequest = []
                await monitorTurns.run { await applyMonitor() }
                throw .microphoneAccess(access)
            }
        }
        await monitorTurns.run { await applyMonitor() }
    }

    /// The monitor writer of `uid`. For tests.
    func monitorWriter(_ uid: String) -> DeviceWriter? { monitors[uid]?.writer }

    /// The tracks with a device route of the monitor request and then of the listen request
    /// (decision 0044), by device UID, in request order. It reads both requests at the turn, so
    /// the last call of each wins.
    private func monitorPlan() -> [String: [MonitoredTrack]] {
        var plan: [String: [MonitoredTrack]] = [:]
        for id in monitorRequest + listenRequest.filter({ !monitorRequest.contains($0) }) {
            // An app route has no monitor: no tap and no prompt at arm time (decision 0029).
            guard case .device(let uid, let channels) = session.track(id)?.route else { continue }
            plan[uid, default: []].append(MonitoredTrack(id: id, channels: channels))
        }
        return plan
    }

    /// Makes the monitor writers match the request: a device with the same tracks keeps its
    /// writer, and a device whose tracks changed or went is finished. The caller holds a monitor
    /// turn. With take writers, it changes nothing. It makes the whole state change before its
    /// first await and then waits for the finish of each released writer, so a take that begins
    /// meanwhile keeps its entries of `liveTracks`. The device of a writer that a stop left
    /// unfinished gets no monitor writer: its queue can wait in a HAL call of that device.
    func applyMonitor() async {
        guard writers.isEmpty else { return }
        let held = Set(unfinishedWriters.map(\.uid))
        let plan = monitorPlan().filter { !held.contains($0.key) }
        var released: [DeviceWriter] = []
        for (uid, monitor) in monitors where plan[uid] != monitor.tracks {
            monitors[uid] = nil
            for track in monitor.tracks { liveTracks[track.id] = nil }
            released.append(monitor.writer)
        }
        for (uid, tracks) in plan where monitors[uid] == nil {
            guard
                let device = InputDevice.placeholder(uid: uid, channels: tracks.flatMap(\.channels.numbers).max() ?? 1)
            else { continue }
            reportNumber += 1
            let writer = DeviceWriter(
                device: device, tracks: tracks.enumerated().map { (arm: $0.offset + 1, channels: $0.element.channels) },
                files: nil, hal: environment.hal, log: environment.log,
                report: Self.monitorReporter(to: self, number: reportNumber, uid: uid),
                silenceLimit: environment.silenceLimit, firstRecordLimit: environment.firstRecordLimit, ringSeconds: 1,
                keepLimit: monitorKeepLimit)
            monitors[uid] = Monitor(writer: writer, tracks: tracks, number: reportNumber)
            for track in tracks { liveTracks[track.id] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0) }
            writer.start()
        }
        // A monitor writer has no file, so one that does not finish in time loses no audio.
        let answers = await boundedEach(released, by: ContinuousClock.now + environment.stopLimit) { await $0.finish() }
        for writer in released where answers[ObjectIdentifier(writer)] == nil { writer.finishLater() }
    }
}

/// The microphone access, read off the main actor.
@concurrent nonisolated func microphoneAccess(of environment: CaptureEnvironment) async -> MicrophoneAccess? {
    environment.microphoneAccess()
}
