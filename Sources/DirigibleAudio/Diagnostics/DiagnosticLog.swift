import CryptoKit
import Foundation
import os

/// The part of the app that a journal line is about (decision 0059).
public enum DiagnosticCategory: String, Sendable {
    case app, take, device, tap, permission, disk, session, recovery, hang, agent
}

/// The level of a journal line. A `fault` line and each `hang` line also call `fsync`.
public enum DiagnosticLevel: String, Sendable {
    case notice, error, fault
}

/// One field value of a journal line. A `uid` reaches the file only as a token.
public enum DiagnosticValue: Sendable {
    case text(String)
    case number(Int64)
    case milliseconds(Double)
    /// Written as the four-character code and the integer, for example `!hog/560492391`.
    case status(OSStatus)
    /// Written as `uid-<8 hex>`: HMAC-SHA256 of the UID with the salt of the log folder.
    case uid(String)

    /// The milliseconds from `start` to now.
    static func since(_ start: ContinuousClock.Instant) -> DiagnosticValue {
        .milliseconds((ContinuousClock.now - start) / .milliseconds(1))
    }
}

/// The journal of one launch (decision 0059): one TSV file, written on one serial queue. The front
/// end starts it once and passes it on; a library caller with no log gets `disabled`.
public final class DiagnosticLog: Sendable {
    public enum Kind: String, Sendable { case app, cli }

    /// Writes nothing: the log before a start, after an open failure, and of a caller with no log.
    public static let disabled = DiagnosticLog(journal: nil)

    /// False for `disabled`, also after a start that could not open the journal.
    public var isEnabled: Bool { journal != nil }
    /// True when the newest earlier app journal ends with no `app quit` line and no process holds
    /// its lock. The journal queue reads that journal after the start, and the first read waits
    /// for it.
    public var previousEndedUnclean: Bool { journal?.previousEndedUnclean ?? false }
    private let journal: Journal?

    private init(journal: Journal?) { self.journal = journal }

    /// `DIRIGIBLE_LOG_FOLDER` when it is set, else `~/Library/Logs/Dirigible`.
    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["DIRIGIBLE_LOG_FOLDER"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return URL.libraryDirectory.appending(path: "Logs/Dirigible", directoryHint: .isDirectory)
    }

    /// Opens `<yyyy-MM-dd-HHmmss>-<kind>-<pid>.tsv` in `folder` (UTC time) and writes the version
    /// line, the header, and the `app launch` line with the build facts of the front end. Then the
    /// queue reads the salt, checks the end of the earlier app journal, and deletes the oldest
    /// journals past the limits. When the journal cannot open, it writes one `fault` line to the
    /// system log and returns `disabled`. A `DIRIGIBLE_AUDIO_OUTPUT` of `none` adds an
    /// `audio-output` notice line after `app launch`; an unknown value adds an error line.
    public static func start(
        _ kind: Kind, folder: URL, version: String, commit: String, now: Date = .now,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DiagnosticLog {
        start(
            kind, folder: folder, version: version, commit: commit, now: now, queue: Journal.makeQueue(),
            environment: environment)
    }

    /// `start` on `queue`, with a part limit of `partLimit` bytes. Tests hold the queue or rotate early.
    static func start(
        _ kind: Kind, folder: URL, version: String, commit: String, now: Date, queue: DispatchQueue,
        partLimit: Int = Journal.partLimit, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DiagnosticLog {
        let launch = Entry(.app, "launch", launchFields(version: version, commit: commit), date: now)
        do throws(JournalOpenError) {
            let journal = try Journal.open(
                kind, folder: folder, now: now, launch: launch, queue: queue, partLimit: partLimit)
            let log = DiagnosticLog(journal: journal)
            switch AudioOutputSetting(environment: environment) {
            case .device: break
            case .noDevice: log.note(.app, "audio-output", ["mode": .text("none")])
            case .unknown(let value): log.note(.app, "audio-output", level: .error, ["unknown": .text(value)])
            }
            return log
        } catch {
            diagnosticsLog.fault("The diagnostics journal did not open: \(error.description, privacy: .public)")
            return .disabled
        }
    }

    /// Queues one line; the caller only takes the time and the thread. Call it on any thread but an
    /// IO thread.
    public func note(
        _ category: DiagnosticCategory, _ event: StaticString, level: DiagnosticLevel = .notice,
        _ fields: KeyValuePairs<String, DiagnosticValue> = [:]
    ) {
        note(category, event, level: level, fields: Array(fields))
    }

    func note(
        _ category: DiagnosticCategory, _ event: StaticString, level: DiagnosticLevel = .notice,
        fields: [(key: String, value: DiagnosticValue)]
    ) {
        guard let journal else { return }
        journal.note(Entry(category, event, fields, level: level))
    }

    /// Writes the begin line of a call that can block, so a call that never returns leaves it in
    /// the file. `end` on the result writes the step line with the ms of the call.
    public func begin(
        _ category: DiagnosticCategory, _ event: StaticString, _ fields: KeyValuePairs<String, DiagnosticValue> = [:]
    ) -> DiagnosticSpan {
        note(category, event, fields: Array(fields))
        return DiagnosticSpan(log: self, category: category, start: .now)
    }

    /// Queues `app quit` and `fsync` behind the queued lines, then closes the journal, and waits
    /// for them at most 1 s. Each later note writes nothing, so a writer queue that notes a line
    /// during the exit cannot make a clean quit look unclean. On a disk that does not answer, it
    /// returns with no quit line.
    public func quit() {
        guard let journal else { return }
        journal.refuseNotes()
        let entry = Entry(.app, "quit", [])
        let written = DispatchWorkItem {
            journal.drain()
            journal.append([entry], sync: true)
            journal.closeFile()
        }
        journal.queue.async(execute: written)
        // A work item wait lends the QoS of the caller to the `.utility` queue; a semaphore wait
        // does not, and under load the queued lines then miss the bound.
        _ = written.wait(timeout: .now() + Self.quitLimit)
    }

    static let quitLimit = 1.0

    /// Tests: returns after the queue ran each block queued before the call.
    func drain() { journal?.queue.sync {} }
}

/// A call between its begin line and its step line (`DiagnosticLog.begin`).
public struct DiagnosticSpan: Sendable {
    let log: DiagnosticLog
    let category: DiagnosticCategory
    let start: ContinuousClock.Instant

    /// Writes the step line: `fields`, then `ms`, the time since the begin line.
    public func end(
        _ event: StaticString, level: DiagnosticLevel = .notice, _ fields: KeyValuePairs<String, DiagnosticValue> = [:]
    ) {
        end(event, level: level, fields: Array(fields))
    }

    func end(_ event: StaticString, level: DiagnosticLevel = .notice, fields: [(key: String, value: DiagnosticValue)]) {
        log.note(category, event, level: level, fields: fields + [("ms", .since(start))])
    }
}

/// The system log of the journal: only for a journal that does not open, or a salt that does not.
let diagnosticsLog = Logger(subsystem: "com.delineas.dirigible", category: "diagnostics")

/// One line before its format: the caller takes the time, the uptime, and the thread, and the
/// journal queue makes the text and the tokens.
struct Entry: Sendable {
    let date: Date
    let uptimeNanos: UInt64
    let thread: String
    let level: DiagnosticLevel
    let category: DiagnosticCategory
    let event: StaticString
    let fields: [(key: String, value: DiagnosticValue)]

    init(
        _ category: DiagnosticCategory, _ event: StaticString, _ fields: [(key: String, value: DiagnosticValue)],
        level: DiagnosticLevel = .notice, date: Date = .now
    ) {
        self.date = date
        uptimeNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        thread = threadName()
        self.level = level
        self.category = category
        self.event = event
        self.fields = fields
    }

    /// The line with its newline: the six columns, then one `key=value` column for each field.
    func line(salt: SymmetricKey?) -> String {
        var line = "\(utcTime(date))\t\(uptimeNanos / 1_000_000)\t\(escaped(thread))\t\(level.rawValue)"
        line += "\t\(category.rawValue)\t\(event)"
        for (key, value) in fields { line += "\t\(escaped(key))=\(text(of: value, salt: salt))" }
        return line + "\n"
    }
}

private func text(of value: DiagnosticValue, salt: SymmetricKey?) -> String {
    switch value {
    case .text(let text): escaped(text)
    case .number(let number): String(number)
    case .milliseconds(let ms): String(format: "%.1f", ms)
    case .status(let status): statusText(status)
    case .uid(let uid): "uid-" + (salt.map { token(uid, salt: $0) } ?? "none")
    }
}

/// The first 8 hex characters of HMAC-SHA256 of `value`, so one value has one token in each
/// journal of the log folder, and the raw value is never in a file.
func token(_ value: String, salt: SymmetricKey) -> String {
    HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: salt).prefix(4)
        .map { String(format: "%02x", $0) }.joined()
}

/// `!hog/560492391` when the four bytes are printable ASCII, else the integer.
private func statusText(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
    guard status != 0, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(status) }
    return escaped(String(decoding: bytes, as: UTF8.self)) + "/" + String(status)
}

