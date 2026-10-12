import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

struct ChaptersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chapters", abstract: "Export the chapter markers.", subcommands: [ChaptersExport.self])
}

struct ChaptersExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write the chapters of a range as a Podcasting 2.0 JSON Chapters 1.2.0 file.",
        discussion: """
            Each chapter marker in the range gives startTime and title, and url and img when it has \
            them. startTime is the time from --from in seconds, rounded to the millisecond. The image \
            of a chapter is written beside the file as <name>-<n>.jpg or .png, n the place of the \
            chapter in the file. Markers that are not chapters are not in \
            the file. A chapter at or after the session end is past the audio: a warning names it, and \
            the file has it only when --to is after it. A chapter that starts at the millisecond of the \
            chapter before it is not in the file, and a warning names it. Exit 1 when the range has no chapter, or when \
            the session has no audio and no --to: the command writes no empty file. Exit 2 \
            when the package cannot be read, --out or an image file exists (unless --replace), or the \
            write fails. The command writes the images first, then the file, each with an atomic \
            write: a failed write leaves the old file or no file, and it can leave new images.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file: .json.") var out: String
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?
    @Flag(help: "Replace the output file when it exists.") var replace = false

    func validate() throws {
        guard URL(filePath: out).pathExtension.lowercased() == "json" else {
            throw ValidationError("--out must end in .json.")
        }
    }

    func run() throws {
        let session = try readPackage(package)
        // A chapter at or after the session end is past the audio: the file leaves it out, and the
        // warning names it, so the user knows that it is not in the file (code gate item 1).
        func warnPast(outside range: Range<Frames>?) {
            for chapter in session.chapters(in: session.end..<Frames.limit)
            where range?.contains(chapter.position) != true {
                let line =
                    "Warning: chapter \"\(chapter.name)\" at \(chapter.position) is at or after the session end \(session.end); the file leaves it out.\n"
                try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
            }
        }
        guard to != nil || session.end > .zero else {
            warnPast(outside: nil)
            throw fail("the session has no audio, so it has no range. Give --to.", code: editRefused)
        }
        let end = to ?? session.end.count
        // The range rule of `export`, so both commands take the same ranges.
        guard end > from, let range = ExportSource(range: Frames(from)..<Frames(end))?.range else {
            throw ValidationError(
                "The range must be 0 or more, with --to more than --from; the session end is \(session.end).")
        }
        warnPast(outside: range)
        guard !session.chapters(in: range).isEmpty else {
            throw fail("no chapter in frames \(from)..<\(end).", code: editRefused)
        }
        warnDropped(session.chapterList(in: range).dropped)
        let output = URL(filePath: out)
        // An lstat: a dangling link is an item too. `[.atomic, .withoutOverwriting]` is a fatal
        // error of Foundation, so the check comes first, and a race with another writer is accepted.
        guard replace || ConfirmedFile(at: output) == nil else { throw fail("\(out) exists.", code: packageError) }
        // `writeChapters` checks the chapter images beside the JSON before any write.
        do throws(ExportError) {
            try writeChapters(session, in: range, to: output, replacingImages: replace, package: package.url)
        } catch {
            throw failure(error, out: out, noun: "chapters file")
        }
    }
}
