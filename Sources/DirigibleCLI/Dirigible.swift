import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

@main
struct Dirigible: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dirigible",
        abstract: "Make, change, and read Dirigible session packages.",
        subcommands: [
            Create.self, Info.self, TrackCommand.self, FileCommand.self, CaptureCommand.self, ClipCommand.self,
            MarkerCommand.self, TakeCommand.self, Devices.self, Apps.self, Record.self, Render.self, Export.self,
            ChaptersCommand.self,
            PeaksCommand.self, LoudnessCommand.self, LevelCommand.self, ImportCommand.self, BackupCommand.self,
            MCPCommand.self,
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
        guard EditRules.isPackagePath(package.url) else {
            throw ValidationError("The package path must end in .dirigible.")
        }
        guard EditRules.sampleRate(sampleRate) != nil else {
            throw ValidationError("The sample rate must be more than 0.")
        }
    }

    func run() throws {
        do {
            try Session.create(at: package.url, sampleRate: sampleRate)
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
        let media: [FileID: MediaFault]
        do {
            media = try checkMedia(session, package: package.url)
        } catch {
            throw fail(mediaCheckMessage(error), code: packageError)
        }
        print(
            json
                ? try SessionView(session, media: media).json()
                : summary(of: session, name: package.url.lastPathComponent, media: media),
            terminator: "")
    }
}
