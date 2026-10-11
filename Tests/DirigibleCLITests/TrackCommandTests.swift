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

    /// Mute and solo C9 a, b (decision 0039): `track mute` and `track solo` set and clear the
    /// flags. `info` shows a flag only when it is set.
    @Test func muteAndSoloSetAndClearTheFlags() async throws {
        try package.edit { try $0.addTrack("guest", name: "Guest", layout: .mono) }
        let silent = CLIResult(status: 0, stdout: "", stderr: "")
        #expect(try await track(["mute", "PKG", "host"]) == silent)
        #expect(try package.read().tracks.map(\.isMuted) == [true, false])
        #expect(try await track(["solo", "PKG", "host", "guest"]) == silent)
        #expect(try package.read().tracks.map(\.isSoloed) == [true, true])
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="5""#), "saved as version 5")

        let text = try await package.run("info", "PKG").stdout
        #expect(text.contains("track host \"Host\" mono 0.0 dB muted soloed\n"), "b: both flags of host")
        #expect(text.contains("track guest \"Guest\" mono 0.0 dB soloed\n"), "b: the solo of guest")
        let json = try await package.run("info", "PKG", "--json").stdout
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let tracks = try #require(object?["tracks"] as? [[String: Any]])
        #expect(tracks[0]["muted"] as? Bool == true && tracks[1]["muted"] == nil, "b: muted only when set")
        #expect(tracks[1]["soloed"] as? Bool == true, "b: soloed in the JSON")

        #expect(try await track(["mute", "PKG", "host", "--off"]) == silent)
        #expect(try await track(["solo", "PKG", "host", "guest", "--off"]) == silent)
        let cleared = try package.read().tracks
        #expect(!cleared.contains { $0.isMuted || $0.isSoloed }, "--off clears the flags")
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="1""#), "back to version 1")
        #expect(try await package.run("info", "PKG").stdout.contains("track host \"Host\" mono 0.0 dB\n"))
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
        (["mute", "PKG", "nope"], "no track \"nope\"."),
        (["solo", "PKG", "host", "nope"], "no track \"nope\"."),
    ])
    func refusedEditExitsOne(arguments: [String], message: String) async throws {
        let before = try package.xml()
        let result = try await track(arguments)
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"))
        #expect(try package.xml() == before)
    }

    /// Track fader C2: `track gain` and `clip gain` refuse a gain outside -96...+96 dB with the
    /// range in the text, and take the range end.
    @Test func aGainOutsideTheRangeIsRefusedWithTheRange() async throws {
        let before = try package.xml()
        for (verb, value) in [("track", "96.1"), ("clip", "-1e300")] {
            let target = verb == "track" ? "host" : "c1"
            let result = try await package.run([verb, "gain", "PKG", target, "--db", value])
            #expect(result.status == 64, "C2: \(verb) gain \(value) is a usage error")
            #expect(result.stderr.contains("A gain is a number of dB from -96 to 96."), "C2: the text gives the range")
        }
        #expect(try package.xml() == before, "C2: a refused gain changes nothing")
        #expect(try await package.run(["track", "gain", "PKG", "host", "--db", "96"]).status == 0)
        #expect(try package.read().track("host")?.gain == Gain(dB: 96), "C2: the range end passes")
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
        ["mute", "PKG"],
        ["solo", "PKG", "--off"],
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

    // MARK: B1b, track add-call

    /// Host on the device channel and Guest on the app; stdout has the Host ID, then the Guest ID.
    @Test func addCallWithBothRoutes() async throws {
        let result = try await track([
            "add-call", "PKG", "--device", "D", "--channels", "2", "--app", "us.zoom.xos", "--host-id", "h",
            "--guest-id", "g",
        ])
        #expect(result == CLIResult(status: 0, stdout: "h\ng\n", stderr: ""))
        let session = try package.read()
        #expect(session.tracks.map(\.id) == ["host", "h", "g"])
        #expect(session.tracks.map(\.name) == ["Host", "Host", "Guest"])
        #expect(session.track("h")?.route == .device(uid: "D", channels: .mono(2)), "the Host route")
        #expect(session.track("g")?.route == .app(bundleID: "us.zoom.xos"), "the Guest route")
        #expect(session.tracks.allSatisfy { $0.layout == .mono })
    }

    /// With no option: two tracks with new UUIDs and no route.
    @Test func addCallWithNoOptions() async throws {
        let result = try await track(["add-call", "PKG"])
        #expect(result.status == 0 && result.stderr.isEmpty)
        let ids = result.stdout.split(separator: "\n").map { TrackID(String($0)) }
        #expect(ids.count == 2 && ids.allSatisfy { UUID(uuidString: $0.rawValue) != nil }, "two UUIDs")
        let session = try package.read()
        #expect(session.tracks.map(\.id) == ["host"] + ids)
        #expect(session.tracks.dropFirst().allSatisfy { $0.route == nil })
    }

    /// A half device route or a channel pair exits 64 with its reason and no change.
    @Test(arguments: [
        (["add-call", "PKG", "--device", "D"], "Give --device with --channels."),
        (["add-call", "PKG", "--channels", "1"], "Give --device with --channels."),
        (["add-call", "PKG", "--device", "D", "--channels", "1,2"], "Host takes one channel."),
    ])
    func addCallRefusesAHalfDeviceRouteOrAChannelPair(arguments: [String], message: String) async throws {
        let before = try package.xml()
        let result = try await track(arguments)
        #expect(result.status == 64)
        #expect(result.stderr.contains(message), "the reason: \(result.stderr)")
        #expect(try package.xml() == before)
    }

    /// A14: with no process taps, `--app` exits 1 and changes nothing; a device route applies.
    @Test func addCallRefusesAnAppWithNoTaps() throws {
        let before = try package.xml()
        let call = try TrackCommand.AddCall.parse([package.path, "--app", "us.zoom.xos"])
        #expect(throws: ExitCode(editRefused)) { try call.apply(tapsAvailable: false) }
        #expect(try package.xml() == before, "the package did not change")

        try TrackCommand.AddCall.parse([package.path, "--device", "D", "--channels", "1"]).apply(tapsAvailable: false)
        #expect(try package.read().tracks.count == 3, "control")
    }
}
