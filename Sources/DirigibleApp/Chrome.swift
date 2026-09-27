import AppKit
import DirigibleAudio

/// An item of the session toolbar (decision 0023). AppKit saves the customization under the raw
/// values, so a rename loses the user layout: never rename or reuse one.
enum ToolbarItemID: String, CaseIterable {
    case addTrack = "track.add"
    case monitor = "record.monitor"
    case stop = "transport.stop"
    case play = "transport.play"
    case record = "transport.record"
    case time = "transport.time"
    case start = "transport.start"
    case end = "transport.end"
    case split = "edit.split"
    case cut = "edit.cut"
    case copy = "edit.copy"
    case paste = "edit.paste"
    case delete = "edit.delete"
    case zoomOut = "view.zoom.out"
    case zoomIn = "view.zoom.in"
    case zoomToSession = "view.zoom.session"
    case export = "file.export"

    static let toolbar = NSToolbar.Identifier("dirigible.session")

    /// The groups, leading to trailing, with a space between them (the macOS 26 glass groups). Cut,
    /// Copy, Paste, Go to Start, and Go to End are in the customization palette only.
    static let defaults: [NSToolbarItem.Identifier] =
        [addTrack.identifier, .space]
        + [monitor, stop, play, record, time].map(\.identifier) + [.space]
        + [split, delete].map(\.identifier) + [.flexibleSpace]
        + [zoomOut, zoomIn, zoomToSession, export].map(\.identifier)

    var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

    /// The SF Symbol: unique per item, each macOS 13 or older. The time display has none.
    var symbol: String? {
        switch self {
        case .addTrack: "waveform.path.badge.plus"
        case .monitor: "mic.and.signal.meter"
        case .stop: "stop.fill"
        case .play: "play.fill"
        case .record: "circle.fill"
        case .time: nil
        case .start: "backward.end.fill"
        case .end: "forward.end.fill"
        case .split: "square.and.line.vertical.and.square"
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .paste: "doc.on.clipboard"
        case .delete: "trash"
        case .zoomOut: "minus.magnifyingglass"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomToSession: "arrow.up.left.and.down.right.magnifyingglass"
        case .export: "square.and.arrow.up"
        }
    }

    /// The transport and the time stay longest; Monitor Inputs and Export stay before the edit and
    /// zoom items (probe P1e: the standard items overflow from the trailing end).
    var priority: NSToolbarItem.VisibilityPriority {
        switch self {
        case .stop, .play, .record, .time: .high
        case .monitor, .export:
            NSToolbarItem.VisibilityPriority(rawValue: NSToolbarItem.VisibilityPriority.standard.rawValue + 500)
        case .addTrack, .start, .end: .standard
        case .split, .cut, .copy, .paste, .delete, .zoomOut, .zoomIn, .zoomToSession: .low
        }
    }

    /// A push-on-push-off button: its on state is a shape, not only a color.
    var isToggle: Bool { self == .record || self == .monitor || self == .play }

    /// The command of the item. Nil only for the time display: a new item with no command does
    /// not compile (F16).
    var command: WindowCommand? {
        switch self {
        case .addTrack: .addTrack
        case .monitor: .toggleMonitor
        case .stop: .stop
        case .play: .transport(.playStop)
        case .record: .record
        case .time: nil
        case .start: .transport(.seek(.start))
        case .end: .transport(.seek(.end))
        case .split: .timeline(.split)
        case .cut: .timeline(.cut)
        case .copy: .timeline(.copy)
        case .paste: .timeline(.paste)
        case .delete: .timeline(.delete)
        case .zoomOut: .timeline(.zoomOut)
        case .zoomIn: .timeline(.zoomIn)
        case .zoomToSession: .timeline(.zoomToSession)
        case .export: .timeline(.export)
        }
    }

    /// The short label under the icon. A meaning that a menu item has reuses its key (0010).
    var label: L10n {
        switch self {
        case .addTrack: .menuTrackAdd
        case .monitor: .toolbarMonitor
        case .stop: .transportStop
        case .play: .transportPlay
        case .record: .transportRecord
        case .time: .toolbarTime
        case .start: .menuTransportStart
        case .end: .menuTransportEnd
        case .split: .menuEditSplit
        case .cut: .menuEditCut
        case .copy: .menuEditCopy
        case .paste: .menuEditPaste
        case .delete: .menuEditDelete
        case .zoomOut: .menuViewZoomOut
        case .zoomIn: .menuViewZoomIn
        case .zoomToSession: .toolbarZoomFit
        case .export: .toolbarExport
        }
    }
}

/// A command that a menu item and a toolbar item share (decision 0023). The toolbar calls
/// `SessionWindow.run(_:)`, which forwards each case to the place that its menu item reaches.
enum WindowCommand: Hashable {
    case timeline(TimelineCommand)
    case transport(TransportCommand)
    case addTrack, record, stop, toggleMonitor

    /// The menu text: the palette label of the toolbar item.
    var title: L10n {
        switch self {
        // Each timeline command of the toolbar is in a menu table (F16).
        case .timeline(let command): TimelineCommand.titles[command]!
        case .transport(.seek(.start)): .menuTransportStart
        case .transport(.seek(.end)): .menuTransportEnd
        case .transport: .menuTransportPlay
        case .addTrack: .menuTrackAdd
        case .record: .menuRecordStart
        case .stop: .menuRecordStop
        case .toggleMonitor: .menuRecordMonitor
        }
    }

    /// Cut, Copy, Paste, and Delete send the selector of their menu item along the responder
    /// chain, so a focused text field takes them first (probe E3).
    var selector: Selector? {
        if case .timeline(let command) = self { command.selector } else { nil }
    }
}

extension TimelineCommand {
    /// The menu text of each timeline command, from the menu tables.
    static let titles = Dictionary(
        (viewItems + pasteboardItems + editItems + markerItems + trackItems + fileItems).map { ($0.command, $0.title) },
        uniquingKeysWith: { first, _ in first })
}
