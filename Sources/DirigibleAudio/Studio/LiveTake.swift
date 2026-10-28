import AVFoundation
import CoreAudio
import DirigibleCore

/// True when this macOS has process taps (14.2 or later, decision 0006). An app route needs it.
public var processTapsAvailable: Bool {
    if #available(macOS 14.2, *) { true } else { false }
}

/// The state of one armed track during a take or a monitor (decision 0015).
public struct LiveTrack: Hashable, Sendable {
    /// `writeFailed` has no cause: a full disk and a volume that goes away give the same status
    /// (decision 0013).
    public enum State: Hashable, Sendable {
        case recording
        case deviceLost
        case writeFailed
        /// The monitor meters the track and writes no file.
        case monitoring
        /// The monitor writer of the device kept its limit of inputs and tries no more attach
        /// until the next monitor start (decision 0015).
        case retryStopped
        /// An app track records silence: the app has no process now (A7).
        case waitingForApp
        /// An app track got only zeros for 5 s while its app plays: the System Audio Recording
        /// access can be missing (A9).
        case noSound
        /// A monitor app tap got `'!hog'` from its grant check and no sound since: macOS does
        /// not allow System Audio Recording (decision 0006).
        case noAccess
        /// The device did not answer its first attach by the start deadline; the other tracks
        /// record, and the first report of its writer replaces this state.
        case notStarted
    }

    public var state: State
    /// The frames that the device dropped in the take so far (decision 0004).
    public var droppedFrames: Int
    /// The largest absolute sample of the last drain (linear, 0 or more). 0 after `.deviceLost`.
    public var peak: Float
    /// The short-term loudness (3 s) of the track (decision 0033). Nil until 3 s of input, and
    /// after `.deviceLost` or `.retryStopped`.
    public var shortTerm: LUFS? = nil
}

/// Why a take ended.
public enum TakeEnd: Hashable, Sendable {
    case requested
    /// The free space went under the WAV bytes of the take plus 1 GB (decision 0004).
    case diskLow
}

/// The result of a take, set when its writers finish and before its finalize.
public struct TakeResult: Hashable, Sendable {
    /// The cause of the first gap of a track.
    public enum Gap: Hashable, Sendable {
        case deviceLost
        case writeFailed
    }

    public let take: Int
    public let end: TakeEnd
    /// The armed tracks with a gap, each with the cause of its first gap.
    public let gaps: [TrackID: Gap]
    /// The armed tracks whose device dropped frames, each with the count.
    public var droppedFrames: [TrackID: Int] = [:]
    /// The armed app tracks that showed the silence warning and got no sound in the take, each
    /// with the app name (A9).
    public var silent: [TrackID: String] = [:]
}

/// A microphone access that is not granted. The library reads it and never requests it; the
/// front ends request and start again (decision 0013).
public enum MicrophoneAccess: Hashable, Sendable {
    case notDetermined
    case denied
    case restricted
}

/// The free space that a take keeps (decision 0004): a start needs it, and a take stops when
/// the free space goes under it plus the WAV bytes of the take.
let diskMargin: Int64 = 1_000_000_000

