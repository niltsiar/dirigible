import ArgumentParser
import DirigibleAudio
import DirigibleCore
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

/// Why a marker edit of `marker set` or `marker_set` changed nothing.
enum MarkerEditError: Error {
    /// The URL text is not an http or https URL, or it is over `Marker.maximumURLBytes`: the message.
    case badURL(String)
    /// A new marker with no name or no position.
    case incomplete
    case artwork(ArtworkError)
    case session(SessionError)

    var message: String {
        switch self {
        case .badURL(let message): message
        case .incomplete: "a new marker needs a name and a position."
        case .artwork(let error): error.message
        case .session(let error): error.message
        }
    }
}

/// The given marker fields as text, from the CLI or an MCP tool (G8, G14 of run
/// 2026-10-11-chapters-in-file). Nil keeps the value of an existing marker; an empty `url` or
/// `image` clears it. `image` is the path of an image file.
struct MarkerFields: Sendable {
    var id, name: String?
    var at: Int?
    var kind: Marker.Kind?
    var url, image: String?

    /// Checks the URL before the package lock, so a bad URL is a usage error.
    func work() throws(MarkerEditError) -> MarkerWork {
        var link: WebURL??
        if let url {
            do throws(EpisodeFieldError) { link = .some(try Marker.url(fromText: url)) } catch {
                throw .badURL(error.message)
            }
        }
        return MarkerWork(
            id: id.map { MarkerID($0) } ?? MarkerID(), name: name, position: at.map { Frames($0) }, kind: kind,
            url: link, image: image)
    }
}

/// A marker edit of the CLI or an MCP tool: the checked fields, and an image file that the edit
/// copies into the package under the lock.
struct MarkerWork: Sendable {
    let id: MarkerID
    let name: String?
    let position: Frames?
    let kind: Marker.Kind?
    /// Nil: no change. `.some(nil)`: no URL.
    let url: WebURL??
    /// Nil: no change. Empty: no image.
    let image: String?

    func run(_ session: inout Session, package: URL) throws(MarkerEditError) -> MarkerID {
        let old = session.markers[id]
        guard let name = name ?? old?.name, let position = position ?? old?.position else { throw .incomplete }
        var marker = Marker(
            id: id, name: name, position: position, kind: kind ?? old?.kind ?? .marker, url: old?.url,
            image: old?.image)
        if let url { marker.url = url }
        if let image {
            do throws(ArtworkError) {
                marker.image = image.isEmpty ? nil : try importArtwork(URL(filePath: image), into: package)
            } catch {
                throw .artwork(error)
            }
        }
        do throws(SessionError) { try session.setMarker(marker) } catch { throw .session(error) }
        return id
    }
}
