import DirigibleAudio
import DirigibleCore
import Foundation

/// The tools of `dirigible mcp`, in a fixed order: session, track, marker, pool, clip, ripple,
/// backup (decisions 0041 and 0043). The name of an edit tool is its command words with `_` for
/// each space and hyphen, and its arguments have the option names of the command.
extension Tool {
    static let all =
        sessionTools + trackTools + markerTools + episodeTools + poolTools + clipTools + rippleTools + backupTools
}

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

private let sampleRate = Param.required("sample_rate", "The session sample rate in Hz, more than 0.", .integer())
private let infoTracks = Param<[String]?>.optional(
    "tracks", "Only these track IDs, with the files and captures that their clips use.", .strings(minItems: 1))
private let infoFrom = Param<Int?>.optional(
    "from", "Only the clips and markers from this frame. Give it with to.", .integer())
private let infoTo = Param<Int?>.optional(
    "to", "Only the clips and markers to this frame. Give it with from.", .integer())

let sessionTools = [
    Tool("session_create", "Make an empty session package.", [sampleRate], saves: false) { a throws(ToolError) in
        guard EditRules.isPackagePath(a.package) else { throw ToolError("The package path must end in .dirigible.") }
        guard let rate = EditRules.sampleRate(try a[sampleRate]) else {
            throw ToolError("The sample rate must be more than 0.")
        }
        return .create(sampleRate: rate)
    },
    Tool(
        "session_info",
        "Read a session package as compact JSON, the JSON of dirigible info --json. For a long session, read it "
            + "in parts with from and to (a frame range), or with tracks. An answer over \(sessionInfoBudget) characters is an "
            + "overview: each track with its clip count, the end frame, and the marker count. episode_get reads the "
            + "episode of any session.",
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

private let markerName = Param<String?>.optional(
    "name", "The marker name. A new marker needs it; an existing marker keeps its name without it.", .string)
private let markerAt = Param<Int?>.optional(
    "at", "The timeline frame. A new marker needs it; an existing marker keeps its frame without it.", .integer())
private let markerKind = Param<Marker.Kind?>.optional(
    "kind", "marker or chapter. A new marker is a marker without it; an existing marker keeps its kind.",
    .choice(["marker", "chapter"], Marker.Kind.init))
private let markerID = Param<String?>.optional("id", "The marker ID. The default is a new UUID.", .string)
private let markerURL = Param<String?>.optional(
    "url",
    "The chapter link: an http or https URL of at most \(Marker.maximumURLBytes) bytes. An empty string clears it.",
    .string)
private let markerImage = Param<String?>.optional(
    "image",
    "The absolute path of the chapter image: a square JPEG or PNG file, at most \(maximumArtworkSide) x "
        + "\(maximumArtworkSide) pixels. The tool copies it into the package. An empty string clears it.",
    .string)
private let marker = Param.required("marker", "The marker ID.", .string)

let markerTools = [
    Tool(
        "marker_set",
        "Add a marker, or change the marker with its ID, and give its ID. For an existing marker, each argument "
            + "that is not given keeps its value.",
        [markerName, markerAt, markerKind, markerID, markerURL, markerImage]
    ) { a throws(ToolError) in
        let image = try a[markerImage]
        if let image, !image.isEmpty, !image.hasPrefix("/") {
            throw ToolError("The argument \"image\" must be an absolute path.")
        }
        let fields = MarkerFields(
            id: try a[markerID], name: try a[markerName], at: try a[markerAt], kind: try a[markerKind],
            url: try a[markerURL], image: image)
        do throws(MarkerEditError) { return .marker(try fields.work()) } catch { throw ToolError(error.message) }
    },
    Tool("marker_remove", "Remove a marker.", [marker]) { a throws(ToolError) in
        let id = MarkerID(try a[marker])
        return .edit { session throws(SessionError) in
            try session.removeMarker(id)
            return []
        }
    },
]

private let capture = Param.required("capture", "The capture ID.", .string)
private let file = Param.required("file", "The file ID.", .string)

/// `capture add` and `file add` have no tool: they write raw clock data and a file record with no
/// audio read (ParityTests.toolExemptions).
let poolTools = [
    Tool("capture_remove", "Remove a capture that no file uses.", [capture]) { a throws(ToolError) in
        let id = CaptureID(try a[capture])
        return .edit { session throws(SessionError) in
            try session.removeCapture(id)
            return []
        }
    },
    Tool("file_remove", "Remove a file that no clip uses.", [file]) { a throws(ToolError) in
        let id = FileID(try a[file])
        return .edit { session throws(SessionError) in
            try session.removeFile(id)
            return []
        }
    },
]

private let backupName = Param.required(
    "name", "The backup file name, as backup_list gives it.",
    Kind(schema: ["type": "string"], expected: backupNameExpected) { ($0 as? String).flatMap(Backup.init(fileName:)) })

let backupTools = [
    Tool("backup_list", "Give the backup file names of the session, newest first.", [], saves: false) { _ in
        .backups
    },
    Tool(
        "backup_revert", "Revert the session to a backup. It keeps a backup of the replaced session first.",
        [backupName]
    ) { a throws(ToolError) in .revert(try a[backupName]) },
]

private func episodeText(_ key: String, _ doc: String) -> Param<String?> {
    .optional(key, doc + " An empty string clears the field.", .string)
}

private let episodeParams = (
    title: episodeText("title", "The title."), show: episodeText("show", "The show name (the album)."),
    author: episodeText("author", "The host or author (the artist)."),
    episode: episodeText("episode", "The episode number, from 1 to \(EpisodeNumber.maximum), as text."),
    season: episodeText("season", "The season number, from 1 to \(EpisodeNumber.maximum), as text."),
    date: episodeText("date", "The date, YYYY-MM-DD."),
    language: episodeText("language", "An ISO 639-2 code, for example eng or spa."),
    copyright: episodeText("copyright", "The copyright."),
    explicit: Param<Bool?>.optional("explicit", "The explicit flag.", .boolean),
    summary: episodeText("summary", "The short description."), notes: episodeText("notes", "The episode notes."),
    episodeURL: episodeText("episode_url", "An http or https URL."),
    feedURL: episodeText("feed_url", "An http or https URL."), guid: episodeText("guid", "The episode GUID."),
    artwork: episodeText(
        "artwork",
        "The absolute path of a square JPEG or PNG file, at most \(maximumArtworkSide) x \(maximumArtworkSide) "
            + "pixels. The tool copies it into the package.")
)

let episodeTools = [
    Tool(
        "episode_set", "Set episode fields of the MP3 and M4A exports. The other fields do not change.",
        [
            episodeParams.title, episodeParams.show, episodeParams.author, episodeParams.episode, episodeParams.season,
            episodeParams.date, episodeParams.language, episodeParams.copyright, episodeParams.explicit,
            episodeParams.summary, episodeParams.notes, episodeParams.episodeURL, episodeParams.feedURL,
            episodeParams.guid, episodeParams.artwork,
        ]
    ) { a throws(ToolError) in
        let p = episodeParams
        let fields = EpisodeFields(
            title: try a[p.title], show: try a[p.show], author: try a[p.author], episode: try a[p.episode],
            season: try a[p.season], date: try a[p.date], language: try a[p.language], copyright: try a[p.copyright],
            explicit: try a[p.explicit], summary: try a[p.summary], notes: try a[p.notes],
            episodeURL: try a[p.episodeURL], feedURL: try a[p.feedURL], guid: try a[p.guid],
            artwork: try a[p.artwork])
        if let artwork = fields.artwork, !artwork.isEmpty, !artwork.hasPrefix("/") {
            throw ToolError("The argument \"artwork\" must be an absolute path.")
        }
        do throws(EpisodeFieldError) { return .episode(try fields.work()) } catch { throw ToolError(error.message) }
    },
    Tool(
        "episode_get",
        "Read the episode fields as compact JSON, the JSON of dirigible episode show. The keys are the argument "
            + "names of episode_set, and only the set fields are in it. artwork is the path in the package.",
        [], saves: false
    ) { _ throws(ToolError) in .episodeInfo },
]
