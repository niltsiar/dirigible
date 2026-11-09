import DirigibleCore
import Foundation
import Testing

@testable import DirigibleMCP

/// One edit tool call and the `dirigible` command that must give the same `session.xml` and the
/// same text (C6), or the same refusal (C7). The package path goes in at run time ("PKG").
struct EditRow {
    let tool: String
    let arguments: [String: Any]
    let command: [String]
    /// The tool and the command each make a new UUID for an ID that the row leaves out.
    var generated = false
    /// The lines that the tool adds after its answer and the command does not print.
    var toolNote: [String] = []
}

/// C6 and C7 for the edit tools, and the fixture that every row starts from.
struct MCPEditTableTests {
    /// Capture k1 has no file. File u has no clip. Track a: clips A 0..<48000, A2 96000..<144000,
    /// and A3 144000..<192000 from another part of file f, so A2 and A3 can have a crossfade. Track b: clip C 90000..<150000 (file f). Track s (stereo): clip G
    /// 0..<48000 (file g). Track e is empty. Marker m1 at 48000.
    static func fixture() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: "k1", deviceUID: "usb", deviceName: "USB", hostTimeNanos: 1, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0, resampledFromRate: nil,
                driftCorrected: true))
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .stereo, length: 480_000))
        try session.addFile(AudioFile(id: "u", path: "u.wav", layout: .mono, length: 480_000))
        for (id, layout) in [("a", ChannelLayout.mono), ("b", .mono), ("s", .stereo), ("e", .mono)] {
            try session.addTrack(TrackID(id), name: id.uppercased(), layout: layout)
        }
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 0, length: 48_000), on: "a")
        try session.place(Clip(id: "A2", file: "f", start: 96_000, offset: 96_000, length: 48_000), on: "a")
        try session.place(Clip(id: "A3", file: "f", start: 144_000, offset: 300_000, length: 48_000), on: "a")
        try session.place(Clip(id: "C", file: "f", start: 90_000, offset: 0, length: 60_000), on: "b")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 48_000), on: "s")
        try session.setMarker(Marker(id: "m1", name: "One", position: 48_000, kind: .marker))
        return session
    }

    static var trackRows: [EditRow] {
        [
            EditRow(
                tool: "track_add", arguments: ["name": "N", "layout": "mono", "id": "n"],
                command: ["track", "add", "PKG", "--name", "N", "--layout", "mono", "--id", "n"]),
            EditRow(
                tool: "track_add", arguments: ["name": "N", "layout": "stereo"],
                command: ["track", "add", "PKG", "--name", "N", "--layout", "stereo"], generated: true),
            EditRow(
                tool: "track_add", arguments: ["name": "N", "layout": "mono", "id": NSNull()],
                command: ["track", "add", "PKG", "--name", "N", "--layout", "mono"], generated: true),
            EditRow(
                tool: "track_add_call",
                arguments: ["device": "D", "channels": [2], "app": "us.zoom.xos", "host_id": "h", "guest_id": "q"],
                command: [
                    "track", "add-call", "PKG", "--device", "D", "--channels", "2", "--app", "us.zoom.xos", "--host-id",
                    "h", "--guest-id", "q",
                ]),
            EditRow(tool: "track_add_call", arguments: [:], command: ["track", "add-call", "PKG"], generated: true),
            EditRow(tool: "track_remove", arguments: ["track": "b"], command: ["track", "remove", "PKG", "b"]),
            EditRow(
                tool: "track_rename", arguments: ["track": "a", "name": "Host"],
                command: ["track", "rename", "PKG", "a", "Host"]),
            EditRow(
                tool: "track_gain", arguments: ["track": "a", "db": -3.5],
                command: ["track", "gain", "PKG", "a", "--db", "-3.5"]),
            EditRow(
                tool: "track_route", arguments: ["track": "a", "device": "D", "channels": [1]],
                command: ["track", "route", "PKG", "a", "--device", "D", "--channels", "1"]),
            EditRow(
                tool: "track_route", arguments: ["track": "s", "device": "D", "channels": [1, 2], "none": false],
                command: ["track", "route", "PKG", "s", "--device", "D", "--channels", "1,2"]),
            EditRow(
                tool: "track_route", arguments: ["track": "a", "app": "us.zoom.xos"],
                command: ["track", "route", "PKG", "a", "--app", "us.zoom.xos"]),
            EditRow(
                tool: "track_route", arguments: ["track": "a", "none": true],
                command: ["track", "route", "PKG", "a", "--none"]),
            EditRow(
                tool: "track_layout",
                arguments: ["track": "e", "layout": "stereo", "device": "D", "channels": [1, 2]],
                command: ["track", "layout", "PKG", "e", "stereo", "--device", "D", "--channels", "1,2"]),
            EditRow(
                tool: "track_mute", arguments: ["tracks": ["a", "b"]], command: ["track", "mute", "PKG", "a", "b"]),
            EditRow(
                tool: "track_mute", arguments: ["tracks": ["a"], "off": true],
                command: ["track", "mute", "PKG", "a", "--off"]),
            EditRow(tool: "track_solo", arguments: ["tracks": ["s"]], command: ["track", "solo", "PKG", "s"]),
            EditRow(
                tool: "track_solo", arguments: ["tracks": ["s"], "off": true],
                command: ["track", "solo", "PKG", "s", "--off"]),
            EditRow(
                tool: "track_follow", arguments: ["tracks": ["a", "b"]], command: ["track", "follow", "PKG", "a", "b"]),
            EditRow(
                tool: "track_follow", arguments: ["tracks": ["a"], "off": true],
                command: ["track", "follow", "PKG", "a", "--off"]),
            EditRow(
                tool: "track_role", arguments: ["track": "a", "role": "music"],
                command: ["track", "role", "PKG", "a", "music"], toolNote: [EditRules.roleReply]),
            EditRow(
                tool: "track_role", arguments: ["track": "a", "role": "none"],
                command: ["track", "role", "PKG", "a", "none"], toolNote: [EditRules.roleReply]),
        ]
    }

    static var trackRefusals: [EditRow] {
        [
            EditRow(
                tool: "track_add", arguments: ["name": "N", "layout": "mono", "id": "a"],
                command: ["track", "add", "PKG", "--name", "N", "--layout", "mono", "--id", "a"]),
            EditRow(
                tool: "track_add_call", arguments: ["host_id": "a"],
                command: ["track", "add-call", "PKG", "--host-id", "a"]),
            EditRow(tool: "track_remove", arguments: ["track": "zz"], command: ["track", "remove", "PKG", "zz"]),
            EditRow(
                tool: "track_rename", arguments: ["track": "zz", "name": "N"],
                command: ["track", "rename", "PKG", "zz", "N"]),
            EditRow(
                tool: "track_gain", arguments: ["track": "zz", "db": 1],
                command: ["track", "gain", "PKG", "zz", "--db", "1"]),
            EditRow(
                tool: "track_route", arguments: ["track": "a", "device": "D", "channels": [0]],
                command: ["track", "route", "PKG", "a", "--device", "D", "--channels", "0"]),
            EditRow(
                tool: "track_layout", arguments: ["track": "a", "layout": "stereo", "none": true],
                command: ["track", "layout", "PKG", "a", "stereo", "--none"]),
            EditRow(tool: "track_mute", arguments: ["tracks": ["zz"]], command: ["track", "mute", "PKG", "zz"]),
            EditRow(tool: "track_follow", arguments: ["tracks": ["zz"]], command: ["track", "follow", "PKG", "zz"]),
            EditRow(
                tool: "track_solo", arguments: ["tracks": ["a", "zz"]], command: ["track", "solo", "PKG", "a", "zz"]),
            EditRow(
                tool: "track_role", arguments: ["track": "zz", "role": "music"],
                command: ["track", "role", "PKG", "zz", "music"]),
        ]
    }

    static var markerAndPoolRows: [EditRow] {
        [
            EditRow(
                tool: "marker_set", arguments: ["name": "Two", "at": 96_000, "kind": "chapter", "id": "m2"],
                command: ["marker", "set", "PKG", "--name", "Two", "--at", "96000", "--kind", "chapter", "--id", "m2"]),
            EditRow(
                tool: "marker_set", arguments: ["name": "Two", "at": 96_000],
                command: ["marker", "set", "PKG", "--name", "Two", "--at", "96000"], generated: true),
            EditRow(tool: "marker_remove", arguments: ["marker": "m1"], command: ["marker", "remove", "PKG", "m1"]),
            EditRow(tool: "capture_remove", arguments: ["capture": "k1"], command: ["capture", "remove", "PKG", "k1"]),
            EditRow(tool: "file_remove", arguments: ["file": "u"], command: ["file", "remove", "PKG", "u"]),
        ]
    }

    static var markerAndPoolRefusals: [EditRow] {
        [
            EditRow(
                tool: "marker_set", arguments: ["name": "X", "at": -1],
                command: ["marker", "set", "PKG", "--name", "X", "--at", "-1"]),
            EditRow(tool: "marker_remove", arguments: ["marker": "zz"], command: ["marker", "remove", "PKG", "zz"]),
            EditRow(tool: "capture_remove", arguments: ["capture": "zz"], command: ["capture", "remove", "PKG", "zz"]),
            EditRow(tool: "file_remove", arguments: ["file": "f"], command: ["file", "remove", "PKG", "f"]),
        ]
    }

    static var editRows: [EditRow] { trackRows + markerAndPoolRows + clipRows }

    /// One case for each row, so each `dirigible mcp` child serves one call: one child for all the
    /// rows took 18 s alone and passed its 30 s limit under the load of the test shards.
    @Test(arguments: 0..<MCPEditTableTests.editRows.count)
    func eachEditToolMatchesItsCommand(row: Int) async throws {
        try await checkEdits([Self.editRows[row]])
    }

    @Test func eachEditToolRefusesAsItsCommand() async throws {
        try await checkRefusals(Self.trackRefusals + Self.markerAndPoolRefusals + Self.clipRefusals)
    }
}

