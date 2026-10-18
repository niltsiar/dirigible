import CryptoKit
import Foundation

/// Why `DiagnosticBundle.collect` wrote no zip.
public enum BundleError: Error, Equatable, Sendable {
    /// A file or a folder is at the zip path.
    case exists
    /// The zip could not be written, with the reason in English.
    case cannotWrite(String)
}

/// The problem report of decision 0059: one zip with `summary.txt`, `devices.tsv`, `logs/`, and
/// `reports/`, with the names of the Mac and its user replaced. It never holds the salt, audio,
/// a session file, or the system log. Nothing leaves the Mac: the user sends the file.
public enum DiagnosticBundle {
    /// What a collect put into the zip.
    public struct Collected: Equatable, Sendable {
        /// The journal files in `logs/`.
        public let logs: Int
        /// The system reports in `reports/`.
        public let reports: Int
        /// One line for each group or file that the bundle could not read, with the reason.
        public let skipped: [String]
    }

    /// The report folders of the user and of the system.
    public static let reportFolders = [
        URL.libraryDirectory.appending(path: "Logs/DiagnosticReports", directoryHint: .isDirectory),
        URL(filePath: "/Library/Logs/DiagnosticReports", directoryHint: .isDirectory),
    ]

    /// Writes the zip at `zip`, which must not exist: the journals of `logs` of the last `days`
    /// days (1 or more), and the `Dirigible` reports of `reports` of the last 30 days, the 20
    /// newest. `version` and `commit` are the build facts of the front end.
    @concurrent public static func collect(
        to zip: URL, days: Int = 7, logs: URL, reports: [URL], version: String, commit: String
    ) async throws(BundleError) -> Collected {
        try write(
            to: zip, days: days, logs: logs, reports: reports, facts: .live(version: version, commit: commit), now: .now
        )
    }

    static let reportDays = 30
    static let reportLimit = 20
    /// The most bytes of a `.hang` or `.spin` report that the bundle reads.
    static let hangReportLimit = 4 * 1024 * 1024

    /// `collect` with the facts of the Mac as a value. Tests give a fake device list and fake names.
    static func write(
        to zip: URL, days: Int, logs: URL, reports: [URL], facts: BundleFacts, now: Date
    ) throws(BundleError) -> Collected {
        try checkTarget(zip)
        let staging = FileManager.default.temporaryDirectory.appending(path: "Dirigible-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        // The zip holds this folder; its fixed name holds no user data.
        let root = staging.appending(path: "Dirigible Report", directoryHint: .isDirectory)
        do {
            for folder in ["logs", "reports"] {
                try FileManager.default.createDirectory(
                    at: root.appending(path: folder), withIntermediateDirectories: true)
            }
        } catch {
            throw .cannotWrite("the temporary folder cannot be made")
        }
        var copy = Copy(root: root, redaction: facts.redaction)
        let salt = existingSalt(in: logs) ?? SymmetricKey(size: .bits256)
        let logCount = try copy.journals(in: logs, since: now.addingTimeInterval(-Double(days) * 86_400))
        let reportCount = try copy.reports(in: reports, since: now.addingTimeInterval(-Double(reportDays) * 86_400))
        try copy.write(deviceTable(facts.devices, salt: salt), as: "devices.tsv")
        try copy.write(
            summary(facts, salt: salt, logs: logCount, reports: reportCount, skipped: copy.skipped), as: "summary.txt")
        try archive(root, to: zip)
        return Collected(logs: logCount, reports: reportCount, skipped: copy.skipped)
    }

    /// Refuses a zip path that exists, or whose folder is missing or has no write permission.
    private static func checkTarget(_ zip: URL) throws(BundleError) {
        var info = stat()
        guard lstat(zip.path, &info) != 0 else { throw .exists }
        let folder = zip.deletingLastPathComponent().path
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            throw .cannotWrite("the folder of the zip does not exist")
        }
        guard access(folder, W_OK) == 0 else { throw .cannotWrite("the folder of the zip has no write permission") }
    }

    /// The salt of the journals, so `devices.tsv` gives each device the token of the journals.
    /// The bundle reads it and never copies it. Nil when the folder has no salt.
    static func existingSalt(in logs: URL) -> SymmetricKey? {
        guard let data = FileManager.default.contents(atPath: logs.appending(path: "salt").path), data.count >= 32
        else { return nil }
        return SymmetricKey(data: data.prefix(32))
    }

