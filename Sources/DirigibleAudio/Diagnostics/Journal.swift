import CryptoKit
import Darwin
import Foundation
import os

/// Why `Journal.open` failed: the step and its errno, for the one `fault` line of the system log.
struct JournalOpenError: Error, CustomStringConvertible {
    let step: String
    let code: Int32
    var description: String { "\(step): errno \(code)" }
}

/// The file side of `DiagnosticLog` (decision 0059). `open` runs on the caller. After it, only
/// `queue` touches the descriptor and the part size; `waiting` has its own lock. The open part
/// holds an exclusive `flock` lock (`O_EXLOCK`) until the quit or the end of the process, so
/// `isLive` tells a running launch from a PID that a new process got after a restart.
final class Journal: @unchecked Sendable {
    /// A part of 4 MiB, then the rotation to `<stem>.prev.tsv`.
    static let partLimit = 4 << 20
    /// The retention at each start: the launches of each kind, and the bytes of all journals.
    static let launchLimit = 20
    static let byteLimit: Int64 = 50 << 20

    static func makeQueue() -> DispatchQueue { DispatchQueue(label: "Dirigible.Journal", qos: .utility) }

    let queue: DispatchQueue
    private let salt: SymmetricKey
    private let current: String
    private let previous: String
    /// The version line, the header, and the launch line: the start of each part.
    private let preamble: Data
    private let partLimit: Int
    private var descriptor: Int32
    private var partBytes: Int
    /// The noted lines that no drain has taken yet, and true after `refuseNotes`.
    private let waiting = OSAllocatedUnfairLock(initialState: (lines: [Entry](), refused: false))

    private init(
        queue: DispatchQueue, salt: SymmetricKey, stem: URL, preamble: Data, partLimit: Int, descriptor: Int32
    ) {
        self.queue = queue
        self.salt = salt
        current = stem.path + ".tsv"
        previous = stem.path + ".prev.tsv"
        self.preamble = preamble
        self.partLimit = partLimit
        self.descriptor = descriptor
        partBytes = preamble.count
    }

    /// Makes the folder and the salt, opens the new journal, writes its preamble, and reads the end
    /// of the earlier app journal (an app start only). Then the queue runs the retention. Returns
    /// the journal and true for an unclean end of the earlier launch.
    static func open(
        _ kind: DiagnosticLog.Kind, folder: URL, now: Date, launch: Entry, queue: DispatchQueue, partLimit: Int
    ) throws(JournalOpenError) -> (Journal, unclean: Bool) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw JournalOpenError(step: "folder", code: Int32((error as NSError).code))
        }
        let salt = try readSalt(in: folder)
        let name = JournalName(time: fileTime(now), kind: kind, pid: getpid())
        let stem = folder.appending(path: name.stem)
        let descriptor = Darwin.open(stem.path + ".tsv", partFlags, 0o644)
        guard descriptor >= 0 else { throw JournalOpenError(step: "open", code: errno) }
        let preamble = Data(("dirigible-journal 1\n" + header + launch.line(salt: salt)).utf8)
        guard writeAll(descriptor, preamble) else {
            let code = errno
            close(descriptor)
            unlink(stem.path + ".tsv")
            throw JournalOpenError(step: "write", code: code)
        }
        let journal = Journal(
            queue: queue, salt: salt, stem: stem, preamble: preamble, partLimit: partLimit, descriptor: descriptor)
        var unclean = false
        if kind == .app, let last = uncleanEnd(in: folder, before: name) {
            unclean = true
            let line = Entry(.app, "previous-unclean", [("last", .text(last.event)), ("last_time", .text(last.time))])
            queue.async { journal.append([line]) }
        }
        queue.async { prune(folder) }
        return (journal, unclean)
    }

    static let header = "time\tuptime_ms\tthread\tlevel\tcategory\tevent\tfields...\n"

    /// A new part, with its lock taken in the same call, so no reader finds it open and unlocked.
    private static let partFlags = O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_CLOEXEC | O_EXLOCK

    /// Adds a line for the next drain. Only the line that finds none waiting queues a drain, so
    /// a backlog costs few writes. After `refuseNotes`, it drops the line.
    func note(_ entry: Entry) {
        let first = waiting.withLock { state in
            guard !state.refused else { return false }
            state.lines.append(entry)
            return state.lines.count == 1
        }
        if first { queue.async { self.drain() } }
    }

    /// Drops each later note, so the line that the quit queues next is the last line.
    func refuseNotes() { waiting.withLock { $0.refused = true } }

    /// Writes each waiting line, on the queue.
    func drain() {
        append(
            waiting.withLock { state in
                defer { state.lines = [] }
                return state.lines
            })
    }

    /// Closes the part, on the queue, after the quit line. The close drops the lock.
    func closeFile() {
        dispatchPrecondition(condition: .onQueue(queue))
        close(descriptor)
        descriptor = -1
    }

    /// Writes the lines on the queue, with one `write(2)` for each part. A full part first moves
    /// to `<stem>.prev.tsv`. A `fault` line, a `hang` line, and `sync` also call `fsync`. Lines
    /// that the disk refuses are lost.
    func append(_ entries: [Entry], sync: Bool = false) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard descriptor >= 0 else { return }
        var batch = Data()
        var needsSync = sync
        func flush() {
            if Self.writeAll(descriptor, batch) { partBytes += batch.count }
            if needsSync { fsync(descriptor) }
            batch.removeAll(keepingCapacity: true)
        }
        for entry in entries {
            let line = entry.line(salt: salt).utf8
            if partBytes + batch.count + line.count > partLimit, partBytes + batch.count > preamble.count {
                flush()
                rotate()
            }
            batch.append(contentsOf: line)
            needsSync = needsSync || entry.level == .fault || entry.category == .hang
        }
        flush()
    }

    /// The part becomes `<stem>.prev.tsv` (it replaces an older one), and a new part starts with
    /// the preamble. When a step fails, the lines go on into the open part. The old part keeps its
    /// lock until the new part has one.
    private func rotate() {
        guard rename(current, previous) == 0 else { return }
        let next = Darwin.open(current, Self.partFlags, 0o644)
        guard next >= 0 else { return }
        close(descriptor)
        descriptor = next
        partBytes = Self.writeAll(next, preamble) ? preamble.count : 0
    }

    private static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

