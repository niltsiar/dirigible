import Foundation
import Testing

@testable import DirigibleCore

/// A package XML file from another person (decision 0003): the reader refuses a DTD and each
/// encoding other than UTF-8, so no entity of the file reads a local file or expands.
struct PackageXMLTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "PackageXMLTests-\(UUID().uuidString)")
    var package: URL { folder.appending(path: "Episode.dirigible") }
    static let canaryText = "canary text of PackageXMLTests"
    static let attributes = #"xmlns="https://github.com/niltsiar/dirigible/session" version="12" sampleRate="48000""#
    /// A session whose notes hold `A`, the internal entity `i`, and `B`.
    static let internalEntity =
        "<!DOCTYPE session [<!ENTITY i \"EXPANDED\">]>\n<session \(attributes)><episode><notes>A&i;B</notes></episode></session>\n"
    /// The DTD of `internalEntity` in UTF-7: every byte is ASCII, and no byte run is `<!DOCTYPE`.
    static let utf7DTD = "+ADw-!DOCTYPE session +AFs-+ADw-!ENTITY i +ACI-EXPANDED+ACI-+AD4-+AF0-+AD4-"
    static let utf7Session = "\(utf7DTD)\n<session \(attributes)><episode><notes>A&i;B</notes></episode></session>\n"

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The notes of the session that `data` reads to, or the error of the read.
    static func notes(_ data: Data) -> Result<String, SessionFileError> {
        Result { () throws(SessionFileError) in try Session(xml: data).episode.notes?.text ?? "" }
    }

    /// `data` with `<!DOCTYPE <root> [<entity>]>` after its XML declaration, and `marker` replaced by `&x;`.
    static func withDTD(_ data: Data, root: String, entity: String, replacing marker: String) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("<?xml ") && text.contains(marker), "the fixture holds \(marker)")
        let dtd = text.replacing("?>", with: "?>\n<!DOCTYPE \(root) [\(entity)]>", maxReplacements: 1)
        return Data(dtd.replacing(marker, with: "&x;", maxReplacements: 1).utf8)
    }

    /// The `file://` URL of a new canary file in the test folder.
    func canary() throws -> String {
        let url = folder.appending(path: "canary.txt")
        try Data(Self.canaryText.utf8).write(to: url)
        return url.absoluteString
    }

    /// C1. An external entity with an absolute path, one with a relative path,
    /// and a parameter entity that loads an external DTD.
    @Test func anExternalEntityIsRefused() throws {
        let canary = try canary()
        let dtd = folder.appending(path: "ext.dtd")
        try Data(#"<!ENTITY y "from-external-dtd">"#.utf8).write(to: dtd)
        let inputs = [
            ("absolute", #"<!DOCTYPE session [<!ENTITY x SYSTEM "\#(canary)">]>"#, "x"),
            ("relative", #"<!DOCTYPE session [<!ENTITY x SYSTEM "canary.txt">]>"#, "x"),
            ("parameter", #"<!DOCTYPE session [<!ENTITY % p SYSTEM "\#(dtd.absoluteString)"> %p;]>"#, "y"),
        ]
        for (name, doctype, entity) in inputs {
            let xml =
                "<?xml version=\"1.0\"?>\n\(doctype)\n<session \(Self.attributes)><episode><notes>A&\(entity);B</notes></episode></session>\n"
            #expect(Self.notes(Data(xml.utf8)) == .failure(.malformedXML), "\(name)")
        }
    }

    /// C2. A transcript file with an external or an internal entity does not decode, and the
    /// package opens with only that transcript not loaded.
    @Test func aTranscriptWithADTDDoesNotLoad() throws {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 500_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 500_000), on: "guest")
        session.addWords([(1, 10_000..<20_000, "Welcome")], file: "h")
        session.addWords([(1, 40_000..<50_000, "yes")], file: "g", transcript: 2)
        let entities = [
            ("external", #"<!ENTITY x SYSTEM "\#(try canary())">"#), ("internal", #"<!ENTITY x "EXPANDED">"#),
        ]
        for (name, entity) in entities {
            let package = folder.appending(path: "\(name).dirigible")
            try session.write(to: package)
            let file = try #require(session.transcripts[TranscriptID(1)]?.file)
            let url = package.appending(path: "Transcripts/\(file).xml")
            let data = try Self.withDTD(Data(contentsOf: url), root: "transcript", entity: entity, replacing: "Welcome")
            try data.write(to: url)

            let decoded = Result { () throws(SessionFileError) in try TranscriptStore.decode(data) }
            #expect(decoded.map { $0["h"]?.all.map(\.text) } == .failure(.malformedXML), "\(name): decode")
            let opened = try Session(contentsOf: package)
            #expect(opened.transcripts[TranscriptID(1)]?.words?["h"]?.all.map(\.text) == nil, "\(name): not loaded")
            #expect(opened.transcripts[TranscriptID(2)]?.words != nil, "\(name): the other transcript loads")
        }
    }

    /// C4. Nested internal entities (5 levels, 300000 characters) and one internal
    /// entity are refused, by the reader and by the byte rules.
    @Test func anInternalEntityIsRefused() {
        let level = (1...4).map { level in
            "<!ENTITY l\(level) \"\(String(repeating: "&l\(level - 1);", count: 10))\">"
        }
        let laughs =
            "<?xml version=\"1.0\"?>\n<!DOCTYPE session [<!ENTITY l0 \"\(String(repeating: "lol", count: 10))\">"
            + level.joined() + "]>\n<session \(Self.attributes)><episode><notes>&l4;</notes></episode></session>\n"
        let declared = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + Self.internalEntity
        for (name, data) in [("small-laughs", Data(laughs.utf8)), ("internal", Data(declared.utf8))] {
            #expect(Self.notes(data).map(\.count) == .failure(.malformedXML), "\(name): the count of the notes")
            #expect(!isPlainPackageXML(data), "\(name): the byte rules")
        }
    }

    /// C5. Each encoding that libxml2 reads, so that a DTD has no `<!DOCTYPE` bytes, is refused
    /// by the reader and by the byte rules. A tab or a line feed before `encoding` too.
    @Test func eachEncodingBypassIsRefused() throws {
        let declared = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n" + Self.internalEntity
        let utf32 = "<?xml version=\"1.0\" encoding=\"UTF-32\"?>\n" + Self.internalEntity
        let latin1 = "<session \(Self.attributes)><episode><notes>A\u{E9}B</notes></episode></session>\n"
        let cp037 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.EBCDIC_CP037.rawValue)))
        let ebcdic = try #require(
            ("<?xml version=\"1.0\" encoding=\"IBM037\"?>\n" + Self.internalEntity).data(using: cp037))
        #expect(ebcdic.prefix(4) == Data([0x4C, 0x6F, 0xA7, 0x94]), "EBCDIC: <?xm in code page 037")
        let inputs: [(String, Data?)] = [
            ("UTF-16LE, no BOM", declared.data(using: .utf16LittleEndian)),
            ("UTF-16BE, no BOM", declared.data(using: .utf16BigEndian)),
            ("UTF-16LE, BOM", declared.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }),
            ("UTF-7", Data("<?xml version=\"1.0\" encoding=\"UTF-7\"?>\n\(Self.utf7Session)".utf8)),
            ("UTF-7, single quotes", Data("<?xml version='1.0' encoding='UTF-7'?>\n\(Self.utf7Session)".utf8)),
            ("UTF-7, spaces", Data("<?xml version=\"1.0\" encoding = \"UTF-7\"?>\n\(Self.utf7Session)".utf8)),
            ("UTF-7, tab", Data("<?xml version=\"1.0\"\tencoding=\"UTF-7\"?>\n\(Self.utf7Session)".utf8)),
            ("UTF-7, line feed", Data("<?xml version=\"1.0\"\nencoding=\"UTF-7\"?>\n\(Self.utf7Session)".utf8)),
            ("no closing quote", Data("<?xml version=\"1.0\" encoding=\"UTF-7?>\n\(Self.utf7Session)".utf8)),
            (
                "Latin-1, declared",
                ("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n" + latin1).data(using: .isoLatin1)
            ),
            ("EBCDIC IBM037", ebcdic),
            ("UTF-32BE, no BOM", utf32.data(using: .utf32BigEndian)),
            ("UTF-32BE, no BOM, no declaration", Self.internalEntity.data(using: .utf32BigEndian)),
            ("Latin-1, no declaration", latin1.data(using: .isoLatin1)),
            (
                "white space before the root",
                Data("\n  <session \(Self.attributes)><episode><notes>AB</notes></episode></session>\n".utf8)
            ),
        ]
        for (name, input) in inputs {
            let data = try #require(input, "\(name): the fixture encodes")
            #expect(Self.notes(data) == .failure(.malformedXML), "\(name): the notes")
            #expect(!isPlainPackageXML(data), "\(name): the byte rules")
        }
    }

    /// C6. What a writer writes reads back: text that looks like a DTD, a declaration with
    /// `UTF-8` in another case or in other quotes, no declaration, and a UTF-8 BOM.
    @Test func guardPassesWhatTheWriterWrites() throws {
        let look = #"<!DOCTYPE x [<!ENTITY a "b">]> &a;"#
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: look, layout: .mono)
        var episode = Episode()
        episode.notes = EpisodeNotes(look)
        session.setEpisode(episode)
        let written = try session.checkedData()
        #expect(isPlainPackageXML(written), "the writer output")
        #expect(try Session(xml: written) == session, "the writer output reads back equal")

        let body = "<session \(Self.attributes)><episode><notes>AB</notes></episode></session>\n"
        let inputs = [
            ("utf-8", Data("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n\(body)".utf8)),
            ("Utf-8", Data("<?xml version=\"1.0\" encoding=\"Utf-8\"?>\n\(body)".utf8)),
            ("single quotes", Data("<?xml version='1.0' encoding='UTF-8'?>\n\(body)".utf8)),
            ("spaces", Data("<?xml version=\"1.0\" encoding = \"UTF-8\"?>\n\(body)".utf8)),
            ("no encoding", Data("<?xml version=\"1.0\"?>\n\(body)".utf8)),
            ("no declaration", Data(body.utf8)),
            ("BOM", Data([0xEF, 0xBB, 0xBF]) + Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\(body)".utf8)),
        ]
        for (name, data) in inputs {
            #expect(isPlainPackageXML(data), "\(name): the byte rules")
            #expect(Self.notes(data) == .success("AB"), "\(name): the notes")
        }

        var random = SplitMix(seed: 1245)
        let parts = ["<!DOCTYPE", "<!ENTITY", "&a;", "<?xml encoding=\"UTF-7\"?>", "]>", "\"", "'", " ", "é", "x"]
        for _ in 0..<50 {
            let text = (0..<8).map { _ in parts[Int.random(in: 0..<parts.count, using: &random)] }.joined()
            var copy = session
            var episode = Episode()
            episode.notes = EpisodeNotes(text)
            copy.setEpisode(episode)
            let data = try copy.checkedData()
            let same = isPlainPackageXML(data) && (try? Session(xml: data)) == copy
            #expect(same, "\(text) reads back equal")
        }
    }

    /// C7. A backup with a DTD is damaged: the revert refuses it, and the prune scan names it and
    /// keeps no file for it.
    @Test func aBackupWithADTDIsDamaged() throws {
        var current = Session(sampleRate: 48_000)
        try current.addTrack("a", name: "A", layout: .mono)
        try current.addFile(AudioFile(id: "b", path: "b.wav", layout: .mono, length: 48_000))
        try current.write(to: package)
        let clips = package.appending(path: clipsFolderName)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Data(count: 4).write(to: clips.appending(path: "b.wav"))
        var old = current
        try old.place(Clip(id: "c", file: "b", start: 0, offset: 0, length: 1), on: "a")
        var episode = Episode()
        episode.notes = EpisodeNotes("AMARKB")
        old.setEpisode(episode)
        let backup = Backup(saved: Date(timeIntervalSince1970: 2_000_000_000))
        let backups = package.appending(path: backupsFolderName)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Self.withDTD(old.checkedData(), root: "session", entity: #"<!ENTITY x "EXPANDED">"#, replacing: "MARK")
            .write(to: backups.appending(path: backup.fileName))

        let lock = try PackageLock(package)
        let revert = Result { () throws(RevertReadError) in try backup.readForRevert(under: lock) }
        #expect(revert.map { $0.episode.notes?.text } == .failure(.backup(.malformedXML)), "the revert")
        withExtendedLifetime(lock) {}
        let scan = try UnusedFiles(scanning: current, keptBy: [], soleCopies: [], in: package)
        #expect(scan.items.map(\.kind) == [.pool("b")], "the backup keeps no file")
        #expect(scan.damagedBackups == [backup], "the scan names the backup")
    }
}
