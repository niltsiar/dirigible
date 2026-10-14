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
            24-bit WAV at the session rate and places it as a clip at --at on --track. The clip \
            overwrites the clips under it. With no --track, the clip goes on a new last track that has \
            the name and the layout of the file. A stereo file on a mono track becomes 0.5 L + 0.5 R; a \
            mono file on a stereo track goes to both channels. Then the clip gets the gain of Auto \
            Level: -16 LUFS for a stereo track and -19 LUFS for a mono track. With --no-level, the clip \
            keeps the gain of the conversion: 0 dB, or the gain that gives back the level of a file \
            with a peak over full scale. The clip ID goes to stdout. Exit 1 when the track is unknown, \
            --at is negative, or the file does not read, is not audio, or has more than 2 channels. \
            Exit 2 when the package cannot be read or written, is locked, has a take that is not \
            finalized, or has too little free disk space.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The audio file to import.") var file: String
    @Option(help: "The ID of the track. The default is a new track.") var track: String?
    @Option(parsing: .unconditional, help: "The timeline frame of the clip start.") var at = 0
    @Flag(help: "Keep the gain of the conversion: no auto level.") var noLevel = false

    func run() throws {
        let clip = try editPackage(package, refused: failure) { session, lock throws(ImportError) -> ClipID in
            let imported = try importAudio(
                URL(filePath: file), to: ImportTarget(track: track.map { TrackID($0) }, start: Frames(at)),
                of: session, in: package.url, level: !noLevel, freeBytes: { lock.freeBytes() })
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
