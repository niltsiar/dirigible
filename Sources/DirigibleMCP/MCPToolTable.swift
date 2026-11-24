import DirigibleAudio
import DirigibleCore
import Foundation

/// The tools of `dirigible mcp`, in a fixed order: session, track, marker, pool, clip, ripple,
/// transcript, take, backup, record, transport, audio, chapter, source, batch (decisions 0041, 0043, 0048, 0049,
/// 0055, 0061, and 0063). The name of an edit tool is its command words with `_` for each space and hyphen, and
/// its arguments have the option names of the command.
extension Tool {
    static let all =
        sessionTools + trackTools + matchTools + presetTools + binTools + markerTools + episodeTools + poolTools
        + clipTools + rideTools
        + syncTools
        + timelineEditTools
        + envelopeTools + rippleTools
        + transcriptTools + takeTools
        + backupTools + recordTools + transportTools + audioTools + sessionImportTools + chapterTools + sourceTools
        + batchTools
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

private let sampleRate = Param<Int?>.optional(
    "sample_rate", "The session sample rate in Hz, more than 0, for an empty session. Give this or template.",
    .integer())
private let template = Param<String?>.optional(
    "template",
    "The absolute path of a session package to copy: the new session has its tracks, clips, markers, show "
        + "fields, and sample rate, "
        + "with no transcript and no episode title, number, date, summary, notes, URL, or GUID. Give this or "
        + "sample_rate.",
    .string)
private let infoTracks = Param<[String]?>.optional(
    "tracks", "Only these track IDs, with the files and captures that their clips use.", .strings(minItems: 1))
private let infoFrom = Param<Int?>.optional(
    "from", "Only the clips and markers from this frame. Give it with to.", .integer())
private let infoTo = Param<Int?>.optional(
    "to", "Only the clips and markers to this frame. Give it with from.", .integer())
private let infoCompact = Param.defaulted(
    "compact", "Only sampleRate, tracks with their clips, and markers: no files, captures, or episode.", .boolean,
    false)

let sessionTools = [
    Tool(
        "session_create", "Make an empty session package, or a new session from a template.", [sampleRate, template],
        saves: false, batch: .alone
    ) {
        a throws(ToolError) in
        guard EditRules.isPackagePath(a.package) else { throw ToolError("The package path must end in .dirigible.") }
        switch (try a[sampleRate], try a[template]) {
        case (let rate?, nil):
            guard let rate = EditRules.sampleRate(rate) else {
                throw ToolError("The sample rate must be more than 0.")
            }
            return .create(.rate(rate))
        case (nil, let template?):
            guard template.hasPrefix("/") else {
                throw ToolError("The argument \"template\" must be an absolute path.")
            }
            return .create(.template(URL(filePath: template)))
        case (nil, nil): throw ToolError("Give sample_rate or template.")
        case (_?, _?): throw ToolError("Give sample_rate or template, not both.")
        }
    },
    Tool(
        "session_info",
        "Read a session package as compact JSON, the JSON of dirigible info --json. For a long session, read it "
            + "in parts with from and to (a frame range), or with tracks. An answer over \(sessionInfoBudget) characters is an "
            + "overview: each track with its clip count, the end frame, and the marker count. With compact, the JSON "
            + "has only sampleRate, tracks with their clips, and markers, so a read costs fewer tokens. episode_get "
            + "reads the episode of any session.",
        [infoTracks, infoFrom, infoTo, infoCompact], saves: false, batch: .alone
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
        return .info(tracks: try a[infoTracks]?.map { TrackID($0) }, range: range, compact: try a[infoCompact])
    }.hinted(.readOnly),
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
private let trackRole = Param<Track.Role?>.required(
    "role", "dialogue, music, effects, or none. none removes the role.", .choice(EditRules.roleWords, EditRules.role))

let trackTools = [
    Tool("track_add", "Add a track and give its ID.", [Arg.name, Arg.layout, trackID], batch: .step) {
        a throws(ToolError) in
        let (id, name, layout) = (try a[trackID].map { TrackID($0) } ?? TrackID(), try a[Arg.name], try a[Arg.layout])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.addTrack(id, name: name, layout: layout)
            return [id.rawValue]
        }
    },
    Tool(
        "track_add_call", "Add the mono tracks Host and Guest of a call, and give their IDs.",
        [hostDevice, hostChannels, guestApp, hostID, guestID], batch: .step
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
        return .edit(ripple: false) { [device] session throws(SessionError) in
            try session.addCallTracks(
                host: host, guest: guest, names: (host: "Host", guest: "Guest"), hostDevice: device, guestApp: app)
            return [host.rawValue, guest.rawValue]
        }
    },
    Tool("track_remove", "Remove a track and its clips.", [Arg.track], batch: .step) { a throws(ToolError) in
        let track = TrackID(try a[Arg.track])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeTrack(track)
            return []
        }
    },
    Tool("track_rename", "Rename a track.", [Arg.track, Arg.name], batch: .step) { a throws(ToolError) in
        let (track, name) = (TrackID(try a[Arg.track]), try a[Arg.name])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.renameTrack(track, to: name)
            return []
        }
    },
    Tool("track_gain", "Set the gain of a track.", [Arg.track, Arg.gain], batch: .step) { a throws(ToolError) in
        let (track, gain) = (TrackID(try a[Arg.track]), try a[Arg.gain])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setGain(gain, track: track)
            return []
        }
    },
    Tool(
        "track_route", "Set the route of a track: device with channels, app, or none.",
        [Arg.track, Arg.device, Arg.channels, Arg.app, Arg.noRoute], batch: .step
    ) { a throws(ToolError) in
        let (track, route) = (TrackID(try a[Arg.track]), try routeArgument(a))
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setRoute(route, track: track)
            return []
        }
    },
    Tool(
        "track_layout", "Set the layout and the route of a track in one edit.",
        [Arg.track, Arg.layout, Arg.device, Arg.channels, Arg.app, Arg.noRoute], batch: .step
    ) { a throws(ToolError) in
        let (track, layout, route) = (TrackID(try a[Arg.track]), try a[Arg.layout], try routeArgument(a))
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setLayout(layout, route: route, track: track)
            return []
        }
    },
    Tool(
        "track_mute", "Mute tracks: the mix, the export, and the render leave them out.", [trackIDs, Arg.off],
        batch: .step
    ) { a throws(ToolError) in
        let (tracks, off) = (try a[trackIDs].map { TrackID($0) }, try a[Arg.off])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setMuted(!off, tracks: tracks)
            return []
        }
    },
    Tool(
        "track_solo",
        "Solo tracks: while a track is soloed, only the soloed tracks that are not muted are heard.",
        [trackIDs, Arg.off], batch: .step
    ) { a throws(ToolError) in
        let (tracks, off) = (try a[trackIDs].map { TrackID($0) }, try a[Arg.off])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setSoloed(!off, tracks: tracks)
            return []
        }
    },
    Tool(
        "track_role", "Set the role of a track: dialogue, music, effects, or none. " + EditRules.roleNote,
        [Arg.track, trackRole], batch: .step
    ) {
        a throws(ToolError) in
        let (track, role) = (TrackID(try a[Arg.track]), try a[trackRole])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setRole(role, tracks: [track])
            return ["OK", EditRules.roleReply]
        }
    },
    Tool(
        "track_follow",
        "Follow ripples: the clips of the tracks move whole in a ripple and a ripple never cuts them.",
        [trackIDs, Arg.off], batch: .step
    ) { a throws(ToolError) in
        let (tracks, off) = (try a[trackIDs].map { TrackID($0) }, try a[Arg.off])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setFollowTrack(!off, tracks: tracks)
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
        [markerName, markerAt, markerKind, markerID, markerURL, markerImage], batch: .step
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
    Tool("marker_remove", "Remove a marker.", [marker], batch: .step) { a throws(ToolError) in
        let id = MarkerID(try a[marker])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeMarker(id)
            return []
        }
    },
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
        ], batch: .step
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
        [], saves: false, batch: .alone
    ) { _ throws(ToolError) in .episodeInfo }.hinted(.readOnly),
]