/// The test seam of the live take (decision 0013): closures and values, no protocol. `live`
/// calls the system.
struct CaptureEnvironment: Sendable {
    var hal: DeviceHAL
    /// The journal of the front end (decision 0059). `live` has `disabled`; `Studio.open` sets it.
    var log = DiagnosticLog.disabled
    /// A running device with no valid record for this long is lost (the watchdog).
    var silenceLimit: Duration
    /// The watchdog limit from an attach to the first valid record of that appearance. A device
    /// (for example a Bluetooth headset) can need seconds to start its IO.
    var firstRecordLimit: Duration
    /// Nil when the access is granted.
    var microphoneAccess: @Sendable () -> MicrophoneAccess?
    /// False on macOS 14.0 and 14.1: no process taps, so no app route records (A14).
    var tapsAvailable = processTapsAvailable
    /// The free bytes of the volume of the package. Called off the main actor.
    var freeBytes: @Sendable (PackageLock) -> Int64
    var diskCheckInterval: Duration
    /// The ring length of each device appearance.
    var ringSeconds: Double = 10
    /// The limit of the device writer waits of a take start, from `begin`.
    var startLimit = Duration.seconds(10)
    /// The limit of the writer waits of a stop, from the stop call, and of a Retry Finalize.
    var stopLimit = Duration.seconds(10)
    /// The autosave write of a session into the package that the lock holds. Returns the package
    /// path that it wrote. Called off the main actor. It is async, so a test holds a write with an
    /// async wait and blocks no thread of the concurrency pool.
    var saveSession: @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL
    /// The output of each Listener (decision 0044). No default, so each direct init names it;
    /// tests give `.offline()`.
    var listenOutput: ListenOutput
    /// A step before each finalize and each placement (decision 0021). Tests hold a finalize or a
    /// placement with it and suspend, so no thread of the concurrency pool waits; `live` does
    /// nothing.
    var beforeFinalize: @Sendable () async -> Void = {}
    /// A step at the block reads of each placement (decision 0021). Tests hold a placement or
    /// check its thread with it; `live` has none.
    var placeRead: ReadFault?
    /// The output of the Player that the next play makes (decision 0016). Tests render offline.
    var playerOutput: Player.Output = .device
    /// A step before the Player stop of a take start, off the main actor. Tests hold it.
    var beforePlayerStop: @Sendable () async -> Void = {}
    /// A step of a take start before the device lookup, off the main actor. Tests hold the start
    /// with it and suspend, so no thread of the concurrency pool waits; `live` does nothing. The
    /// step passes its `#isolation`, so a test hook runs on the thread of the step.
    var beforeLookUp: @Sendable (isolated (any Actor)?) async -> Void = { _ in }
    /// A step of a test take start (`Studio.startTake`) before its save, off the main actor.
    /// Tests check its thread with it; `live` does nothing. It passes its `#isolation`, as
    /// `beforeLookUp`.
    var beforeStartSave: @Sendable (isolated (any Actor)?) async -> Void = { _ in }
    /// The wait of a timed take from its start to its stop (decision 0048). Tests hold it with a
    /// gate, so no wall clock races a check.
    var takeLength: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// A step of a take start after the take begins, before the app attach. Tests hold it to stop
    /// the take before the start returns; `live` does nothing.
    var afterStart: @Sendable () async -> Void = {}
    /// The sleep assertion of a take start, on the main actor. Tests read the journal in it.
    var makeSleepAssertion: @Sendable () -> SleepAssertion = { SleepAssertion() }
    /// A step of a take start before the save of `<recording>`, off the main actor. Tests read the
    /// journal in it.
    var beforeTakeSave: @Sendable () async -> Void = {}
    /// A step at the start of each media check of `Studio.checkMedia` and `Studio.exportFaults`, off the main actor. Tests
    /// hold the check with it and suspend, so no thread of the concurrency pool waits.
    var beforeMediaCheck: @Sendable () async -> Void = {}
    /// Finds the speed unit of the Player (decision 0052). Tests give one that finds nothing.
    var speedUnit: SpeedUnitLookup = findSpeedUnit
    /// Starts the engine of the Player. Tests give one that throws.
    var startEngine: @Sendable (AVAudioEngine) throws -> Void = { try $0.start() }
    /// A step before each block of a peak compute (decision 0017), isolated to the actor of the
    /// compute (nil: none). Tests count, hold, or slow the blocks with it.
    var beforePeakBlock: @Sendable (isolated (any Actor)?) async -> Void = { _ in }
    /// A step on the thread of each WAV read of a peak pass: at each file start (the open and the
    /// cache read) and after each block read. Tests check that it is never the main thread.
    var peakRead: @Sendable () -> Void = {}
    /// A step on the export thread at each cancel check: each chunk and once after the close
    /// (decision 0019). Tests record the thread and the QoS with it, or hold or slow the export.
    var exportChunk: @Sendable () -> Void = {}
    /// A step on the import thread at each cancel check (decision 0040). Tests record the thread
    /// with it, or hold or slow the import.
    var importStep: @Sendable () -> Void = {}
    /// A step after the work of a file import returns, before its run reads the cancel flag
    /// (decision 0049). Tests cancel there.
    var importWorkDone: @Sendable () async -> Void = {}
    /// A fault or a thread record at the block reads of a clip render (decision 0054); `live` has
    /// none.
    var clipRenderRead: ReadFault?
    /// A step after the render of a clip render returns, before its run reads the cancel flag
    /// (decision 0049). Tests hold or cancel the render there.
    var clipRenderWorkDone: @Sendable () async -> Void = {}
    /// The reason of the activity that each blocking run holds (decision 0040). Tests set a UUID
    /// text, so the IOPM list of the process shows the activity of one studio.
    var blockingRunReason = "Dirigible imports or changes audio files"
    /// A step on the thread of each block of `Studio.measureLoudness` and of the read of a level or
    /// a duck (`Studio.runReadJob`, decision 0049). Tests hold the read with it.
    var loudnessBlock: @Sendable () -> Void = {}

