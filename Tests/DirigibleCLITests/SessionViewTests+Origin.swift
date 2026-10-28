import DirigibleCore
import Foundation
import Testing

/// `info`, `info --json`, and `session_info` give the origin of each rendered file (decision 0057,
/// run render-link C10), with the fixture of `ClipRestoreCommandTests`.
extension SessionViewTests {
    /// The JSON object of each file of a session view, by file ID.
    static func files(_ text: String) throws -> [String: [String: Any]] {
        let view = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let files = try #require(view["files"] as? [[String: Any]])
        return Dictionary(uniqueKeysWithValues: files.map { ($0["id"] as? String ?? "", $0) })
    }

    /// C10. The text gives the source, the offset, the added gain, and the effects after the
    /// length. A file with no origin has none.
    @Test func originLine() async throws {
        let package = try TemporaryPackage(try ClipRestoreCommandTests.rendered())
        let text = try await dirigible("info", package.path).stdout

        let lines = text.split(separator: "\n").filter { $0.hasPrefix("file ") }
        #expect(
            lines == [
                #"file f "f.wav" mono length 1000000 media missing"#,
                #"file f NR "f NR.wav" mono length 500000 origin f offset 100000 added gain 1.0 dB noise 12 dB media missing"#,
                #"file f NR NR "f NR NR.wav" mono length 200000 origin f NR offset 50000 added gain 2.0 dB noise 12 dB media missing"#,
                #"file g "g.wav" mono length 1000000 media missing"#,
            ], "\(text)")
    }

    /// C10. The JSON of `info --json` and of `session_info` has `origin` for a rendered file only;
    /// the compact form has no file.
    @Test func originJSON() async throws {
        let package = try TemporaryPackage(try ClipRestoreCommandTests.rendered())
        let json = try await dirigible("info", "--json", package.path).stdout
        let answers = try await mcp([toolCall(1, "session_info", ["package": package.path])])
        let tool = toolResult(answer(answers, id: 1))
        let compact = try await dirigible("info", "--json", "--compact", package.path).stdout

        for text in [json, tool.text] {
            let files = try Self.files(text)
            let origin = files["f NR NR"]?["origin"] as? NSDictionary
            let expected: NSDictionary = [
                "source": "f NR", "offset": 50_000, "addedGain": 2,
                "effects": [["kind": "noise", "decibels": 12]],
            ]
            #expect(origin == expected, "\(text)")
            #expect(files["f"] != nil && files["f"]?["origin"] == nil)
        }
        #expect(!tool.isError)
        #expect(!compact.contains("origin") && !compact.isEmpty, "\(compact)")
    }

    /// C22: a hum origin shows its frequency in the `info` text, in `info --json`, and in
    /// `session_info`.
    @Test func humOrigin() async throws {
        var session = try ClipRestoreCommandTests.rendered()
        let both = try #require(Treatment([.hum(.hz60), .noise(.standard)]))
        try session.addFile(
            AudioFile(
                id: "g HR", path: "g HR.wav", layout: .mono, length: 300_000,
                origin: RenderOrigin(source: "g", offset: 0, treatment: Treatment(.hum(.hz50)), addedGain: .zero)))
        try session.addFile(
            AudioFile(
                id: "g NR", path: "g NR.wav", layout: .mono, length: 300_000,
                origin: RenderOrigin(source: "g", offset: 0, treatment: both, addedGain: .zero)))
        let package = try TemporaryPackage(session)

        let text = try await dirigible("info", package.path).stdout
        let json = try await dirigible("info", "--json", package.path).stdout
        let tool = toolResult(answer(try await mcp([toolCall(1, "session_info", ["package": package.path])]), id: 1))

        let lines = text.split(separator: "\n").filter { $0.hasPrefix("file g HR") || $0.hasPrefix("file g NR") }
        #expect(
            lines == [
                #"file g HR "g HR.wav" mono length 300000 origin g offset 0 added gain 0.0 dB hum 50 Hz media missing"#,
                #"file g NR "g NR.wav" mono length 300000 origin g offset 0 added gain 0.0 dB hum 60 Hz, noise 12 dB media missing"#,
            ], "\(text)")
        for view in [json, tool.text] {
            let files = try Self.files(view)
            let alone = (files["g HR"]?["origin"] as? NSDictionary)?["effects"] as? NSArray
            let pair = (files["g NR"]?["origin"] as? NSDictionary)?["effects"] as? NSArray
            #expect(alone == [["kind": "hum", "hz": 50]] as NSArray, "\(view)")
            #expect(pair == [["kind": "hum", "hz": 60], ["kind": "noise", "decibels": 12]] as NSArray, "\(view)")
        }
    }
}
