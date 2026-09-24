import AVFoundation
import CoreAudio
import DirigibleCore
import IOKit.pwr_mgt

/// The state of one armed track during a take.
public struct LiveTrack: Hashable, Sendable {
    /// `writeFailed` has no cause: a full disk and a volume that goes away give the same status
    /// (decision 0013).
    public enum State: Hashable, Sendable {
        case recording
        case deviceLost
        case writeFailed
    }

    public var state: State
    /// The frames that the device dropped in the take so far (decision 0004).
    public var droppedFrames: Int
    /// The largest absolute sample of the last drain (linear, 0 or more). 0 after `.deviceLost`.
    public var peak: Float
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
    /// A running device with no valid record for this long is lost (the watchdog).
    var silenceLimit: Duration
    /// The watchdog limit from an attach to the first valid record of that appearance. A device
    /// (for example a Bluetooth headset) can need seconds to start its IO.
    var firstRecordLimit: Duration
    /// Nil when the access is granted.
    var microphoneAccess: @Sendable () -> MicrophoneAccess?
    /// The free bytes of the volume of the package. Called off the main actor.
    var freeBytes: @Sendable (PackageLock) -> Int64
    var diskCheckInterval: Duration
    /// The ring length of each device appearance.
    var ringSeconds: Double = 10
    /// The autosave write of a session into the package that the lock holds. Returns the package
    /// path that it wrote. Called off the main actor.
    var saveSession: @Sendable (Session, PackageLock) throws(SessionFileError) -> URL

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
        saveSession: { session, lock throws(SessionFileError) in try session.write(under: lock) })
}

/// `kIOPMAssertPreventUserIdleSystemSleep` for the life of the value (decision 0004). A refused
/// assertion gives no ID, and the take goes on without it.
final class SleepAssertion: Sendable {
    let id: IOPMAssertionID?

    init() {
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Dirigible is recording" as CFString, &id)
        self.id = status == kIOReturnSuccess ? id : nil
    }

    deinit {
        if let id { IOPMAssertionRelease(id) }
    }
}

/// An armed track with its arm number (1-based), route, and device, after the route checks.
struct ArmedRoute: Sendable {
    let track: TrackID
    let arm: Int
    let route: Route
    let device: InputDevice
}

/// A take that `session.xml` holds: the session with `<recording>`, the take, the routes, and
/// the package path of the save (`packageIdentity` form).
struct StartedTake: Sendable {
    let session: Session
    let take: Int
    let routes: [ArmedRoute]
    let package: URL
}

/// Checks the route of each armed track against `devices`.
func checkRoutes(_ session: Session, armed: [TrackID], devices: [InputDevice]) throws(StudioError) -> [ArmedRoute] {
    var routes: [ArmedRoute] = []
    var owners: [String: [Int: TrackID]] = [:]
    for (index, id) in armed.enumerated() {
        guard let track = session.track(id) else { throw .session(.unknownTrack(id)) }
        guard let route = track.route else { throw .noRoute(id) }
        guard let device = devices.first(where: { $0.uid == route.deviceUID }) else { throw .deviceMissing(id) }
        for channel in route.channels.numbers {
            guard channel <= device.channelCount else { throw .channelOutOfRange(id) }
            if let owner = owners[device.uid, default: [:]][channel] { throw .channelInUse(owner, id) }
            owners[device.uid, default: [:]][channel] = id
        }
        routes.append(ArmedRoute(track: id, arm: index + 1, route: route, device: device))
    }
    return routes
}

/// The file part of the 0004 start order in the package that `lock` holds now: `mkdir
/// Capture/`, then save `session.xml` with `<recording>`. It resolves the package path once
/// (decision 0014). A throw leaves `session.xml` unchanged.
func saveTakeStart(
    _ session: Session, lock: PackageLock, routes: [ArmedRoute], playhead: Frames, hostTimeNanos: UInt64
) throws(StudioError) -> StartedTake {
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
    do { try started.write(under: lock) } catch { throw .file(error) }
    return StartedTake(session: started, take: take, routes: routes, package: packageIdentity(package))
}

/// Steps 2 to 5 of the start order of decision 0013, off the main actor: the device lookup and
/// the route checks, the microphone access, the disk check, and the save. Then the list entry,
/// before the attach (decision 0004).
@concurrent nonisolated func prepareTake(
    of session: Session, lock: PackageLock, armed: [TrackID], playhead: Frames, environment: CaptureEnvironment,
    recordings: ActiveRecordings?
) async throws(StudioError) -> StartedTake {
    dispatchPrecondition(condition: .notOnQueue(.main))
    var devices: [InputDevice] = []
    for id in armed {
        guard let uid = session.track(id)?.route?.deviceUID, !devices.contains(where: { $0.uid == uid }),
            let found = environment.hal.lookUp(uid)
        else { continue }
        devices.append(found.device)
    }
    let routes = try checkRoutes(session, armed: armed, devices: devices)
    if let access = environment.microphoneAccess() { throw .microphoneAccess(access) }
    guard environment.freeBytes(lock) >= diskMargin else { throw .diskLow }
    let started = try saveTakeStart(
        session, lock: lock, routes: routes, playhead: playhead,
        hostTimeNanos: AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()))
    recordings?.set(started.package, active: true)
    return started
}

/// The free bytes of the volume of the package that `lock` holds, off the main actor.
@concurrent nonisolated func freeBytes(of lock: PackageLock, _ environment: CaptureEnvironment) async -> Int64 {
    environment.freeBytes(lock)
}

/// The WAV bytes that the finalize of pending take `take` needs: 3 for each 4 CAF bytes.
@concurrent nonisolated func pendingWAVBytes(take: Int, in package: URL) async -> Int64 {
    let capture = package.appending(path: captureFolderName)
    let bytes = ((try? captureSegments(in: package)) ?? []).filter { $0.take == take }.reduce(Int64(0)) { sum, name in
        let size = try? FileManager.default.attributesOfItem(atPath: capture.appending(path: "\(name.stem).caf").path)[
            .size]
        return sum + ((size as? NSNumber)?.int64Value ?? 0)
    }
    return bytes * 3 / 4
}
