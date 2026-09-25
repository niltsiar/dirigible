import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the session mix to a 32-bit float stereo CAF file at the session rate.",
        discussion: """
            Exit 2 when the package cannot be read, the output path exists, or the write fails; a failed \
            render leaves no output file. A missing or short audio file renders as silence, with one warning \
            line on stderr, and exit 0.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file. It must not exist.") var out: String
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?

    func run() throws {
        let session = try readPackage(package)
        let end = to ?? session.end.count
        guard end > from, let source = ExportSource(range: Frames(from)..<Frames(end)) else {
            throw ValidationError(
                "The range must be 0 or more, with --to more than --from; the session end is \(session.end).")
        }
        let output = URL(filePath: out)
        let interrupt = removeLeftoversOnInterrupt(of: output)
        defer { interrupt.cancel() }
        let faults: [FileID: MediaFault]
        do {
            faults = try exportMix(session, source: source, options: .render, to: output, package: { package.url })
        } catch .rateNotSupported(let rate) {
            throw fail("cannot write \(out) at \(rate) Hz.", code: packageError)
        } catch {
            throw failure(error, out: out, noun: "render")
        }
        warn(faults, in: session)
    }
}

/// Control-C: removes the temporary file of an export to `output`, then exits as the default
/// action does. Cancel the source at the end.
func removeLeftoversOnInterrupt(of output: URL) -> DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler {
        removeExportLeftovers(of: output)
        Foundation.exit(128 + SIGINT)
    }
    interrupt.resume()
    return interrupt
}

/// The exit of a failed render or export. `noun` is "render" or "export". The switch has no
/// `default`, so a new error case does not compile until it has a message. The caller gives the
/// message of `.rateNotSupported`.
func failure(_ error: ExportError, out: String, noun: String) -> ExitCode {
    let message =
        switch error {
        case .exists: "\(out) exists."
        case .writeFailed(let status): "cannot write \(out) (status \(status))."
        case .openFailed(let code): "cannot open the audio files: \(String(cString: strerror(code)))."
        case .moveFailed(let code): "cannot move the \(noun) to \(out): \(String(cString: strerror(code)))."
        case .rateNotSupported(let rate): "cannot write \(out) at \(rate) Hz."
        case .diskFull: "cannot write \(out): the disk is full."
        case .packageUnavailable: "cannot read the package."
        case .cancelled: "the \(noun) was cancelled."
        }
    return fail(message, code: packageError)
}

/// One warning line on stderr for each file that rendered as silence.
func warn(_ faults: [FileID: MediaFault], in session: Session) {
    for (id, fault) in faults.sorted(by: { $0.key < $1.key }) {
        FileHandle.standardError.write(
            Data(
                "Warning: file \(id) \(path(of: id, in: session)) \(describe(fault)); its clips render as silence.\n"
                    .utf8))
    }
}

/// The pool path of a file, quoted.
func path(of id: FileID, in session: Session) -> String {
    session.files[id].map { String(reflecting: $0.path) } ?? "?"
}

/// The media state of a file in words: "is missing", "has 5000 frames", or "cannot be read".
func describe(_ fault: MediaFault) -> String {
    switch fault {
    case .missing: "is missing"
    case .short(let frames): "has only \(frames) frames"
    case .unreadable: "cannot be read"
    }
}
