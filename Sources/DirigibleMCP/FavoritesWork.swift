import DirigibleAudio
import DirigibleCore
import Foundation

/// The add of `dirigible favorites add` and of `favorites_add` (F23, decision 0081): a range of
/// tracks or whole clips of a package, copied into the Favorites store as a new item.
package struct FavoritesWork: Sendable {
    let selection: BinWork.Selection
    let name: String
    /// The store bin, or nil for the first bin.
    let bin: String?

    package init(_ selection: BinWork.Selection, named name: String, bin: String?) {
        (self.selection, self.name, self.bin) = (selection, name, bin)
    }

    /// Reads `source` with no lock, as `info`, and adds the excerpt to `store` under the store lock
    /// (`Favorites.add`). Gives the new item ID.
    package func run(source: URL, store: URL, log: () -> DiagnosticLog) throws(EditFailure<PasteError>) -> BinItemID {
        let read: Session
        do throws(SessionFileError) {
            read = try Session(contentsOf: source)
        } catch {
            throw .body(.sourceMissing(file: source.lastPathComponent))
        }
        let excerpt: Excerpt
        do throws(SessionError) {
            excerpt =
                switch selection {
                case .range(let range, let tracks): try read.excerpt(of: range, on: tracks)
                case .clips(let ids): try read.excerpt(of: ids)
                }
        } catch {
            throw .body(.session(error))
        }
        return try Favorites.add(
            Clipboard(excerpt, package: source, origin: PackageID(lockFileOf: source)), from: source, named: name,
            bin: bin.map { BinID($0) }, store: store, log: log)
    }
}
