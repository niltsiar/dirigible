import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation
import os

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the session mix to a 32-bit float stereo CAF file at the session rate.",
        discussion: """
            Exit 64 when --out is in a .dirigible package. Exit 2 when the package cannot be read, the \
            output path exists, or the write fails; a failed \
            render leaves no output file. A missing or short audio file renders as silence, with one warning \
            line on stderr, and exit 0.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file. It must not exist.") var out: String
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?

    func validate() throws {
        try checkOutsidePackages(out)
    }

    func run() throws {
        let work = ExportWork(
            out: out, options: .render, from: from, to: to, tracks: [], replace: false, allowMissing: true,
            spelling: .cli)
        try runWork(work, package: package.url, session: try readPackage(package))
    }
}

/// The steps of `export` and `render` from `ExportWork`, with the exit codes of the command: 64
/// for a refused range or track, 2 for a refused file or a failed job.
func runWork(_ work: ExportWork, package: URL, session: Session) throws {
    let source: ExportSource
    do { source = try work.source(in: session) } catch { throw ValidationError(error.message) }
    do { try work.checkFiles(session, package: package, source: source) } catch {
        throw fail(error.message, code: packageError)
    }
    let interrupt = cancelOnInterrupt()
    defer { interrupt.source.cancel() }
    let result: ExportResult
    do {
        result = try work.export(session, source: source, package: package, isCancelled: interrupt.isCancelled)
    } catch {
        // Control-C: the exit status of the default action, with no message.
        guard let message = work.message(error) else { throw ExitCode(128 + SIGINT) }
        throw fail(message, code: packageError)
    }
    let lines: (stdout: [String], stderr: [String])
    do { lines = try work.lines(of: result, session: session, source: source) } catch {
        throw fail(error.message, code: packageError)
    }
    warn(lines.stderr)
    for line in lines.stdout { print(line) }
}

/// Control-C: the returned check becomes true, so the export cancels at its next chunk and
/// removes its temporary file; `failure` then exits as the default action does. The export
/// holds an flock on its temporary file, so a sweep here would skip it. Cancel the source at
/// the end.
func cancelOnInterrupt() -> (source: DispatchSourceSignal, isCancelled: @Sendable () -> Bool) {
    signal(SIGINT, SIG_IGN)
    let interrupted = OSAllocatedUnfairLock(initialState: false)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { interrupted.withLock { $0 = true } }
    interrupt.resume()
    return (interrupt, { interrupted.withLock { $0 } })
}

/// Refuses an `--out` inside a session package, as a usage error.
func checkOutsidePackages(_ out: String) throws(ValidationError) {
    do throws(ToolError) {
        try ExportText.checkOutsidePackages(URL(filePath: out))
    } catch {
        throw ValidationError(error.message)
    }
}

/// Writes each line on stderr, with a line break.
func warn(_ lines: [String]) {
    for line in lines { try? FileHandle.standardError.write(contentsOf: Data((line + "\n").utf8)) }
}
