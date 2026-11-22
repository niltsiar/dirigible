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
            -1 dBTP. When the limiter lowers the level, the export raises the gain until the limited \
            mix is within 0.1 LU of the target. If the encoder or the resampler changes the file (AAC, \
            MP3, or a --rate other than the session rate), the export decodes the file, as macOS does, \
            and writes it again when it decodes over -1 dBTP or more than 0.2 LU off the target. The \
            search stops after 4 trial renders in a round and 2 rewrites, so it can end short of the \
            target. Then it prints one line, for example "loudness -16.0 LUFS, true peak -1.2 dBTP, gain \
            +3.4 dB", with the values of the file; "none" means no measurement, and the gain is then \
            0 dB. A 16-bit export has TPDF dither. AAC takes a rate of 48000 Hz or less; MP3 takes \
            32000, 44100, or 48000 Hz. An .m4a gets the chapter markers of the range as a chapter \
            track, and an .mp3 gets them as ID3 CHAP frames, at most 255. Each chapter keeps its URL \
            and its image. A chapter at the time of the chapter before it is not in the file, and a \
            warning names it. An .m4a with a chapter image, a chapter with none, and no episode \
            artwork gets no chapter images, and a warning says so. With --split chapters or --split \
            markers, the export writes one file for each part of the range, named <prefix>-<NN>-<title> \
            from the file name of --out, in the folder of --out, and prints the path of each file; with \
            --loudness, each line adds a tab and the loudness line of its file. Each file has its own \
            gain. The part before the first point is number 00. A point at the millisecond of the point \
            before it, or of the range end, has no file of its own, and a warning names it. Exit 1 when \
            the range has no chapter (or no marker). Exit 2, before any file is written, when a file is at a target (unless \
            --replace). Control-C or a failed file stops the set: the files before it stay, and stderr \
            names the files that were not written (exit 130 or 2). A set with files that only the export \
            found bad prints the path of each file, then names each file with such a fault (exit 2, unless \
            --allow-missing). After a set, stderr names the older \
            files of the prefix; Dirigible keeps them. The file <prefix>.<ext> is never written. \
            With --preset, --out is <folder>/<prefix>, with no file extension, and the export writes one \
            file for each preset, named <prefix>.<ext>, or <prefix>-<preset>.<ext> when two presets have \
            one extension. A preset is a preset of the session or a built-in preset: master (WAV, 24 bit, \
            session rate) or podcast (MP3, mono, 44100 Hz, -19 LUFS). A session preset wins over a \
            built-in of the same name. Each file has the options of its preset, so --preset cannot go with \
            --bits, --bitrate, --mono, --rate, --loudness, or --split (exit 64, also for an unknown \
            preset). It prints the path of each file, and with a loudness target a tab and the loudness \
            line. Exit 2, before any file is written, when two presets give one file name, or a file is \
            at a target (unless --replace). The older files of the prefix stay.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file: .wav, .m4a, .mp3, or .flac. With --preset: <folder>/<prefix>.") var out: String
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
    @Option(help: "Write one file for each chapter or marker of the range: chapters or markers.") var split: String?
    @Option(
        help:
            "Write one file for each preset: a session preset or master or podcast. Repeat it for more presets. --out is then <folder>/<prefix>."
    )
    var preset: [String] = []

    func validate() throws {
        guard preset.isEmpty else {
            _ = try presetWork()
            return
        }
        _ = try options()
        _ = try splitKind()
    }

    /// The work of `--preset`, or a usage error: no option that a preset sets, and an `--out` that
    /// is a folder and a prefix.
    func presetWork() throws(ValidationError) -> ExportWork {
        let given = [
            ("bits", bits != nil), ("bitrate", bitrate != nil), ("mono", mono), ("rate", rate != nil),
            ("loudness", loudness != nil), ("split", split != nil),
        ].filter { $0.1 }.map { $0.0 }
        do throws(ToolError) {
            try ExportText.checkPresets(out: out, given: given, spelling: .cli)
        } catch {
            throw ValidationError(error.message)
        }
        return ExportWork(
            presets: preset, out: out, from: from, to: to, tracks: track.map { TrackID($0) }, replace: replace,
            allowMissing: allowMissing, spelling: .cli)
    }

    /// The split that `--split` gives, or a usage error.
    func splitKind() throws(ValidationError) -> SplitKind? {
        do throws(ToolError) { return try ExportText.splitKind(split, spelling: .cli) } catch {
            throw ValidationError(error.message)
        }
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
        if !preset.isEmpty {
            try runPresets(try presetWork(), package: package.url, session: try readPackage(package))
            return
        }
        let kind = try splitKind()
        let work = ExportWork(
            out: out, options: try options(), from: from, to: to, tracks: track.map { TrackID($0) }, replace: replace,
            allowMissing: allowMissing, spelling: .cli, split: kind)
        let session = try readPackage(package)
        if let kind {
            try runSet(work, by: kind, package: package.url, session: session)
        } else {
            try runWork(work, package: package.url, session: session)
        }
    }
}

