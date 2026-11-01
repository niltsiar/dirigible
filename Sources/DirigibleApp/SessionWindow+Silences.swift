import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// Tools > Find Silences... and the Silences tab (decision 0066). The studio scans off the main
/// actor and applies the plan as one undo entry; the window keeps the list and the note.
extension SessionWindow {
    /// The playhead of a row click: 2 s before the silence, so the user hears the end of the
    /// sentence before the gap.
    static let silencePreRoll = 2

    /// The item and the Scan button are off with a dialog or a busy studio, an import, or no clip.
    var canFindSilences: Bool { !dialogShowing && isOn(.autoLevel) }

    /// Scan is also off while the keep is not under the minimum, or when no track is checked.
    var canScanSilences: Bool {
        guard canFindSilences, let session = idleStudio?.session, !silences.settings.keepRefused else { return false }
        return silences.settings.scanned(in: session)?.isEmpty != true
    }

    /// Apply is off with no row to apply, a settings change or a clip change after the scan, or a
    /// keep that is not under the minimum.
    var canApplySilences: Bool {
        guard let studio = idleStudio, let review = silences.review, !silences.isStale(in: studio),
            !silences.settings.keepRefused
        else { return false }
        return review.plan != nil
    }

    /// The shade of the lanes: the rows of a current list, while the Silences tab shows.
    func silenceBands(in studio: Studio) -> [SilenceBand] {
        showsInspector && inspectorTab == .silences ? silences.bands(in: studio) : []
    }

    /// True when the first responder of `keyWindow` is the Silences list: a table of this window's
    /// inspector, which has no other table.
    func silenceListHasFocus(in keyWindow: NSWindow?) -> Bool {
        guard showsInspector, inspectorTab == .silences, keyWindow === window else { return false }
        var view = keyWindow?.firstResponder as? NSView
        while let current = view, !(current is NSTableView) { view = current.superview }
        return view != nil
    }

    /// Return and Delete with the list as first responder (criterion C33). Return applies while
    /// Apply is on, and Delete sets the selected rows to Skip; with Apply off, Return does nothing.
    func silenceListKey(_ command: TimelineCommand) {
        if command == .delete {
            setSilenceAction(.skip, rows: silences.selection)
        } else if canApplySilences {
            applySilences()
        }
    }

    /// Tools > Find Silences...: shows the inspector on the Silences tab, then scans. A refused
    /// Episode draft keeps its tab, and then nothing scans.
    func findSilences() async {
        guard canFindSilences else { return }
        commitDrafts()
        selectInspectorTab(.silences)
        guard inspectorTab == .silences else { return }
        if !showsInspector { toggleInspector() }
        await scanSilences()
    }

    /// Scans the checked tracks over the range of the selection, or the whole session, with the
    /// settings of the tab. The range that a row click set is no scope: then the scan keeps the
    /// scope of the list. The play stops. Cancel and a read error leave the list as it was.
    func scanSilences() async {
        guard canScanSilences, let studio = idleStudio else { return }
        let settings = silences.settings
        let session = studio.session
        let rate = session.sampleRate
        let selected = timeline.selection.marks?.selection(in: session)?.range
        let range = selected != nil && selected == silences.rowRange ? silences.review?.scan.range : selected
        silences.note = nil
        do throws(StudioError) {
            let scan = try await studio.scanSilences(
                tracks: settings.scanned(in: session), range: range, threshold: Gain(dB: settings.threshold)!,
                minLength: Frames(settings.minimum * rate / 1_000))
            silences.review = SilenceReview(scan: scan, settings: settings, session: studio.session)
            silences.selection = []
        } catch .silencesCancelled {
            // The banner Cancel: the user asked for it, so no alert.
        } catch {
            alert = .error(error)
        }
    }

    /// A change of the selection of the list. One row selects its silence as the range and puts
    /// the playhead before it (a row click, Up, or Down); more rows only select.
    func selectSilences(_ rows: Set<Int>) {
        silences.selection = rows
        guard rows.count == 1, let id = rows.first, let row = silences.review?.rows.first(where: { $0.id == id }),
            let studio
        else { return }
        let session = studio.session
        timeline.selection = .range(
            Marks(
                inPoint: row.silence.lowerBound, outPoint: row.silence.upperBound, tracks: Set(session.tracks.map(\.id))
            )
        )
        silences.rowRange = timeline.selection.marks?.selection(in: session)?.range
        let before = Frames(max(0, row.silence.lowerBound.count - Self.silencePreRoll * session.sampleRate))
        transport(.seek(.frame(before)))
    }

    /// The Action pop-up, the context actions, and Delete (Skip): sets the action of `rows` and no
    /// other row.
    func setSilenceAction(_ action: SilenceAction, rows: Set<Int>) {
        guard var review = silences.review else { return }
        for index in review.rows.indices where rows.contains(review.rows[index].id) {
            review.rows[index].action = action
        }
        silences.review = review
    }

    /// Apply: the rows that are not Skip as one edit and one undo entry, while stopped or playing.
    /// The Marks clear, the playhead moves by Rule M, and the list gives way to the note. A list
    /// that the tracks outran shows the stale alert, and a ripple that a pending take blocks beeps.
    func applySilences() {
        guard canApplySilences, let review = silences.review, let plan = review.plan, let studio = idleStudio else {
            return
        }
        commitDrafts()
        let (before, playhead) = (studio.session.end, studio.playhead)
        do throws(StudioError) {
            let result = try studio.applySilences(plan, scan: review.scan)
            let summary = review.summary
            timeline.selection = .none
            let moved = SilenceReview.moved(playhead, by: result.cuts)
            if moved != playhead { transport(.seek(.frame(moved))) }
            let note = SilenceNote(
                shortened: result.cuts.count, muted: summary.counts[.mute] ?? 0, marked: result.markers.count,
                removed: result.removed, before: before, after: before - result.removed, rate: review.rate)
            (silences.review, silences.selection, silences.note) = (nil, [], note)
            chrome?.announce(note.text(), .medium)
        } catch .rippleBlocked {
            beep()
        } catch {
            alert = .error(error)
        }
    }
}
