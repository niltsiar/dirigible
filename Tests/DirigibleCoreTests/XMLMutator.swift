import Foundation

/// A mutation family of `XMLMutator`.
enum MutationFamily: String, CaseIterable, Sendable {
    case byte = "M1 byte"
    case cut = "M2 cut"
    case value = "M3 value"
    case drop = "M4 drop"
    case copy = "M5 copy"
    case remove = "M6 remove"
    case move = "M7 move"
    case version = "M8 version"
    case namespace = "M9 namespace"
    case text = "M10 text"
    case prolog = "M11 prolog"
    case poolPath = "M12 pool path"
}

/// What the reader may do with a mutated file.
enum Expected: Equatable, Sendable {
    /// A typed refusal, or a value that writes and reads back equal.
    case refuseOrRoundTrip
    /// DTD text as markup before the root: `.malformedXML`.
    case malformed
    /// The reference parse has a DTD node: any refusal.
    case refused
    /// A pool path outside `Clips/`: `.invalidSession(.invalidPath(path))`.
    case pathRefused(String)
    /// A pool path inside `Clips/`: the file `file` opens with this path.
    case pathKept(file: String, path: String)
}

/// One mutated file, with a short note of the change for the issue text.
struct Mutation: Sendable {
    let family: MutationFamily
    let data: Data
    let note: String
    var expected = Expected.refuseOrRoundTrip
}

/// Mutates a valid package XML file, which the writer made, into the families M1 to M12 of the
/// session file fuzz: on the bytes, on the text of the start tags, and on `XMLDocument` copies.
struct XMLMutator {
    struct Attribute {
        let element: String
        let name: String
        let value: String
        let whole: Range<String.Index>
        let valueRange: Range<String.Index>
        /// The `id` of the start tag of the attribute.
        let id: String?
    }

    let data: Data
    let text: String
    let attributes: [Attribute]

    init(_ data: Data) {
        self.data = data
        text = String(decoding: data, as: UTF8.self)
        attributes = text.matches(of: /<([A-Za-z_][\w.:-]*)((?:\s+[\w.:-]+="[^"]*")*)\s*\/?>/).flatMap { tag in
            let pairs = tag.output.2.matches(of: /\s+([\w.:-]+)="([^"]*)"/)
            let id = pairs.first { $0.output.1 == "id" }.map { String($0.output.2) }
            return pairs.map {
                Attribute(
                    element: String(tag.output.1), name: String($0.output.1), value: String($0.output.2),
                    whole: $0.range, valueRange: $0.output.2.startIndex..<$0.output.2.endIndex, id: id)
            }
        }
    }

    /// The stress values of the attributes and texts.
    static let stressValues: [String] = [
        "-1", "0", "1", "1099511627776", "1099511627777", "9223372036854775807", "-9223372036854775808",
        "9223372036854775808", "9007199254740993", "1e400", "-1e400", "nan", "inf", "-0", "1.5", "0x10", "+1",
        " 1", "1_000", "", "true", "false", "TRUE", "yes", "&#1;", "&#x9;", "&#xFFFE;", "../x.wav", "/etc/hosts",
        "Clips/../../x", "a/../../b.wav", String(repeating: "n", count: 4_092) + ".wav",
        String(repeating: "a", count: 100_000),
    ]

    /// The stress values, the value in capitals, and the value with its first letter changed.
    static func stressValues(for value: String) -> [String] {
        stressValues + [value.uppercased(), "x" + value.dropFirst()]
    }

    /// The pool path values, each with true when the path is outside `Clips/`.
    static let poolPaths: [(path: String, refused: Bool)] = [
        ("../x.wav", true), ("a/../../b.wav", true), ("Clips/../../x", true), ("..", true), ("/etc/hosts", true),
        ("/", true), ("./x.wav", false), ("a//b.wav", false), ("a/b/c/d.wav", false), ("x.wav/", false),
        ("...", false), ("..x.wav", false), ("%2e%2e/x.wav", false), ("\u{2025}/x.wav", false),
        (String(repeating: "n", count: 4_092) + ".wav", false),
    ]

    /// The `version` values of M8: the edges, each version where a field starts, and one past the newest.
    static let versions = [-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15, 16, 17, 18, Int.max].map(String.init)

