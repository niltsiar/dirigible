import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct ExportStemsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-stems",
        abstract: "Export one file for each heard track or role, all from the same start, into a new folder.",
        discussion: """
            Each file has the range length and starts at the range start, so the files line up at 0 in \
            another app. With --by track, each heard track gets the file <NN> <track name>; with --by role, \
            each role of a heard track gets Dialogue, Music, or Effects, and the tracks with no role get \
            No Role. A muted track, a track that is not soloed while another is, and a stem with no clip in \
            the range get no file, and a warning names them. When nothing clips, the files add up to the \
            mix: a warning names each file over 0 dBFS, and one line says when the mix is over. Stdout has \
            one line for each file: the file name and the track IDs, separated by tabs. The folder appears \
            whole or not at all: Control-C or a failure leaves no folder and no stem (exit 130 or 2). Exit \
            64 for a usage error, also when --out is in a .dirigible package or its folder name is over \
            \(stemFolderNameLimit) bytes. Exit 2 when the package cannot be read, --out exists, a file in \
            the range is missing, short, or unreadable (unless --allow-missing), the volume has too little \
            free space, or the write fails. Exit 1 when no stem has a clip in the range; no folder is made.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The new folder of the files. It must not exist.") var out: String
    @Option(help: "One file for each track or each role: track or role. The default is track.") var by: String?
    @Option(help: "The file format: wav or flac. The default is wav.") var format: String?
    @Option(help: "The bit depth: 16 or 24. The default is 24.") var bits: Int?
    @Flag(help: "Fold each file to one channel: 0.5 x (L + R).") var mono = false
    @Option(help: "The file rate in Hz: 44100 or 48000. The default is the session rate.") var rate: Int?
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?
    @Option(help: "A track of the set. Repeat it for more tracks. The default is every track.")
    var track: [String] = []
    @Flag(help: "Export the clips of a missing, short, or unreadable file as silence, with a warning.")
    var allowMissing = false

    func validate() throws { _ = try work() }

    /// The work that the arguments give, or a usage error.
    func work() throws(ValidationError) -> StemsWork {
        do throws(ToolError) {
            return try StemsWork(
                out: out, by: by, format: format, bits: bits, mono: mono, rate: rate, from: from, to: to,
                tracks: track.map { TrackID($0) }, allowMissing: allowMissing, spelling: .cli)
        } catch {
            throw ValidationError(error.message)
        }
    }

    func run() throws {
        let work = try work()
        let session = try readPackage(package)
        let source: ExportSource
        do { source = try work.source(in: session) } catch { throw ValidationError(error.message) }
        do { try work.checkFiles(session, package: package.url, source: source) } catch {
            throw fail(error.message, code: packageError)
        }
        let interrupt = cancelOnInterrupt()
        defer { interrupt.source.cancel() }
        let result: StemsResult
        do {
            result = try work.export(session, source: source, package: package.url, isCancelled: interrupt.isCancelled)
        } catch {
            guard let message = work.message(error) else { throw ExitCode(128 + SIGINT) }
            guard case .noStem = error else { throw fail(message, code: packageError) }
            throw fail(message, code: editRefused)
        }
        let lines: (stdout: [String], stderr: [String])
        do { lines = try work.lines(of: result, session: session, source: source) } catch {
            throw fail(error.message, code: packageError)
        }
        for line in lines.stdout { print(line) }
        warn(lines.stderr)
    }
}
