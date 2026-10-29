import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

extension ClipCommand {
    struct Denoise: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Reduce the noise or remove the hum in clips and write one line for each clip.",
            discussion: """
                The command renders each run of clips of one file through the noise reduction of macOS into \
                a new 24-bit WAV in Clips/, with a 10 s handle on each side of the run, and moves the clips \
                onto it. The source file stays. On a clip that this version reduced, the command renders \
                again from the source of the reduction, and the same amount prints "Nothing to change." and \
                writes nothing. A clip that an older version reduced has no link, so the command reduces it \
                again. --reduction is a whole number of dB from 1 to 30; the \
                default is 12. --hum 50 or --hum 60 also removes mains hum at that frequency and its \
                harmonics, before the noise reduction. --no-noise with --hum removes only the hum, and it \
                also removes a stored noise reduction of the clip: the new file ends in HR, and the clip \
                can be on any track. A line has the clip and its new file, \
                with a tab between them. With the noise reduction on, the command refuses a clip on a music \
                or effects track. Exit 64 when --no-noise has no --hum or comes with --reduction. Exit 1 when a clip is unknown, a clip is on a \
                music or effects track, or the noise reduction does not load. Exit 2 when the package cannot \
                be read or written, is locked, has a take that is not finalized, has a source WAV that is \
                missing or unreadable, has too little free disk space, or the render fails. Control-C \
                leaves the package as it was and exits 130.
                """)

        @OptionGroup var package: PackageArgument
        @Argument(help: "A clip. For the noise reduction its track has no role or the dialogue role. Give one or more.")
        var clips: [String] = []
        @Option(
            parsing: .unconditional, help: "The noise reduction in dB, 1 to 30. The default is 12.",
            transform: parseReduction)
        var reduction: NoiseReduction?
        @Option(
            parsing: .unconditional, help: "Remove mains hum at 50 or 60 Hz and its harmonics.",
            transform: parseHum)
        var hum: Hum?
        @Flag(
            name: .customLong("no-noise"),
            help: "Do not reduce the noise, and remove a stored noise reduction. Needs --hum."
        )
        var noNoise = false

        func validate() throws {
            guard !clips.isEmpty else { throw ValidationError("Give one or more clips.") }
            _ = try request()
        }

        /// The request of the options. A combination that `ClipRenderWork.request` refuses exits 64.
        private func request() throws -> ClipRenderRequest {
            do throws(ClipRenderWork.Refusal) {
                return try ClipRenderWork.request(noise: !noNoise, reduction: reduction, hum: hum)
            } catch {
                throw ValidationError(error.rawValue)
            }
        }

        func run() throws {
            try runClipRender(ClipRenderWork(clips: clips.map { ClipID($0) }, request: try request()), in: package)
        }
    }
}

/// Renders `work` in the package and prints one line for each moved clip. A failure prints its error
/// line and exits with its code.
func runClipRender(_ work: ClipRenderWork, in package: PackageArgument) throws {
    let interrupt = cancelOnInterrupt()
    defer { interrupt.source.cancel() }
    let moved = try editPackage(package, ripple: false, writeUnchanged: false, refused: clipRenderFailure) {
        session, lock throws(ClipRenderError) in
        try work.render(
            &session, in: package.url, lock: lock, progress: { _ in }, isCancelled: interrupt.isCancelled)
    }
    for line in ClipRenderWork.lines(moved) { print(line) }
}

/// The error line and the exit code of a render that changed nothing. Control-C gives the status of
/// the default action, with no message.
private func clipRenderFailure(_ error: ClipRenderError) -> ExitCode {
    switch error {
    case .cancelled: ExitCode(128 + SIGINT)
    case .session, .trackRole, .mixedTreatments, .effectUnavailable, .cornerTooHigh:
        fail(error.message, code: editRefused)
    case .space, .write, .sourceUnreadable, .sourceMissing, .notDownloaded, .engine, .stillOverFullScale,
        .nonFiniteSample:
        fail(error.message, code: packageError)
    }
}

/// `NoiseReduction(decibels:)` refuses a value outside its range. A text that is not a whole number
/// is refused too.
private func parseReduction(_ text: String) throws -> NoiseReduction {
    guard let decibels = Int(text), let reduction = NoiseReduction(decibels: decibels) else {
        throw ValidationError("A reduction is \(ClipRenderWork.reductionExpected).")
    }
    return reduction
}

/// `Hum(rawValue:)` refuses a value that is not 50 or 60, and a text that is not a whole number.
private func parseHum(_ text: String) throws -> Hum {
    guard let hertz = Int(text), let hum = Hum(rawValue: hertz) else {
        throw ValidationError("A hum is \(ClipRenderWork.humExpected).")
    }
    return hum
}
