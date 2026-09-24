import DirigibleCore
import Foundation
import Testing

struct TrackCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        package = try TemporaryPackage(session)
    }

    private func track(_ arguments: [String]) throws -> CLIResult { try package.run(["track"] + arguments) }

    @Test func eachVerbAppliesItsEdit() throws {
        let fresh = try TemporaryPackage(Session(sampleRate: 48_000))
        #expect(
            try dirigible("track", "add", fresh.path, "--id", "host", "--name", "Host", "--layout", "mono")
                == CLIResult(status: 0, stdout: "host\n", stderr: ""))
        #expect(try fresh.read().track("host")?.name == "Host")
        #expect(try fresh.read().track("host")?.layout == .mono)

        let added = try dirigible("track", "add", fresh.path, "--name", "Guest", "--layout", "stereo")
        #expect(added.status == 0)
        let guest = TrackID(String(added.stdout.dropLast()))
        #expect(added.stdout == "\(guest)\n" && UUID(uuidString: guest.rawValue) != nil)
        #expect(try fresh.read().track(guest)?.layout == .stereo)

        let silent = CLIResult(status: 0, stdout: "", stderr: "")
        #expect(try dirigible("track", "rename", fresh.path, "host", "Presenter") == silent)
        #expect(try fresh.read().track("host")?.name == "Presenter")

        #expect(try dirigible("track", "gain", fresh.path, "host", "--db", "-3.5") == silent)
        #expect(try fresh.read().track("host")?.gain == Gain(dB: -3.5))

        #expect(try dirigible("track", "route", fresh.path, "host", "--device", "D", "--channels", "1") == silent)
        #expect(try fresh.read().track("host")?.route == Route(deviceUID: "D", channels: .mono(1)))

        #expect(try dirigible("track", "layout", fresh.path, "host", "stereo", "--none") == silent)
        #expect(try fresh.read().track("host")?.layout == .stereo)
        #expect(try fresh.read().track("host")?.route == nil)

        #expect(
            try dirigible("track", "route", fresh.path, guest.rawValue, "--device", "D", "--channels", "1,2") == silent)
        #expect(try fresh.read().track(guest)?.route == Route(deviceUID: "D", channels: .stereo(1, 2)))
        #expect(try dirigible("track", "route", fresh.path, guest.rawValue, "--none") == silent)
        #expect(try fresh.read().track(guest)?.route == nil)

        #expect(try dirigible("track", "remove", fresh.path, "host") == silent)
        #expect(try fresh.read().tracks.map(\.id) == [guest])
    }

    @Test func aNameAfterTheSeparatorCanStartWithADash() throws {
        #expect(try track(["rename", "PKG", "host", "--", "-Odd"]) == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read().track("host")?.name == "-Odd")
    }

    @Test(arguments: [
        (["rename", "PKG", "nope", "X"], "no track \"nope\"."),
        (["rename", "PKG", "host", "A\u{01}B"], "the text \"A\\u{01}B\" has a control character."),
        (
            ["route", "PKG", "host", "--device", "D", "--channels", "1,2"],
            "the route does not have the layout of track \"host\"."
        ),
        (["route", "PKG", "host", "--device", "D", "--channels", "0"], "a channel number is less than 1."),
    ])
    func refusedEditExitsOne(arguments: [String], message: String) throws {
        let before = try package.xml()
        let result = try track(arguments)
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"))
        #expect(try package.xml() == before)
    }

    @Test(arguments: [
        ["gain", "PKG", "host", "--db", "nan"],
        ["gain", "PKG", "host", "--db", "inf"],
        ["add", "PKG", "--name", "X", "--layout", "quad"],
        ["route", "PKG", "host", "--device", "D", "--channels", "1,2,3"],
        ["route", "PKG", "host", "--device", "D", "--channels", "one"],
        ["route", "PKG", "host", "--none", "--device", "D", "--channels", "1"],
        ["route", "PKG", "host", "--device", "D"],
        ["route", "PKG", "host"],
        ["layout", "PKG", "host", "stereo"],
    ])
    func usageErrorExits64(arguments: [String]) throws {
        try package.edit { try $0.setRoute(Route(deviceUID: "D", channels: .mono(1)), track: "host") }
        let before = try package.xml()
        let result = try track(arguments)
        #expect(result.status == 64)
        #expect(try package.xml() == before)
    }

    /// Every edit command goes through one read-edit-save step, so one command covers them all.
    @Test func editRefusesAPackageWithAPendingTake() throws {
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["host"]))
        }
        let before = try package.xml()
        #expect(
            try track(["gain", "PKG", "host", "--db", "1"])
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path) has a take that is not finalized; open it in Dirigible first.\n"))
        #expect(try package.xml() == before)
        #expect(try dirigible("info", package.path).status == 0)
    }
}
