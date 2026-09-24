import ArgumentParser
import DirigibleCore

struct MarkerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "marker", abstract: "Set and remove markers and chapters.",
        subcommands: [SetMarker.self, Remove.self])

    struct SetMarker: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Add a marker, or replace the marker with its ID, and write its ID.")
        @OptionGroup var package: PackageArgument
        @Option var name: String
        @Option(parsing: .unconditional, help: "The timeline frame.") var at: Int
        @Option(help: "marker or chapter.", transform: parseKind) var kind: Marker.Kind = .marker
        @Option(help: "The marker ID. The default is a new UUID.") var id: String?

        func run() throws {
            let marker = Marker(id: id.map { MarkerID($0) } ?? MarkerID(), name: name, position: Frames(at), kind: kind)
            try editPackage(package) { session throws(SessionError) in try session.setMarker(marker) }
            print(marker.id)
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
