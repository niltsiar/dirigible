import ArgumentParser
import DirigibleCore
import Foundation

@main
struct Dirigible: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dirigible",
        abstract: "Make, change, and read Dirigible session packages.",
        subcommands: [
            Create.self, Info.self, TrackCommand.self, FileCommand.self, CaptureCommand.self, ClipCommand.self,
            MarkerCommand.self, TakeCommand.self, Devices.self,
        ])
}

struct PackageArgument: ParsableArguments {
    @Argument(help: ArgumentHelp("The session package, for example Show.dirigible.", valueName: "package"))
    var path: String
    var url: URL { URL(filePath: path) }
}

struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make an empty session package.")

    @OptionGroup var package: PackageArgument
    @Option(parsing: .unconditional, help: "The session sample rate in Hz.") var sampleRate: Int

    func validate() throws {
        guard package.url.pathExtension == "dirigible" else {
            throw ValidationError("The package path must end in .dirigible.")
        }
        // Session.init traps on a rate that is not positive.
        guard sampleRate > 0 else { throw ValidationError("The sample rate must be more than 0.") }
    }

    func run() throws {
        guard !FileManager.default.fileExists(atPath: package.path) else {
            throw fail("\(package.path) exists.", code: packageError)
        }
        do {
            try Session(sampleRate: sampleRate).write(to: package.url)
        } catch {
            throw fail(error.message(package: package.path), code: packageError)
        }
    }
}

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the contents of a session package.")

    @OptionGroup var package: PackageArgument
    @Flag(help: "Write the session as JSON.") var json = false

    func run() throws {
        let session = try readPackage(package)
        print(
            json ? try SessionView(session).json() : summary(of: session, name: package.url.lastPathComponent),
            terminator: "")
    }
}
