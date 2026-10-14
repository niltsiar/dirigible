import CoreAudio
import CoreServices
import DirigibleCore
import Foundation

/// The UID prefix of each tap aggregate that Dirigible makes (decision 0030).
let tapUIDPrefix = "com.delineas.dirigible.tap."

/// The devices without the tap aggregates of this process, which the creating process sees in
/// its device list (probe P9d, A10).
func visibleInputs(_ devices: [InputDevice]) -> [InputDevice] {
    devices.filter { !$0.uid.hasPrefix(tapUIDPrefix) }
}

/// One Core Audio process object (decision 0006): its bundle ID (empty when it has none), its
/// executable path, and `kAudioProcessPropertyIsRunningOutput`.
struct AudioProcess: Hashable, Sendable {
    let id: AudioObjectID
    let bundleID: String
    let path: String
    let playing: Bool
}

/// A running regular app with one or more audio process objects (A3, A15).
public struct RunningApp: Hashable, Sendable {
    public let bundleID: String
    public let name: String
    /// The path of the app bundle.
    public let path: String
    /// True when a process of the app has `IsRunningOutput` 1.
    public let playing: Bool
    /// The process objects of the app, in the order of the process list.
    let processes: [AudioObjectID]
}

/// A4: a process is part of the app `appID` when its bundle ID is `appID` or starts with
/// `appID` and a dot (whole components, so `com.google.ChromeX` is not part of Chrome).
func isPart(_ bundleID: String, of appID: String) -> Bool {
    bundleID == appID || bundleID.hasPrefix(appID + ".")
}

/// A4: the process objects of an app: each process that `isPart` of its bundle ID, or whose
/// executable is inside its bundle. A Teams helper with no bundle ID is inside the bundle, and
/// the Chrome main process runs from a clone outside it (probe P1).
func appProcesses(_ bundleID: String, bundlePath: String?, in processes: [AudioProcess]) -> [AudioProcess] {
    processes.filter { process in
        isPart(process.bundleID, of: bundleID) || bundlePath.map { process.path.hasPrefix($0 + "/") } == true
    }
}

/// The facts of an app bundle from its `Info.plist`, read once for each bundle.
private struct AppBundle {
    let id: String
    let name: String
    /// `CFBundlePackageType` `APPL` and no `LSUIElement` or `LSBackgroundOnly` true: an app
    /// with a Dock icon, not an agent, a daemon, or an XPC service.
    let regular: Bool

    init?(_ url: URL) {
        guard let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any],
            let id = info["CFBundleIdentifier"] as? String, !id.isEmpty
        else { return nil }
        self.id = id
        name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? id
        regular =
            info["CFBundlePackageType"] as? String == "APPL" && !isTrue(info["LSUIElement"])
            && !isTrue(info["LSBackgroundOnly"])
    }
}

/// An Info.plist flag can be a Boolean or a string such as "1" or "YES".
private func isTrue(_ value: Any?) -> Bool {
    if let flag = value as? Bool { return flag }
    return (value as? String).map { ["1", "yes", "true"].contains($0.lowercased()) } ?? false
}

/// A3 and A15: the regular apps of `processes`, by name. The app of a process is the longest
/// bundle ID that `isPart` takes and whose app (from `appURL`) is regular, else the outermost
/// `.app` of its path that is regular (W6b). So a helper with its own agent bundle counts for
/// its app. A process with no regular app is not listed, and neither are Safari and FaceTime:
/// they play their audio from system processes, so a tap of the app records silence.
func appList(_ processes: [AudioProcess], appURL: (String) -> URL?) -> [RunningApp] {
    var bundles: [String: AppBundle?] = [:]
    func bundle(_ url: URL) -> AppBundle? {
        if let known = bundles[url.path] { return known }
        let read = AppBundle(url)
        bundles[url.path] = read
        return read
    }
    func owner(of process: AudioProcess) -> (url: URL, bundle: AppBundle)? {
        let parts = process.bundleID.split(separator: ".", omittingEmptySubsequences: false)
        for count in stride(from: parts.count, through: 1, by: -1) where !process.bundleID.isEmpty {
            let id = parts.prefix(count).joined(separator: ".")
            if let url = appURL(id), let found = bundle(url), found.regular { return (url, found) }
        }
        // The `.app` folders of the path, the outermost first.
        let components = URL(filePath: process.path).pathComponents
        let apps = components.indices.filter { components[$0].hasSuffix(".app") }.map {
            URL(filePath: NSString.path(withComponents: Array(components[...$0])))
        }
        for url in apps {
            if let found = bundle(url), found.regular { return (url, found) }
        }
        return nil
    }

    var groups: [(url: URL, bundle: AppBundle, processes: [AudioProcess])] = []
    for process in processes {
        guard let (url, found) = owner(of: process), !["com.apple.Safari", "com.apple.FaceTime"].contains(found.id)
        else { continue }
        if let index = groups.firstIndex(where: { $0.bundle.id == found.id }) {
            groups[index].processes.append(process)
        } else {
            groups.append((url, found, [process]))
        }
    }
    return groups.map {
        RunningApp(
            bundleID: $0.bundle.id, name: $0.bundle.name, path: $0.url.path,
            playing: $0.processes.contains(where: \.playing), processes: $0.processes.map(\.id))
    }.sorted { first, second in
        let order = first.name.localizedStandardCompare(second.name)
        return order == .orderedSame ? first.bundleID < second.bundleID : order == .orderedAscending
    }
}