    static let live = CaptureEnvironment(
        hal: .live, silenceLimit: .seconds(2), firstRecordLimit: .seconds(10),
        microphoneAccess: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: nil
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            default: .denied
            }
        },
        freeBytes: { $0.freeBytes() }, diskCheckInterval: .seconds(1),
        saveSession: { session, lock throws(SessionFileError) in try session.write(under: lock) },
        listenOutput: .live)
}

/// An armed track with its arm number (1-based), channels, and device, after the route checks.
/// For an app route, `app` is the bundle ID, `device` has the UID `app:<bundle ID>` and the app
/// name, and `channels` are the mixdown channels of the tap (decision 0030).
struct ArmedRoute: Sendable {
    let track: TrackID
    let arm: Int
    let channels: Route.Channels
    let device: InputDevice
    var app: String? = nil
}

/// A take that `session.xml` holds: the session with `<recording>`, the take, the routes, and
/// the package path of the save (`packageIdentity` form).
struct StartedTake: Sendable {
    let session: Session
    let take: Int
    let routes: [ArmedRoute]
    let package: URL
}

/// Checks the route of each armed track against `devices`. An app route finds its device by the
/// UID `app:<bundle ID>` and takes the mixdown channels of the track layout, so a second track
/// on the same app has a channel in use.
func checkRoutes(_ session: Session, armed: [TrackID], devices: [InputDevice]) throws(StudioError) -> [ArmedRoute] {
    var routes: [ArmedRoute] = []
    var owners: [String: [Int: TrackID]] = [:]
    for (index, id) in armed.enumerated() {
        guard let track = session.track(id) else { throw .session(.unknownTrack(id)) }
        guard let route = track.route else { throw .noRoute(id) }
        let (uid, channels, app): (String, Route.Channels, String?) =
            switch route {
            case .device(let uid, let channels): (uid, channels, nil)
            case .app(let bundleID): (appUID(bundleID), appChannels(track.layout), bundleID)
            }
        guard let device = devices.first(where: { $0.uid == uid }) else { throw .deviceMissing(id) }
        for channel in channels.numbers {
            guard channel <= device.channelCount else { throw .channelOutOfRange(id) }
            if let owner = owners[device.uid, default: [:]][channel] { throw .channelInUse(owner, id) }
            owners[device.uid, default: [:]][channel] = id
        }
        routes.append(ArmedRoute(track: id, arm: index + 1, channels: channels, device: device, app: app))
    }
    return routes
}

/// The file part of the 0004 start order in the package that `lock` holds now: `mkdir
/// Capture/`, then save `session.xml` with `<recording>`. It resolves the package path once
/// (decision 0014). A throw leaves `session.xml` unchanged. Off the main actor.
func saveTakeStart(
    _ session: Session, lock: PackageLock, routes: [ArmedRoute], playhead: Frames, hostTimeNanos: UInt64
) throws(StudioError) -> StartedTake {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do { package = try lock.package() } catch { throw .file(error) }
    let take = SegmentName.nextTake(in: package, session: session)
    var started = session
    do throws(SessionError) {
        try started.setRecording(
            Recording(
                take: take, playheadFrame: playhead, takeStartHostTimeNanos: hostTimeNanos,
                armedTracks: routes.map(\.track)))
    } catch {
        throw .session(error)
    }
    let capture = package.appending(path: captureFolderName)
    guard mkdir(capture.path, 0o755) == 0 || errno == EEXIST else {
        throw .file(.writeFailed(step: captureFolderName, errno: errno))
    }
    // A crash before the save leaves no <recording>, so a stale marker must not skip the
    // recovery of this take.
    unlink(marker(in: package).path)
    // No backup step here: it made the start 43 ms slower (run 14). The finalize save keeps
    // this file (the state before the take, with <recording>) only when a backup is due (0043).
    do { try started.write(under: lock, backups: .none) } catch { throw .file(error) }
    return StartedTake(session: started, take: take, routes: routes, package: packageIdentity(package))
}