/// A tab, a line feed, a carriage return, and a backslash become `\t`, `\n`, `\r`, and `\\`, so
/// one line stays one line with six fixed columns.
func escaped(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: { "\t\n\r\\".unicodeScalars.contains($0) }) else { return text }
    var out = ""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\t": out += "\\t"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\\": out += "\\\\"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// `main`, or the label of the current queue. A Dirigible label is `Dirigible.<owner>` with an
/// optional detail, and only its first two parts go to the file.
private func threadName() -> String {
    if pthread_main_np() != 0 { return "main" }
    let label = String(cString: __dispatch_queue_get_label(nil))
    if label.hasPrefix("Dirigible.") { return label.split(separator: ".").prefix(2).joined(separator: ".") }
    return label.isEmpty ? "thread" : label
}

/// `2026-10-16T19:20:00.123Z`.
private func utcTime(_ date: Date) -> String {
    let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let parts = utcParts(ms / 1000)
    return String(
        format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
        parts.tm_hour, parts.tm_min, parts.tm_sec, Int32(ms % 1000))
}

/// `2026-10-16-192000`, the time part of a journal name.
func fileTime(_ date: Date) -> String {
    let parts = utcParts(Int64(date.timeIntervalSince1970.rounded(.down)))
    return String(
        format: "%04d-%02d-%02d-%02d%02d%02d", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday, parts.tm_hour,
        parts.tm_min, parts.tm_sec)
}

private func utcParts(_ seconds: Int64) -> tm {
    var time = time_t(seconds)
    var parts = tm()
    gmtime_r(&time, &parts)
    return parts
}

/// The fields of `app launch`: the build facts of the front end, macOS, the architecture, the
/// model, and the locale. `summary.txt` of a bundle has the same facts.
func launchFields(version: String, commit: String) -> [(key: String, value: DiagnosticValue)] {
    let system = ProcessInfo.processInfo.operatingSystemVersion
    #if arch(arm64)
        let arch = "arm64"
    #else
        let arch = "x86_64"
    #endif
    let macos = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion) (\(sysctlText("kern.osversion")))"
    return [
        ("version", .text(version)), ("commit", .text(commit)), ("macos", .text(macos)),
        ("arch", .text(arch)), ("model", .text(sysctlText("hw.model"))), ("locale", .text(Locale.current.identifier)),
    ]
}

private func sysctlText(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var bytes = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}
