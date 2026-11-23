import AppKit
import DirigibleAudio
import DirigibleCore

/// Edit > Add to Favorites (F23, decision 0081): a copy of the selection into the one Favorites store
/// of the app, as a blocking run with the banner of an import. The Favorites section of the Bins list
/// pastes, renames, and removes favorites.
extension SessionWindow {
    /// On with a range or a clip set to copy, as Add to Bin, and a store (none in a test app, C35).
    var canAddToFavorites: Bool { canAddToBin && app?.favorites.canAdd == true }

    /// Adds a copy of the selection to the first Favorites group, named after its first track (C25).
    /// A Cancel or a take start shows no alert; another fault shows its alert. On each result the
    /// window reads the store again, because a stop can come after the store write (C14). After an
    /// add, the pane shows the new favorite selected, with its name field open.
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
            var added: BinItemID?
            do throws(StudioError) {
                added = try await studio.addToFavorites(excerpt, named: name, writer: writer) { [weak self] in
                    self?.importProgressed($0)
                }
            } catch .favoritesCopy(.cancelled), .favoritesYielded {
            } catch {
                self?.alert = .refusing(error, in: studio.session)
            }
            shown.cancel()
            await favorites.reload()
            guard let self else { return }
            importJob = nil
            guard let added else { return }
            showPane(at: .bins)
            selectBinItem(.favorite(added))
            beginBinRename(.favorite(added))
        }
    }

    /// Paste at Playhead, or Insert at Playhead with `insert`, of a favorite of the store as last read:
    /// a paste from another package, which copies its files into this session (decision 0042).
    func pasteFavorite(_ id: BinItemID, insert: Bool) {
        guard let studio = idleStudio, let favorites = app?.favorites, let store = favorites.writer?.store,
            case .loaded(let session) = favorites.state
        else { return }
        if insert, !studio.canRipple { return beep() }
        guard let excerpt = try? session.excerpt(of: id) else { return beep() }
        let at = studio.playhead
        paste(
            mode: insert ? .insert(at: at) : .over(at: at),
            from: Clipboard(excerpt, package: store, origin: favorites.identity))
    }

    /// Delete on a favorite: a question first, because no session Undo covers the store (C26).
    func removeFavorite(_ id: BinItemID) {
        guard let item = app?.favorites.bins.lazy.flatMap(\.items).first(where: { $0.id == id }) else { return beep() }
        alert = .confirmRemoveFavorite(.item(id), name: item.name)
    }

    /// Delete on a store group: the same question as for a favorite.
    func removeFavoriteGroup(_ id: BinID) {
        guard let bin = app?.favorites.bins.first(where: { $0.id == id }) else { return beep() }
        alert = .confirmRemoveFavorite(.group(id), name: bin.name)
    }

    /// Remove of the question: the store edit through the one writer.
    func confirmRemoveFavorite(_ part: FavoritePart) {
        editFavorites { session throws(SessionError) in
            switch part {
            case .item(let id): try session.removeItem(id)
            case .group(let id): try session.removeBin(id)
            }
        }
    }

    /// Runs `body` on the store through the one writer; the model reads the store again after it. A
    /// fault shows its alert.
    func editFavorites(_ body: @escaping @Sendable (inout Session) throws(SessionError) -> Void) {
        guard let favorites = app?.favorites else { return }
        Task { [weak self] in
            do throws(StudioError) {
                _ = try await favorites.edit(body)
            } catch {
                self?.alert = .error(error)
            }
        }
    }
}
