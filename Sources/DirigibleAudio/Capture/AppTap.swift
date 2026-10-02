import CoreAudio
import CoreServices
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
/// its app. A process with no regular app is not listed.
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
        guard let (url, found) = owner(of: process) else { continue }
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
