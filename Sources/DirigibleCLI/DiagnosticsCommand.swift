import ArgumentParser
import DirigibleAudio
import Foundation

struct DiagnosticsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics", abstract: "Save the logs and the reports of a problem.",
        subcommands: [Collect.self])
}

extension DiagnosticsCommand {
    struct Collect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Save a problem report: one zip with the journals, the crash and hang reports, and the devices.",
            discussion: """
                The zip replaces the home folder, the user name, and the names of the Mac. It holds no audio and no \
                session file, and nothing leaves the Mac: send the file by hand. It reads no package and changes \
                none. Exit 2 when the zip exists or cannot be written (decision 0059).
                """)

        @Argument(help: ArgumentHelp("The zip file to write. It must not exist.", valueName: "zip"))
        var zip: String
        @Option(parsing: .unconditional, help: "The journals of the last <days> days.") var days = 7
        @Option(help: "The journal folder. The default is DIRIGIBLE_LOG_FOLDER, else ~/Library/Logs/Dirigible.")
        var logs: String?
        @Option(
            help: """
                A folder of crash and hang reports. Repeat it for each folder. The default is the \
                DiagnosticReports folder of the user and of the system.
                """)
        var reports: [String] = []

        func validate() throws {
            guard (1...3650).contains(days) else { throw ValidationError("The days must be from 1 to 3650.") }
        }

        func run() async throws {
            let collected: DiagnosticBundle.Collected
            do throws(BundleError) {
                collected = try await DiagnosticBundle.collect(
                    to: URL(filePath: zip), days: days,
                    logs: logs.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? DiagnosticLog.folder(),
                    reports: reports.isEmpty
                        ? DiagnosticBundle.reportFolders
                        : reports.map { URL(filePath: $0, directoryHint: .isDirectory) },
                    version: Dirigible.appVersion, commit: Dirigible.appCommit)
            } catch {
                switch error {
                case .exists: throw fail("\(zip) exists.", code: packageError)
                case .cannotWrite(let reason): throw fail("\(zip) was not written: \(reason).", code: packageError)
                }
            }
            print("Saved \(zip): \(collected.logs) journals, \(collected.reports) reports.")
            for line in collected.skipped {
                try? FileHandle.standardError.write(contentsOf: Data("Skipped \(line)\n".utf8))
            }
        }
    }
}
