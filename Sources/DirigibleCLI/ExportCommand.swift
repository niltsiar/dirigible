import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export the session mix to WAV, AAC (.m4a), MP3, or FLAC.",
        discussion: """
            The extension of --out gives the format: .wav, .m4a, .mp3, or .flac. Exit 2 when the package cannot \
            be read, the output path exists (unless --replace), a file in the range is missing, short, or \
            unreadable (unless --allow-missing), or the write fails; a failed export leaves no output file \
            and the old file does not change. A file that the check finds whole but the export cannot read \
            also gives exit 2 (unless --allow-missing); then the output file has its clips as silence. \
            With --loudness, the export measures the mix, applies one gain to the target, and limits the \
            true peak to -1 dBTP. Then it prints one line, for example "loudness -16.0 LUFS, true peak \
            -1.2 dBTP, gain +3.4 dB"; "none" means no measurement, and the gain is then 0 dB. The limit \
            and the printed values are at the session rate: a --rate change can add about 0.3 dB of true \
            peak. A 16-bit export has TPDF dither. AAC takes a rate of 48000 Hz or less; MP3 takes 32000, \
            44100, or 48000 Hz. An MP3 decodes up to 0.45 dB lower than the printed loudness: LAME scales \
            its input. An .m4a gets the chapter markers of the range as a chapter track, and an .mp3 gets \
            them as ID3 CHAP frames, at most 255. Each chapter keeps its URL and its image. A chapter at \
            the time of the chapter before it is not in the file, and a warning names it. An .m4a with a \
            chapter image, a chapter with none, and no episode artwork gets no chapter images, and a \
            warning says so.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file: .wav, .m4a, .mp3, or .flac.") var out: String
    @Option(help: "The bit depth of WAV and FLAC: 16 or 24. The default is 24.") var bits: Int?
    @Option(help: "The AAC or MP3 bit rate in kbit/s: 64, 96, 128, 160, 192, or 256. The default is 128.")
    var bitrate: Int?
    @Flag(help: "Fold the mix to one channel: 0.5 x (L + R).") var mono = false
    @Option(help: "The file rate in Hz: 44100 or 48000. The default is the session rate.") var rate: Int?
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?
    @Option(help: "A track to export. Repeat it for more tracks. The default is every track.")
    var track: [String] = []
    @Option(
        help:
            "Normalize to a loudness target: podcast (-16), speech (-18), ebu (-23), or atsc (-24) LUFS; --mono is 3 LU lower."
    )
    var loudness: String?
    @Flag(help: "Replace the output file when it exists.") var replace = false
    @Flag(help: "Export the clips of a missing, short, or unreadable file as silence, with a warning.")
    var allowMissing = false

    func validate() throws {
        _ = try options()
    }

    /// The options that the arguments give, or a usage error.
    func options() throws(ValidationError) -> ExportOptions {
        do throws(ToolError) {
            return try ExportText.options(
                out: out, bits: bits, bitrate: bitrate, mono: mono, rate: rate, loudness: loudness)
        } catch {
            throw ValidationError(error.message)
        }
    }

    func run() throws {
        let options = try options()
        let session = try readPackage(package)
        let tracks = track.map { TrackID($0) }
        if let unknown = tracks.first(where: { session.track($0) == nil }) {
            throw ValidationError(ExportText.noTrackMessage(unknown))
        }
        let end = to ?? session.end.count
        guard end > from,
            let source = ExportSource(range: Frames(from)..<Frames(end), tracks: tracks.isEmpty ? nil : Set(tracks))
        else {
            throw ValidationError(ExportText.rangeMessage(end: session.end))
        }
        let faults: [FileID: MediaFault]
        do {
            faults = try checkMedia(session, package: package.url, source: source)
        } catch {
            throw fail(mediaCheckMessage(error), code: packageError)
        }
        guard faults.isEmpty || allowMissing else {
            throw fail(ExportText.faultMessage(faults, in: session), code: packageError)
        }
        let output = URL(filePath: out)
        // The item at --out now is the one that --replace confirms.
        let confirmed = replace ? ConfirmedFile(at: output) : nil
        let interrupt = cancelOnInterrupt()
        defer { interrupt.source.cancel() }
        let result: ExportResult
        do {
            result = try exportMix(
                session, source: source, options: options, to: output, replacing: confirmed, package: { package.url },
                isCancelled: interrupt.isCancelled)
        } catch .rateNotSupported(let rate) {
            throw fail(ExportText.rateMessage(out: out, rate: rate), code: packageError)
        } catch {
            throw failure(error, out: out, noun: "export")
        }
        // The check found no fault, or --allow-missing: a fault of the export itself is a file that
        // went bad after the check. The file is written, so the error says so.
        let read = result.faults
        guard read.isEmpty || allowMissing else {
            throw fail(ExportText.readFaultMessage(read, in: session, out: out), code: packageError)
        }
        warn(ExportText.warnings(of: result, session: session, source: source, output: output))
        if let report = result.loudness { print(ExportText.loudnessLine(report)) }
    }
}