    static let prologInserts = [#"<!DOCTYPE session>"#, #"<!DOCTYPE session [<!ENTITY a "A">]>"#, #"<!ENTITY a "A">"#]

    /// M3 for the first `attribute` of an `element`, or nil when the file has none.
    func setting(_ element: String, _ attribute: String, to value: String) -> Mutation? {
        attributes.first { $0.element == element && $0.name == attribute }.map { setting($0, to: value, .value) }
    }

    /// M12 with `path` on the `<file>` at `index` of the file list, or nil when the file has no file.
    func settingPath(_ path: String, refused: Bool, file index: Int) -> Mutation? {
        let files = attributes.filter { $0.element == "file" && $0.name == "path" }
        guard !files.isEmpty else { return nil }
        let target = files[index % files.count]
        var mutation = setting(target, to: path, .poolPath)
        mutation.expected = refused ? .pathRefused(path) : .pathKept(file: target.id ?? "", path: path)
        return mutation
    }

    /// One random mutation of `family`, or nil when the file has nothing that the family changes.
    func mutate(_ family: MutationFamily, using random: inout SplitMix) -> Mutation? {
        switch family {
        case .byte: byteMutation(using: &random)
        case .cut:
            data.isEmpty ? nil : cut(at: Int.random(in: 0..<data.count, using: &random))
        case .value:
            attributes.randomElement(using: &random).map {
                setting($0, to: Self.stressValues(for: $0.value).randomElement(using: &random)!, .value)
            }
        case .drop:
            attributes.randomElement(using: &random).map { attribute in
                var copy = text
                copy.removeSubrange(attribute.whole)
                return Mutation(
                    family: .drop, data: Data(copy.utf8), note: "drop \(attribute.element)@\(attribute.name)")
            }
        case .version:
            attributes.first { $0.name == "version" }.map {
                setting($0, to: Self.versions.randomElement(using: &random)!, .version)
            }
        case .text: textMutation(using: &random)
        case .prolog: prologMutation(using: &random)
        case .poolPath:
            Self.poolPaths.randomElement(using: &random).flatMap {
                settingPath($0.path, refused: $0.refused, file: Int.random(in: 0..<8, using: &random))
            }
        case .copy, .remove, .move, .namespace: documentMutation(family, using: &random)
        }
    }

    private func setting(_ attribute: Attribute, to value: String, _ family: MutationFamily) -> Mutation {
        var copy = text
        copy.replaceSubrange(attribute.valueRange, with: value)
        let shown = value.count > 40 ? "\(value.prefix(20))... (\(value.utf8.count) bytes)" : value
        return Mutation(family: family, data: Data(copy.utf8), note: "\(attribute.element)@\(attribute.name)=\(shown)")
    }

    private func cut(at end: Int) -> Mutation {
        Mutation(family: .cut, data: data.prefix(end), note: "cut at byte \(end) of \(data.count)")
    }

    /// M1: 1 to 8 byte edits (set, delete, or insert) at random offsets, half with XML markup bytes.
    private func byteMutation(using random: inout SplitMix) -> Mutation {
        var bytes = [UInt8](data)
        var edits: [String] = []
        for _ in 0..<Int.random(in: 1...8, using: &random) {
            let offset = Int.random(in: 0...bytes.count, using: &random)
            let byte =
                Bool.random(using: &random)
                ? Array("<>&\"'/=;#x?!-".utf8).randomElement(using: &random)!
                : UInt8.random(in: 0...255, using: &random)
            switch Int.random(in: 0..<3, using: &random) {
            case 0 where offset < bytes.count:
                bytes[offset] = byte
                edits.append("set \(offset) to \(byte)")
            case 1 where offset < bytes.count:
                bytes.remove(at: offset)
                edits.append("delete \(offset)")
            default:
                bytes.insert(byte, at: offset)
                edits.append("insert \(byte) at \(offset)")
            }
        }
        return Mutation(family: .byte, data: Data(bytes), note: edits.joined(separator: ", "))
    }

    /// M10: the text of a `<summary>` or `<notes>`, or one line of a `<words>`, becomes a stress text.
    private func textMutation(using random: inout SplitMix) -> Mutation? {
        let nodes = text.matches(of: /<(summary|notes|words)(?:\s[^>]*)?>([^<]*)</)
        guard let node = nodes.randomElement(using: &random) else { return nil }
        let texts =
            Self.stressValues + [
                "&#13;", "a&#13;b", "a&#10;b", "1 0 1", "1 5 2 x", "0 0 1 x", "1 0 1099511627777 x", "1 -1 1 x",
                "1 0 1 a  b ", "1 0 1 &#13;",
            ]
        let stress = texts.randomElement(using: &random)!
        var replacement = stress
        if node.output.1 == "words" {
            var lines = node.output.2.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let line = Int.random(in: 0..<lines.count, using: &random)
            let fields = lines[line].split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            lines[line] =
                Bool.random(using: &random) || fields.count < 4
                ? stress : fields.prefix(3).joined(separator: " ") + " " + stress
            replacement = lines.joined(separator: "\n")
        }
        var copy = text
        copy.replaceSubrange(node.output.2.startIndex..<node.output.2.endIndex, with: replacement)
        return Mutation(
            family: .text, data: Data(copy.utf8), note: "\(node.output.1) text \(String(reflecting: stress.prefix(30)))"
        )
    }

    /// M11: a random prolog of comments, PIs, and white space after the optional BOM and the writer
    /// declaration, with one DTD text as markup at a random place of it or inside one of its comments
    /// or PIs.
    private func prologMutation(using random: inout SplitMix) -> Mutation? {
        guard text.hasPrefix("<?xml"), let end = text.range(of: "?>")?.upperBound else { return nil }
        var items = (0..<Int.random(in: 0...4, using: &random)).map { number in
            ["<!-- c\(number) -->", "<?p d\(number)?>", " ", "\n", "\t"].randomElement(using: &random)!
        }
        let insert = Self.prologInserts.randomElement(using: &random)!
        let asText = Bool.random(using: &random)
        var expected = Expected.malformed
        if asText {
            let place = Bool.random(using: &random) ? "<!-- \(insert) -->" : "<?p \(insert)?>"
            items.insert(place, at: Int.random(in: 0...items.count, using: &random))
            expected = .refuseOrRoundTrip
        } else {
            items.insert(insert, at: Int.random(in: 0...items.count, using: &random))
        }
        let bom = Bool.random(using: &random) ? Data([0xEF, 0xBB, 0xBF]) : Data()
        let prolog = "\n" + items.joined()
        let bytes = bom + Data((String(text[..<end]) + prolog + String(text[end...])).utf8)
        let reference = try? XMLDocument(data: bytes, options: .nodeLoadExternalEntitiesNever)
        if expected == .refuseOrRoundTrip, reference?.dtd != nil { expected = .refused }
        let note =
            "\(asText ? "text" : "markup") \(insert) in prolog \(String(reflecting: prolog)), BOM \(!bom.isEmpty)"
        return Mutation(family: .prolog, data: bytes, note: note, expected: expected)
    }

    /// M5, M6, M7, M9 on an `XMLDocument` copy of the file.
    private func documentMutation(_ family: MutationFamily, using random: inout SplitMix) -> Mutation? {
        guard let document = try? XMLDocument(data: data), let root = document.rootElement(),
            let element = Self.elements(in: root).dropFirst().randomElement(using: &random)
        else { return nil }
        let name = element.name ?? "?"
        let note: String
        switch family {
        case .copy:
            guard let parent = element.parent as? XMLElement, let copy = element.copy() as? XMLElement else {
                return nil
            }
            parent.insertChild(copy, at: element.index + 1)
            note = "copy \(name)"
        case .remove:
            element.detach()
            note = "remove \(name)"
        case .move:
            let inside = Self.elements(in: element)
            let targets = Self.elements(in: root).filter { target in !inside.contains { $0 === target } }
            guard let target = targets.randomElement(using: &random) else { return nil }
            element.detach()
            target.addChild(element)
            note = "move \(name) under \(target.name ?? "?")"
        default:
            let namespace = XMLNode(kind: .namespace)
            switch Int.random(in: 0..<3, using: &random) {
            case 0:
                root.removeNamespace(forPrefix: "")
                note = "no default namespace"
            case 1:
                namespace.name = ""
                namespace.stringValue = "urn:other"
                element.addNamespace(namespace)
                note = "namespace urn:other on \(name)"
            default:
                namespace.name = "d"
                namespace.stringValue = root.uri
                root.addNamespace(namespace)
                element.name = "d:\(element.localName ?? name)"
                note = "prefix d on \(name)"
            }
        }
        return Mutation(family: family, data: document.xmlData, note: note)
    }

    private static func elements(in element: XMLElement) -> [XMLElement] {
        [element] + (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap(elements(in:))
    }
}
