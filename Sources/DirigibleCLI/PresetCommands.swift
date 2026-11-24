import ArgumentParser
import DirigibleCore
import DirigibleMCP

struct PresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset", abstract: "Set or remove an export preset of the session.",
        discussion: """
            A preset has a name and the options of one export file: the format, the bit depth or the bit \
            rate, the channels, the file rate, and the loudness target. The session stores it, so a \
            template copies it. `export --preset` writes one file for each preset. The built-in presets \
            master and podcast are not stored and cannot change.
            """,
        subcommands: [SetPreset.self, RemovePreset.self])

    struct SetPreset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Add an export preset, or change one.",
            discussion: """
                A name that the session stores changes that preset, in its place, also when a built-in \
                preset has that name. With --rename, the name is the new name of the preset that --rename \
                gives. Another name adds a preset at the end of the list. Exit 64 for a value outside its \
                list, or a name that the session cannot store (1 to 64 characters, no space at either end, \
                no control character). Exit 1, with no change, for a new name that is the name of another \
                preset or of a built-in preset (master or podcast, with no regard to case), and for a \
                preset that the session does not store.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "The preset name.") var name: String
        @Option(help: "The file format: wav, flac, aac, or mp3.") var format: String
        @Option(help: "The bit depth of wav and flac: 16 or 24. The default is 24.") var bits: Int?
        @Option(help: "The aac or mp3 bit rate in kbit/s: 64, 96, 128, 160, 192, or 256. The default is 128.")
        var bitrate: Int?
        @Flag(help: "Fold the mix to one channel.") var mono = false
        @Option(help: "The file rate in Hz: 44100 or 48000. The default is the session rate.") var rate: Int?
        @Option(help: "Normalize to a loudness target: podcast, speech, ebu, or atsc. The default is none.")
        var loudness: String?
        @Option(help: "The name of the stored preset that this command renames to the name.") var rename: String?

        func validate() throws { _ = try edit() }

        private func edit() throws(ValidationError) -> PresetWork.Edit {
            do throws(ToolError) {
                return try PresetWork.set(
                    name: name, format: format, bits: bits, bitrate: bitrate, mono: mono, rate: rate,
                    loudness: loudness, rename: rename, spelling: .cli)
            } catch {
                throw ValidationError(error.message)
            }
        }

        func run() throws {
            let edit = try edit()
            try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try edit(&session)
            }
        }
    }

    struct RemovePreset: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove", abstract: "Remove an export preset of the session.",
            discussion: "Exit 1, with no change, when the session does not store a preset of this name.")

        @OptionGroup var package: PackageArgument
        @Argument(help: "The preset name.") var name: String

        func validate() throws { _ = try edit() }

        private func edit() throws(ValidationError) -> PresetWork.Edit {
            do throws(ToolError) { return try PresetWork.remove(name: name) } catch {
                throw ValidationError(error.message)
            }
        }

        func run() throws {
            let edit = try edit()
            try editPackage(package, ripple: false, touchesClips: false) { session throws(SessionError) in
                try edit(&session)
            }
        }
    }
}
