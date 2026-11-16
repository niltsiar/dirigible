import Foundation

/// The agent log of a package (decision 0050): `agent-log.tsv` at the top level, one line for
/// each end of an agent record request. The first line is the version (decision 0024 P1), the
/// second line is the column header. The file is not part of the session: undo, a backup revert,
/// and Remove Unused Files keep it.
public enum AgentLog {
    public static let fileName = "agent-log.tsv"
    public static let version = 1
    static let versionText = "# Dirigible agent log, version "
    static let header = "time\tevent\ttake\tagent\tconnection\ttracks\tseconds\treason"

    /// How an agent record request ended.
    public enum Event: String, Sendable {
        /// The user clicked Record in the sheet.
        case click
        /// A window grant started the take with no sheet.
        case grant
        case declined
        case noAnswer = "no-answer"
        /// The app refused the request, or it ended with no sheet answer: the reason says why.
        case refused
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
        /// Why a `refused` request ended, or nil.
        public let reason: String?

        public init(
            time: Date, event: Event, take: Int?, agent: String?, connection: UInt64?, tracks: [String],
            seconds: Double, reason: String? = nil
        ) {
            (self.time, self.event, self.take, self.agent) = (time, event, take, agent)
            (self.connection, self.tracks, self.seconds, self.reason) = (connection, tracks, seconds, reason)
        }

        /// The line with its line break. A tab or a line break in a text becomes a space. A text
        /// that starts with =, +, -, or @ gets a leading ', so a spreadsheet does not read a formula.
        var line: String {
            func clean(_ text: String) -> String {
                let flat = String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
                return flat.first.map { "=+-@".contains($0) } == true ? "'" + flat : flat
            }
            let time = ISO8601DateFormatter.string(
                from: time, timeZone: .current, formatOptions: [.withInternetDateTime])
            let length = seconds.rounded() == seconds ? "\(Int(seconds))" : "\(seconds)"
            let fields = [
                time, event.rawValue, take.map(String.init) ?? "-", agent.map(clean) ?? "-",
                connection.map(String.init) ?? "-",
                clean(tracks.joined(separator: ", ")), length, reason.map(clean) ?? "-",
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

    /// Appends `entry` to the log of `package`. It opens the log, and only when there is no log
    /// it makes one (`O_EXCL`) with the version line, the header, and the entry in one `write()`.
    /// When that first write is short, it removes the file, so the next append starts clean. The
    /// append makes no other file, so it works on each volume (exFAT has no `RENAME_EXCL`). A file
    /// of 0 bytes gets the three lines in one `write()`. After a partial last line, the entry
    /// starts on a new line. `writing` is the write step; tests give their own.
    static func append(
        _ entry: Entry, to package: URL, writing: (String, Int32) -> Result = write(_:to:)
    ) -> Result {
        let path = package.appending(path: fileName).path
        let first = versionText + "\(version)\n" + header + "\n" + entry.line
        // A link at the name fails (ELOOP), so an append never writes out of the package.
        let fd = open(path, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? create(first, at: path, writing) : .failed(errno) }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count >= 0 else { return .failed(errno) }
        if count == 0 { return writing(first, fd) }
        guard let newline = bytes[..<count].firstIndex(of: UInt8(ascii: "\n")),
            let line = String(bytes: bytes[..<newline], encoding: .utf8), line.hasPrefix(versionText),
            case let digits = line.dropFirst(versionText.count),
            !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let found = Int(digits)
        else { return .unreadable }
        guard found <= version else { return .newer(found) }
        var last: UInt8 = 0
        let end = lseek(fd, 0, SEEK_END)
        guard end > 0, pread(fd, &last, 1, end - 1) == 1 else { return .failed(errno) }
        return writing((last == UInt8(ascii: "\n") ? "" : "\n") + entry.line, fd)
    }

    /// Makes the log at `path` with `text`, or gives `.failed(EEXIST)` when it exists. A short
    /// write removes the file.
    private static func create(_ text: String, at path: String, _ writing: (String, Int32) -> Result) -> Result {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .failed(errno) }
        let written = writing(text, fd)
        close(fd)
        if written != .written { unlink(path) }
        return written
    }

    static func write(_ text: String, to fd: Int32) -> Result {
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
    package static func drain() { queue.sync {} }
}