/// The steps of `export --split` from `ExportWork`: the exit codes of `runWork`, and exit 1 for a
/// range with no split point. A stop or a failure prints the files on disk and the stop line.
func runSet(_ work: ExportWork, by kind: SplitKind, package: URL, session: Session) throws {
    let source: ExportSource
    do { source = try work.source(in: session) } catch { throw ValidationError(error.message) }
    do { try work.checkFiles(session, package: package, source: source) } catch {
        throw fail(error.message, code: packageError)
    }
    let replacing: [URL: ConfirmedFile]
    do { replacing = try work.splitConfirmations(session, source: source, by: kind) } catch {
        throw fail(error.message, code: error.isNoPoint ? editRefused : packageError)
    }
    let interrupt = cancelOnInterrupt()
    defer { interrupt.source.cancel() }
    let result: ExportPartsResult
    do {
        result = try work.exportSet(
            session, source: source, by: kind, replacing: replacing, package: package,
            isCancelled: interrupt.isCancelled)
    } catch {
        guard case .stopped(let stop) = error else { throw fail(work.setRefusal(error), code: packageError) }
        let lines = work.stopLines(stop)
        for line in lines.stdout { print(line) }
        warn(lines.stderr)
        throw ExitCode(stop.error == .cancelled ? 128 + SIGINT : packageError)
    }
    let lines: (stdout: [String], stderr: [String])
    do {
        lines = try work.setLines(
            of: result, session: session, source: source, old: work.oldFiles(besides: result.files))
    } catch {
        for line in error.stdout { print(line) }
        warn(error.warnings + error.refusals.map { "Error: " + $0 })
        throw ExitCode(packageError)
    }
    warn(lines.stderr)
    for line in lines.stdout { print(line) }
}

/// The steps of `export --preset` from `ExportWork`: exit 64 for an unknown preset, and exit 2, in this
/// order, for a rate that a preset cannot write, a refused file, two presets of one file name, a file at
/// a target, or a failed job. A stop or a failure prints the files on disk and the stop line.
func runPresets(_ work: ExportWork, package: URL, session: Session) throws {
    let source: ExportSource
    do { source = try work.source(in: session) } catch { throw ValidationError(error.message) }
    let list: [PresetEntry]
    do { list = try work.presetList(in: session) } catch { throw ValidationError(error.message) }
    do {
        try work.checkRates(list, in: session)
        try work.checkFiles(session, package: package, source: source)
    } catch {
        throw fail(error.message, code: packageError)
    }
    let replacing: [URL: ConfirmedFile]
    do { replacing = try work.presetConfirmations(list, sessionRate: session.sampleRate) } catch {
        throw fail(work.presetRefusal(error), code: packageError)
    }
    let interrupt = cancelOnInterrupt()
    defer { interrupt.source.cancel() }
    let files: [ExportedPreset]
    do {
        files = try work.exportPresetSet(
            session, source: source, list: list, replacing: replacing, package: package,
            isCancelled: interrupt.isCancelled)
    } catch {
        guard case .stopped(let stop) = error else { throw fail(work.presetRefusal(error), code: packageError) }
        let lines = work.presetStopLines(stop)
        for line in lines.stdout { print(line) }
        warn(lines.stderr)
        throw ExitCode(stop.error == .cancelled ? 128 + SIGINT : packageError)
    }
    let lines: (stdout: [String], stderr: [String])
    do {
        lines = try work.presetLines(of: files, list: list, session: session, source: source)
    } catch {
        for line in error.stdout { print(line) }
        warn(error.warnings + error.refusals.map { "Error: " + $0 })
        throw ExitCode(packageError)
    }
    warn(lines.stderr)
    for line in lines.stdout { print(line) }
}
