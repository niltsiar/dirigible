import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// `dirigible import`: the file import of the app (decision 0040).
struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import an audio file into a track.",
        discussion: """
            The formats are WAV, AIFF, FLAC, MP3, and M4A. The command copies the file into Clips/ as a \
            24-bit WAV at the session rate and places it as a clip at --at on --track. When a file of the \
            session has the same bytes as that WAV, the clip uses that file, and Clips/ gets no copy. The clip \
            overwrites the clips under it. With no --track, the clip goes on a new last track that has \
            the name and the layout of the file. A stereo file on a mono track becomes 0.5 L + 0.5 R; a \
            mono file on a stereo track goes to both channels. Then the clip gets the gain of Auto \
            Level: -16 LUFS for a stereo track and -19 LUFS for a mono track. With --no-level, the clip \
            keeps the gain of the conversion: 0 dB, or the gain that gives back the level of a file \
            with a peak over full scale. With --db, the clip gets that gain, and no level runs. \
            --id gives the clip ID; the file ID and the WAV keep the file name. --offset and --length \
            are frames of the made WAV at the session rate, so the clip takes a part of the file; a \
            --length past the end of the WAV stops at its end. The level measures that part. \
            --fade-in and --fade-out set the fades of the clip. The clip ID goes to stdout. Exit 1 \
            when the track is unknown, --at is negative, --id is used, the range or the fades are not \
            inside the made WAV, or the file does not read, is not audio, or has more than 2 \
            channels. Exit 2 when the package cannot be read or written, is locked, has a take that \
            is not finalized, or has too little free disk space.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The audio file to import.") var file: String
    @Option(help: "The ID of the track. The default is a new track.") var track: String?
    @Option(parsing: .unconditional, help: "The timeline frame of the clip start.") var at = 0
    @Flag(help: "Keep the gain of the conversion: no auto level.") var noLevel = false
    @Option(help: "The clip ID. The default is the file name with no extension.") var id: String?
    @Option(parsing: .unconditional, help: "The first clip frame in the made WAV, at the session rate.")
    var offset = 0
    @Option(parsing: .unconditional, help: "The clip length in frames of the made WAV. The default is the rest.")
    var length: Int?
    @Option(parsing: .unconditional, help: "The clip gain in dB. No auto level runs.", transform: parseGain)
    var db: Gain?
    @Option(parsing: .unconditional, help: "The fade-in length in frames.") var fadeIn = 0
    @Option(parsing: .unconditional, help: "The fade-out length in frames.") var fadeOut = 0

    func validate() throws {
        guard EditRules.importRange(offset: offset, length: length) != nil else {
            throw ValidationError("--offset is a frame in 0...2^40, and --length is a length in 1...2^40.")
        }
        guard Fades(fadeIn: Frames(fadeIn), fadeOut: Frames(fadeOut)) != nil else {
            throw ValidationError("--fade-in and --fade-out are lengths in 0...2^40.")
        }
    }

    /// The target of the options, after `validate()`.
    var target: ImportTarget {
        ImportTarget(
            track: track.map { TrackID($0) }, start: Frames(at), clip: id.map { ClipID($0) }, offset: Frames(offset),
            length: length.map { Frames($0) }, gain: db, fades: Fades(fadeIn: Frames(fadeIn), fadeOut: Frames(fadeOut))!
        )
    }

    func run() throws {
        let clip = try editPackage(package, ripple: false, refused: failure) {
            session, lock throws(ImportError) -> ClipID in
            let imported = try importAudio(
                URL(filePath: file), to: target, of: session, in: package.url, level: !noLevel,
                freeBytes: { lock.freeBytes() })
            session = imported.session
            return imported.clip
        }
        print(clip)
    }

    /// The error line and the exit code of an import that changed nothing.
    func failure(_ error: ImportError) -> ExitCode {
        let message = ImportWork.message(error, file: file, package: package.path)
        return switch error {
        case .notAudio, .notDownloaded, .tooManyChannels, .unreadable, .session: fail(message, code: editRefused)
        case .space, .write, .cancelled: fail(message, code: packageError)
        }
    }
}
