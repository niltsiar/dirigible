import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct Fade: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the fade-in or the fade-out of a clip in frames (decision 0035). 0 removes a fade.")
        @OptionGroup var package: PackageArgument
        @Option var clip: String
        @Option(
            name: .customLong("in"), parsing: .unconditional,
            help: "The fade-in length in frames. The default is the current value.")
        var fadeIn: Int?
        @Option(
            name: .customLong("out"), parsing: .unconditional,
            help: "The fade-out length in frames. The default is the current value.")
        var fadeOut: Int?

        func validate() throws {
            guard EditRules.fadeGiven(fadeIn: fadeIn, fadeOut: fadeOut) else {
                throw ValidationError("Give --in, --out, or both.")
            }
        }

        func run() throws {
            try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                let id = ClipID(clip)
                guard let current = session.clip(id)?.clip.fades else { throw .unknownClip(id) }
                let fadeIn = fadeIn.map { Frames($0) } ?? current.fadeIn
                let fadeOut = fadeOut.map { Frames($0) } ?? current.fadeOut
                guard let fades = Fades(fadeIn: fadeIn, fadeOut: fadeOut) else { throw .frameOutOfRange }
                try session.setFades([id: fades])
            }
        }
    }
}

extension ClipCommand {
    struct Crossfade: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Set the crossfade at the end of a clip and the start of the clip that touches it, in frames "
                + "(decision 0036). 0 removes it.")
        @OptionGroup var package: PackageArgument
        @Option(help: "The left clip of the join.") var clip: String
        @Option(
            parsing: .unconditional, help: "The crossfade length in frames, an even number.",
            transform: parseCrossfadeLength)
        var length: Frames

        func run() throws {
            try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try session.setCrossfades([ClipID(clip): length])
            }
        }
    }
}

extension ClipCommand {
    struct Heal: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract:
                "Join the clips that touch and play on in one file at one gain at each frame, the envelope included, "
                + "with no fade at the join. The sound does not change: it undoes a split. Write the ID of each healed clip."
        )
        @OptionGroup var package: PackageArgument
        @Option(help: "A track. The default is all tracks.") var track: [String] = []
        @Option(parsing: .unconditional, help: "Only the joins from this timeline frame. Give it with --to.")
        var from: Int?
        @Option(
            parsing: .unconditional,
            help: "Only the joins to this timeline frame, a join at this frame too. Give it with --from.")
        var to: Int?

        func validate() throws {
            switch (from, to) {
            case (nil, nil): break
            case (let from?, let to?):
                guard EditRules.joinRange(from: from, to: to) != nil else {
                    throw ValidationError("--from must not be more than --to.")
                }
            default: throw ValidationError("Give --from and --to, or neither.")
            }
        }

        func run() throws {
            var range: ClosedRange<Frames>?
            if let from, let to { range = EditRules.joinRange(from: from, to: to) }
            let healed = try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try session.heal(tracks: track.isEmpty ? nil : track.map { TrackID($0) }, range: range)
            }
            for id in healed { print(id) }
        }
    }
}

/// `EditRules.crossfadeLength` of a number.
func parseCrossfadeLength(_ text: String) throws -> Frames {
    guard let length = Int(text).flatMap(EditRules.crossfadeLength) else {
        throw ValidationError("A crossfade length is an even number of frames, 0 or more.")
    }
    return length
}
