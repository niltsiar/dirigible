import DirigibleCore
import Foundation

/// The facade that the app calls for one open package (decisions 0002 and 0004). It holds the
/// package lock, runs recovery at open, and keeps the pending take.
@MainActor public final class Studio {
    public enum Transport: Hashable, Sendable {
        case idle
        case recording(take: Int)
        case finalizing(take: Int)
    }

    public let url: URL
    public private(set) var transport: Transport = .idle
    public var session: Session { history.session }
    /// Derived, not stored: `session.recording` while the transport is idle (decision 0004).
    public var pendingTake: Recording? { transport == .idle ? session.recording : nil }
    /// The last error of a finalize or of the save after it. Nil after a success.
    public private(set) var takeError: StudioError?
    /// The stems of CAFs with audio that no pool file points to (decision 0012). Derived from
    /// the session on each read, so an edit, an undo, or a redo changes it.
    public var unplacedSegments: [String] { DirigibleAudio.unplacedSegments(segmentsWithAudio, session: session) }
    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }

    private var history: History
    /// The disk fact under `unplacedSegments`. Open, stop, and retry read it off the main actor.
    private var segmentsWithAudio: [SegmentName]
    /// The live state of each armed track of the take. Empty while no take records.
    public var liveTracks: [TrackID: LiveTrack] {
        Dictionary(
            uniqueKeysWithValues: armed.map { track in
                (
                    track.id,
                    LiveTrack(
                        state: trackStates[track.id] ?? .recording, droppedFrames: track.writer.droppedFrames)
                )
            })
    }

    /// The Core Audio calls of a take. Tests give their own.
    var environment = CaptureEnvironment.live
    /// The device writers of the take that records, by device UID.
    private var writers: [String: DeviceWriter] = [:]
    /// The armed tracks of the take that records, in arm order, with the writer of each.
    private var armed: [(id: TrackID, writer: DeviceWriter)] = []
    private var trackStates: [TrackID: LiveTrack.State] = [:]
    /// Held for the life of the studio. Dropping the studio releases it.
    private let lock: PackageLock

    private init(url: URL, opened: OpenedPackage) {
        self.url = url
        self.lock = opened.lock
        self.history = History(opened.session)
        self.takeError = opened.takeError
        self.segmentsWithAudio = opened.segmentsWithAudio
    }

    /// Opens the package and runs recovery (decision 0004). No file I/O runs on the main actor.
    /// Throws `.locked` when another studio or the CLI has the package.
    public static func open(_ package: URL) async throws(StudioError) -> Studio {
        Studio(url: package, opened: try await openPackage(package))
    }

    /// Runs `body` on a copy of the session and records one undo entry if it changed.
    public func edit<Result>(_ body: (inout Session) throws(SessionError) -> Result) throws(StudioError) -> Result {
        try checkIdle()
        do {
            return try history.edit(body)
        } catch {
            throw .session(error)
        }
    }

    public func undo() throws(StudioError) {
        try checkIdle()
        do { try history.undo() } catch { throw .session(error) }
    }

    public func redo() throws(StudioError) {
        try checkIdle()
        do { try history.redo() } catch { throw .session(error) }
    }

    /// Saves `session.xml` atomically. With a pending take, it writes `<recording>` back.
    public func save() throws(StudioError) {
        try checkIdle()
        do { try session.write(to: url) } catch { throw .file(error) }
    }

    /// Runs finalize again for the pending take (decision 0004). With no pending take, it does
    /// nothing. A success records one undo entry. A failure keeps the take pending and throws.
    public func retryFinalize() async throws(StudioError) {
        try checkIdle()
        guard let take = pendingTake?.take else { return }
        try await complete(take)
    }

    /// Stops the take: drains and closes each device writer, then finalizes and saves
    /// (decision 0004). With no take, it does nothing. A success records one undo entry. A
    /// failure keeps the take pending and throws.
    public func stopRecording() async throws(StudioError) {
        if case .finalizing = transport { throw .busy }
        guard case .recording(let take) = transport else { return }
        transport = .finalizing(take: take)
        for writer in writers.values { await writer.finish() }
        writers = [:]
        armed = []
        trackStates = [:]
        try await complete(take)
    }

    /// The device writer of `uid` in the take that records. For tests.
    func writer(_ uid: String) -> DeviceWriter? { writers[uid] }

    /// The test seam of decision 0004: starts a take from device descriptions. capture-live adds
    /// the public `startRecording` on top of it. Checks the route of each armed track, then saves
    /// `session.xml` with `<recording>`, then starts each device writer on the environment HAL. A
    /// throw changes nothing.
    func startTake(
        armed: [TrackID], devices: [InputDevice], playhead: Frames, hostTimeNanos: UInt64
    ) throws(StudioError) -> [String: DeviceWriter] {
        try checkIdle()
        guard pendingTake == nil else { throw .busy }
        var routes: [(track: TrackID, arm: Int, route: Route, device: InputDevice)] = []
        var owners: [String: [Int: TrackID]] = [:]
        for (index, id) in armed.enumerated() {
            guard let route = session.track(id)?.route else { throw .noRoute(id) }
            guard let device = devices.first(where: { $0.uid == route.deviceUID }) else { throw .deviceMissing(id) }
            for channel in route.channels.numbers {
                guard channel <= device.channelCount else { throw .channelOutOfRange(id) }
                if let owner = owners[device.uid, default: [:]][channel] { throw .channelInUse(owner, id) }
                owners[device.uid, default: [:]][channel] = id
            }
            routes.append((id, index + 1, route, device))
        }
        let take = SegmentName.nextTake(in: url, session: session)
        var started = session
        do throws(SessionError) {
            try started.setRecording(
                Recording(
                    take: take, playheadFrame: playhead, takeStartHostTimeNanos: hostTimeNanos, armedTracks: armed))
        } catch {
            throw .session(error)
        }
        let capture = url.appending(path: captureFolderName)
        guard mkdir(capture.path, 0o755) == 0 || errno == EEXIST else {
            throw .file(.writeFailed(step: captureFolderName, errno: errno))
        }
        // A crash before the save leaves no <recording>, so a stale marker must not skip the
        // recovery of this take.
        unlink(marker(in: url).path)
        do { try started.write(to: url) } catch { throw .file(error) }
        history.edit { $0 = started }

        let report = Self.reporter(to: self)
        for device in devices where routes.contains(where: { $0.device == device }) {
            let tracks = routes.filter { $0.device == device }.map { (arm: $0.arm, channels: $0.route.channels) }
            writers[device.uid] = DeviceWriter(
                device: device, tracks: tracks, take: take, folder: capture, hal: environment.hal, report: report,
                silenceLimit: environment.silenceLimit)
        }
        self.armed = routes.map { ($0.track, writers[$0.device.uid]!) }
        trackStates = [:]
        transport = .recording(take: take)
        for writer in writers.values { writer.start() }
        return writers
    }

    /// The report closure of the device writers. They call it on their queues, so it is built
    /// in a nonisolated context (AGENTS.md) and hops to the main actor.
    private nonisolated static func reporter(to studio: Studio) -> @Sendable (Report) -> Void {
        { [weak studio] report in Task { @MainActor in studio?.apply(report) } }
    }

    /// A report of another take, or of a take that ended, changes nothing.
    private func apply(_ report: Report) {
        guard transport == .recording(take: report.take), armed.indices.contains(report.arm - 1) else { return }
        trackStates[armed[report.arm - 1].id] = report.state
    }

    /// Finalize, the marker, and the save off the main actor, then the outcome here.
    private func complete(_ take: Int) async throws(StudioError) {
        transport = .finalizing(take: take)
        let outcome = await completeTake(of: session, in: url)
        transport = .idle
        takeError = outcome.error
        segmentsWithAudio = outcome.segmentsWithAudio
        if let error = outcome.error { throw error }
        history.edit { $0 = outcome.session }
    }

    /// Edits, saves, and a new take wait while a take records or finalizes (decision 0004).
    private func checkIdle() throws(StudioError) {
        guard transport == .idle else { throw .busy }
    }
}

public enum StudioError: Error, Hashable, Sendable {
    /// A take records or finalizes, or a new take waits for a pending take.
    case busy
    /// Another studio or the CLI has the package.
    case locked
    /// The armed track has no route.
    case noRoute(TrackID)
    /// The route of the armed track names a device that is not in the list.
    case deviceMissing(TrackID)
    /// The route of the armed track names a channel that the device does not have.
    case channelOutOfRange(TrackID)
    /// Two armed tracks route the same device channel: the first track and the second.
    case channelInUse(TrackID, TrackID)
    case session(SessionError)
    case file(SessionFileError)
    case finalize(FinalizeError)
}
