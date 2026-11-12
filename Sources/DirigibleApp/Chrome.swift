import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
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
    /// View > Show Session Index.
    case index = "view.index"
    /// The vari-speed pop-up (decision 0052).
    case speed = "transport.speed"
    /// Record with Pre-roll (decision 0070): in Customize Toolbar only, not in the default set.
    case preRoll = "transport.pre.roll"

    static let toolbar = NSToolbar.Identifier("dirigible.session")

    /// The groups, leading to trailing, with a space between them (the macOS 26 glass groups). Cut,
    /// Copy, Paste, and Go to End are in the customization palette only.
    static let defaults: [NSToolbarItem.Identifier] = {
        let transport: [ToolbarItemID] = [monitor, start, stop, play, record, time, speed]
        let view: [ToolbarItemID] = [zoomOut, zoomIn, zoomToSession, snap, export, inspector]
        var items: [NSToolbarItem.Identifier] = [index.identifier, addTrack.identifier, .space]
        items += transport.map(\.identifier) + [.space]
        items += [split, delete].map(\.identifier) + [.flexibleSpace]
        return items + view.map(\.identifier)
    }()

    var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier(rawValue) }

    /// The SF Symbol: unique per item, each macOS 13 or older. The time display and the speed
    /// pop-up have none.
    var symbol: String? {
        switch self {
        case .addTrack: "waveform.path.badge.plus"
        case .monitor: "mic.and.signal.meter"
        case .stop: "stop.fill"
        case .play: "play.fill"
        case .record: "circle.fill"
        case .preRoll: "record.circle"
        case .time, .speed: nil
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
        case .index: "sidebar.leading"
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
        case .addTrack, .start, .end, .index: .standard
        case .split, .cut, .copy, .paste, .delete, .zoomOut, .zoomIn, .zoomToSession, .snap, .speed, .preRoll: .low
        }
    }

    /// A push-on-push-off button: its on state is a shape, not only a color.
    var isToggle: Bool { [.record, .monitor, .play, .inspector, .snap, .index].contains(self) }

    /// The command of the item. Nil only for the time display and the speed pop-up, whose picks
    /// run `SessionWindow.speed(.set(_))`: a new item with no command does not compile (F16).
    var command: WindowCommand? {
        switch self {
        case .addTrack: .addTrack
        case .monitor: .toggleMonitor
        case .stop: .stop
        case .play: .transport(.playStop)
        case .record: .record
        case .preRoll: .recordPreRoll
        case .time, .speed: nil
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
        case .index: .toggleIndex
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
        case .preRoll: .toolbarPreRoll
        case .time: .toolbarTime
        case .speed: .toolbarSpeed
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
        case .index: .indexSegmentIndex
        case .snap: .menuViewSnap
        }
    }
}

/// A command that a menu item and a toolbar item share (decision 0023). The toolbar calls
/// `SessionWindow.run(_:)`, which forwards each case to the place that its menu item reaches.
enum WindowCommand: Hashable {
    case timeline(TimelineCommand)
    case transport(TransportCommand)
    case addTrack, record, recordPreRoll, stop, toggleMonitor, toggleInspector, toggleIndex, toggleSnap

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
        case .recordPreRoll: return (.menuRecordPreRoll, MenuKeys.preRoll)
        case .stop: return (.menuTransportStop, MenuKeys.stop)
        case .toggleMonitor: return (.menuRecordMonitor, MenuKeys.monitor)
        case .toggleInspector: return (.menuViewInspectorShow, MenuKeys.inspector)
        case .toggleIndex: return (.menuViewIndexShow, MenuKeys.showIndex)
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
        (viewItems + pasteboardItems + rippleItems + editItems + gainPointSeekItems + markerItems + trackItems
            + fileItems + toolItems + [splitStereoItem, restoreOriginalItem])
            .map {
                ($0.command, $0)
            },
        uniquingKeysWith: { first, _ in first })
}

