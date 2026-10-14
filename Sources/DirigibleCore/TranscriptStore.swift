import Foundation

/// The name of a transcript file in `Transcripts/`: the text of a UUID (decision 0055). A new name
/// comes from a new UUID, and a read name only from a canonical UUID text, so a name never holds a
/// path.
struct TranscriptFileName: Hashable, Sendable, CustomStringConvertible {
    let description: String

    init() { description = UUID().uuidString }

    init?(_ text: String) {
        guard UUID(uuidString: text)?.uuidString == text else { return nil }
        description = text
    }
}

/// The folder of the transcript files in a package (decision 0055).
let transcriptsFolderName = "Transcripts"
let transcriptNamespace = "https://github.com/niltsiar/dirigible/transcript"

/// `Transcripts/<name>.xml`, format version 1 (decision 0055): one `<words>` element per file ID,
/// sorted by file ID, one line per anchor, "number start end text", in the order of `Anchors`.
enum TranscriptStore {
    static let version = 1

    static func encode(_ words: [FileID: Anchors]) -> Data {
        let root = XMLElement(name: "transcript")
        let namespace = XMLNode(kind: .namespace)
        namespace.name = ""
        namespace.stringValue = transcriptNamespace
        root.addNamespace(namespace)
        root.setAttributesWith(["version": String(version)])
        for (file, anchors) in words.sorted(by: { $0.key < $1.key }) {
            let lines = anchors.all.map { "\($0.number) \($0.range.lowerBound) \($0.range.upperBound) \($0.text)" }
            let node = XMLElement(name: "words", stringValue: lines.joined(separator: "\n"))
            node.setAttributesWith(["file": file.rawValue])
            root.addChild(node)
        }
        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"
        document.version = "1.0"
        return document.xmlData(options: .nodePrettyPrint)
    }

    /// The words of a transcript file. Another root or namespace, a version that is not 1, a line
    /// that does not split at its first three spaces into a number of 1 or more, two integers, and
    /// a text, an end before the start, two `<words>` of one file, and no `<words>` throw here;
    /// `Session.checkWords` checks the rest.
    static func decode(_ data: Data) throws(SessionFileError) -> [FileID: Anchors] {
        guard let document = try? XMLDocument(data: data), let root = document.rootElement(),
            root.localName == "transcript", root.uri == transcriptNamespace
        else { throw .malformedXML }
        guard let version = root.attribute(forName: "version")?.stringValue.flatMap(Int.init), version >= 1 else {
            throw .invalidValue(element: "transcript", attribute: "version")
        }
        guard version <= Self.version else { throw .unsupportedVersion(version) }
        var words: [FileID: Anchors] = [:]
        for element in root.elements(forLocalName: "words", uri: transcriptNamespace) {
            guard let name = element.attribute(forName: "file")?.stringValue else {
                throw .missingAttribute(element: "words", attribute: "file")
            }
            let file = FileID(name)
            guard words[file] == nil else { throw .invalidSession(.duplicateID(file.rawValue)) }
            var anchors: [Anchor] = []
            for line in (element.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
                let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
                guard fields.count == 4, let number = Int(fields[0]), number >= 1, let start = Int(fields[1]),
                    let end = Int(fields[2])
                else { throw .invalidValue(element: "words", attribute: "line") }
                guard start <= end else { throw .invalidSession(.wordOutsideFile(file)) }
                anchors.append(Anchor(number: number, range: Frames(start)..<Frames(end), text: String(fields[3])))
            }
            words[file] = Anchors(anchors)
        }
        guard !words.isEmpty else { throw .invalidValue(element: "transcript", attribute: "words") }
        return words
    }
}
