import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct MarkerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marker", abstract: "Set and remove markers and chapters.",
        subcommands: [SetMarker.self, Remove.self])

    struct SetMarker: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Add a marker, or change the marker with its ID, and write its ID.",
            discussion: """
                With --id of an existing marker, each option that is not given keeps its value, the kind \
                too, and an empty --url or --image removes its value. A new marker needs --name and --at; \
                its kind is marker by default, and it has no URL and no image.
                """)
        @OptionGroup var package: PackageArgument
        @Option var name: String?
        @Option(parsing: .unconditional, help: "The timeline frame.") var at: Int?
        @Option(help: "marker or chapter.", transform: parseKind) var kind: Marker.Kind?
        @Option(help: "The marker ID. The default is a new UUID.") var id: String?
        @Option(help: "The chapter link: an http or https URL of at most \(Marker.maximumURLBytes) bytes.")
        var url: String?
        @Option(
            help: ArgumentHelp(
                "The chapter image: a square JPEG or PNG file, at most \(maximumArtworkSide) x "
                    + "\(maximumArtworkSide) pixels.",
                discussion: "The command copies it into Artwork/."))
        var image: String?

        func run() throws {
            let work: MarkerWork
            do throws(MarkerEditError) {
                work = try MarkerFields(id: id, name: name, at: at, kind: kind, url: url, image: image).work()
            } catch {
                throw ValidationError(error.message)
            }
            let id = try editPackage(package, refused: refusedMarker) { session, _ throws(MarkerEditError) in
                try work.run(&session, package: package.url)
            }
            print(id)
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a marker.")
        @OptionGroup var package: PackageArgument
        @Argument var marker: String

        func run() throws {
            try editPackage(package) { session throws(SessionError) in try session.removeMarker(MarkerID(marker)) }
        }
    }
}

private func parseKind(_ text: String) throws -> Marker.Kind {
    guard let kind = Marker.Kind(rawValue: text) else { throw ValidationError("A kind is marker or chapter.") }
    return kind
}

/// The exit of a refused marker edit: 64 for a new marker with no name or position, as a usage
/// error; 2 for a failed image copy; else 1.
private func refusedMarker(_ error: MarkerEditError) -> ExitCode {
    switch error {
    case .incomplete, .badURL: fail(error.message, code: ExitCode.validationFailure.rawValue)
    case .artwork(.writeFailed): fail(error.message, code: packageError)
    case .artwork, .session: fail(error.message, code: editRefused)
    }
}
