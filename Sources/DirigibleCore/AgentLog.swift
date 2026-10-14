import Foundation

/// The agent log of a package (decision 0050): `agent-log.tsv` at the top level, one line for
/// each end of an agent record request. The first line is the version (decision 0024 P1), the
/// second line is the column header. The file is not part of the session: undo, a backup revert,
/// and Remove Unused Files keep it.
public enum AgentLog {
    public static let fileName = "agent-log.tsv"
    public static let version = 1
    static let versionText = "# Dirigible agent log, version "
    static let header = "time\tevent\ttake\tagent\tconnection\ttracks\tseconds"

    /// How an agent record request ended.
    public enum Event: String, Sendable {
        /// The user clicked Record in the sheet.
        case click
        /// A window grant started the take with no sheet.
        case grant
        case declined
        case noAnswer = "no-answer"
    }

    /// One line of the log.
    public struct Entry: Sendable, Equatable {
        public let time: Date
        public let event: Event
        /// The take number, or nil when no take started.
        public let take: Int?
        /// The name that the agent gave, or nil.
        public let agent: String?
        /// The connection serial, or nil for a call with no bridge.
        public let connection: UInt64?
        public let tracks: [String]
        public let seconds: Double

        public init(
            time: Date, event: Event, take: Int?, agent: String?, connection: UInt64?, tracks: [String], seconds: Double
        ) {
            (self.time, self.event, self.take, self.agent) = (time, event, take, agent)
            (self.connection, self.tracks, self.seconds) = (connection, tracks, seconds)
        }

        /// The line with its line break. A tab or a line break in a text becomes a space.
        var line: String {
            func clean(_ text: String) -> String {
                String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
            }
            let time = ISO8601DateFormatter.string(
                from: time, timeZone: .current, formatOptions: [.withInternetDateTime])
            let length = seconds.rounded() == seconds ? "\(Int(seconds))" : "\(seconds)"
            let fields = [
                time, event.rawValue, take.map(String.init) ?? "-", agent.map(clean) ?? "-",
                connection.map(String.init) ?? "-",
                clean(tracks.joined(separator: ", ")), length,
            ]
            return fields.joined(separator: "\t") + "\n"
        }
    }

    /// The result of one append.
    public enum Result: Equatable, Sendable {
        case written
        /// The file has a higher version: no line (decision 0024 P4).
        case newer(Int)
        /// The first line does not parse: no line.
        case unreadable
        /// An open, a read, or a write failed with this errno.
        case failed(Int32)
    }

    /// Appends `entry` to the log of `package`. A new file, or a file of 0 bytes, gets the
    /// version line, the header, and the entry in one `write()`.
    public static func append(_ entry: Entry, to package: URL) -> Result {
        let path = package.appending(path: fileName).path
        let first = versionText + "\(version)\n" + header + "\n" + entry.line
        let created = open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC, 0o644)
        if created >= 0 {
            defer { close(created) }
            return write(first, to: created)
        }
        guard errno == EEXIST else { return .failed(errno) }
        let fd = open(path, O_RDWR | O_APPEND | O_CLOEXEC)
        guard fd >= 0 else { return .failed(errno) }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count >= 0 else { return .failed(errno) }
        if count == 0 { return write(first, to: fd) }
        guard let newline = bytes[..<count].firstIndex(of: UInt8(ascii: "\n")),
            let line = String(bytes: bytes[..<newline], encoding: .utf8), line.hasPrefix(versionText),
            case let digits = line.dropFirst(versionText.count),
            !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let found = Int(digits)
        else { return .unreadable }
        guard found <= version else { return .newer(found) }
        return write(entry.line, to: fd)
    }

    private static func write(_ text: String, to fd: Int32) -> Result {
        let data = Array(text.utf8)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        return written == data.count ? .written : .failed(written < 0 ? errno : EIO)
    }
}

/// The one writer of the agent logs of the process (decision 0050). The main actor calls it in
/// the order of the events, and one serial queue writes, so the lines keep that order. `holding`
/// stays alive until the write ends: the app gives the studio, which holds the package lock.
/// `done` gets the result, and then drops `holding`, on the main queue.
public enum AgentLogWriter {
    private static let queue = DispatchQueue(label: "Dirigible.AgentLog")

    public static func append(
        _ entry: AgentLog.Entry, to package: URL, holding: (any Sendable)? = nil,
        done: @escaping @MainActor @Sendable (AgentLog.Result) -> Void = { _ in }
    ) {
        queue.async {
            let result = AgentLog.append(entry, to: package)
            DispatchQueue.main.async {
                withExtendedLifetime(holding) { MainActor.assumeIsolated { done(result) } }
            }
        }
    }

    /// Waits until each queued write ended. For the tests.
    public static func drain() { queue.sync {} }
}
