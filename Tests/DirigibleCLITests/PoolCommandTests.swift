import DirigibleCore
import Foundation
import Testing

/// The file pool: `capture` and `file` commands.
struct PoolCommandTests {
    let package: TemporaryPackage
    let silent = CLIResult(status: 0, stdout: "", stderr: "")

    init() throws {
        package = try TemporaryPackage(Session(sampleRate: 48_000))
    }

    private func addCapture(_ extra: String...) async throws -> CLIResult {
        try await package.run(
            [
                "capture", "add", "PKG", "--device-uid", "usb-1", "--device-name", "USB Mic", "--host-time",
                "123456789", "--sample-time", "-1234.5", "--nominal-rate", "48000", "--measured-rate", "48000.1",
                "--latency", "12",
            ] + extra)
    }

    @Test func eachVerbAppliesItsEdit() async throws {
        #expect(
            try await addCapture("--resampled-from", "44100", "--drift-not-corrected", "--id", "k1")
                == CLIResult(status: 0, stdout: "k1\n", stderr: ""))
        #expect(
            try package.read().captures["k1"]
                == Capture(
                    id: "k1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 123_456_789,
                    sampleTime: -1234.5,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000.1, latency: 12, resampledFromRate: 44_100,
                    driftCorrected: false))

        let second = try await addCapture()
        let k2 = CaptureID(String(second.stdout.dropLast()))
        #expect(second.status == 0 && UUID(uuidString: k2.rawValue) != nil)
        #expect(try package.read().captures[k2]?.resampledFromRate == nil)
        #expect(try package.read().captures[k2]?.driftCorrected == true)

        #expect(
            try await package.run(
                "file", "add", "PKG", "--path", "host-1.wav", "--layout", "mono", "--length", "480000", "--capture",
                "k1",
                "--id", "f1") == CLIResult(status: 0, stdout: "f1\n", stderr: ""))
        #expect(
            try package.read().files["f1"]
                == AudioFile(id: "f1", path: "host-1.wav", layout: .mono, length: 480_000, capture: "k1"))

        let imported = try await package.run(
            "file", "add", "PKG", "--path", "a/b.wav", "--layout", "stereo", "--length", "5")
        let f2 = FileID(String(imported.stdout.dropLast()))
        #expect(imported.status == 0 && UUID(uuidString: f2.rawValue) != nil)
        #expect(try package.read().files[f2] == AudioFile(id: f2, path: "a/b.wav", layout: .stereo, length: 5))

        #expect(try await package.run("file", "remove", "PKG", f2.rawValue) == silent)
        #expect(try await package.run("file", "remove", "PKG", "f1") == silent)
        #expect(try await package.run("capture", "remove", "PKG", "k1") == silent)
        #expect(try package.read().files.isEmpty)
        #expect(try package.read().captures.keys.sorted() == [k2])
    }

    @Test func refusedEditsExitOne() async throws {
        try package.edit {
            try $0.addCapture(
                Capture(
                    id: "k1", deviceUID: "u", deviceName: "n", hostTimeNanos: 1, sampleTime: 0,
                    nominalSampleRate: 48_000,
                    measuredSampleRate: 48_000, latency: 0))
            try $0.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 10, capture: "k1"))
        }
        let before = try package.xml()
        let cases: [([String], String)] = [
            (
                ["file", "add", "PKG", "--path", "/abs.wav", "--layout", "mono", "--length", "1"],
                "the path \"/abs.wav\" is not inside Clips/."
            ),
            (
                ["file", "add", "PKG", "--path", "x.wav", "--layout", "mono", "--length", "-1"],
                "a frame is negative or more than 2^40."
            ),
            (["capture", "remove", "PKG", "k1"], "capture \"k1\" is used by a file."),
        ]
        for (arguments, message) in cases {
            #expect(try await package.run(arguments) == CLIResult(status: 1, stdout: "", stderr: "Error: \(message)\n"))
        }
        #expect(
            try await addCapture("--nominal-rate", "0", "--id", "k2")
                == CLIResult(
                    status: 1, stdout: "",
                    stderr:
                        "Error: capture \"k2\" has a sample time that is not finite or a rate that is not positive.\n"))
        #expect(try package.xml() == before)
    }

    @Test(arguments: [
        [
            "capture", "add", "PKG", "--device-uid", "u", "--device-name", "n", "--host-time", "-1", "--sample-time",
            "0",
            "--nominal-rate", "48000", "--measured-rate", "48000", "--latency", "0",
        ],
        ["file", "add", "PKG", "--path", "x.wav", "--layout", "mono", "--length", "1.5"],
    ])
    func nonIntegerFrameIsAUsageError(arguments: [String]) async throws {
        let before = try package.xml()
        #expect(try await package.run(arguments).status == 64)
        #expect(try package.xml() == before)
    }
}
