import DirigibleCore
import Foundation
import Testing

struct MarkerCommandTests {
    let package: TemporaryPackage

    init() throws {
        package = try TemporaryPackage(Session(sampleRate: 48_000))
    }

    @Test func eachVerbAppliesItsEdit() throws {
        #expect(
            try package.run(
                "marker", "set", "PKG", "--id", "m1", "--name", "Intro", "--at", "48000", "--kind", "chapter")
                == CLIResult(status: 0, stdout: "m1\n", stderr: ""))
        #expect(try package.read().markers == ["m1": Marker(id: "m1", name: "Intro", position: 48_000, kind: .chapter)])

        #expect(
            try package.run("marker", "set", "PKG", "--id", "m1", "--name", "Start", "--at", "0")
                == CLIResult(status: 0, stdout: "m1\n", stderr: ""))
        #expect(try package.read().markers == ["m1": Marker(id: "m1", name: "Start", position: 0, kind: .marker)])

        let added = try package.run("marker", "set", "PKG", "--name", "Note", "--at", "10")
        let id = MarkerID(String(added.stdout.dropLast()))
        #expect(added.status == 0 && UUID(uuidString: id.rawValue) != nil)
        #expect(try package.read().markers[id] == Marker(id: id, name: "Note", position: 10, kind: .marker))

        #expect(try package.run("marker", "remove", "PKG", "m1") == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read().markers.keys.sorted() == [id])
    }

    @Test func refusedEditsExitOne() throws {
        let before = try package.xml()
        #expect(
            try package.run("marker", "remove", "PKG", "nope")
                == CLIResult(status: 1, stdout: "", stderr: "Error: no marker \"nope\".\n"))
        #expect(
            try package.run("marker", "set", "PKG", "--name", "X", "--at", "-1")
                == CLIResult(status: 1, stdout: "", stderr: "Error: a frame is negative or more than 2^40.\n"))
        #expect(try package.xml() == before)
    }

    @Test func markerRefusesUnknownKind() throws {
        let before = try package.xml()
        #expect(try package.run("marker", "set", "PKG", "--name", "X", "--at", "0", "--kind", "note").status == 64)
        #expect(try package.xml() == before)
    }
}
