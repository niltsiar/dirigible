import ArgumentParser
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleCLI

let invalidRouteMessage = "the route has a channel number less than 1 or an empty app ID."

struct TrackCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("host", name: "Host", layout: .mono)
        package = try TemporaryPackage(session)
    }

    private func track(_ arguments: [String]) async throws -> CLIResult { try await package.run(["track"] + arguments) }

    @Test func eachVerbAppliesItsEdit() async throws {
        let fresh = try TemporaryPackage(Session(sampleRate: 48_000))
        #expect(
            try await dirigible("track", "add", fresh.path, "--id", "host", "--name", "Host", "--layout", "mono")
                == CLIResult(status: 0, stdout: "host\n", stderr: ""))
        #expect(try fresh.read().track("host")?.name == "Host")
        #expect(try fresh.read().track("host")?.layout == .mono)

        let added = try await dirigible("track", "add", fresh.path, "--name", "Guest", "--layout", "stereo")
        #expect(added.status == 0)
        let guest = TrackID(String(added.stdout.dropLast()))
        #expect(added.stdout == "\(guest)\n" && UUID(uuidString: guest.rawValue) != nil)
        #expect(try fresh.read().track(guest)?.layout == .stereo)

        let silent = CLIResult(status: 0, stdout: "", stderr: "")
        #expect(try await dirigible("track", "rename", fresh.path, "host", "Presenter") == silent)
        #expect(try fresh.read().track("host")?.name == "Presenter")

        #expect(try await dirigible("track", "gain", fresh.path, "host", "--db", "-3.5") == silent)
        #expect(try fresh.read().track("host")?.gain == Gain(dB: -3.5))

        #expect(try await dirigible("track", "route", fresh.path, "host", "--device", "D", "--channels", "1") == silent)
        #expect(try fresh.read().track("host")?.route == Route.device(uid: "D", channels: .mono(1)))

        #expect(try await dirigible("track", "layout", fresh.path, "host", "stereo", "--none") == silent)
        #expect(try fresh.read().track("host")?.layout == .stereo)
        #expect(try fresh.read().track("host")?.route == nil)

        #expect(
            try await dirigible("track", "route", fresh.path, guest.rawValue, "--device", "D", "--channels", "1,2")
                == silent)
        #expect(try fresh.read().track(guest)?.route == Route.device(uid: "D", channels: .stereo(1, 2)))
        #expect(try await dirigible("track", "route", fresh.path, guest.rawValue, "--none") == silent)
        #expect(try fresh.read().track(guest)?.route == nil)

        #expect(try await dirigible("track", "remove", fresh.path, "host") == silent)
        #expect(try fresh.read().tracks.map(\.id) == [guest])
    }

    /// A3: `track route --app` sets an app route, and the package saves version 2.
    @Test func routeAppSetsAnAppRoute() async throws {
        #expect(
            try await track(["route", "PKG", "host", "--app", "us.zoom.xos"])
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read().track("host")?.route == .app(bundleID: "us.zoom.xos"), "the app route")
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="2""#), "version 2")
        #expect(
            try await track(["layout", "PKG", "host", "stereo", "--app", "us.zoom.xos"])
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read().track("host")?.layout == .stereo, "a stereo mixdown")
    }

    /// A14: with no process taps (macOS 14.0 and 14.1), `--app` exits 1 and changes nothing.
    /// The availability is an injected value; a device route still applies.
    @Test func routeAppNeedsProcessTaps() throws {
        let before = try package.xml()
        let route = try TrackCommand.SetRoute.parse([package.path, "host", "--app", "us.zoom.xos"])
        #expect(throws: ExitCode(editRefused)) { try route.apply(tapsAvailable: false) }
        let layout = try TrackCommand.SetLayout.parse([package.path, "host", "stereo", "--app", "us.zoom.xos"])
        #expect(throws: ExitCode(editRefused)) { try layout.apply(tapsAvailable: false) }
        #expect(try package.xml() == before, "the package did not change")
        #expect(appSourcesUnavailableMessage == "app sources need macOS 14.2 or later.")

        try TrackCommand.SetRoute.parse([package.path, "host", "--device", "D", "--channels", "1"])
            .apply(tapsAvailable: false)
        #expect(try package.read().track("host")?.route == .device(uid: "D", channels: .mono(1)), "control")
    }

    @Test func aNameAfterTheSeparatorCanStartWithADash() async throws {
        #expect(
            try await track(["rename", "PKG", "host", "--", "-Odd"]) == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read().track("host")?.name == "-Odd")
    }

    @Test(arguments: [
        (["rename", "PKG", "nope", "X"], "no track \"nope\"."),
        (["rename", "PKG", "host", "A\u{01}B"], "the text \"A\\u{01}B\" has a control character."),
        (
            ["route", "PKG", "host", "--device", "D", "--channels", "1,2"],
            "the route does not have the layout of track \"host\"."
        ),
        (["route", "PKG", "host", "--device", "D", "--channels", "0"], invalidRouteMessage),
        (["route", "PKG", "host", "--app", ""], invalidRouteMessage),
        (["route", "PKG", "host", "--app", "a\u{01}b"], "the text \"a\\u{01}b\" has a control character."),
    ])
    func refusedEditExitsOne(arguments: [String], message: String) async throws {
        let before = try package.xml()
        let result = try await track(arguments)
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
        ["route", "PKG", "host", "--app", "us.zoom.xos", "--device", "D", "--channels", "1"],
        ["route", "PKG", "host", "--app", "us.zoom.xos", "--device", "D"],
        ["route", "PKG", "host", "--app", "us.zoom.xos", "--none"],
        ["layout", "PKG", "host", "stereo", "--app", "us.zoom.xos", "--none"],
        ["layout", "PKG", "host", "stereo"],
    ])
    func usageErrorExits64(arguments: [String]) async throws {
        try package.edit { try $0.setRoute(Route.device(uid: "D", channels: .mono(1)), track: "host") }
        let before = try package.xml()
        let result = try await track(arguments)
        #expect(result.status == 64)
        #expect(try package.xml() == before)
    }

    /// Every edit command goes through one read-edit-save step, so one command covers them all.
    @Test func editRefusesAPackageWithAPendingTake() async throws {
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["host"]))
        }
        let before = try package.xml()
        #expect(
            try await track(["gain", "PKG", "host", "--db", "1"])
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path) has a take that is not finalized; open it in Dirigible first.\n"))
        #expect(try package.xml() == before)
        #expect(try await dirigible("info", package.path).status == 0)
    }
}
