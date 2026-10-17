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
    }
]
