import AppKit
import DirigibleCore

/// The play mark of the index list: a 1 pt line between two rows at the head, and a tint on the
/// current row, the last shown row that starts at or before the head. Both are sublayers of the
/// table layer, so a tick moves them with no row view, no cell view, and no reload. The layers
/// are no accessibility element.
@MainActor final class IndexPlayMark {
    /// Why the list does not follow the head. Each reason clears at the next play start or take start.
    struct Hold: OptionSet {
        let rawValue: Int
        static let listScroll = Hold(rawValue: 1)
        static let search = Hold(rawValue: 2)
    }

    let line = CALayer()
    let tint = CALayer()
    /// The start of each shown row, in row order.
    private var starts: [Frames] = []
    private var head = Frames.zero
    /// The index of the current row: nil while the head is before the first shown row.
    private(set) var row: Int?
    private(set) var hold: Hold = []
    /// Play or a take runs: a user scroll or a search key holds the follow only then.
    private var active = false
    private var taking = false
    private var width = 0.0
    private var liveScrollStart: Double?

    init() {
        let still: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        for layer in [line, tint] {
            layer.actions = still
            layer.anchorPoint = .zero
            // AppKit adds its own layers to the table: stay over them.
            layer.zPosition = 100
            layer.isHidden = true
        }
    }

    func attach(to table: NSTableView) {
        table.wantsLayer = true
        table.layer?.addSublayer(tint)
        table.layer?.addSublayer(line)
        restyle(table.effectiveAppearance)
    }

    func restyle(_ appearance: NSAppearance) {
        line.backgroundColor = PlayheadColors(appearance: appearance, taking: taking).core
        appearance.performAsCurrentDrawingAppearance {
            tint.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        }
    }

    /// The shown rows changed: the mark takes its row from the new starts, and the list does not scroll.
    func show(starts: [Frames], in table: NSTableView) {
        self.starts = starts
        place(in: table, force: true)
    }

    /// One display tick, with the head of the lanes. `running` is play or a take. A change of the
    /// current row moves the layers and, with Follow on and no hold, scrolls the list to the row.
    func tick(head: Frames, running: Bool, taking: Bool, started: Bool, follows: Bool, in table: NSTableView) {
        if started { hold = [] }
        active = running
        if taking != self.taking {
            self.taking = taking
            restyle(table.effectiveAppearance)
        }
        self.head = head
        guard place(in: table), let row, follows, hold.isEmpty, liveScrollStart == nil else { return }
        table.scrollRowToVisible(row)
    }

    func holdFollow(_ reason: Hold) {
        if active { hold.insert(reason) }
    }

    func liveScrollStarted(at origin: Double) { liveScrollStart = origin }

    /// A live scroll that moved the list holds the follow; one with no move holds nothing.
    func liveScrollEnded(at origin: Double) {
        if let start = liveScrollStart, origin != start { holdFollow(.listScroll) }
        liveScrollStart = nil
    }

    /// Moves the layers when the current row or the width changed, or with `force`.
    /// True when the current row changed.
    @discardableResult
    func place(in table: NSTableView, force: Bool = false) -> Bool {
        // The last start at or before the head: a binary search over the row starts.
        var (low, high) = (0, starts.count)
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= head { low = middle + 1 } else { high = middle }
        }
        let current = low > 0 ? low - 1 : nil
        let moved = current != row
        guard force || moved || table.bounds.width != width else { return false }
        row = current
        width = table.bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !starts.isEmpty else {
            (line.isHidden, tint.isHidden) = (true, true)
            return moved
        }
        let box = current.map { table.rect(ofRow: $0) }
        line.frame = CGRect(x: 0, y: box.map { $0.maxY - 0.5 } ?? 0, width: width, height: 1)
        tint.frame = box.map { CGRect(x: 0, y: $0.minY, width: width, height: $0.height) } ?? .zero
        (line.isHidden, tint.isHidden) = (false, box == nil)
        return moved
    }
}
