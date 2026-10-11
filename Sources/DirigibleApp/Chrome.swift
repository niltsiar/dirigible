import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

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
    case inspector = "view.inspector"
    case snap = "view.snap"

    static let toolbar = NSToolbar.Identifier("dirigible.session")

    /// The groups, leading to trailing, with a space between them (the macOS 26 glass groups). Cut,
    /// Copy, Paste, and Go to End are in the customization palette only.
    static let defaults: [NSToolbarItem.Identifier] =
        [addTrack.identifier, .space]
        + [monitor, start, stop, play, record, time].map(\.identifier) + [.space]
        + [split, delete].map(\.identifier) + [.flexibleSpace]
        + [zoomOut, zoomIn, zoomToSession, snap, export, inspector].map(\.identifier)

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
        case .inspector: "sidebar.trailing"
        case .snap: "arrow.right.and.line.vertical.and.arrow.left"
        }
    }

    /// The transport, the time, and the inspector stay longest (an inspector button stays at
    /// every window size, ui-panel 9); Input Levels and Export stay before the edit and
    /// zoom items (probe P1e: the standard items overflow from the trailing end).
    var priority: NSToolbarItem.VisibilityPriority {
        switch self {
        case .stop, .play, .record, .time, .inspector: .high
        case .monitor, .export:
            NSToolbarItem.VisibilityPriority(rawValue: NSToolbarItem.VisibilityPriority.standard.rawValue + 500)
        case .addTrack, .start, .end: .standard
        case .split, .cut, .copy, .paste, .delete, .zoomOut, .zoomIn, .zoomToSession, .snap: .low
        }
    }

    /// A push-on-push-off button: its on state is a shape, not only a color.
    var isToggle: Bool { [.record, .monitor, .play, .inspector, .snap].contains(self) }

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
        case .inspector: .toggleInspector
        case .snap: .toggleSnap
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
        case .inspector: .toolbarInspector
        case .snap: .menuViewSnap
        }
    }
}

/// A command that a menu item and a toolbar item share (decision 0023). The toolbar calls
/// `SessionWindow.run(_:)`, which forwards each case to the place that its menu item reaches.
enum WindowCommand: Hashable {
    case timeline(TimelineCommand)
    case transport(TransportCommand)
    case addTrack, record, stop, toggleMonitor, toggleInspector, toggleSnap

    /// The title and the key of the menu item of the command: a lookup in the menu tables, the
    /// one source of the menus and of the palette label, the tooltip, and the key of the item.
    var menuItem: (title: L10n, key: KeyboardShortcut) {
        switch self {
        case .timeline(let command):
            // Each timeline command of the toolbar is in a menu table (F16).
            let item = TimelineCommand.menuItems[command]!
            return (item.title, KeyboardShortcut(item.key, modifiers: item.modifiers))
        case .transport(let command):
            let item = TransportMenu.groups.joined().first { $0.command == command }!
            return (item.title, item.key)
        case .addTrack: return (.menuTrackAdd, MenuKeys.addTrack)
        case .record: return (.menuRecordStart, MenuKeys.record)
        case .stop: return (.menuTransportStop, MenuKeys.stop)
        case .toggleMonitor: return (.menuRecordMonitor, MenuKeys.monitor)
        case .toggleInspector: return (.menuViewInspectorShow, MenuKeys.inspector)
        case .toggleSnap: return (.menuViewSnap, MenuKeys.snap)
        }
    }

    /// Cut, Copy, Paste, and Delete send the selector of their menu item along the responder
    /// chain, so a focused text field takes them first (probe E3).
    var selector: Selector? {
        if case .timeline(let command) = self { command.selector } else { nil }
    }
}

extension TimelineCommand {
    /// The menu item of each timeline command, from the menu tables.
    static let menuItems = Dictionary(
        (viewItems + pasteboardItems + rippleItems + editItems + markerItems + trackItems + fileItems + toolItems).map {
            ($0.command, $0)
        },
        uniquingKeysWith: { first, _ in first })
}

/// The tooltip of a toolbar item: the menu text and the key, "Record (⌘R)". The zoom items also
/// name the gestures that zoom at the pointer (run 2026-10-11-ui-polish-header C21). `format` is
/// the value of `tooltipKey(command)` in the app language.
func toolbarTooltip(_ command: WindowCommand, format: String? = nil) -> String {
    let title = command.menuItem.title.text
    return String(format: format ?? tooltipKey(command).text, locale: .current, title, keyText(command.menuItem.key))
}

/// The key of the tooltip format of `command`.
func tooltipKey(_ command: WindowCommand) -> L10n {
    [.timeline(.zoomIn), .timeline(.zoomOut)].contains(command) ? .toolbarTooltipZoom : .toolbarTooltip
}

/// A key as a menu shows it: the modifier glyphs, then the key ("⌥⌘N", "⌘.", "⌫").
func keyText(_ shortcut: KeyboardShortcut) -> String {
    let glyphs: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    let modifiers = glyphs.filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined()
    let key: String =
        switch shortcut.key {
        case .space: L10n.keySpace.text
        case .delete: "⌫"
        case .home: "↖"
        case .end: "↘"
        default: String(shortcut.key.character).uppercased()
        }
    return modifiers + key
}

/// The values that the chrome loop writes only on a change and SwiftUI reads, so no SwiftUI body
/// reads `Studio.play` (decision 0023).
struct ShownChrome: Equatable {
    /// The record-over warning (decisions 0016, 0017). `ChromeState` is its only owner.
    var recordOver = false
    /// The banner rows under the take banner, in order.
    var banners: [WindowBanner] = []
    /// A take or a play runs: the Stop item and the Stop menu item are on. When nothing runs,
    /// Command-period reaches a sheet (decision 0023).
    var isRunning = false
}

