import AppKit
import DirigibleAudio
import DirigibleCore

/// Edit > Add to Favorites (F23, decision 0081): a copy of the selection into the one Favorites store
/// of the app, as a blocking run with the banner of an import.
extension SessionWindow {
    /// On with a range or a clip set to copy, as Add to Bin, and a store (none in a test app, C35).
    var canAddToFavorites: Bool { canAddToBin && app?.favorites.canAdd == true }

    /// Adds a copy of the selection to the first Favorites group, named after its first track (C25).
    /// A Cancel or a take start shows no alert; another fault shows its alert. On each result the
    /// window reads the store again, because a stop can come after the store write (C14).
    func addToFavorites() {
        guard let studio = idleStudio, let favorites = app?.favorites, let writer = favorites.writer,
            let excerpt = try? timeline.selection.excerpt(in: studio.session)
        else { return }
        let name = excerpt.lanes.first?.name ?? ""
        // A blocking run: a typed name that waits for it is lost (run 13c, plan gate 2 item 1).
        commitDrafts()
        importJob = ImportJob(visible: false)
        let wait = bannerWait
        let shown = Task { [weak self] in
            await wait()
            guard let self, !Task.isCancelled, importJob != nil else { return }
            importJob?.visible = true
            chrome?.announce(L10n.favoritesBanner.text, .high)
        }
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                _ = try await studio.addToFavorites(excerpt, named: name, writer: writer) { [weak self] in
                    self?.importProgressed($0)
                }
            } catch .favoritesCopy(.cancelled), .favoritesYielded {
            } catch {
                self?.alert = .refusing(error, in: studio.session)
            }
            shown.cancel()
            await favorites.reload()
            self?.importJob = nil
        }
    }
}