/// The values that the chrome loop writes only on a change and SwiftUI reads, so no SwiftUI body
/// reads `Studio.play` (decision 0023).
struct ShownChrome: Equatable {
    /// The record-over warning (decisions 0016, 0017). `ChromeState` is its only owner.
    var recordOver = RecordOverWarning()
    /// The banner rows under the take banner, in order.
    var banners: [WindowBanner] = []
    /// The shown state of the record-time part of the window subtitle at the last loop turn.
    /// `ChromeState` gives it to `showsLowRecordTime` as `shownBefore`; no view reads it.
    var recordTime = false
    /// A take or a play runs: the Stop item and the Stop menu item are on. When nothing runs,
    /// Command-period reaches a sheet (decision 0023).
    var isRunning = false
    /// The vari-speed and whether the speed unit loads: the radio items of Transport > Playback
    /// Speed read them (decision 0052).
    var speed = Speed.one
    var canChangeSpeed = false
    /// The tracks that show **No sound from** (`.noSound`) or **No access** (`.noAccess`), with
    /// that state: `SessionChrome` announces each change to it.
    var appWarnings: [TrackID: LiveTrack.State] = [:]
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
    /// One or more agents are connected to the app server (C12).
    var agentConnected = false
    /// A pre-roll take plays before T: the subtitle starts with "Pre-roll".
    var preRolling = false