    /// Zips `root` with Foundation only. The coordinator deletes its zip when the block returns,
    /// so the move runs in the block.
    private static func archive(_ root: URL, to zip: URL) throws(BundleError) {
        var coordinatorError: NSError?
        var moveError: CocoaError?
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinatorError) { made in
            do {
                try FileManager.default.moveItem(at: made, to: zip)
            } catch {
                moveError = error as? CocoaError ?? CocoaError(.fileWriteUnknown)
            }
        }
        if moveError?.code == .fileWriteFileExists { throw .exists }
        if let failure = moveError ?? coordinatorError.map({ CocoaError(CocoaError.Code(rawValue: $0.code)) }) {
            throw .cannotWrite("the zip was not written (Cocoa error \(failure.code.rawValue))")
        }
    }
}

/// The copy of the files into the folder of the zip, each through the redaction.
private struct Copy {
    let root: URL
    let redaction: Redaction
    private(set) var skipped: [String] = []

    init(root: URL, redaction: Redaction) {
        self.root = root
        self.redaction = redaction
    }

    /// The journal parts that changed since `start`. Only journal names, so never the salt.
    mutating func journals(in folder: URL, since start: Date) throws(BundleError) -> Int {
        let files = list(folder, group: "logs").filter { file in
            JournalName(file: file.url.lastPathComponent) != nil && file.modified >= start
        }
        var count = 0
        for file in files where try copy(file.url, to: "logs", group: "logs") { count += 1 }
        return count
    }

    /// The `Dirigible` reports of the folders that changed since `start`, newest first, at most
    /// `reportLimit`. The prefix ignores case, so a report of the `dirigible` tool comes too.
    mutating func reports(in folders: [URL], since start: Date) throws(BundleError) -> Int {
        var found: [File] = []
        for folder in folders {
            found += list(folder, group: "reports \(folder.path)").filter { file in
                file.url.lastPathComponent.lowercased().hasPrefix("dirigible") && file.modified >= start
            }
        }
        var names: Set<String> = []
        let newest = found.sorted { $0.modified > $1.modified }.filter {
            names.insert($0.url.lastPathComponent).inserted
        }
        var count = 0
        for file in newest.prefix(DiagnosticBundle.reportLimit)
        where try copy(file.url, to: "reports", group: "reports") {
            count += 1
        }
        return count
    }

    func write(_ text: String, as name: String) throws(BundleError) {
        try save(redaction.apply(text), to: root.appending(path: name))
    }

    private func save(_ text: String, to file: URL) throws(BundleError) {
        do {
            try Data(text.utf8).write(to: file)
        } catch {
            throw .cannotWrite("the temporary folder is full or has no write permission")
        }
    }

    private struct File {
        let url: URL
        let modified: Date
    }

    /// The regular files of `folder`. A folder that does not exist gives no file and no skip line.
    private mutating func list(_ folder: URL, group: String) -> [File] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
        } catch {
            if let reason = reason(error) { skipped.append("\(group): \(reason)") }
            return []
        }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                let modified = values.contentModificationDate
            else { return nil }
            return File(url: url, modified: modified)
        }
    }

    /// Copies one text file with its name and its text redacted. False when it cannot be read.
    /// A spindump report (`.hang`, `.spin`) holds the stacks of each process of the Mac, so the
    /// copy reads at most `hangReportLimit` bytes and stops before its second `Process:` line:
    /// the header and the first process with its binary images stay.
    private mutating func copy(_ file: URL, to folder: String, group: String) throws(BundleError) -> Bool {
        var text: String
        let isSpindump = ["hang", "spin"].contains(file.pathExtension.lowercased())
        do {
            if isSpindump {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                text = String(
                    decoding: try handle.read(upToCount: DiagnosticBundle.hangReportLimit) ?? Data(), as: UTF8.self)
            } else {
                text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            }
        } catch {
            skipped.append("\(group) \(file.lastPathComponent): \(reason(error) ?? "the file is gone")")
            return false
        }
        if isSpindump, let second = text.matches(of: /(?m)^Process:/).dropFirst().first {
            text = String(text[..<second.range.lowerBound])
        }
        let name = redaction.apply(file.lastPathComponent)
        try save(redaction.apply(text), to: root.appending(path: folder).appending(path: name))
        return true
    }

    /// The reason of a read error in English, or nil when the item does not exist.
    private func reason(_ error: any Error) -> String? {
        switch (error as NSError).code {
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError: nil
        case NSFileReadNoPermissionError: "no read permission (a system folder needs an administrator)"
        default: "Cocoa error \((error as NSError).code)"
        }
    }
}
