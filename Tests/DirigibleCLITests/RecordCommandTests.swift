import DirigibleCore
import Foundation
import Testing

/// `dirigible record` refusals (criterion 17). Each case fails before the microphone access
/// read (the lookup or an earlier check), so no test reads or requests the access, and none
/// opens a device. The success path runs in `RecordTests` through the same `Studio.record` call.
struct RecordCommandTests {
    let package: TemporaryPackage
    var capture: URL { package.url.appending(path: "Capture") }

    /// Track `t1` routed to a device that no Mac has.
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "no-such-device", channels: .mono(1)), track: "t1")
        package = try TemporaryPackage(session)
    }

    /// Runs `arguments`, and checks that `session.xml` and `Capture/` did not change.
    func refused(_ arguments: String...) throws -> CLIResult {
        let before = try package.xml()
        let result = try package.run(arguments)
        #expect(try package.xml() == before)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        return result
    }

    @Test func usageErrorsExitSixtyFour() throws {
        #expect(try refused("record", "PKG", "--seconds", "0", "--arm", "t1").status == 64)
        #expect(try refused("record", "PKG", "--seconds", "86400.001", "--arm", "t1").status == 64)
        #expect(try refused("record", "PKG", "--seconds", "1e12", "--arm", "t1").status == 64)
        #expect(try refused("record", "PKG", "--seconds", "1").status == 64)
        #expect(try refused("record", "PKG", "--seconds", "1", "--arm", "t1", "--playhead", "-1").status == 64)
    }

    @Test func anUnknownTrackExitsOne() throws {
        #expect(
            try refused("record", "PKG", "--seconds", "1", "--arm", "x")
                == CLIResult(status: 1, stdout: "", stderr: "Error: no track \"x\".\n"))
    }

    @Test func aMissingDeviceExitsOne() throws {
        #expect(
            try refused("record", "PKG", "--seconds", "1", "--arm", "t1")
                == CLIResult(status: 1, stdout: "", stderr: "Error: the device of track \"t1\" is missing.\n"))
    }

    @Test func aLockedPackageExitsTwo() throws {
        let asError: (SessionFileError) -> any Error = { $0 }
        let result = try PackageLock.withLock(package.url, locked: asError) {
            try refused("record", "PKG", "--seconds", "1", "--arm", "t1")
        }

        #expect(result == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) is open in Dirigible.\n"))
    }

    @Test func aPendingTakeExitsTwo() throws {
        try package.edit { session in
            try session.setRecording(
                Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1_000, armedTracks: ["t1"]))
        }

        #expect(
            try refused("record", "PKG", "--seconds", "1", "--arm", "t1")
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path) has a take that is not finalized; open it in Dirigible first.\n"))
    }

    /// Control: the byte comparison of `refused` can fail.
    @Test func aRouteEditChangesTheBytes() throws {
        let before = try package.xml()

        #expect(try package.run("track", "route", "PKG", "t1", "--device", "other", "--channels", "1").status == 0)

        #expect(try package.xml() != before)
    }

    @Test func recordHasHelp() throws {
        #expect(try dirigible("record", "--help").stdout.contains("USAGE: dirigible record <package>"))
    }
}
