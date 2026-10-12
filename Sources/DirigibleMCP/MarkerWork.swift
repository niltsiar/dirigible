import DirigibleAudio
import DirigibleCore
import Foundation

/// Why a marker edit of `marker set` or `marker_set` changed nothing.
package enum MarkerEditError: Error {
    /// The URL text is not an http or https URL, or it is over `Marker.maximumURLBytes`: the message.
    case badURL(String)
    /// A new marker with no name or no position.
    case incomplete
    case artwork(ArtworkError)
    case session(SessionError)

    package var message: String {
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
package struct MarkerFields: Sendable {
    var id, name: String?
    var at: Int?
    var kind: Marker.Kind?
    var url, image: String?

    package init(id: String?, name: String?, at: Int?, kind: Marker.Kind?, url: String?, image: String?) {
        (self.id, self.name, self.at, self.kind, self.url, self.image) = (id, name, at, kind, url, image)
    }

    /// Checks the URL before the package lock, so a bad URL is a usage error.
    package func work() throws(MarkerEditError) -> MarkerWork {
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
package struct MarkerWork: Sendable {
    let id: MarkerID
    let name: String?
    let position: Frames?
    let kind: Marker.Kind?
    /// Nil: no change. `.some(nil)`: no URL.
    let url: WebURL??
    /// Nil: no change. Empty: no image.
    let image: String?

    /// The marker of this edit from the marker with its ID, with no image file read: an empty
    /// `image` removes the image, and a path keeps the old one. The live path of an agent runs it
    /// in `Studio.edit` (decision 0046).
    package func marker(from old: Marker?) throws(MarkerEditError) -> Marker {
        guard let name = name ?? old?.name, let position = position ?? old?.position else { throw .incomplete }
        var marker = Marker(
            id: id, name: name, position: position, kind: kind ?? old?.kind ?? .marker, url: old?.url,
            image: image == "" ? nil : old?.image)
        if let url { marker.url = url }
        return marker
    }

    package func run(_ session: inout Session, package: URL) throws(MarkerEditError) -> MarkerID {
        var marker = try marker(from: session.markers[id])
        if let image, !image.isEmpty {
            do throws(ArtworkError) {
                marker.image = try importArtwork(URL(filePath: image), into: package)
            } catch {
                throw .artwork(error)
            }
        }
        do throws(SessionError) { try session.setMarker(marker) } catch { throw .session(error) }
        return id
    }
}
