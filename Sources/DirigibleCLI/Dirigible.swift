import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

@main
struct Dirigible: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dirigible",
        abstract: "Make, change, and read Dirigible session packages.",
        version: appVersion,
        subcommands: [
            Create.self, Info.self, TrackCommand.self, FileCommand.self, CaptureCommand.self, ClipCommand.self,
            MarkerCommand.self, EpisodeCommand.self, TakeCommand.self, Devices.self, Apps.self, Record.self,
            Render.self, Export.self,
            ChaptersCommand.self,
            PeaksCommand.self, LoudnessCommand.self, LevelCommand.self, DuckCommand.self, ImportCommand.self,
            TranscriptCommand.self,
            BackupCommand.self,
            MCPCommand.self, SkillCommand.self, DiagnosticsCommand.self,
        ])

    @Flag(help: "Print the agent manual: the instructions that dirigible mcp gives an agent.")
    var instructions = false

    func run() async throws {
        guard instructions else { throw CleanExit.helpRequest(self) }
        print(AgentManual.instructions)
    }

    /// The `CFBundleShortVersionString` of the app that holds this tool at
    /// `<name>.app/Contents/Helpers/dirigible`, also through a symlink. Else 0.0.0, the version with
    /// no tag, as in `scripts/version.sh` and `Support/Info.plist`.
    static var appVersion: String { appInfo("CFBundleShortVersionString") ?? "0.0.0" }
    /// The `DirigibleCommit` of that app (`scripts/bundle.sh`), else `none`.
    static var appCommit: String { appInfo("DirigibleCommit") ?? "none" }

    private static func appInfo(_ key: String) -> String? {
        guard let contents = Bundle.main.executableURL.flatMap(appContents(of:)),
            let data = try? Data(contentsOf: contents.appending(path: "Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }
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
    @Flag(help: "With --json, write only sampleRate, tracks with their clips, and markers.") var compact = false

    func validate() throws {
        if compact && !json { throw ValidationError("--compact needs --json.") }
    }

    func run() throws {
        let session = try readPackage(package)
        let media: [FileID: MediaFault]
        do {
            media = try checkMedia(session, package: package.url)
        } catch {
            throw fail(mediaCheckMessage(error), code: packageError)
        }
        let takeMap = TakeMap.of(session, anchors: TakeAnchors.result(package.url))
        print(
            json
                ? try SessionView(session, media: media, takeMap: takeMap).json(compact: compact)
                : summary(of: session, name: package.url.lastPathComponent, media: media, takeMap: takeMap),
            terminator: "")
    }
}
