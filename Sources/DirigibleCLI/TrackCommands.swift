import ArgumentParser
import DirigibleCore

struct TrackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "track", abstract: "Add, change, and remove tracks.",
        subcommands: [Add.self, Remove.self, Rename.self, SetGain.self, SetLayout.self, SetRoute.self])

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

    struct SetLayout: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "layout", abstract: "Set the layout and the route of a track in one edit.")
        @OptionGroup var package: PackageArgument
        @Argument var track: String
        @Argument(help: "mono or stereo.", transform: parseLayout) var layout: ChannelLayout
        @OptionGroup var route: RouteOptions

        func run() throws {
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

        func run() throws {
            try editPackage(package) { session throws(SessionError) in
                try session.setRoute(route.route, track: TrackID(track))
            }
        }
    }
}

/// Exactly one route form: `--device` with `--channels`, or `--none`. No command leaves the
/// route unstated, so a layout change never removes a route by accident.
struct RouteOptions: ParsableArguments {
    @Option(help: "The device UID.") var device: String?
    @Option(parsing: .unconditional, help: "One channel, or two as 1,2. Channels start at 1.", transform: parseChannels)
    var channels: Route.Channels?
    @Flag(help: "Remove the route.") var none = false

    func validate() throws {
        guard (device != nil && channels != nil && !none) || (device == nil && channels == nil && none) else {
            throw ValidationError("Give --device with --channels, or --none.")
        }
    }

    var route: Route? {
        guard let device, let channels else { return nil }
        return Route(deviceUID: device, channels: channels)
    }
}
