import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct ChaptersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chapters", abstract: "Export and import the chapter markers.",
        subcommands: [ChaptersExport.self, ChaptersImport.self])
}

struct ChaptersImport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Add the chapters of a Podcasting 2.0 JSON Chapters file as chapter markers, in one edit.",
        discussion: """
            The file is JSON Chapters version 1.x. Each chapter gives a marker at --at plus startTime \
            in seconds, rounded to the frame. A chapter with toc false is a plain marker, a chapter with \
            no title is named Chapter N, and a url that is not an http or https link is dropped with a \
            warning. The import copies no image. With --replace, the command first removes each chapter \
            marker and keeps each plain marker. The image of a removed chapter moves to the file chapter \
            at the same millisecond; when a removed image has no such chapter, the command stops and \
            changes nothing. A chapter with toc false takes no image. With --replace, it adds no \
            marker when a plain marker has its title and frame, and gives the ID of that marker. The \
            command prints the ID of the marker of each file chapter, in file order, one on each line. \
            Exit 1 when the file does not read, is not a regular file, is not on this Mac, is \
            larger than 1 MiB, is not a chapters file, has a chapter with no startTime that is a number \
            of 0 seconds or more, or has a frame past 2^40, or when --replace would drop an \
            image. Exit 64 when --at is not in 0...2^40. Exit 2 when the package cannot be read or \
            written, is locked, or has a take that is not finalized.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The chapters file.") var file: String
    @Option(parsing: .unconditional, help: "The timeline frame of second 0 of the file. The default is 0.")
    var at = 0
    @Flag(help: "Remove the chapters first and keep their images at the same time.") var replace = false

    func validate() throws {
        do throws(ToolError) { _ = try ChaptersWork.Import.frame(at: at, spelling: .cli) } catch {
            throw ValidationError(error.message)
        }
    }

    func run() throws {
        let work: ChaptersWork.Import
        do throws(ToolError) {
            work = try ChaptersWork.Import(
                path: file, at: try ChaptersWork.Import.frame(at: at, spelling: .cli), replace: replace)
        } catch {
            throw fail(error.message, code: editRefused)
        }
        let result = try editPackage(package, ripple: false) { session throws(SessionError) in
            try work.apply(&session)
        }
        print(result.ids.joined(separator: "\n"))
        warn(result.warnings)
    }
}

struct ChaptersExport: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write the chapters of a range as a Podcasting 2.0 JSON Chapters 1.2.0 file or a text list.",
        discussion: """
            The extension of --out gives the form: .json or .txt. In the JSON, each chapter marker in \
            the range gives startTime and title, and url and img when it has them. startTime is the \
            time from --from in seconds, rounded to the millisecond. The image of a chapter is written \
            beside the file as <name>-<n>.jpg or .png, n the place of the chapter in the file. The text \
            list has one line for each chapter, HH:MM:SS, one space, and the title, with the time from \
            --from rounded down to the second, and no image. A list with no chapter at 00:00:00 gets a \
            warning. Markers that are not chapters are not in \
            the file. A chapter at or after the session end is past the audio: a warning names it, and \
            the file has it only when --to is after it. A chapter that starts at the millisecond of the \
            chapter before it is not in the file, and a warning names it. Exit 1 when the range has no chapter, or when \
            the session has no audio and no --to: the command writes no empty file. Exit 64 when --out \
            is in a .dirigible package. Exit 2 \
            when the package cannot be read, --out or an image file exists (unless --replace), or the \
            write fails. The command writes the images first, then the file, each with an atomic \
            write: a failed write leaves the old file or no file, and it can leave new images.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file: .json or .txt.") var out: String
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?
    @Flag(help: "Replace the output file when it exists.") var replace = false

    /// The work of the options, or the usage error of `out`.
    func work() throws(ValidationError) -> ChaptersWork {
        do throws(ToolError) {
            return try ChaptersWork(out: out, from: from, to: to, replace: replace, spelling: .cli)
        } catch {
            throw ValidationError(error.message)
        }
    }

    func validate() throws {
        _ = try work()
    }

    func run() throws {
        let work = try work()
        let session = try readPackage(package)
        let source: ChaptersWork.Source
        do throws(ChaptersWork.Refusal) { source = try work.source(in: session) } catch {
            switch error {
            case .range(let message): throw ValidationError(message)
            case .nothing(let message, let warnings):
                warn(warnings)
                throw fail(message, code: editRefused)
            }
        }
        warn(source.warnings)
        do throws(ToolError) { try work.checkTarget() } catch { throw fail(error.message, code: packageError) }
        do throws(ExportError) { try work.write(session, source: source, package: package.url) } catch {
            throw fail(work.message(error), code: packageError)
        }
    }
}
