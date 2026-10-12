import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation
import os

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
        let interrupt = cancelOnInterrupt()
        defer { interrupt.source.cancel() }
        let faults: [FileID: MediaFault]
        do {
            faults = try exportMix(
                session, source: source, options: .render, to: output, package: { package.url },
                isCancelled: interrupt.isCancelled
            ).faults
        } catch .rateNotSupported(let rate) {
            throw fail("cannot write \(out) at \(rate) Hz.", code: packageError)
        } catch {
            throw failure(error, out: out, noun: "render")
        }
        warn(faults, in: session)
        warnUnheard(session, source: source)
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

/// The exit of a failed or cancelled render or export. `noun` is "render" or "export". The
/// caller gives the message of `.rateNotSupported`.
func failure(_ error: ExportError, out: String, noun: String) -> ExitCode {
    // Control-C: the exit status of the default action, with no message.
    guard let message = failureMessage(error, out: out, noun: noun) else { return ExitCode(128 + SIGINT) }
    return fail(message, code: packageError)
}

/// The message of a failed render or export, nil for a cancel. The switch has no `default`, so a
/// new error case does not compile until it has a message.
func failureMessage(_ error: ExportError, out: String, noun: String) -> String? {
    switch error {
    case .cancelled: nil
    case .exists: "\(out) exists."
    case .chapterImageExists(let path): "\(path) exists."
    case .writeFailed(let status): "cannot write \(out) (status \(status))."
    case .openFailed(let code): "cannot open the audio files: \(String(cString: strerror(code)))."
    case .moveFailed(let code): "cannot move the \(noun) to \(out): \(String(cString: strerror(code)))."
    case .rateNotSupported(let rate): "cannot write \(out) at \(rate) Hz."
    case .diskFull: "cannot write \(out): the disk is full."
    case .packageUnavailable: "cannot read the package."
    case .artworkMissing(let file):
        "the artwork file \(file) is not in the package, or it is not downloaded. Set the artwork again with "
            + "`dirigible episode set --artwork <image> <package>`, or remove it with `--artwork \"\"`."
    case .chapterImageMissing(let chapter, _):
        "the image file of chapter \"\(chapter.name)\" at \(chapter.position) is not in the package, or it is "
            + "not downloaded. Set the image again with `dirigible marker set --id \(chapter.id) --image <image> "
            + "<package>`, or remove it with `--image \"\"`."
    case .tooManyChapters(let count):
        "the range has \(count) chapters, and an MP3 file holds at most \(maximumChapters). Remove chapters, "
            + "or export a smaller range."
    case .tagTooLarge:
        "the ID3 tag of \(out) is over \(maximumTagSize) bytes. Use a smaller artwork file or shorter notes."
    case .chaptersTooLong:
        "an MP3 file with chapters holds at most \(maximumChapterMilliseconds) ms (about 49.7 days). Export a "
            + "shorter range."
    }
}

/// One warning line on stderr for each chapter that a file leaves out, in `export` and in
/// `chapters export`. Only an audio file has an end of the audio: pass `pastEnd` false for a
/// chapters file (code gate item E2).
func warnDropped(_ chapters: [Marker], pastEnd: Bool) {
    let reason = pastEnd ? ", or at or after the end of the audio" : ""
    for chapter in chapters {
        let line =
            "Warning: chapter \"\(chapter.name)\" at \(chapter.position) starts at the time of another chapter"
            + "\(reason); the file leaves it out.\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
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

/// One warning line on stderr when a track of the source is not heard (decision 0039), or no
/// track is: then the file is silent.
func warnUnheard(_ session: Session, source: ExportSource) {
    let unheard = session.unheardCount(in: source.tracks)
    guard unheard > 0 else { return }
    let line =
        session.heardTracks(in: source.tracks).isEmpty
        ? "no track is heard; the file is silent."
        : unheard == 1
            ? "1 track is muted or not soloed and is not in the export."
            : "\(unheard) tracks are muted or not soloed and are not in the export."
    FileHandle.standardError.write(Data("Warning: \(line)\n".utf8))
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
