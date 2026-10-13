import ArgumentParser
import DirigibleCore
import DirigibleMCP
import Foundation

struct CaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Add and remove capture timing data (decision 0004), and place captured audio (decision 0021).",
        subcommands: [Add.self, Remove.self, Place.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a capture and write its ID.")
        @OptionGroup var package: PackageArgument
        @Option var deviceUID: String
        @Option var deviceName: String
        @Option(parsing: .unconditional, help: "The host time of the first frame in ns.") var hostTime: UInt64
        @Option(parsing: .unconditional, help: "The device sample time of the first frame.") var sampleTime: Double
        @Option(parsing: .unconditional, help: "The nominal device rate in Hz.") var nominalRate: Double
        @Option(parsing: .unconditional, help: "The measured device rate in Hz.") var measuredRate: Double
        @Option(parsing: .unconditional, help: "The device latency in frames at the device rate.") var latency: Int
        @Option(parsing: .unconditional, help: "The source rate when finalize resampled.") var resampledFrom: Double?
        @Flag(help: "Finalize refused the drift fit.") var driftNotCorrected = false
        @Option(help: "The capture ID. The default is a new UUID.") var id: String?

        func run() throws {
            let capture = Capture(
                id: id.map { CaptureID($0) } ?? CaptureID(), deviceUID: deviceUID, deviceName: deviceName,
                hostTimeNanos: hostTime, sampleTime: sampleTime, nominalSampleRate: nominalRate,
                measuredSampleRate: measuredRate, latency: latency, resampledFromRate: resampledFrom,
                driftCorrected: !driftNotCorrected)
            try editPackage(package) { session throws(SessionError) in try session.addCapture(capture) }
            print(capture.id)
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a capture that no file uses.")
        @OptionGroup var package: PackageArgument
        @Argument var capture: String

        func run() throws {
            try editPackage(package) { session throws(SessionError) in try session.removeCapture(CaptureID(capture)) }
        }
    }
}

struct FileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file", abstract: "Add and remove audio files in the pool.",
        subcommands: [Add.self, Remove.self, Prune.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a file to the pool and write its ID. The command does not read the audio.")
        @OptionGroup var package: PackageArgument
        @Option(help: "The path relative to the Clips folder of the package.") var path: String
        @Option(help: "mono or stereo.", transform: parseLayout) var layout: ChannelLayout
        @Option(parsing: .unconditional, help: "The length in frames.") var length: Int
        @Option(help: "The capture that recorded the file. Leave it out for an imported file.") var capture: String?
        @Option(help: "The file ID. The default is a new UUID.") var id: String?

        func run() throws {
            let file = AudioFile(
                id: id.map { FileID($0) } ?? FileID(), path: path, layout: layout, length: Frames(length),
                capture: capture.map { CaptureID($0) })
            try editPackage(package) { session throws(SessionError) in try session.addFile(file) }
            print(file.id)
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a file that no clip uses.")
        @OptionGroup var package: PackageArgument
        @Argument var file: String

        func run() throws {
            try editPackage(package) { session throws(SessionError) in try session.removeFile(FileID(file)) }
        }
    }
}

extension FileCommand {
    /// `dirigible file prune` (decision 0047): the lock is held from the read to the last move.
    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Move the clip files that no clip uses to the Trash.",
            discussion: """
                It lists each pool file that no clip uses and each WAV in Clips that the pool does not name, and \
                removes their pool entries. A file that a clip of session.xml or of a backup uses stays. The command \
                cannot see the clipboard of an app window. The space comes back when you empty the Trash. Exit 1 \
                when a file did not move or a backup blocks the scan, 2 when the package cannot be read or written, \
                is locked, or has a take that is not finalized.
                """)
        @OptionGroup var package: PackageArgument
        @Flag(help: "Write the list and change nothing.") var dryRun = false

        func run() async throws {
            let lock: PackageLock
            do throws(SessionFileError) {
                lock = try PackageLock(package.url)
            } catch {
                throw fail(error.message(package: package.path), code: packageError)
            }
            defer { withExtendedLifetime(lock) {} }
            var session = try readPackage(package)
            guard session.recording == nil else { throw fail(pendingTakeMessage(package.path), code: packageError) }
            let scan: UnusedFiles
            do throws(UnusedFilesError) {
                scan = try UnusedFiles(scanning: session, keptBy: [], in: package.url)
            } catch {
                throw failure(error)
            }
            for backup in scan.damagedBackups { print("Damaged backup, it keeps no file: Backups/\(backup.fileName)") }
            guard !dryRun else {
                for item in scan.items { print("\(item.path)\t\(item.bytes) bytes") }
                print("Unused files: \(count(scan.items.map(\.bytes)))")
                print("Kept for a backup: \(scan.kept.count) (\(scan.kept.bytes) bytes)")
                return
            }
            session.removeTemporaryFiles(in: package.url)
            let report: PruneReport
            do throws(UnusedFilesError) {
                report = try await scan.prune(&session) { session throws(SessionFileError) in
                    try session.write(under: lock)
                }
            } catch {
                throw failure(error)
            }
            for moved in report.moved { print("\(moved.item.path)\t\(moved.item.bytes) bytes\t\(moved.trashURL.path)") }
            print(
                "Moved to the Trash: \(count(report.moved.map(\.item.bytes))). The space comes back when you empty the Trash."
            )
            print("Kept for a backup: \(scan.kept.count) (\(scan.kept.bytes) bytes)")
            var exit: ExitCode?
            for failed in report.failed {
                let reason = NSError(domain: failed.fault.domain, code: failed.fault.code).localizedDescription
                exit = fail("\(failed.item.path) did not move to the Trash: \(reason)", code: editRefused)
            }
            if let exit { throw exit }
        }

        private func count(_ bytes: [Int64]) -> String { "\(bytes.count) (\(bytes.reduce(0, +)) bytes)" }

        /// A backup that blocks the scan exits 1; a package fault exits 2.
        private func failure(_ error: UnusedFilesError) -> ExitCode {
            let code = if case .backupUnreadable = error { editRefused } else { packageError }
            return fail(error.message(package: package.path), code: code)
        }
    }
}
