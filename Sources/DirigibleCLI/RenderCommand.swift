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
        let session = try readPackage(package)
        let end = to ?? session.end.count
        guard end > from, let source = ExportSource(range: Frames(from)..<Frames(end)) else {
            throw ValidationError(ExportText.rangeMessage(end: session.end, spelling: .cli))
        }
        let output = URL(filePath: out)
        let interrupt = cancelOnInterrupt()
        defer { interrupt.source.cancel() }
        let faults: [FileID: MediaFault]
        do {
            faults = try exportMix(
                session, source: source, options: .render, to: output, package: { package.url },
                isCancelled: interrupt.isCancelled
            ).faults
        } catch {
            throw failure(error, out: out, noun: "render")
        }
        warn(ExportText.faultLines(faults, in: session) + ExportText.unheardLines(session, source: source))
    }
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

/// The exit of a failed or cancelled render or export. `noun` is "render", "export", or "chapters file".
func failure(_ error: ExportError, out: String, noun: String) -> ExitCode {
    // Control-C: the exit status of the default action, with no message.
    guard let message = ExportText.failureMessage(error, out: out, noun: noun, spelling: .cli) else {
        return ExitCode(128 + SIGINT)
    }
    return fail(message, code: packageError)
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