extension RunningApp {
    /// The running regular apps with an audio process object, without this process. HAL and
    /// LaunchServices reads only: no tap, no aggregate, and no prompt. Call it off the main actor.
    public static func all() -> [RunningApp] {
        appList(AudioProcess.all().filter { $0.pid != getpid() }.map(\.process), appURL: launchServicesURL)
    }
}

/// The first app URL that LaunchServices knows for `bundleID`.
private func launchServicesURL(_ bundleID: String) -> URL? {
    let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue()
    return (urls as? [URL])?.first
}

extension AudioProcess {
    /// The process objects of the system with their PIDs. A process whose reads fail is left out.
    static func all() -> [(pid: pid_t, process: AudioProcess)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let ids = (try? readArray(system, kAudioHardwarePropertyProcessObjectList, as: AudioObjectID.self)) ?? []
        return ids.compactMap { id in
            guard let pid = try? readValue(id, kAudioProcessPropertyPID, as: pid_t.self),
                let running = try? readValue(id, kAudioProcessPropertyIsRunningOutput, as: UInt32.self)
            else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let path =
                length > 0
                ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            let bundleID = readString(id, kAudioProcessPropertyBundleID) ?? ""
            return (pid, AudioProcess(id: id, bundleID: bundleID, path: path, playing: running == 1))
        }
    }
}

// MARK: The tap of one app appearance (decision 0030)

/// The identity of one app appearance: the matched process objects, sorted (empty when the app
/// does not run), and an output UID. The key of a writer slot holds the main sub-device UID of
/// its running aggregate. A found key holds the output that a matched process reports, or nil
/// when none reports one, so a default output change alone does not rebuild (code gates E3, F2).
struct AppKey: Hashable, Sendable {
    let processes: [AudioObjectID]
    let output: String?
}

/// W1: the found set has a process that the tap lacks, or a matched process reports an output
/// that is not the main sub-device of the running aggregate. `current` is the key of the writer
/// slot, whose output is that main sub-device; a found key with no reported output, or with that
/// device, keeps the tap (code gate 2 F2).
func needsRebuild(_ current: AppKey, _ found: AppKey) -> Bool {
    !Set(found.processes).isSubset(of: current.processes) || (found.output != nil && found.output != current.output)
}

/// What the app lookup finds, with reads only: no tap, no aggregate, and no prompt. `device` has
/// the UID `app:<bundle ID>`, the rate of the output, and one buffer with the mixdown channels.
struct AppFound: Sendable {
    let key: AppKey
    /// The UID of the main sub-device of the aggregate: the reported output, else the default
    /// output (decision 0006).
    let output: String
    let device: InputDevice
    /// True when a matched process has `IsRunningOutput` 1.
    let playing: Bool
}

/// The description of a private tap aggregate (decision 0006). Auto start is false, so the IO
/// runs from the take start, also for a tap with no process (probe P11).
func aggregateDescription(output: String, tapUID: String, uid: String) -> [String: Any] {
    [
        kAudioAggregateDeviceNameKey: "Dirigible app tap", kAudioAggregateDeviceUIDKey: uid,
        kAudioAggregateDeviceMainSubDeviceKey: output, kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: false,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
    ]
}

/// The name of an app from its bundle, else its bundle ID. LaunchServices reads: call it off the
/// main actor.
public func appName(_ bundleID: String) -> String {
    launchServicesURL(bundleID).flatMap { AppBundle($0)?.name } ?? bundleID
}

