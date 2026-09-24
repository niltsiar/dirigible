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
    /// Meters `armed` while no take writer exists (decision 0015). Each armed track with a route
    /// gets an entry in `liveTracks`: `.monitoring`, `.deviceLost` while its device is gone, or
    /// `.retryStopped` at the keep limit.
    /// It writes no file. An empty request (or no routed track) releases every monitor device
    /// before it returns. It runs in the monitor order, not in the package write chain, so it
    /// never waits for an autosave, a start save, or a finalize. While take writers exist, it
    /// only stores the request. The last call wins. Throws `.microphoneAccess` when the access
    /// is not granted; then it holds no device.
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

    /// The hand-over to a take (decision 0015), after `begin`: in one monitor turn, it waits until
    /// each take writer tried its first attach, then finishes each monitor writer. So the device
    /// keeps running (probe Q1). `begin` replaced the entries of `liveTracks` already.
    func handOver() async {
        await monitorTurns.run {
            for writer in writers.values { await writer.started() }
            let released = monitors
            monitors = [:]
            for monitor in released.values { await monitor.writer.finish() }
        }
    }

    /// The monitor writer of `uid`. For tests.
    func monitorWriter(_ uid: String) -> DeviceWriter? { monitors[uid]?.writer }

    /// The armed tracks of the request with a route, by device UID, in request order.
    private func monitorPlan() -> [String: [MonitoredTrack]] {
        var plan: [String: [MonitoredTrack]] = [:]
        for id in monitorRequest {
            guard let route = session.track(id)?.route else { continue }
            plan[route.deviceUID, default: []].append(MonitoredTrack(id: id, channels: route.channels))
        }
        return plan
    }

    /// Makes the monitor writers match the request: a device with the same tracks keeps its
    /// writer, and a device whose tracks changed or went is finished. The caller holds a monitor
    /// turn. With take writers, it changes nothing.
    func applyMonitor() async {
        guard writers.isEmpty else { return }
        let plan = monitorPlan()
        for (uid, monitor) in monitors where plan[uid] != monitor.tracks {
            monitors[uid] = nil
            for track in monitor.tracks { liveTracks[track.id] = nil }
            await monitor.writer.finish()
        }
        for (uid, tracks) in plan where monitors[uid] == nil {
            guard
                let device = InputDevice.placeholder(uid: uid, channels: tracks.flatMap(\.channels.numbers).max() ?? 1)
            else { continue }
            reportNumber += 1
            let writer = DeviceWriter(
                device: device, tracks: tracks.enumerated().map { (arm: $0.offset + 1, channels: $0.element.channels) },
                files: nil, hal: environment.hal,
                report: Self.monitorReporter(to: self, number: reportNumber, uid: uid),
                silenceLimit: environment.silenceLimit, firstRecordLimit: environment.firstRecordLimit, ringSeconds: 1,
                keepLimit: monitorKeepLimit)
            monitors[uid] = Monitor(writer: writer, tracks: tracks, number: reportNumber)
            for track in tracks { liveTracks[track.id] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0) }
            writer.start()
        }
    }
}

/// The microphone access, read off the main actor.
@concurrent nonisolated func microphoneAccess(of environment: CaptureEnvironment) async -> MicrophoneAccess? {
    environment.microphoneAccess()
}
