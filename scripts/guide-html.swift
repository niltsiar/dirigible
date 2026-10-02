// Convert docs/guide.md to the guide page of the app bundle: Contents/Resources/Guide/guide.html.
// usage: swift scripts/guide-html.swift <guide.md> <out.html>
// It prints the path of each image, one per line, so scripts/bundle.sh copies only those files.
// It refuses an element that the page cannot show: raw HTML, a block with no kind or an unknown
// kind, or an image outside images/. Heading ids follow the slug rule of scripts/check-docs.sh.
// Exit: 0 written, 1 a refused element (no output file), 2 usage or a missing input.
import Foundation

func stop(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("guide-html: \(message)\n".utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { stop("usage: swift scripts/guide-html.swift <guide.md> <out.html>", 2) }
guard let markdown = try? String(contentsOfFile: arguments[1], encoding: .utf8) else {
    stop("no file \(arguments[1])", 2)
}
let text: AttributedString
do {
    text = try AttributedString(
        markdown: markdown,
        options: .init(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .throwError))
} catch {
    stop("cannot parse \(arguments[1]): \(error)", 1)
}

func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

/// The GitHub heading slug of check-docs.sh: lower case, only a-z, 0-9, space, _ and -, spaces to -.
func slug(_ heading: String) -> String {
    let kept = heading.lowercased().unicodeScalars.filter {
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || " _-".unicodeScalars.contains($0)
    }
    return String(String.UnicodeScalarView(kept)).replacingOccurrences(of: " ", with: "-")
}

// The text of each heading, for its id, and the first level-1 heading, for the page title.
var headings: [Int: String] = [:]
var titleIdentity: Int?
for run in text.runs {
    for block in run.presentationIntent?.components ?? [] {
        guard case .header(let level) = block.kind else { continue }
        headings[block.identity, default: ""] += String(text[run.range].characters)
        if level == 1 && titleIdentity == nil { titleIdentity = block.identity }
    }
}
let title = titleIdentity.flatMap { headings[$0] } ?? ""

/// The open and close tags of a block. A table cell is a th in the header row.
func tags(_ block: PresentationIntent.IntentType, parent: PresentationIntent.IntentType?) -> (String, String) {
    switch block.kind {
    case .paragraph: return ("<p>", "</p>\n")
    case .header(let level): return ("<h\(level) id=\"\(slug(headings[block.identity] ?? ""))\">", "</h\(level)>\n")
    case .unorderedList: return ("<ul>", "</ul>\n")
    case .orderedList: return ("<ol>", "</ol>\n")
    case .listItem: return ("<li>", "</li>\n")
    case .blockQuote: return ("<blockquote>", "</blockquote>\n")
    case .codeBlock: return ("<pre><code>", "</code></pre>\n")
    case .table: return ("<table>", "</table>\n")
    case .tableHeaderRow, .tableRow: return ("<tr>", "</tr>\n")
    case .tableCell:
        if case .tableHeaderRow = parent?.kind { return ("<th>", "</th>") }
        return ("<td>", "</td>")
    default: stop("unknown block: \(block.kind)", 1)
    }
}

let known: InlinePresentationIntent = [.emphasized, .stronglyEmphasized, .code, .strikethrough, .softBreak, .lineBreak]
var body = ""
var images: [String] = []
var open: [(identity: Int, close: String)] = []  // the outermost block first
for run in text.runs {
    let raw = String(text[run.range].characters)
    let style = run.inlinePresentationIntent ?? []
    if style.contains(.inlineHTML) || style.contains(.blockHTML) { stop("raw HTML: \(raw)", 1) }
    if !style.subtracting(known).isEmpty { stop("unknown inline style \(style.rawValue): \(raw)", 1) }
    guard let intent = run.presentationIntent else { stop("a block with no kind: \(raw)", 1) }

    // Close the blocks that this run is not in, then open its new blocks.
    let path = Array(intent.components.reversed())
    var common = 0
    while common < min(open.count, path.count) && open[common].identity == path[common].identity { common += 1 }
    for block in open[common...].reversed() { body += block.close }
    open.removeLast(open.count - common)
    for index in common..<path.count {
        let (start, close) = tags(path[index], parent: index > 0 ? path[index - 1] : nil)
        body += start
        open.append((path[index].identity, close))
    }

    if let image = run.imageURL {
        let source = image.relativeString
        guard source.range(of: #"^images/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
            !source.contains("..")
        else { stop("image outside images/: \(source)", 1) }
        images.append(source)
        body += "<img src=\"\(escape(source))\" alt=\"\(escape(raw))\">"
        continue
    }
    var html = style.contains(.lineBreak) ? "<br>" : escape(raw)
    if style.contains(.code) { html = "<code>\(html)</code>" }
    if style.contains(.emphasized) { html = "<em>\(html)</em>" }
    if style.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
    if style.contains(.strikethrough) { html = "<del>\(html)</del>" }
    if let link = run.link { html = "<a href=\"\(escape(link.relativeString))\">\(html)</a>" }
    body += html
}
for block in open.reversed() { body += block.close }

let page = """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(escape(title))</title>
    <style>
    :root { color-scheme: light dark; }
    body { font: 15px/1.5 -apple-system, sans-serif; max-width: 52em; margin: 2em auto; padding: 0 16px; }
    img { max-width: 100%; height: auto; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #8886; padding: 4px 8px; text-align: left; vertical-align: top; }
    code { font: 13px ui-monospace, monospace; }
    pre { padding: 8px; overflow-x: auto; background: #8882; }
    blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #8888; }
    </style>
    </head>
    <body>
    \(body)</body>
    </html>

    """
do {
    try page.write(toFile: arguments[2], atomically: true, encoding: .utf8)
} catch {
    stop("cannot write \(arguments[2]): \(error)", 1)
}
if !images.isEmpty { print(images.joined(separator: "\n")) }
