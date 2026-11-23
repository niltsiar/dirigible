import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The edits of the Bins segment (F22). Each one is one session edit through `edit`, so one undo entry,
/// and none runs during a take or a run.
extension SessionWindow {
    /// Edit > Add to Bin is on with a range or a clip set to copy (C15), as `Selection.excerpt(in:)`
    /// gives one. The menu reads it at each update, so it builds no excerpt.
    var canAddToBin: Bool {
        guard canEdit, let session = studio?.session else { return false }
        return switch timeline.selection {
        case .range(let marks): marks.rippleScope(selectedOnly: false, in: session)?.selected.isEmpty == false
        case .clips: !timeline.selection.selectedClips(in: session).isEmpty
        }
    }

    /// The bins of the Add to Bin submenu, in user order. New Bin follows them (C22).
    var addToBinItems: [(title: String, bin: BinID)] {
        studio?.session.bins.map { ($0.name, $0.id) } ?? []
    }

    /// Adds a copy of the selection to `bin`, or to a new bin for nil. The pane shows at Bins with the new
    /// item selected and its name field open, prefilled with the first track and the start (C25).
    func addToBin(_ bin: BinID?) {
        guard let studio = idleStudio, let excerpt = try? timeline.selection.excerpt(in: studio.session) else { return }
        let start = timeline.selection.span(in: studio.session)?.lowerBound ?? .zero
        let rate = studio.session.sampleRate
        let time = rulerLabel(Double(start.count) / Double(rate), tenths: false)
        let name = excerpt.lanes.first.map { "\($0.name) \(time)" } ?? time
        let added = edit(ripple: false) { session throws(SessionError) -> BinItemID in
            let target: BinID
            if let bin { target = bin } else { target = try session.addBin(named: Self.newBinName(session)) }
            return try session.addItem(excerpt, named: name, to: target)
        }
        guard let added else { return }
        showPane(at: .bins)
        selectBinItem(.session(added))
        beginBinRename(.item(added))
    }

    /// The New Bin button of the empty segment and of the footer: an empty bin with the next number.
    func newBin() {
        edit(ripple: false) { session throws(SessionError) in try session.addBin(named: Self.newBinName(session)) }
    }

    /// The name of the first number from 1 that no bin has. Of the numbers to count + 1, one is free when
    /// `name` gives each number its own name; else the name of count + 1.
    static func newBinName(_ session: Session, name: (Int) -> String = { L10n.binsNewName.format($0) }) -> String {
        let taken = Set(session.bins.map(\.name))
        let last = session.bins.count + 1
        return (1...last).lazy.map(name).first { !taken.contains($0) } ?? name(last)
    }

    func selectBinItem(_ pick: BinsPick) {
        leadingPane.selectedBinItem = pick
        leadingPane.binsTable?.source?.showSelection()
    }

    /// Paste at Playhead, or Insert at Playhead with `insert`: a paste of a Copy of the item, with the
    /// targets of Paste (C8). An item with a media fault pastes nothing and shows its alert (C32).
    func pasteBinItem(_ id: BinItemID, insert: Bool) {
        guard let studio = idleStudio else { return }
        if insert, !studio.canRipple { return beep() }
        let clipboard: Clipboard
        do throws(StudioError) {
            clipboard = try studio.clipboard(of: id)
        } catch {
            return beep()
        }
        let files = clipboard.excerpt.lanes.flatMap { $0.clips.map(\.file) }
        if let file = files.first(where: { studio.missingMedia[$0] != nil }), let fault = studio.missingMedia[file] {
            alert = .binFileFault(studio.session.files[file]?.path ?? file.rawValue, fault)
            return
        }
        paste(mode: insert ? .insert(at: studio.playhead) : .over(at: studio.playhead), from: clipboard)
    }

    /// Opens the name field of a bin, an item, a store group, or a favorite. An open field commits
    /// first. A take or a run, or a target that the session or the store as last read does not have,
    /// does nothing.
    func beginBinRename(_ target: BinRename) {
        guard canEdit, let bins = studio?.session.bins else { return }
        let favorites = app?.favorites.bins ?? []
        let known =
            switch target {
            case .bin(let id): bins.contains { $0.id == id }
            case .item(let id): bins.contains { $0.items.contains { $0.id == id } }
            case .favoriteBin(let id): favorites.contains { $0.id == id }
            case .favorite(let id): favorites.contains { $0.items.contains { $0.id == id } }
            }
        guard known else { return }
        finishBinRename(save: true)
        leadingPane.binRename = target
        leadingPane.binsTable?.source?.openField()
    }

    /// Ends the name field. With `save`, a typed name goes in one edit of the session or of the store;
    /// a name that is empty after the trim, or that does not change, keeps the name (C25). The state is
    /// cleared first, so the focus loss of the field adds no edit.
    func finishBinRename(save: Bool) {
        guard let target = leadingPane.binRename else { return }
        leadingPane.binRename = nil
        let text = leadingPane.binsTable?.source?.closeField()
        guard save, let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let favorites = app?.favorites.bins ?? []
        switch target {
        case .bin(let id):
            edit(ripple: false) { session throws(SessionError) in
                guard session.bins.first(where: { $0.id == id })?.name != text else { return }
                try session.renameBin(id, to: text)
            }
        case .item(let id):
            edit(ripple: false) { session throws(SessionError) in
                guard session.bins.lazy.flatMap(\.items).first(where: { $0.id == id })?.name != text else { return }
                try session.renameItem(id, to: text)
            }
        case .favoriteBin(let id):
            guard favorites.first(where: { $0.id == id })?.name != text else { return }
            editFavorites { session throws(SessionError) in try session.renameBin(id, to: text) }
        case .favorite(let id):
            guard favorites.lazy.flatMap(\.items).first(where: { $0.id == id })?.name != text else { return }
            editFavorites { session throws(SessionError) in try session.renameItem(id, to: text) }
        }
    }

    /// Delete on an item: one undo entry, and Undo brings it back with its ID and name (C26).
    func removeBinItem(_ id: BinItemID) {
        edit(ripple: false) { session throws(SessionError) in try session.removeItem(id) }
        if leadingPane.selectedBinItem == .session(id) { leadingPane.selectedBinItem = nil }
    }

    /// Delete on a bin: the bin and its items, one undo entry.
    func removeBin(_ id: BinID) {
        edit(ripple: false) { session throws(SessionError) in try session.removeBin(id) }
    }
}
