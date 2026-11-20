import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of an `export-stems` command or an `export_stems` call after its arguments are checked
/// (decisions 0041 and 0049). It is the one owner of the argument rules, the steps, and the texts
/// of both. The shared option and warning texts come from `ExportText`.
package struct StemsWork: Sendable {
    /// An absolute path outside each session package: the new stem folder.
    let out: String
    package let grouping: StemGrouping
    package let options: StemOptions
    let from: Int
    let to: Int?
    let tracks: [TrackID]
    let allowMissing: Bool
    /// How the texts name an option.
    let spelling: OptionSpelling

    /// Checks the arguments: `by` is track or role, `format` is wav or flac, and the `out` folder is
    /// outside each package with a name that fits `stemFolderNameLimit`. Nil gives the default.
    package init(
        out: String, by: String?, format: String?, bits: Int?, mono: Bool, rate: Int?, from: Int, to: Int?,
        tracks: [TrackID], allowMissing: Bool, spelling o: OptionSpelling
    ) throws(ToolError) {
        // The folder itself and each folder above it must not be a package.
        try ExportText.checkOutsidePackages(URL(filePath: out).appending(path: "x"))
        guard URL(filePath: out).lastPathComponent.utf8.count <= stemFolderNameLimit else {
            throw ToolError("The \(o("out")) folder name is over \(stemFolderNameLimit) bytes.")
        }
        guard let grouping = StemGrouping(rawValue: by ?? "track") else {
            throw ToolError("\(o("by")) must be track or role.")
        }
        let depth = try ExportText.bitDepth(bits, spelling: o)
        let format: StemFormat =
            switch format ?? "wav" {
            case "wav": .wav(depth)
            case "flac": .flac(depth)
            default: throw ToolError("\(o("format")) must be wav or flac.")
            }
        (self.out, self.grouping, self.from, self.to, self.tracks) = (out, grouping, from, to, tracks)
        options = StemOptions(
            format: format, layout: mono ? .mono : .stereo, rate: try ExportText.exportRate(rate, spelling: o))
        (self.allowMissing, spelling) = (allowMissing, o)
    }

    var url: URL { URL(filePath: out) }

    /// The range and the tracks, with the refusals of a usage error.
    package func source(in session: Session) throws(ToolError) -> ExportSource {
        if let unknown = tracks.first(where: { session.track($0) == nil }) {
            throw ToolError(ExportText.noTrackMessage(unknown))
        }
        let end = to ?? session.end.count
        guard end > from,
            let source = ExportSource(range: Frames(from)..<Frames(end), tracks: tracks.isEmpty ? nil : Set(tracks))
        else { throw ToolError(ExportText.rangeMessage(end: session.end, spelling: spelling)) }
        return source
    }

    /// The media check of the files that the heard tracks of the source read, and its refusal with
    /// no `allow_missing`.
    package func checkFiles(_ session: Session, package: URL, source: ExportSource) throws(ToolError) {
        let faults: [FileID: MediaFault]
        do throws(POSIXError) { faults = try checkMedia(session, package: package, source: source) } catch {
            throw ToolError(mediaCheckMessage(error))
        }
        guard faults.isEmpty || allowMissing else {
            throw ToolError(ExportText.faultMessage(faults, in: session, spelling: spelling))
        }
    }

    /// The job on the files: the CLI and the tools name the role files in English.
    package func export(
        _ session: Session, source: ExportSource, package: URL, progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool
    ) throws(ExportStemsError) -> StemsResult {
        try exportStems(
            session, by: grouping, source: source, titles: .english, options: options, to: url,
            package: { package }, progress: progress, isCancelled: isCancelled)
    }

    /// The text of a refused or failed job, or nil for a cancel.
    package func message(_ error: ExportStemsError) -> String? {
        switch error {
        case .noStem: return "No track of the set has a clip in the range. No folder was made."
        case .notEnoughSpace(let need, let free):
            return "cannot write \(out): the stems need \(need) bytes, and the volume has \(free) bytes free. "
                + "No stem was written."
        case .stopped(let error):
            return ExportText.failureMessage(error, out: out, noun: "stems", spelling: spelling).map {
                "\($0) No stem was written."
            }
        case .publish(.exists): return "\(out) exists."
        case .publish(.writeFailed(let step, let code)):
            return "cannot make the stem folder \(out) (\(step)): \(String(cString: strerror(code)))."
        case .publish(let error): return "cannot make the stem folder \(out): \(error.message(package: out))"
        }
    }

    /// The stdout lines and the stderr lines of a job: a line for each file, then the warnings. A
    /// file that only the export found bad refuses with no `allow_missing`; the folder is written.
    package func lines(of result: StemsResult, session: Session, source: ExportSource) throws(ToolError) -> (
        stdout: [String], stderr: [String]
    ) {
        guard result.faults.isEmpty || allowMissing else {
            throw ToolError(ExportText.readFaultMessage(result.faults, in: session, out: out, spelling: spelling))
        }
        let order = Dictionary(uniqueKeysWithValues: session.tracks.enumerated().map { ($1.id, $0) })
        let stdout = result.files.map { file in
            ([file.name] + file.tracks.sorted { order[$0, default: 0] < order[$1, default: 0] }.map(\.rawValue))
                .joined(separator: "\t")
        }
        var stderr =
            ExportText.faultLines(result.faults, in: session) + ExportText.unheardLines(session, source: source)
        stderr += result.plan.empty.map {
            "Warning: \(Self.describe($0, in: session)) has no clip in the range, so it has no stem file."
        }
        if result.plan.noRoleSet {
            stderr.append("Note: no heard track of the set has a role, so one file holds them all.")
        }
        for file in result.files where file.isOverFullScale {
            stderr.append(
                "Warning: \(file.name) is over 0 dBFS (peak \(Self.decibels(file.samplePeak))): it clips, so the "
                    + "stems do not add up to the mix.")
        }
        if let peak = result.mixPeak, peak > 1 {
            stderr.append(
                "Warning: the mix of the stems is over 0 dBFS (peak \(Self.decibels(peak))): the stems do not add up "
                    + "to a mix export.")
        }
        return (stdout, stderr)
    }

    static func describe(_ key: Stem.Key, in session: Session) -> String {
        switch key {
        case .track(let id): "track \(id) (\(session.track(id)?.name ?? ""))"
        case .role(let role?): "the \(role.rawValue) stem"
        case .role(nil): "the stem of the tracks with no role"
        }
    }

    static func decibels(_ peak: Float) -> String { String(format: "%+.1f dB", 20 * log10(Double(peak))) }
}
