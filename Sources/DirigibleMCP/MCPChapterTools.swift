import DirigibleCore
import Foundation

/// The chapter tools of `dirigible mcp`. Each one shares its argument rules and its text with its
/// command through `ChaptersWork`.
private let out = Param.required(
    "out",
    "The absolute path of the chapters file, outside each session package: .json or .txt. It must not exist, "
        + "unless replace.", .string)
private let from = Param.defaulted("from", "The first frame. The file times start at 0 there.", .integer(), 0)
private let to = Param<Int?>.optional(
    "to", "The frame after the last frame. The default is the session end.", .integer())
private let replace = Param.defaulted(
    "replace", "Replace the file and its chapter images when they exist.", .boolean, false)

private let importPath = Param.required(
    "path", "The absolute path of a Podcasting 2.0 JSON Chapters file, version 1.x, of at most 1 MiB.", .string)
private let importAt = Param.defaulted("at", "The timeline frame of second 0 of the file.", .integer(), 0)
private let importReplace = Param.defaulted(
    "replace",
    "Remove each chapter first and keep each plain marker. The image of a removed chapter moves to the file chapter at "
        + "its millisecond. When a removed image has no chapter at its time, the call fails and changes nothing. A toc "
        + "false chapter takes no image, and adds no marker when a plain marker has its title and frame.",
    .boolean, false)

let chapterTools = [
    Tool(
        "chapters_export",
        "Write the chapters of a range to a file, as dirigible chapters export. A .json out gives a Podcasting 2.0 "
            + "JSON Chapters 1.2.0 file, with each chapter image beside it; a .txt out gives a text list, one line "
            + "HH:MM:SS and the title for each chapter, for an episode description. The text is the warning lines, "
            + "or OK. A range with no chapter writes no file.",
        [out, from, to, replace], saves: false
    ) { a throws(ToolError) in
        let (first, end, replaces) = (try a[from], try a[to], try a[replace])
        let path = try outPath(a, out)
        return .chapters(try ChaptersWork(out: path, from: first, to: end, replace: replaces))
    },
    Tool(
        "chapters_import",
        "Add the chapters of a Podcasting 2.0 JSON Chapters file as chapter markers, as dirigible chapters import. A "
            + "chapter with toc false is a plain marker. A chapter with no title is named Chapter N. The import copies "
            + "no image. Give the ID of the marker of each file chapter, in file order, one on each line, then the "
            + "warning lines. With replace, a chapter with toc false can give the ID of an existing plain marker. A "
            + "bad file or a failed call changes nothing.",
        [importPath, importAt, importReplace]
    ) { a throws(ToolError) in
        let (location, first, replaces) = (try a[importPath], try a[importAt], try a[importReplace])
        guard location.hasPrefix("/") else { throw ToolError("The argument \"path\" must be an absolute path.") }
        let work = try ChaptersWork.Import(
            path: location, at: try ChaptersWork.Import.frame(at: first, spelling: .tool), replace: replaces)
        return .edit(ripple: false) { session throws(SessionError) in
            let result = try work.apply(&session)
            return result.ids + result.warnings
        }
    },
]
