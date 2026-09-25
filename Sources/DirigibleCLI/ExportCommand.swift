import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Export the session mix to WAV, AAC (.m4a), or FLAC.",
        discussion: """
            The extension of --out gives the format: .wav, .m4a, or .flac. Exit 2 when the package cannot \
            be read, the output path exists (unless --replace), a file in the range is missing, short, or \
            unreadable (unless --allow-missing), or the write fails; a failed export leaves no output file \
            and the old file does not change. A file that the check finds whole but the export cannot read \
            also gives exit 2 (unless --allow-missing); then the output file has its clips as silence.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file: .wav, .m4a, or .flac.") var out: String
    @Option(help: "The bit depth of WAV and FLAC: 16 or 24. The default is 24.") var bits: Int?
    @Option(help: "The AAC bit rate in kbit/s: 64, 96, 128, 160, 192, or 256. The default is 128.")
    var bitrate: Int?
    @Flag(help: "Fold the mix to one channel: 0.5 x (L + R).") var mono = false
    @Option(help: "The file rate in Hz: 44100 or 48000. The default is the session rate.") var rate: Int?
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?
    @Option(help: "A track to export. Repeat it for more tracks. The default is every track.")
    var track: [String] = []
    @Flag(help: "Replace the output file when it exists.") var replace = false
    @Flag(help: "Export the clips of a missing, short, or unreadable file as silence, with a warning.")
    var allowMissing = false

    func validate() throws {
        _ = try options()
    }

    /// The options that the arguments give, or a usage error.
    func options() throws(ValidationError) -> ExportOptions {
        let format: ExportFormat
        switch URL(filePath: out).pathExtension.lowercased() {
        case "wav", "flac":
            guard bitrate == nil else { throw ValidationError("--bitrate is only for .m4a.") }
            guard let depth = BitDepth(rawValue: bits ?? 24) else { throw ValidationError("--bits must be 16 or 24.") }
            format = URL(filePath: out).pathExtension.lowercased() == "wav" ? .wav(depth) : .flac(depth)
        case "m4a":
            guard bits == nil else { throw ValidationError("--bits is only for .wav and .flac.") }
            guard let rate = AACBitRate(rawValue: bitrate ?? 128) else {
                throw ValidationError("--bitrate must be 64, 96, 128, 160, 192, or 256.")
            }
            format = .aac(rate)
        default:
            throw ValidationError("--out must end in .wav, .m4a, or .flac.")
        }
        let fileRate: ExportRate
        switch rate {
        case nil: fileRate = .session
        case 44_100: fileRate = .hz44100
        case 48_000: fileRate = .hz48000
        default: throw ValidationError("--rate must be 44100 or 48000.")
        }
        return ExportOptions(format: format, layout: mono ? .mono : .stereo, rate: fileRate)
    }

    func run() throws {
        let options = try options()
        let session = try readPackage(package)
        let tracks = track.map { TrackID($0) }
        if let unknown = tracks.first(where: { session.track($0) == nil }) {
            throw ValidationError("The session has no track \(unknown).")
        }
        let end = to ?? session.end.count
        guard end > from,
            let source = ExportSource(range: Frames(from)..<Frames(end), tracks: tracks.isEmpty ? nil : Set(tracks))
        else {
            throw ValidationError(
                "The range must be 0 or more, with --to more than --from; the session end is \(session.end).")
        }
        let faults: [FileID: MediaFault]
        do {
            faults = try checkMedia(session, package: package.url, source: source)
        } catch {
            throw fail("cannot check the audio files: \(error.localizedDescription)", code: packageError)
        }
        guard faults.isEmpty || allowMissing else {
            let files = faults.sorted { $0.key < $1.key }.map {
                "file \($0.key) \(path(of: $0.key, in: session)) \(describe($0.value))"
            }
            throw fail(
                "\(files.joined(separator: "; ")). Use --allow-missing to export its clips as silence.",
                code: packageError)
        }
        let output = URL(filePath: out)
        // The item at --out now is the one that --replace confirms.
        let confirmed = replace ? ConfirmedFile(at: output) : nil
        let interrupt = cancelOnInterrupt()
        defer { interrupt.source.cancel() }
        let read: [FileID: MediaFault]
        do {
            read = try exportMix(
                session, source: source, options: options, to: output, replacing: confirmed, package: { package.url },
                isCancelled: interrupt.isCancelled)
        } catch .rateNotSupported(let rate) {
            throw fail("cannot write \(out) at \(rate) Hz. Use --rate 44100 or --rate 48000.", code: packageError)
        } catch {
            throw failure(error, out: out, noun: "export")
        }
        // The check found no fault, or --allow-missing: a fault of the export itself is a file that
        // went bad after the check. The file is written, so the error says so.
        guard read.isEmpty || allowMissing else {
            let files = read.sorted { $0.key < $1.key }.map {
                "file \($0.key) \(path(of: $0.key, in: session)) \(describe($0.value))"
            }
            throw fail(
                "\(files.joined(separator: "; ")); its clips in \(out) are silence. Use --allow-missing to accept it.",
                code: packageError)
        }
        warn(read, in: session)
    }
}
