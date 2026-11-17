import Foundation

/// The name of a transcript file in `Transcripts/`: the text of a UUID (decision 0055). A new name
/// comes from a new UUID, and a read name only from a canonical UUID text, so a name never holds a
/// path.
public struct TranscriptFileName: Hashable, Sendable, CustomStringConvertible {
    public let description: String

    init() { description = UUID().uuidString }

    init?(_ text: String) {
        guard UUID(uuidString: text)?.uuidString == text else { return nil }
        description = text
    }
}

/// The folder of the transcript files in a package (decision 0055).
package let transcriptsFolderName = "Transcripts"
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
    /// a text of characters that `isStorableInSession` takes, an end before the start, a frame outside `Frames.isInRange` (the midpoint of
    /// `Anchors` must not overflow), two `<words>` of one file, and no `<words>` throw here;
    /// `Session.checkWords` checks the rest.
    static func decode(_ data: Data) throws(SessionFileError) -> [FileID: Anchors] {
        guard let document = packageXML(data), let root = document.rootElement(),
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
                    let end = Int(fields[2]), fields[3].unicodeScalars.allSatisfy(\.isStorableInSession)
                else { throw .invalidValue(element: "words", attribute: "line") }
                guard start <= end, Frames(start).isInRange, Frames(end).isInRange else {
                    throw .invalidSession(.wordOutsideFile(file))
                }
                anchors.append(Anchor(number: number, range: Frames(start)..<Frames(end), text: String(fields[3])))
            }
            words[file] = Anchors(anchors)
        }
        guard !words.isEmpty else { throw .invalidValue(element: "transcript", attribute: "words") }
        return words
    }
}

extension Session {
    /// The file name of each transcript, loaded or not: the holders of Remove Unused Files.
    var transcriptFiles: Set<TranscriptFileName> { Set(transcripts.values.map(\.file)) }

    /// Loads the words of each transcript from `Transcripts/<name>.xml` of `package`. A transcript
    /// whose file is missing, does not decode, or breaks a rule of the import keeps no words.
    mutating func loadTranscripts(from package: URL) {
        let folder = package.appending(path: transcriptsFolderName)
        resolveTranscripts { transcript in
            (try? Data(contentsOf: folder.appending(path: "\(transcript.file).xml")))
                .flatMap { try? TranscriptStore.decode($0) }
        }
    }

    /// Writes the file of each transcript with words that has no regular file of 1 byte or more in
    /// `Transcripts/` yet: a temporary file, a full flush, a plain rename (exFAT has no
    /// `RENAME_EXCL`, decision 0016), and a flush of the folder. A file of 0 bytes is the trace of
    /// a crash, and a link is not the file, so the rename replaces them. The name is new and the
    /// caller holds the package lock, so a file never changes after its first write. Call it before
    /// the replace of `session.xml`, so a failure keeps the old session.
    func writeTranscriptFiles(in package: URL) throws(SessionFileError) {
        let folder = package.appending(path: transcriptsFolderName)
        var madeFolder = false
        for transcript in transcripts.values.sorted(by: { $0.id < $1.id }) {
            guard let words = transcript.words else { continue }
            let target = folder.appending(path: "\(transcript.file).xml")
            var info = stat()
            if lstat(target.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 { continue }
            // Only a write makes the folder, so a session with no transcript gets none.
            let made = mkdir(folder.path, 0o755) == 0
            guard made || errno == EEXIST else { throw .writeFailed(step: "createDirectory", errno: errno) }
            madeFolder = madeFolder || made
            let data = TranscriptStore.encode(words)
            guard (try? TranscriptStore.decode(data)) == words else { throw .wouldNotReadBack(nil) }
            try replaceDurably(target, with: data)
        }
        if madeFolder, let code = fullFlush(path: package.path) { throw .writeFailed(step: "fsync", errno: code) }
    }
}
