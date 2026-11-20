import DirigibleAudio
import DirigibleCore
import Foundation

/// How a text names an option: `--allow-missing` for the command line, `allow_missing` for an
/// MCP tool (decision 0041).
package enum OptionSpelling: Sendable {
    case cli, tool

    func callAsFunction(_ key: String) -> String {
        switch self {
        case .cli: "--" + key.replacing("_", with: "-")
        case .tool: key
        }
    }
}

/// The one owner of each text of `export` and `render`: the option rules, the refusals, and the
/// warning and report lines. A command and its MCP tool call it, so both give the same text
/// (decision 0041). A line has no line break at its end.
package enum ExportText {
    /// The options that the arguments of `export` give. The refusal text names the option as the
    /// caller spells it.
    package static func options(
        out: String, bits: Int?, bitrate: Int?, mono: Bool, rate: Int?, loudness: String?, spelling o: OptionSpelling
    ) throws(ToolError) -> ExportOptions {
        try checkOutsidePackages(URL(filePath: out))
        let format: ExportFormat
        let pathExtension = URL(filePath: out).pathExtension.lowercased()
        switch pathExtension {
        case "wav", "flac":
            guard bitrate == nil else { throw ToolError("\(o("bitrate")) is only for .m4a and .mp3.") }
            let depth = try bitDepth(bits, spelling: o)
            format = pathExtension == "wav" ? .wav(depth) : .flac(depth)
        case "m4a", "mp3":
            guard bits == nil else { throw ToolError("\(o("bits")) is only for .wav and .flac.") }
            guard let rate = BitRate(rawValue: bitrate ?? 128) else {
                throw ToolError("\(o("bitrate")) must be 64, 96, 128, 160, 192, or 256.")
            }
            format = pathExtension == "m4a" ? .aac(rate) : .mp3(rate)
        default:
            throw ToolError("\(o("out")) must end in .wav, .m4a, .mp3, or .flac.")
        }
        let fileRate = try exportRate(rate, spelling: o)
        var target: LoudnessTarget?
        if let loudness {
            guard let value = LoudnessTarget(rawValue: loudness) else {
                throw ToolError("\(o("loudness")) must be podcast, speech, ebu, or atsc.")
            }
            target = value
        }
        return ExportOptions(format: format, layout: mono ? .mono : .stereo, rate: fileRate, loudness: target)
    }

    /// The bit depth of WAV and FLAC that `bits` gives: 24 for nil.
    package static func bitDepth(_ bits: Int?, spelling o: OptionSpelling) throws(ToolError) -> BitDepth {
        guard let depth = BitDepth(rawValue: bits ?? 24) else { throw ToolError("\(o("bits")) must be 16 or 24.") }
        return depth
    }

    /// The file rate that `rate` gives: the session rate for nil.
    package static func exportRate(_ rate: Int?, spelling o: OptionSpelling) throws(ToolError) -> ExportRate {
        switch rate {
        case nil: .session
        case 44_100: .hz44100
        case 48_000: .hz48000
        default: throw ToolError("\(o("rate")) must be 44100 or 48000.")
        }
    }

    /// The split kind that the `split` argument gives, nil for no split. Another word is a usage
    /// error.
    package static func splitKind(_ word: String?, spelling o: OptionSpelling) throws(ToolError) -> SplitKind? {
        guard let word else { return nil }
        guard let kind = SplitKind(rawValue: word) else {
            throw ToolError("\(o("split")) must be chapters or markers.")
        }
        return kind
    }

    /// The refusal of an output file inside a session package: a write there can replace a take.
    package static let insidePackageMessage = "The output file must be outside the session package."

    /// Refuses an output file in any session package. The links of its folder resolve first, so a
    /// link into a package is refused too. The extension compares with no case, as the package
    /// name can have any case.
    package static func checkOutsidePackages(_ out: URL) throws(ToolError) {
        let folder = out.absoluteURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        if folder.pathComponents.contains(where: { ($0 as NSString).pathExtension.lowercased() == "dirigible" }) {
            throw ToolError(insidePackageMessage)
        }
    }

    package static func noTrackMessage(_ track: TrackID) -> String { "The session has no track \(track)." }

    /// The refusal of a range that is empty, below 0, or past the frame limit.
    package static func rangeMessage(end: Frames, spelling o: OptionSpelling) -> String {
        "The range must be 0 or more, with \(o("to")) more than \(o("from")); the session end is \(end)."
    }

    /// The refusal of the files that the media check finds bad before the export.
    package static func faultMessage(_ faults: [FileID: MediaFault], in session: Session, spelling o: OptionSpelling)
        -> String
    {
        "\(files(faults, in: session)). Use \(o("allow_missing")) to export its clips as silence."
    }

    /// The refusal of the files that only the export finds bad. The output file is written.
    package static func readFaultMessage(
        _ faults: [FileID: MediaFault], in session: Session, out: String, spelling o: OptionSpelling
    ) -> String {
        "\(files(faults, in: session)); its clips in \(out) are silence. Use \(o("allow_missing")) to accept it."
    }

    /// The refusal of an export rate that the format does not take.
    package static func rateMessage(out: String, rate: Int, spelling o: OptionSpelling) -> String {
        "cannot write \(out) at \(rate) Hz. Use \(o("rate")) 44100 or \(o("rate")) 48000."
    }

    /// The message of a failed render or export, nil for a cancel. `noun` is "render", "export", or
    /// "chapters file". The switch has no `default`, so a new error case does not compile until it
    /// has a message.
    package static func failureMessage(_ error: ExportError, out: String, noun: String, spelling: OptionSpelling)
        -> String?
    {
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
            "the artwork file \(file) is not in the package, or it is not downloaded. "
                + (spelling == .cli
                    ? "Set the artwork again with `dirigible episode set --artwork <image> <package>`, or remove it "
                        + "with `--artwork \"\"`."
                    : "Set the artwork again with the episode_set tool and artwork, or remove it with artwork \"\".")
        case .chapterImageMissing(let chapter, _):
            "the image file of chapter \"\(chapter.name)\" at \(chapter.position) is not in the package, or it "
                + "is not downloaded. "
                + (spelling == .cli
                    ? "Set the image again with `dirigible marker set --id \(chapter.id) --image <image> <package>`, "
                        + "or remove it with `--image \"\"`."
                    : "Set the image again with the marker_set tool, id \(chapter.id), and image, or remove it with "
                        + "image \"\".")
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

    /// The warning lines of an export, in this order: the files that rendered as silence, the
    /// tracks that are not heard, the `droppedChapters` that the file leaves out, the chapter images,
    /// and the title tag.
    package static func warnings(
        of result: ExportResult, droppedChapters: [Marker], session: Session, source: ExportSource, output: URL,
        format: ExportFormat, spelling: OptionSpelling
    ) -> [String] {
        var lines = faultLines(result.faults, in: session) + unheardLines(session, source: source)
        lines += droppedLines(droppedChapters, pastEnd: true)
        if result.chapterImagesOmitted {
            lines.append(
                "Warning: \(output.path) has no chapter images: a chapter has no image, and the episode has no "
                    + "artwork. Set the episode artwork, or an image for each chapter.")
        }
        return lines + titleLines(session, format: format, output: output, spelling: spelling)
    }

    /// True when an MP3 or M4A file of `session` has no title tag, because the episode has no title.
    /// The tag writers skip an absent title (`ID3Tag`, `M4ATags`).
    package static func lacksTitleTag(_ session: Session, format: ExportFormat) -> Bool {
        switch format {
        case .mp3, .aac: session.episode.title == nil
        case .wav, .flac, .floatCAF: false
        }
    }

    /// One warning line when `output` gets no title tag.
    package static func titleLines(_ session: Session, format: ExportFormat, output: URL, spelling: OptionSpelling)
        -> [String]
    {
        guard lacksTitleTag(session, format: format) else { return [] }
        let action =
            spelling == .cli
            ? "`dirigible episode set --title <title> <package>`" : "episode_set and title"
        return ["Warning: the episode has no title, so \(output.path) has no title tag. Set it with \(action)."]
    }

    /// One warning line for each file that rendered as silence.
    package static func faultLines(_ faults: [FileID: MediaFault], in session: Session) -> [String] {
        faults.sorted { $0.key < $1.key }.map {
            "Warning: file \($0.key) \(path(of: $0.key, in: session)) \(describe($0.value)); its clips render as "
                + "silence."
        }
    }

    /// One warning line when a track of the source is not heard (decision 0039), or no track is:
    /// then the file is silent.
    package static func unheardLines(_ session: Session, source: ExportSource) -> [String] {
        let unheard = session.unheardCount(in: source.tracks)
        guard unheard > 0 else { return [] }
        let line =
            session.heardTracks(in: source.tracks).isEmpty
            ? "no track is heard; the file is silent."
            : unheard == 1
                ? "1 track is muted or not soloed and is not in the export."
                : "\(unheard) tracks are muted or not soloed and are not in the export."
        return ["Warning: \(line)"]
    }

    /// One warning line for each chapter that a file leaves out, in `export` and in
    /// `chapters export`. Only an audio file has an end of the audio: pass `pastEnd` false for a
    /// chapters file (code gate item E2).
    package static func droppedLines(_ chapters: [Marker], pastEnd: Bool) -> [String] {
        let reason = pastEnd ? ", or at or after the end of the audio" : ""
        return chapters.map {
            "Warning: chapter \"\($0.name)\" at \($0.position) starts at the time of another chapter\(reason); "
                + "the file leaves it out."
        }
    }

    /// One warning line for each split point that has no file of its own (decision 0067): its audio is
    /// in the file before it.
    package static func droppedPointLines(_ points: [Marker]) -> [String] {
        points.map {
            "Warning: \($0.kind == .chapter ? "chapter" : "marker") \"\($0.name)\" at \($0.position) starts at the "
                + "time of the split point before it, or at the end of the range; it has no file of its own."
        }
    }

    /// The stdout line of an export with a loudness target.
    package static func loudnessLine(_ report: LoudnessReport) -> String {
        let loudness = report.output.map { String(format: "%.1f LUFS", $0.value) } ?? "none"
        let peak = report.truePeak.map { String(format: "%.1f dBTP", $0) } ?? "none"
        return "loudness \(loudness), true peak \(peak), gain \(String(format: "%+.1f dB", report.gain.dB))"
    }

    /// The refusal of a split export whose range has no split point.
    package static func noPointMessage(_ kind: SplitKind, range: Range<Frames>) -> String {
        "no \(kind == .chapters ? "chapter" : "marker") in frames \(range.lowerBound)..<\(range.upperBound)."
    }

    /// The refusal of a split export when files are at its targets and `replace` is off.
    package static func partsExistMessage(_ urls: [URL], spelling o: OptionSpelling) -> String {
        let list = urls.map(\.path).joined(separator: ", ")
        return urls.count == 1
            ? "1 file exists: \(list). Use \(o("replace")) to replace it."
            : "\(urls.count) files exist: \(list). Use \(o("replace")) to replace them."
    }

    /// The stdout line of a file of a split export: its path, and with a loudness target a tab and the
    /// loudness line of the file.
    package static func partLine(_ file: ExportedPart) -> String {
        file.url.path + (file.result.loudness.map { "\t" + loudnessLine($0) } ?? "")
    }

    /// "1 file", "2 files".
    static func count(_ number: Int) -> String { number == 1 ? "1 file" : "\(number) files" }

    /// The paths of `urls` in a list, separated by ", ".
    static func list(_ urls: [URL]) -> String { urls.map(\.path).joined(separator: ", ") }

    /// The stderr line of a split export that stopped: the files that it did not write. An old item
    /// at each path stays.
    package static func stopLine(remaining: [URL]) -> String {
        let (verb, which) = remaining.count == 1 ? ("was", "this path") : ("were", "each path")
        return "Stopped: \(count(remaining.count)) \(verb) not written: \(list(remaining)). "
            + "An existing file at \(which) did not change."
    }

    /// The counts of a stopped set for a tool that has no stderr: "2 files were written; 8 files were not
    /// written: <paths>."
    package static func stopCounts(_ stop: ExportPartsStop) -> String {
        func verb(_ number: Int) -> String { number == 1 ? "was" : "were" }
        return "\(count(stop.written.count)) \(verb(stop.written.count)) written; "
            + "\(count(stop.remaining.count)) \(verb(stop.remaining.count)) not written: \(list(stop.remaining))."
    }

    /// The stderr line of a split export that ended with exit 0: the files of the prefix that an
    /// earlier set wrote and this set did not. Dirigible keeps them. Nil with none.
    package static func oldFilesLine(_ old: [URL]) -> String? {
        guard !old.isEmpty else { return nil }
        return old.count == 1
            ? "Warning: 1 older file of this prefix stays: \(list(old)). Dirigible does not delete it."
            : "Warning: \(old.count) older files of this prefix stay: \(list(old)). Dirigible does not delete them."
    }

    /// The files of `faults` in ID order, separated by "; ".
    static func files(_ faults: [FileID: MediaFault], in session: Session) -> String {
        faults.sorted { $0.key < $1.key }.map {
            "file \($0.key) \(path(of: $0.key, in: session)) \(describe($0.value))"
        }
        .joined(separator: "; ")
    }

    /// The pool path of a file, quoted.
    static func path(of id: FileID, in session: Session) -> String {
        session.files[id].map { String(reflecting: $0.path) } ?? "?"
    }

    /// The media state of a file in words: "is missing", "has only 5000 frames", or "cannot be read".
    static func describe(_ fault: MediaFault) -> String {
        switch fault {
        case .missing: "is missing"
        case .short(let frames): "has only \(frames) frames"
        case .unreadable: "cannot be read"
        }
    }
}