/// Everything that the AppKit chrome of a window shows, derived from the window state in one
/// observation loop (decision 0023).
struct ChromeState: Equatable {
    var enabled: Set<ToolbarItemID> = []
    /// The push-on items that are on: Record during a take, Play during a play, Input Levels.
    var on: Set<ToolbarItemID> = []
    var playing = false
    var time = timeDisplayText(0, rate: 48_000, playing: false)
    var subtitle = ""
    var shown = ShownChrome()

    @MainActor init(model: SessionWindow) {
        guard let studio = model.studio else { return }
        let recording = model.canStop
        playing = studio.playback != .stopped
        // During a take, the time shows the record head with tenths.
        let head = studio.liveHead()
        time = timeDisplayText(
            head ?? studio.playhead, rate: studio.session.sampleRate, playing: playing || head != nil)
        // Record stays on during a take: a click then does nothing (ux-decisions 4).
        if recording || model.canRecord { enabled.insert(.record) }
        if recording || playing { enabled.insert(.stop) }
        if model.canMonitor { enabled.insert(.monitor) }
        // A zoom changes no session data, so it runs during a take, as the View menu and the gestures.
        enabled.formUnion([.zoomOut, .zoomIn, .zoomToSession, .snap, .inspector])
        if model.canEdit {
            enabled.formUnion([.addTrack, .play, .start, .end, .split, .cut, .copy, .paste, .delete])
            if model.isOn(.export) { enabled.insert(.export) }
        }
        if recording { on.insert(.record) }
        if playing { on.insert(.play) }
        if model.monitoring { on.insert(.monitor) }
        if model.showsInspector { on.insert(.inspector) }
        if model.snaps { on.insert(.snap) }
        // During a take the disk watch gives the time left; before it, the idle read of the
        // armed tracks with a route.
        let left = recording ? studio.recordTimeLeft : model.armedWithRoute.isEmpty ? nil : model.idleRecordTimeLeft
        subtitle = subtitleText(
            rate: studio.session.sampleRate, tracks: studio.session.tracks.count, recordTimeLeft: left)
        var banners: [WindowBanner] = []
        if let stop = studio.playbackStop { banners.append(.playbackStopped(stop)) }
        if !studio.missingMedia.isEmpty {
            banners.append(
                .missingMedia(studio.missingMedia.keys.sorted().map { studio.session.files[$0]?.path ?? $0.rawValue }))
        }
        let shownBefore = model.shown.banners.contains { $0.key == "lowRecordTime" }
        if let left, showsLowRecordTime(left: left, recording: recording, shownBefore: shownBefore) {
            banners.append(.lowRecordTime(minutes: lowRecordTimeMinutes(left)))
        }
        if model.deviceList.defaults.speakers,
            studio.session.tracks.contains(where: { track in
                guard model.armed.contains(track.id), case .app = track.route else { return false }
                return true
            })
        {
            banners.append(.useHeadphones)
        }
        if model.deviceList.defaults.speakers, !model.listenedDeviceTracks(studio).isEmpty {
            banners.append(.monitorHeadphones)
        }
        if let shown = model.exportReport, shown.revision == studio.sessionRevision {
            banners.append(.exportReport(shown.report, file: shown.file))
        }
        if let shown = model.droppedChapters, shown.revision == studio.sessionRevision {
            banners.append(.chaptersDropped(shown.names, file: shown.file))
        }
        shown = ShownChrome(recordOver: model.showsRecordOver, banners: banners, isRunning: recording || playing)
    }
}

/// The head of the toolbar: h:mm:ss.t during play or a take, h:mm:ss.mmm when stopped. The digits
/// are cut, not rounded.
func timeDisplayText(_ frames: Frames, rate: Int, playing: Bool) -> String {
    let milliseconds = frames.count * 1000 / max(1, rate)
    let (hours, minutes) = (milliseconds / 3_600_000, milliseconds / 60_000 % 60)
    let (seconds, rest) = (milliseconds / 1000 % 60, milliseconds % 1000)
    return playing
        ? String(format: "%d:%02d:%02d.%d", hours, minutes, seconds, rest / 100)
        : String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, rest)
}

/// Low record time (decision 0023): before a take under 60 min, during a take under 10 min. A
/// banner that shows hides only 60 s over the limit, so it does not blink at the limit.
func showsLowRecordTime(left: Duration, recording: Bool, shownBefore: Bool) -> Bool {
    let limit: Duration = recording ? .seconds(600) : .seconds(3600)
    return left < (shownBefore ? limit + .seconds(60) : limit)
}

/// The N of the banner "Less than N min": the whole minutes left plus one, so the text is true
/// also at a whole minute and in the last minute (1 min, not 0 min).
func lowRecordTimeMinutes(_ left: Duration) -> Int { Int(left / .seconds(60)) + 1 }

/// The window subtitle: "48 kHz · Tracks: 3 · Record time: 2 hr, 10 min". No plural form
/// (0010); Foundation gives the units of the time. `text` gives the value of a key.
func subtitleText(
    rate: Int, tracks: Int, recordTimeLeft: Duration?, locale: Locale = .current,
    text: (L10n) -> String = { $0.text }
) -> String {
    let kHz = (Double(rate) / 1000).formatted(.number.locale(locale))
    var parts = ["\(kHz) kHz", "\(text(.subtitleTracks)) \(tracks)"]
    if let recordTimeLeft {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated).locale(locale)
        parts.append("\(text(.subtitleRecordTime)) \(recordTimeLeft.formatted(style))")
    }
    return parts.joined(separator: " · ")
}