// MARK: The salt

extension Journal {
    /// The 32 bytes of `salt` in `folder`. A start with no salt writes 32 random bytes to a new
    /// temporary file, moves it to `salt` only when no salt exists (`RENAME_EXCL`), and reads
    /// `salt` back, so two starts at once use one salt. A salt of fewer than 32 bytes is replaced.
    /// A test runs a second start in `beforeMove`, between the temporary write and the move.
    static func readSalt(in folder: URL, beforeMove: () -> Void = {}) throws(JournalOpenError) -> SymmetricKey {
        let path = folder.appending(path: "salt").path
        let found = FileManager.default.contents(atPath: path)
        if let found, found.count >= 32 { return SymmetricKey(data: found.prefix(32)) }
        // The UUID makes the name new for each start, also for two starts in one process.
        let temporary = folder.appending(path: "salt.\(getpid())-\(UUID().uuidString).tmp").path
        let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw JournalOpenError(step: "salt", code: errno) }
        let written = writeAll(descriptor, Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        let synced = fsync(descriptor) == 0
        close(descriptor)
        guard written, synced else {
            let code = errno
            unlink(temporary)
            throw JournalOpenError(step: "salt", code: code)
        }
        beforeMove()
        let moved = found == nil ? renamex_np(temporary, path, UInt32(RENAME_EXCL)) : rename(temporary, path)
        if moved != 0 {
            let code = errno
            unlink(temporary)
            guard code == EEXIST else { throw JournalOpenError(step: "salt", code: code) }
        }
        guard let back = FileManager.default.contents(atPath: path), back.count >= 32 else {
            throw JournalOpenError(step: "salt", code: EIO)
        }
        return SymmetricKey(data: back.prefix(32))
    }
}

// MARK: The names, the retention, and the unclean end

/// A journal file name: `<yyyy-MM-dd-HHmmss>-<kind>-<pid>.tsv`, or its `.prev.tsv` part.
struct JournalName: Hashable {
    let time: String
    let kind: DiagnosticLog.Kind
    let pid: Int32
    var stem: String { "\(time)-\(kind.rawValue)-\(pid)" }

    init(time: String, kind: DiagnosticLog.Kind, pid: Int32) {
        self.time = time
        self.kind = kind
        self.pid = pid
    }