/// The save of the test take start (`Studio.startTake`), off the main actor, as `prepareTake`.
@concurrent nonisolated func saveTestTakeStart(
    _ session: Session, lock: PackageLock, routes: [ArmedRoute], playhead: Frames, hostTimeNanos: UInt64,
    environment: CaptureEnvironment
) async throws(StudioError) -> StartedTake {
    await environment.beforeStartSave(#isolation)
    return try saveTakeStart(session, lock: lock, routes: routes, playhead: playhead, hostTimeNanos: hostTimeNanos)
}

/// Steps 2 and 3 of the start order of decision 0013: the device lookup and the route checks,
/// then the microphone access. It changes nothing, so a refusal keeps a running export
/// (decision 0019).
nonisolated func checkTake(
    of session: Session, armed: [TrackID], environment: CaptureEnvironment
) throws(StudioError) -> [ArmedRoute] {
    let tracks = armed.compactMap { session.track($0) }
    let hasApp = tracks.contains { if case .app = $0.route { true } else { false } }
    if hasApp, !environment.tapsAvailable { throw .appSourcesUnavailable }
    let check = environment.log.begin(.take, "check-begin")
    var devices: [InputDevice] = []
    for track in tracks {
        switch track.route {
        case .device(let uid, _):
            guard !devices.contains(where: { $0.uid == uid }), let found = environment.hal.lookUp(uid) else { continue }
            devices.append(found.device)
        case .app(let bundleID):
            // The app name and the facts of the output, read only; nil only with no output device.
            guard !devices.contains(where: { $0.uid == appUID(bundleID) }),
                let found = environment.hal.lookUpApp(bundleID, track.layout)
            else { continue }
            devices.append(found.device.named(environment.hal.appName(bundleID)))
        case nil: continue
        }
    }
    check.end("check", ["devices": .number(Int64(devices.count))])
    let routes = try checkRoutes(session, armed: armed, devices: devices)
    // An app-only take needs no microphone access (A13).
    if routes.contains(where: { $0.app == nil }) {
        let read = environment.log.begin(.permission, "microphone-begin")
        let access = environment.microphoneAccess()
        read.end("microphone", ["status": .text(access.map { "\($0)" } ?? "granted")])
        if let access { throw .microphoneAccess(access) }
    }
    return routes
}

/// The device UID of an app source in the capture header and `<capture>` (decision 0029).
func appUID(_ bundleID: String) -> String { "app:\(bundleID)" }

/// The channels of an app route in the tap mixdown: the track layout (decision 0029).
func appChannels(_ layout: ChannelLayout) -> Route.Channels { layout == .mono ? .mono(1) : .stereo(1, 2) }

/// Steps 2 to 5 of the start order of decision 0013, off the main actor: `checkTake`, the disk
/// check, and the save. Then the list entry, before the attach (decision 0004). `endExport` runs
/// after the checks and before the disk check (decision 0019), so a refused start keeps the
/// export and the disk check sees the space that the export frees. It is nil when no export
/// runs, so the start makes no main-actor turn between its checks and its save. It also returns
/// the free bytes of the disk check.
@concurrent nonisolated func prepareTake(
    of session: Session, lock: PackageLock, armed: [TrackID], playhead: Frames, environment: CaptureEnvironment,
    recordings: ActiveRecordings?, endExport: (@MainActor @Sendable () async -> Void)?
) async throws(StudioError) -> (started: StartedTake, free: Int64) {
    dispatchPrecondition(condition: .notOnQueue(.main))
    await environment.beforeLookUp(#isolation)
    let routes = try checkTake(of: session, armed: armed, environment: environment)
    if let endExport { await endExport() }
    let disk = environment.log.begin(.disk, "free-begin")
    let free = environment.freeBytes(lock)
    disk.end("free", ["bytes": .number(free)])
    guard free >= diskMargin else { throw .diskLow }
    let save = environment.log.begin(.session, "save-begin")
    await environment.beforeTakeSave()
    let started = try saveTakeStart(
        session, lock: lock, routes: routes, playhead: playhead,
        hostTimeNanos: hostNanosNow())
    save.end("save", ["take": .number(Int64(started.take))])
    recordings?.set(started.package, active: true)
    return (started, free)
}

/// The free bytes of the volume of the package that `lock` holds, off the main actor.
@concurrent nonisolated func freeBytes(of lock: PackageLock, _ environment: CaptureEnvironment) async -> Int64 {
    environment.freeBytes(lock)
}

/// The WAV bytes that the finalize of pending take `take` needs: 3 for each 4 CAF bytes. It
/// reads the package that `lock` holds now, not `Studio.url`, which follows a move only at the
/// next write (decision 0014). A package that left its volume gives 0.
@concurrent nonisolated func pendingWAVBytes(take: Int, of lock: PackageLock) async -> Int64 {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return 0 }
    return wavBytes(of: ((try? captureSegments(in: package)) ?? []).filter { $0.take == take }, in: package)
}

/// The WAV bytes that the finalize of `segments` needs: 3 for each 4 CAF bytes (decision 0013).
/// A CAF that does not give its size counts 0.
func wavBytes(of segments: [SegmentName], in package: URL) -> Int64 {
    let capture = package.appending(path: captureFolderName)
    let bytes = segments.reduce(Int64(0)) { sum, name in
        let size = try? FileManager.default.attributesOfItem(atPath: capture.appending(path: "\(name.stem).caf").path)[
            .size]
        return sum + ((size as? NSNumber)?.int64Value ?? 0)
    }
    return bytes * 3 / 4
}
