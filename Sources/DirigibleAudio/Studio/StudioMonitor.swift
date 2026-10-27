import DirigibleCore
import Foundation

/// The reason of the latency activity of a monitor.
let monitorReason = "Dirigible monitors inputs"
/// The kept inputs of one monitor writer: about 200 bytes each (decision 0015).
let monitorKeepLimit = 64

/// One source of the monitor: its writer, its tracks in arm order, and the number of its reports.
struct Monitor {
    let writer: DeviceWriter
    let source: MonitorSource
    let tracks: [MonitoredTrack]
    let number: Int
}

/// What a monitor writer reads: an input device, or the tap of an app (decision 0029).
enum MonitorSource: Hashable {
    case device(uid: String)
    case app(bundleID: String)

    /// The key of the writer in `Studio.monitors`: the device UID, or `app:<bundle ID>`.
    var uid: String {
        switch self {
        case .device(let uid): uid
        case .app(let bundleID): appUID(bundleID)
        }
    }

    var bundleID: String? {
        switch self {
        case .device: nil
        case .app(let bundleID): bundleID
        }
    }
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
    /// only stores the request. The last call wins. When a track of the plan has a device route,
    /// it reads the microphone access, and throws `.microphoneAccess` when it is not granted;
    /// then it holds no device. An armed app track gets a tap, which can show the System Audio
    /// Recording prompt. A listened track keeps its meter until `listen(to:)` releases it and
    /// the next call of this function runs.
    public func monitor(armed: [TrackID]) async throws(StudioError) {
        monitorRequest = armed
        if monitorPlan().keys.contains(where: { $0.bundleID == nil }) {
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

    /// The tracks with a route of the monitor request, and then the tracks with a device route of
    /// the listen request (decision 0044), by source, in request order. It reads both requests at
    /// the turn, so the last call of each wins.
    private func monitorPlan() -> [MonitorSource: [MonitoredTrack]] {
        var plan: [MonitorSource: [MonitoredTrack]] = [:]
        for id in monitorRequest + listenRequest.filter({ !monitorRequest.contains($0) }) {
            guard let track = session.track(id) else { continue }
            switch track.route {
            case .device(let uid, let channels):
                plan[.device(uid: uid), default: []].append(MonitoredTrack(id: id, channels: channels))
            case .app(let bundleID) where monitorRequest.contains(id):
                plan[.app(bundleID: bundleID), default: []].append(
                    MonitoredTrack(id: id, channels: appChannels(track.layout)))
            case .app, nil: continue
            }
        }
        return plan
    }

    /// Makes the monitor writers match the request: a source with the same tracks keeps its
    /// writer, and a source whose tracks changed or went is finished. The caller holds a monitor
    /// turn. With take writers, it changes nothing. It makes the whole state change before its
    /// first await and then waits for the finish of each released writer, so a take that begins
    /// meanwhile keeps its entries of `liveTracks`. The device of a writer that a stop left
    /// unfinished gets no monitor writer: its queue can wait in a HAL call of that device. A new
    /// device writer starts in the turn; a new app writer starts in `startAppMonitors`.
    func applyMonitor() async {
        guard writers.isEmpty else { return }
        let held = Set(unfinishedWriters.map(\.uid))
        let plan = monitorPlan().filter { !held.contains($0.key.uid) }
        var released: [DeviceWriter] = []
        for (uid, monitor) in monitors where plan[monitor.source] != monitor.tracks {
            monitors[uid] = nil
            for track in monitor.tracks { liveTracks[track.id] = nil }
            released.append(monitor.writer)
        }
        var apps: [DeviceWriter] = []
        for (source, tracks) in plan where monitors[source.uid] == nil {
            let uid = source.uid
            guard
                let device = InputDevice.placeholder(uid: uid, channels: tracks.flatMap(\.channels.numbers).max() ?? 1)
            else { continue }
            reportNumber += 1
            let writer = DeviceWriter(
                device: device, tracks: tracks.enumerated().map { (arm: $0.offset + 1, channels: $0.element.channels) },
                files: nil, hal: environment.hal, log: environment.log,
                report: Self.monitorReporter(to: self, number: reportNumber, uid: uid),
                silenceLimit: environment.silenceLimit, firstRecordLimit: environment.firstRecordLimit, ringSeconds: 1,
                keepLimit: monitorKeepLimit, app: source.bundleID)
            monitors[uid] = Monitor(writer: writer, source: source, tracks: tracks, number: reportNumber)
            for track in tracks { liveTracks[track.id] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0) }
            if writer.app == nil { writer.start() } else { apps.append(writer) }
        }
        if !apps.isEmpty { startAppMonitors(apps) }
        // A monitor writer has no file, so one that does not finish in time loses no audio.
        let answers = await boundedEach(released, by: ContinuousClock.now + environment.stopLimit) { await $0.finish() }
        for writer in released where answers[ObjectIdentifier(writer)] == nil { writer.finishLater() }
    }

    /// Starts the app writers `apps` after the first attach try of each device monitor writer,
    /// by the start deadline: the A5 order of `startApps`. A task after the turn waits, so no
    /// monitor wait delays a stop, Retry Finalize, or a later turn. A writer that a later turn
    /// released, or that a take start made old, does not start: the System Audio Recording
    /// prompt comes only from a tap that the monitor still holds.
    private func startAppMonitors(_ apps: [DeviceWriter]) {
        let devices = monitors.values.map(\.writer).filter { $0.app == nil }
        let deadline = ContinuousClock.now + environment.startLimit
        Task { @MainActor in
            _ = await boundedEach(devices, by: deadline) { await $0.started() }
            for writer in apps {
                guard writers.isEmpty, monitors.values.contains(where: { $0.writer === writer }) else {
                    writer.finishLater()
                    continue
                }
                writer.start()
            }
        }
    }
}

/// The microphone access, read off the main actor.
@concurrent nonisolated func microphoneAccess(of environment: CaptureEnvironment) async -> MicrophoneAccess? {
    environment.microphoneAccess()
}