    /// Nil for each other file, the salt too.
    init?(file: String) {
        guard let match = file.wholeMatch(of: #/(\d{4}-\d{2}-\d{2}-\d{6})-(app|cli)-(\d{1,10})(?:\.prev)?\.tsv/#),
            let kind = DiagnosticLog.Kind(rawValue: String(match.2)), let pid = Int32(match.3)
        else { return nil }
        self.init(time: String(match.1), kind: kind, pid: pid)
    }
}

extension Journal {
    /// True while another open holds the lock of a part of the launch. A PID is no proof: after a
    /// restart, a new process can have the PID of an earlier launch. The kernel drops the lock
    /// when the process ends.
    static func isLive(_ name: JournalName, in folder: URL) -> Bool {
        [".tsv", ".prev.tsv"].contains { suffix in
            let descriptor = Darwin.open(
                folder.appending(path: name.stem + suffix).path, O_RDONLY | O_CLOEXEC | O_SHLOCK | O_NONBLOCK)
            guard descriptor >= 0 else { return errno == EWOULDBLOCK }
            close(descriptor)
            return false
        }
    }

    /// Deletes the oldest launches (both parts of each) until each kind has `launchLimit` or fewer
    /// and all journals have `byteLimit` bytes or fewer. It lists only journal names, and it never
    /// deletes a live launch.
    static func prune(_ folder: URL, launches: Int = launchLimit, bytes limit: Int64 = byteLimit) {
        var parts: [JournalName: (files: [String], bytes: Int64)] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            guard let name = JournalName(file: file) else { continue }
            var info = stat()
            let size = stat(folder.appending(path: file).path, &info) == 0 ? Int64(info.st_size) : 0
            parts[name, default: ([], 0)].files.append(file)
            parts[name]?.bytes += size
        }
        let oldestFirst = parts.keys.sorted { ($0.time, $0.stem) < ($1.time, $1.stem) }
        var doomed: Set<JournalName> = []
        for kind in [DiagnosticLog.Kind.app, .cli] {
            var excess = oldestFirst.count { $0.kind == kind } - launches
            for name in oldestFirst where excess > 0 && name.kind == kind && !isLive(name, in: folder) {
                doomed.insert(name)
                excess -= 1
            }
        }
        var total = parts.filter { !doomed.contains($0.key) }.values.reduce(0) { $0 + $1.bytes }
        for name in oldestFirst where total > limit && !doomed.contains(name) && !isLive(name, in: folder) {
            doomed.insert(name)
            total -= parts[name]?.bytes ?? 0
        }
        for name in doomed {
            for file in parts[name]?.files ?? [] { unlink(folder.appending(path: file).path) }
        }
    }

    /// The last line of the newest app journal before `name`, when it is not `app quit` and the
    /// launch is not live. Nil with no earlier app journal.
    static func uncleanEnd(in folder: URL, before name: JournalName) -> (event: String, time: String)? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let earlier = Set(files.compactMap(JournalName.init(file:))).filter {
            $0.kind == .app && $0 != name && ($0.time, $0.stem) < (name.time, name.stem)
        }
        guard let newest = earlier.max(by: { ($0.time, $0.stem) < ($1.time, $1.stem) }),
            !isLive(newest, in: folder)
        else { return nil }
        let stem = folder.appending(path: newest.stem).path
        let text = lastLine(of: stem + ".tsv") ?? lastLine(of: stem + ".prev.tsv")
        guard let line = text.flatMap(JournalLine.init) else { return ("unreadable", "") }
        if line.category == DiagnosticCategory.app.rawValue, line.event == "quit" { return nil }
        return ("\(line.category) \(line.event)", line.time)
    }

    /// The last line of the file, from its last 64 KiB. Nil when the file does not open.
    private static func lastLine(of path: String) -> Substring? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return tail.split(separator: "\n").last
    }
}

/// The fixed columns of one journal line that a reader needs. Nil for the version line, the
/// header, and a line with fewer than six columns (a line of another version, or a torn line).
struct JournalLine {
    let time: String
    let category: String
    let event: String

    init?(_ text: Substring) {
        let columns = text.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count >= 6, columns[0] != "time" else { return nil }
        time = String(columns[0])
        category = String(columns[4])
        event = String(columns[5])
    }
}
