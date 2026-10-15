import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export the session mix to WAV, AAC (.m4a), MP3, or FLAC.",
        discussion: """
            The extension of --out gives the format: .wav, .m4a, .mp3, or .flac. Exit 64 when --out is in a \
            .dirigible package. Exit 2 when the package cannot \
            be read, the output path exists (unless --replace), a file in the range is missing, short, or \
            unreadable (unless --allow-missing), or the write fails; a failed export leaves no output file \
            and the old file does not change. A file that the check finds whole but the export cannot read \
            also gives exit 2 (unless --allow-missing); then the output file has its clips as silence. \
            With --loudness, the export measures the mix, sets one gain, and limits the true peak to \
            -1 dBTP. When the limiter lowers the level, the export raises the gain until the file is \
            within 0.1 LU of the target. Then it prints one line, for example "loudness -16.0 LUFS, true peak \
            -1.2 dBTP, gain +3.4 dB"; "none" means no measurement, and the gain is then 0 dB. A 16-bit export \
            has TPDF dither. AAC takes a rate of 48000 Hz or less; MP3 takes 32000, 44100, or 48000 Hz. For \
            AAC, MP3, and a --rate other than the session rate, the export decodes the file, as macOS does, \
            and the printed values are those of the decoded file; it writes the file again when the true \
            peak is over -1 dBTP or the loudness is 0.2 LU off. An .m4a gets the chapter markers of the \
            range as a chapter track, and an .mp3 gets them as ID3 CHAP frames, at most 255. Each chapter keeps its URL and its image. A chapter at \
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
                out: out, bits: bits, bitrate: bitrate, mono: mono, rate: rate, loudness: loudness, spelling: .cli)
        } catch {
            throw ValidationError(error.message)
        }
    }

    func run() throws {
        let work = ExportWork(
            out: out, options: try options(), from: from, to: to, tracks: track.map { TrackID($0) }, replace: replace,
            allowMissing: allowMissing, spelling: .cli)
        try runWork(work, package: package.url, session: try readPackage(package))
    }
}