/// Runs each row on its own two copies of the fixture: the tool on one, the command on the other.
/// The `session.xml` files must be equal byte for byte, and the text must be the printed IDs or OK,
/// then the note lines of the row.
/// A generated ID must be a UUID; a placeholder takes its place before the compare.
func checkEdits(_ rows: [EditRow]) async throws {
    let fixture = try MCPEditTableTests.fixture()
    var copies: [(tool: TemporaryPackage, cli: TemporaryPackage)] = []
    for _ in rows { copies.append((try TemporaryPackage(fixture), try TemporaryPackage(fixture))) }
    let answers = try await mcp(
        rows.enumerated().map { index, row in
            toolCall(index, row.tool, row.arguments.merging(["package": copies[index].tool.path]) { $1 })
        })
    for (index, row) in rows.enumerated() {
        let cli = try await copies[index].cli.run(row.command)
        var tool = toolResult(answer(answers, id: index))
        #expect(cli.status == 0 && !tool.isError, "\(row.tool) \(row.arguments): \(tool.text) \(cli.stderr)")
        if !row.toolNote.isEmpty {
            let note = "\n" + row.toolNote.joined(separator: "\n")
            #expect(tool.text.hasSuffix(note), "\(row.tool) lacks its note: \(tool.text)")
            if tool.text.hasSuffix(note) { tool.text = String(tool.text.dropLast(note.count)) }
        }
        let cliIDs = cli.stdout.split(separator: "\n").map(String.init)
        let toolIDs = tool.text == "OK" ? [] : tool.text.split(separator: "\n").map(String.init)
        #expect(tool.text != "" && (cliIDs.isEmpty == (tool.text == "OK")), "\(row.tool): \(tool.text)")
        var toolXML = String(decoding: try copies[index].tool.xml(), as: UTF8.self)
        var cliXML = String(decoding: try copies[index].cli.xml(), as: UTF8.self)
        if row.generated {
            let ids = toolIDs + cliIDs
            #expect(
                toolIDs.count == cliIDs.count && ids.allSatisfy { UUID(uuidString: $0) != nil }, "\(row.tool) \(ids)")
            for (number, (toolID, cliID)) in zip(toolIDs, cliIDs).enumerated() {
                toolXML = toolXML.replacing(toolID, with: "ID-\(number)")
                cliXML = cliXML.replacing(cliID, with: "ID-\(number)")
            }
        } else {
            #expect(toolIDs == cliIDs, "\(row.tool) \(row.arguments)")
        }
        #expect(toolXML == cliXML, "\(row.tool) \(row.arguments) gives another session.xml than its command")
    }
}

/// Runs each refused row on one copy of the fixture: the tool error text is the CLI error line,
/// and the package does not change.
func checkRefusals(_ rows: [EditRow]) async throws {
    let package = try TemporaryPackage(try MCPEditTableTests.fixture())
    let before = try package.xml()
    let answers = try await mcp(
        rows.enumerated().map { index, row in
            toolCall(index, row.tool, row.arguments.merging(["package": package.path]) { $1 })
        })
    for (index, row) in rows.enumerated() {
        let cli = try await package.run(row.command)
        let tool = toolResult(answer(answers, id: index))
        #expect(cli.status == 1 || cli.status == 3, "\(row.command): \(cli)")
        #expect(tool.isError && tool.text == errorText(cli), "\(row.tool): \(tool.text) | \(cli.stderr)")
    }
    #expect(try package.xml() == before)
}