    @MainActor init(model: SessionWindow) {
        agentConnected = (model.app?.agents.connected ?? 0) > 0
        guard let studio = model.studio else { return }
        let recording = model.canStop
        playing = studio.playback != .stopped
        // During a take, the time shows the record head with tenths.
        let head = studio.liveHead()
        time = timeDisplayText(
            head ?? studio.playhead, rate: studio.session.sampleRate, playing: playing || head != nil)
        // Record stays on during a take: a click then does nothing (ux-decisions 4).
        if recording || model.canRecord { enabled.insert(.record) }
        if model.canRecord { enabled.insert(.preRoll) }
        if recording || playing { enabled.insert(.stop) }
        if model.canMonitor { enabled.insert(.monitor) }
        // A zoom changes no session data, so it runs during a take, as the View menu and the gestures.
        enabled.formUnion([.zoomOut, .zoomIn, .zoomToSession, .snap, .inspector, .index])
        if model.canEdit {
            enabled.formUnion([.addTrack, .play, .start, .end, .split, .cut, .copy, .paste, .delete])
            if studio.canChangeSpeed { enabled.insert(.speed) }
            if model.isOn(.export) { enabled.insert(.export) }
        }
        if recording { on.insert(.record) }
        if playing { on.insert(.play) }
        if model.monitoring { on.insert(.monitor) }
        if model.showsInspector { on.insert(.inspector) }
        if model.leadingPane.shown { on.insert(.index) }
        if model.snaps { on.insert(.snap) }
        // During a take the take start and the disk watch give the time left; before it, the
        // idle read of the armed tracks with a route.
        let left = recording ? studio.recordTimeLeft : model.armedWithRoute.isEmpty ? nil : model.idleRecordTimeLeft
        // The subtitle shows the time left on the rule before a take, also during a take (F152).
        let subtitleLeft = left.flatMap {
            showsLowRecordTime(left: $0, recording: false, shownBefore: model.shown.recordTime) ? $0 : nil
        }
        preRolling = studio.preRollFrame != nil
        subtitle = subtitleText(
            rate: studio.session.sampleRate, tracks: studio.session.tracks.count, recordTimeLeft: subtitleLeft,
            preRoll: preRolling, dragMode: model.dragMode)
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
        banners += Self.reportBanners(model, studio)
        shown = ShownChrome(
            recordOver: model.showsRecordOver, banners: banners, recordTime: subtitleLeft != nil,
            isRunning: recording || playing, speed: studio.speed, canChangeSpeed: studio.canChangeSpeed,
            appWarnings: studio.liveStates.filter { $0.value == .noSound || $0.value == .noAccess })
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

/// Low record time (decision 0023): before a take under 3 h, during a take under 10 min. A
/// banner that shows hides only over the limit plus a band (300 s before a take, 60 s during it),
/// so it does not blink at the limit.
func showsLowRecordTime(left: Duration, recording: Bool, shownBefore: Bool) -> Bool {
    let (limit, band): (Duration, Duration) =
        recording ? (.seconds(600), .seconds(60)) : (.seconds(10_800), .seconds(300))
    return left < (shownBefore ? limit + band : limit)
}

/// The minutes of the banner "Less than N": the whole minutes left plus one, so the text is true
/// also at a whole minute and in the last minute (1 min, not 0 min).
func lowRecordTimeMinutes(_ left: Duration) -> Int { Int(left / .seconds(60)) + 1 }

/// The units of the record time in the subtitle and the banner: "2 hr, 10 min". The style rounds
/// to the nearest minute, so each caller gives it whole minutes.
func recordTimeStyle(_ locale: Locale) -> Duration.UnitsFormatStyle {
    Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated).locale(locale)
}

/// The text of the low-record-time banner: "Less than 2 hr, 1 min of record time left on this
/// disk. ...". `text` gives the value of a key.
func lowRecordTimeText(minutes: Int, locale: Locale = .current, text: (L10n) -> String = { $0.text }) -> String {
    String(
        format: text(.bannerLowRecordTimeLeft), locale: locale,
        Duration.seconds(minutes * 60).formatted(recordTimeStyle(locale)))
}

/// The window subtitle: "48 kHz · Tracks: 3 · Record time left: 2 hr, 10 min", with the time left
/// rounded down to the minute. No plural form (0010); Foundation gives the units of the time.
/// During the pre-roll of a take it starts with "Pre-roll". Outside Overwrite, the cue "Drag Mode:
/// Shuffle" comes next, before the rate. `text` gives the value of a key.
func subtitleText(
    rate: Int, tracks: Int, recordTimeLeft: Duration?, preRoll: Bool = false, dragMode: DragMode = .overwrite,
    locale: Locale = .current,
    text: (L10n) -> String = { $0.text }
) -> String {
    let kHz = (Double(rate) / 1000).formatted(.number.locale(locale))
    var parts = ["\(kHz) kHz", "\(text(.subtitleTracks)) \(tracks)"]
    if dragMode != .overwrite {
        parts.insert(String(format: text(.timelineDragModeCue), locale: locale, text(dragMode.title)), at: 0)
    }
    if preRoll { parts.insert(text(.subtitlePreRoll), at: 0) }
    if let recordTimeLeft {
        let minutes = Duration.seconds(Int(recordTimeLeft / .seconds(60)) * 60)
        parts.append("\(text(.subtitleRecordTime)) \(minutes.formatted(recordTimeStyle(locale)))")
    }
    return parts.joined(separator: " · ")
}

/// The trailing title bar mark of a connected agent (ui-panel.md): the `sparkles` symbol and
/// "Agent" in secondary gray, with no animation. The session chrome adds it to the title bar only
/// while an agent is connected.
@MainActor func agentMarkAccessory() -> NSTitlebarAccessoryViewController {
    let image = NSImageView(
        image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
    image.contentTintColor = .secondaryLabelColor
    let label = NSTextField(labelWithString: L10n.agentMark.text)
    label.textColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let stack = NSStackView(views: [image, label])
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    stack.toolTip = L10n.agentMarkHelp.text
    stack.setAccessibilityElement(true)
    stack.setAccessibilityRole(.staticText)
    stack.setAccessibilityLabel(L10n.agentMarkHelp.text)
    // The title bar sizes a trailing accessory from the frame of its view, not from Auto Layout.
    stack.frame.size = stack.fittingSize
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .trailing
    accessory.view = stack
    return accessory
}
