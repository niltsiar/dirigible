import DirigibleAudio
import DirigibleCore
import Foundation

/// The tools of `dirigible mcp`, in a fixed order: session, track, marker, pool, clip, ripple
/// (decision 0041). The name of an edit tool is its command words with `_` for each space and
/// hyphen, and its arguments have the option names of the command.
let tools: [Tool] = sessionTools + trackTools

/// The parameters that more than one tool has.
enum Arg {
    static let track = Param.required("track", "The track ID.", .string)
    static let name = Param.required("name", "The name.", .string)
    static let layout = Param.required("layout", "mono or stereo.", .choice(["mono", "stereo"], ChannelLayout.init))
    static let gain = Param.required("db", "The gain in dB.", .gain)
    static let off = Param.defaulted("off", "Clear the flag in place of setting it.", .boolean, false)
    static let device = Param<String?>.optional("device", "The device UID. Give it with channels.", .string)
    static let channels = Param<Route.Channels?>.optional(
        "channels", "One channel, or two as [1, 2]. Channels start at 1.", .channels)
    static let app = Param<String?>.optional(
        "app", "The bundle ID of an app to record, for example us.zoom.xos.", .string)
    static let noRoute = Param.defaulted("none", "Remove the route.", .boolean, false)
    static let from = Param.required("from", "The first frame.", .integer())
    static let to = Param.required("to", "The frame after the last frame.", .integer())
}

/// The new IDs of an edit, as text: one on each line, or OK.
func toolText(_ ids: [String]) -> String { ids.isEmpty ? "OK" : ids.joined(separator: "\n") }

private let sampleRate = Param.required("sample_rate", "The session sample rate in Hz.", .integer(minimum: 1))
private let infoTracks = Param<[String]?>.optional(
    "tracks", "Only these track IDs, with the files and captures that their clips use.", .strings(minItems: 1))
private let infoFrom = Param<Int?>.optional(
    "from", "Only the clips and markers from this frame. Give it with to.", .integer())
private let infoTo = Param<Int?>.optional(
    "to", "Only the clips and markers to this frame. Give it with from.", .integer())

let sessionTools = [
    Tool("session_create", "Make an empty session package.", [sampleRate], saves: false) { a throws(ToolError) in
        guard EditRules.isPackagePath(a.package) else { throw ToolError("The package path must end in .dirigible.") }
        return .create(sampleRate: try a[sampleRate])
    },
    Tool(
        "session_info",
        "Read a session package as compact JSON, the JSON of dirigible info --json. For a long session, read it "
            + "in parts with tracks, or with from and to.",
        [infoTracks, infoFrom, infoTo], saves: false
    ) { a throws(ToolError) in
        let (from, to) = (try a[infoFrom], try a[infoTo])
        var range: Range<Frames>?
        switch (from, to) {
        case (nil, nil): range = nil
        case (let from?, let to?):
            guard let checked = EditRules.frameRange(from: from, to: to) else {
                throw ToolError("from must not be more than to.")
            }
            range = checked
        default: throw ToolError("Give from and to, or neither.")
        }
        return .info(tracks: try a[infoTracks]?.map { TrackID($0) }, range: range)
    },
]

private let trackID = Param<String?>.optional("id", "The track ID. The default is a new UUID.", .string)
private let hostID = Param<String?>.optional("host_id", "The Host track ID. The default is a new UUID.", .string)
private let guestID = Param<String?>.optional("guest_id", "The Guest track ID. The default is a new UUID.", .string)
private let hostDevice = Param<String?>.optional("device", "The device UID of Host.", .string)
private let hostChannels = Param<Route.Channels?>.optional(
    "channels", "The one channel of Host, as [1]. Channels start at 1.", .channels)
private let guestApp = Param<String?>.optional(
    "app", "The bundle ID of the app of Guest, for example us.zoom.xos.", .string)
private let trackIDs = Param.required("tracks", "The track IDs.", .strings(minItems: 1))

