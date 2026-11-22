import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

/// `dirigible import-session`: the session import of the app (decision 0075).
struct ImportSessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-session",
        abstract: "Import the tracks of another session package.",
        discussion: """
            Each track of the source becomes a new last track with its name, layout, gain, role, mute, follow \
            flag, and voice match; solo and the input route stay off. A name that a track already has gets the \
            source session name in parentheses, or a number. A track with an app route imports muted: it \
            repeats the voice of the other side. The clips keep their positions plus --at, in frames of this \
            session; a negative --at drops the head of the source. Each file that a clip names is copied into \
            Clips/ under a new file ID, and converted at another sample rate. With --markers, the markers and \
            chapters come too, with no chapter image. The source package does not change. The new track IDs go \
            to stdout, one per line. Exit 64 when --at is outside -2^40...2^40. Exit 1 when the source is this \
            session, has no clip after --at, or a clip lands after frame 2^40. Exit 2 when a package cannot be \
            read or written, is locked, has a take that is not finalized, has a sample rate outside \
            8000...384000 Hz, has a named file that is a link or not a plain file, or the disk has too little \
            free space.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The session package to import from.") var source: String
    @Option(parsing: .unconditional, help: "The offset of the source timeline, in frames of this session.") var at = 0
    @Flag(help: "Also import the markers and chapters.") var markers = false

    func run() throws {
        let work = ImportSessionWork(source: source, at: at, markers: markers)
        let tracks = try editPackage(package, ripple: false, refused: failure) {
            session, lock throws(ImportSessionWork.Failure) in
            try work.run(&session, lock: lock, package: package.url)
        }
        for track in tracks { print(track) }
    }

    /// The error line and the exit code of an import that changed nothing.
    func failure(_ error: ImportSessionWork.Failure) -> ExitCode {
        fail(error.message(source: source, package: package.path), code: error.exitCode)
    }
}
