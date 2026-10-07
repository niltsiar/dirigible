import ArgumentParser
import DirigibleAudio
import DirigibleCore

struct TrackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "track", abstract: "Add, change, and remove tracks.",
        subcommands: [
            Add.self, AddCall.self, Remove.self, Rename.self, SetGain.self, SetLayout.self, SetRoute.self, Mute.self,
            Solo.self,
        ])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a track and write its ID.")
        @OptionGroup var package: PackageArgument
        @Option var name: String
        @Option(help: "mono or stereo.", transform: parseLayout) var layout: ChannelLayout
        @Option(help: "The track ID. The default is a new UUID.") var id: String?

        func run() throws {
            let id = id.map { TrackID($0) } ?? TrackID()
            try editPackage(package) { session throws(SessionError) in
                try session.addTrack(id, name: name, layout: layout)
            }
            print(id)
        }
    }

    /// Not `RouteOptions`: Host takes a device route and Guest an app route in one command.
    struct AddCall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-call", abstract: "Add the mono tracks Host and Guest of a call, and write their IDs.")
        @OptionGroup var package: PackageArgument
        @Option(help: "The device UID of Host.") var device: String?
        @Option(
            parsing: .unconditional, help: "The one channel of Host. Channels start at 1.", transform: parseChannels)
        var channels: Route.Channels?
        @Option(help: "The bundle ID of the app of Guest, for example us.zoom.xos.") var app: String?
        @Option(help: "The Host track ID. The default is a new UUID.") var hostId: String?
        @Option(help: "The Guest track ID. The default is a new UUID.") var guestId: String?

        func validate() throws {
            switch EditRules.hostDevice(device: device, channels: channels) {
            case .unpaired: throw ValidationError("Give --device with --channels.")
            case .stereo: throw ValidationError("Host takes one channel.")
            case .none, .mono: break
            }
        }

        func run() throws { try apply(tapsAvailable: processTapsAvailable) }

        func apply(tapsAvailable: Bool) throws {
            guard EditRules.appRouteAllowed(app, tapsAvailable: tapsAvailable) else {
                throw fail(appSourcesUnavailableMessage, code: editRefused)
            }
            let (host, guest) = (hostId.map { TrackID($0) } ?? TrackID(), guestId.map { TrackID($0) } ?? TrackID())
            var hostDevice: (uid: String, channel: Int)?
            if case .mono(let uid, let channel) = EditRules.hostDevice(device: device, channels: channels) {
                hostDevice = (uid, channel)
            }
            try editPackage(package) { session throws(SessionError) in
                try session.addCallTracks(
                    host: host, guest: guest, names: (host: "Host", guest: "Guest"), hostDevice: hostDevice,
                    guestApp: app)
            }
            print(host)
            print(guest)
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a track and its clips.")
        @OptionGroup var package: PackageArgument
        @Argument var track: String

        func run() throws {
            try editPackage(package) { session throws(SessionError) in try session.removeTrack(TrackID(track)) }
        }
    }

    struct Rename: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a track.")
        @OptionGroup var package: PackageArgument
        @Argument var track: String
        @Argument var name: String

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.renameTrack(TrackID(track), to: name)
            }
        }
    }

    struct SetGain: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "gain", abstract: "Set the gain of a track.")
        @OptionGroup var package: PackageArgument
        @Argument var track: String
        @Option(parsing: .unconditional, help: "The gain in dB.", transform: parseGain) var db: Gain

        func run() throws {
            try editPackage(package) { session throws(SessionError) in try session.setGain(db, track: TrackID(track)) }
        }
    }

    struct Mute: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mute tracks: the mix, the export, and the render leave them out.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The track IDs.") var tracks: [String] = []
        @Flag(help: "Unmute the tracks.") var off = false

        func validate() throws { if tracks.isEmpty { throw ValidationError("Give one track or more.") } }

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.setMuted(!off, tracks: tracks.map { TrackID($0) })
            }
        }
    }

    struct Solo: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Solo tracks: while a track is soloed, only the soloed tracks that are not muted are heard.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The track IDs.") var tracks: [String] = []
        @Flag(help: "Clear the solo of the tracks.") var off = false

        func validate() throws { if tracks.isEmpty { throw ValidationError("Give one track or more.") } }

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.setSoloed(!off, tracks: tracks.map { TrackID($0) })
            }
        }
    }

    struct SetLayout: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "layout", abstract: "Set the layout and the route of a track in one edit.")
        @OptionGroup var package: PackageArgument
        @Argument var track: String
        @Argument(help: "mono or stereo.", transform: parseLayout) var layout: ChannelLayout
        @OptionGroup var route: RouteOptions

        func run() throws { try apply(tapsAvailable: processTapsAvailable) }

        func apply(tapsAvailable: Bool) throws {
            try route.checkAvailable(tapsAvailable)
            try editPackage(package) { session throws(SessionError) in
                try session.setLayout(layout, route: route.route, track: TrackID(track))
            }
        }
    }

    struct SetRoute: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "route", abstract: "Set the route of a track.")
        @OptionGroup var package: PackageArgument
        @Argument var track: String
        @OptionGroup var route: RouteOptions

        func run() throws { try apply(tapsAvailable: processTapsAvailable) }

        func apply(tapsAvailable: Bool) throws {
            try route.checkAvailable(tapsAvailable)
            try editPackage(package) { session throws(SessionError) in
                try session.setRoute(route.route, track: TrackID(track))
            }
        }
    }
}

/// Exactly one route form: `--device` with `--channels`, `--app`, or `--none`. No command
/// leaves the route unstated, so a layout change never removes a route by accident.
struct RouteOptions: ParsableArguments {
    @Option(help: "The device UID.") var device: String?
    @Option(parsing: .unconditional, help: "One channel, or two as 1,2. Channels start at 1.", transform: parseChannels)
    var channels: Route.Channels?
    @Option(help: "The bundle ID of an app to record, for example us.zoom.xos.") var app: String?
    @Flag(help: "Remove the route.") var none = false

    func validate() throws {
        guard EditRules.route(device: device, channels: channels, app: app, none: none) != nil else {
            throw ValidationError("Give --device with --channels, --app, or --none.")
        }
    }

    /// `validate()` checked that the form is one of the three.
    var route: Route? { EditRules.route(device: device, channels: channels, app: app, none: none) ?? nil }

    /// Refuses an app route before the package lock when this macOS has no process taps.
    func checkAvailable(_ tapsAvailable: Bool) throws(ExitCode) {
        guard EditRules.appRouteAllowed(app, tapsAvailable: tapsAvailable) else {
            throw fail(appSourcesUnavailableMessage, code: editRefused)
        }
    }
}
