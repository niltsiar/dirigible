import ArgumentParser
import DirigibleCore
import DirigibleMCP

extension ClipCommand {
    struct Envelope: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Set the gain points of a clip inside its window, in timeline frames (decision 0060). The points "
                + "outside the window stay. The ride layer of clip level-over-time is separate and stays.")
        @OptionGroup var package: PackageArgument
        @Argument var clip: String
        @Option(
            name: .customLong("point"), parsing: .unconditionalSingleValue,
            help: ArgumentHelp(
                "A timeline frame inside the clip and a gain in dB. Give one or more.", valueName: "frame:dB"))
        var points: [String] = []
        @Flag(
            help: ArgumentHelp(
                "Remove the points inside the clip window. The points outside it still set the gain at the clip "
                    + "edges. To make the clip flat, set a 0 dB point at the first frame and at the last frame of "
                    + "the clip."))
        var clear = false

        func validate() throws {
            guard !points.isEmpty != clear else { throw ValidationError("Give --point or --clear.") }
            if let twice = EditRules.firstRepeat(try points.map(parsePoint).map(\.frame)) {
                throw ValidationError("Frame \(twice) is given twice.")
            }
        }

        func run() throws {
            let map = Dictionary(uniqueKeysWithValues: try points.map(parsePoint))
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.setEnvelope(map, clip: ClipID(clip))
            }
        }
    }

    struct GainRange: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Add a gain to a range of tracks, with ramps outside the range, on top of the gain points (decision "
                + "0060). Write the ID of each changed clip.")
        @OptionGroup var package: PackageArgument
        @Option(help: "A track. Give one or more.") var track: [String] = []
        @Option(parsing: .unconditional, help: "The first frame.") var from: Int
        @Option(parsing: .unconditional, help: "The frame after the last frame.") var to: Int
        @Option(parsing: .unconditional, help: "The gain in dB.", transform: parseGain) var db: Gain
        @Option(parsing: .unconditional, help: "The ramp length in frames, 1 or more. The default is 500 ms.")
        var ramp: Int?

        func validate() throws {
            guard !track.isEmpty else { throw ValidationError("Give one or more --track.") }
            guard EditRules.gainRange(from: from, to: to) != nil else {
                throw ValidationError("--from must be less than --to.")
            }
            if let ramp, ramp < 1 { throw ValidationError("--ramp must be 1 or more.") }
        }

        func run() throws {
            let changed = try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.changeGain(
                    by: db, in: Frames(from)..<Frames(to), on: track.map { TrackID($0) },
                    ramp: ramp.map { Frames($0) } ?? session.gainRamp)
            }
            for id in changed { print(id) }
        }
    }
}

/// `<frame>:<dB>`, with `EditRules.envelopePoint`.
func parsePoint(_ text: String) throws -> (frame: Frames, gain: Gain) {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let frame = Int(parts[0]), let dB = Double(parts[1]),
        let point = EditRules.envelopePoint(frame: frame, dB: dB)
    else {
        throw ValidationError("A point is <frame>:<dB>, with a frame 0 or more and a gain \(Gain.rangeText).")
    }
    return point
}