let trackTools = [
    Tool("track_add", "Add a track and give its ID.", [Arg.name, Arg.layout, trackID]) { a throws(ToolError) in
        let (id, name, layout) = (try a[trackID].map { TrackID($0) } ?? TrackID(), try a[Arg.name], try a[Arg.layout])
        return .edit { session throws(SessionError) in
            try session.addTrack(id, name: name, layout: layout)
            return [id.rawValue]
        }
    },
    Tool(
        "track_add_call", "Add the mono tracks Host and Guest of a call, and give their IDs.",
        [hostDevice, hostChannels, guestApp, hostID, guestID]
    ) { a throws(ToolError) in
        let app = try a[guestApp]
        var device: (uid: String, channel: Int)?
        switch EditRules.hostDevice(device: try a[hostDevice], channels: try a[hostChannels]) {
        case .unpaired: throw ToolError("Give device with channels.")
        case .stereo: throw ToolError("Host takes one channel.")
        case .mono(let uid, let channel): device = (uid, channel)
        case .none: device = nil
        }
        guard EditRules.appRouteAllowed(app, tapsAvailable: processTapsAvailable) else {
            throw ToolError(appSourcesUnavailableMessage)
        }
        let (host, guest) = (
            try a[hostID].map { TrackID($0) } ?? TrackID(), try a[guestID].map { TrackID($0) } ?? TrackID()
        )
        return .edit { [device] session throws(SessionError) in
            try session.addCallTracks(
                host: host, guest: guest, names: (host: "Host", guest: "Guest"), hostDevice: device, guestApp: app)
            return [host.rawValue, guest.rawValue]
        }
    },
    Tool("track_remove", "Remove a track and its clips.", [Arg.track]) { a throws(ToolError) in
        let track = TrackID(try a[Arg.track])
        return .edit { session throws(SessionError) in
            try session.removeTrack(track)
            return []
        }
    },
    Tool("track_rename", "Rename a track.", [Arg.track, Arg.name]) { a throws(ToolError) in
        let (track, name) = (TrackID(try a[Arg.track]), try a[Arg.name])
        return .edit { session throws(SessionError) in
            try session.renameTrack(track, to: name)
            return []
        }
    },
    Tool("track_gain", "Set the gain of a track.", [Arg.track, Arg.gain]) { a throws(ToolError) in
        let (track, gain) = (TrackID(try a[Arg.track]), try a[Arg.gain])
        return .edit { session throws(SessionError) in
            try session.setGain(gain, track: track)
            return []
        }
    },
    Tool(
        "track_route", "Set the route of a track: device with channels, app, or none.",
        [Arg.track, Arg.device, Arg.channels, Arg.app, Arg.noRoute]
    ) { a throws(ToolError) in
        let (track, route) = (TrackID(try a[Arg.track]), try routeArgument(a))
        return .edit { session throws(SessionError) in
            try session.setRoute(route, track: track)
            return []
        }
    },
    Tool(
        "track_layout", "Set the layout and the route of a track in one edit.",
        [Arg.track, Arg.layout, Arg.device, Arg.channels, Arg.app, Arg.noRoute]
    ) { a throws(ToolError) in
        let (track, layout, route) = (TrackID(try a[Arg.track]), try a[Arg.layout], try routeArgument(a))
        return .edit { session throws(SessionError) in
            try session.setLayout(layout, route: route, track: track)
            return []
        }
    },
    Tool(
        "track_mute", "Mute tracks: the mix, the export, and the render leave them out.", [trackIDs, Arg.off]
    ) { a throws(ToolError) in
        let (tracks, off) = (try a[trackIDs].map { TrackID($0) }, try a[Arg.off])
        return .edit { session throws(SessionError) in
            try session.setMuted(!off, tracks: tracks)
            return []
        }
    },
    Tool(
        "track_solo",
        "Solo tracks: while a track is soloed, only the soloed tracks that are not muted are heard.",
        [trackIDs, Arg.off]
    ) { a throws(ToolError) in
        let (tracks, off) = (try a[trackIDs].map { TrackID($0) }, try a[Arg.off])
        return .edit { session throws(SessionError) in
            try session.setSoloed(!off, tracks: tracks)
            return []
        }
    },
]

/// The route of `track_route` and `track_layout` (V6: `EditRules.route`; V5: an app route needs
/// process taps).
private func routeArgument(_ a: Arguments) throws(ToolError) -> Route? {
    let app = try a[Arg.app]
    guard
        let route = EditRules.route(
            device: try a[Arg.device], channels: try a[Arg.channels], app: app, none: try a[Arg.noRoute])
    else { throw ToolError("Give device with channels, app, or none.") }
    guard EditRules.appRouteAllowed(app, tapsAvailable: processTapsAvailable) else {
        throw ToolError(appSourcesUnavailableMessage)
    }
    return route
}