/// The live app lookup: the A4 process set of the app, the output device of a matched process
/// (else the default output), and its rate. Nil when there is no output device.
func lookUpApp(_ bundleID: String, layout: ChannelLayout) -> AppFound? {
    let processes = appProcesses(
        bundleID, bundlePath: launchServicesURL(bundleID)?.path,
        in: AudioProcess.all().filter { $0.pid != getpid() }.map(\.process))
    let system = AudioObjectID(kAudioObjectSystemObject)
    let reported = processes.lazy.compactMap {
        try? readArray(
            $0.id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput, as: AudioObjectID.self
        )
        .first
    }.first
    let fallback = try? readValue(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
    guard let output = reported ?? fallback, let uid = readString(output, kAudioDevicePropertyDeviceUID),
        let rate = try? readValue(output, kAudioDevicePropertyNominalSampleRate, as: Float64.self)
    else { return nil }
    return appFound(bundleID, processes: processes, output: uid, reported: reported != nil, rate: rate, layout: layout)
}

/// What the lookup of an app gives from its reads. `output` is the UID of the main sub-device;
/// `reported` is true when a matched process reports it, and only then it is in the key (E3).
func appFound(
    _ bundleID: String, processes: [AudioProcess], output: String, reported: Bool, rate: Double, layout: ChannelLayout
) -> AppFound? {
    guard
        let device = InputDevice(
            uid: appUID(bundleID), name: bundleID, nominalRate: rate, availableRates: [rate...rate],
            channelsPerBuffer: [layout.channelCount], latency: 0)
    else { return nil }
    return AppFound(
        key: AppKey(processes: processes.map(\.id).sorted(), output: reported ? output : nil), output: output,
        device: device, playing: processes.contains(where: \.playing))
}

/// Makes a private, unmuted mixdown tap of the processes of `found` and its private aggregate
/// (decision 0006). The teardown destroys the aggregate, then the tap; each step runs, and it is
/// clean only when both return noErr.
@available(macOS 14.2, *)
func makeTap(_ found: AppFound) throws(HALError) -> (id: AudioObjectID, device: InputDevice, teardown: Detach) {
    let description =
        found.device.channelCount == 1
        ? CATapDescription(monoMixdownOfProcesses: found.key.processes)
        : CATapDescription(stereoMixdownOfProcesses: found.key.processes)
    description.isPrivate = true
    description.muteBehavior = .unmuted
    var tap = AudioObjectID(kAudioObjectUnknown)
    var status = AudioHardwareCreateProcessTap(description, &tap)
    guard status == noErr else { throw .status(status) }
    let tapUID = readString(tap, kAudioTapPropertyUID) ?? description.uuid.uuidString
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    let wanted = aggregateDescription(
        output: found.output, tapUID: tapUID, uid: tapUIDPrefix + UUID().uuidString)
    status = AudioHardwareCreateAggregateDevice(wanted as CFDictionary, &aggregate)
    guard status == noErr else {
        _ = AudioHardwareDestroyProcessTap(tap)
        throw .status(status)
    }
    let (made, madeTap) = (aggregate, tap)
    let teardown: Detach = {
        let aggregateDestroyed = AudioHardwareDestroyAggregateDevice(made) == noErr
        return AudioHardwareDestroyProcessTap(madeTap) == noErr && aggregateDestroyed
    }
    guard let device = InputDevice.read(aggregate) else {
        _ = teardown()
        throw .status(kAudioHardwareUnspecifiedError)
    }
    return (aggregate, device, teardown)
}

/// A9: the silence check of an app track for one take, by record host time. It starts at the
/// first drain with a matched process. After 5.0 s of zeros while a matched process plays, it
/// warns once; it rebuilds the tap at the warning, 10 s after it, and 40 s after it. The first
/// sample that is not zero ends it: no warning and no rebuild after it. It reads the playing
/// flag at most once for each second of records.
struct SilenceCheck {
    /// The zeros before the warning.
    static let limit: UInt64 = 5_000_000_000
    /// The rebuilds after the warning.
    static let rebuilds: [UInt64] = [atWarning, 10_000_000_000, 40_000_000_000]
    /// The first rebuild comes with the warning.
    static let atWarning: UInt64 = 0
    static let readInterval: UInt64 = 1_000_000_000

    /// True after a routed sample that is not zero in the take.
    private(set) var heard = false
    /// The host time of the first drain with a process: the start of the zeros.
    private var start: UInt64?
    /// The host time of the last record.
    private var last: UInt64?
    private(set) var warnedAt: UInt64?
    private var done = 0
    private var nextRead: UInt64 = 0

    /// True while the track shows the warning: it warned and no sound came.
    var warns: Bool { warnedAt != nil && !heard }

    /// Takes one drain: the host times of its first and last records, whether a routed sample
    /// was not zero, and whether the tap has a matched process.
    mutating func take(firstHost: UInt64, lastHost: UInt64, heard: Bool, hasProcess: Bool) {
        if heard { self.heard = true }
        if start == nil, hasProcess { start = firstHost }
        last = lastHost
    }

    /// The warning and the rebuild that are due now. `playing` reads the app; it runs only when
    /// a step is due by time, and at most once for each second of records.
    mutating func due(playing: () -> Bool) -> (warn: Bool, rebuild: Bool) {
        guard !heard, let start, let last, done < Self.rebuilds.count else { return (false, false) }
        let from = warnedAt ?? start
        let wait = warnedAt == nil ? Self.limit : Self.rebuilds[done]
        guard last &- from >= wait, last >= nextRead else { return (false, false) }
        nextRead = last &+ Self.readInterval
        guard playing() else { return (false, false) }
        let warn = warnedAt == nil
        if warn { warnedAt = last }
        done += 1
        return (warn, true)
    }
}
