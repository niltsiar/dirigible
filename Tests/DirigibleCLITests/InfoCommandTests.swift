import DirigibleCore
import Foundation
import Testing

/// Golden tests of the two views of `info`. The JSON view is a contract with scripts and agents
/// (decision 0011). The session is written through the library, not the CLI.
struct InfoCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: "k1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 123_456_789, sampleTime: 1234.5,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000.1, latency: 12, resampledFromRate: 44_100,
                driftCorrected: false))
        try session.addFile(AudioFile(id: "f1", path: "host-1.wav", layout: .mono, length: 480_000, capture: "k1"))
        try session.addFile(AudioFile(id: "f2", path: "guest.wav", layout: .stereo, length: 1000))
        try session.addTrack("host", name: "Host", layout: .mono)
        try session.setGain(Gain(dB: -3.5)!, track: "host")
        try session.setRoute(Route(deviceUID: "BuiltIn", channels: .mono(1)), track: "host")
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 480_000), on: "host")
        try session.split("c1", at: 96_000)
        try session.setGain(Gain(dB: -6)!, clip: "c1@96000")
        try session.addTrack("guest", name: "Guest", layout: .stereo)
        try session.place(Clip(id: "c3", file: "f2", start: 0, offset: 0, length: 1000), on: "guest")
        try session.setMarker(Marker(id: "m1", name: "Note", position: 96_000, kind: .marker))
        try session.setMarker(Marker(id: "m2", name: "Intro", position: 48_000, kind: .chapter))
        try session.setRecording(
            Recording(take: 2, playheadFrame: 0, takeStartHostTimeNanos: 987_654_321, armedTracks: ["host"]))
        package = try TemporaryPackage(session)
    }

    @Test func infoPrintsTheText() async throws {
        let expected = """
            Show.dirigible: 48000 Hz
            track host "Host" mono -3.5 dB route "BuiltIn" 1
              clip c1 file f1 start 0 offset 0 length 96000 0.0 dB
              clip c1@96000 file f1 start 96000 offset 96000 length 384000 -6.0 dB
            track guest "Guest" stereo 0.0 dB
              clip c3 file f2 start 0 offset 0 length 1000 0.0 dB
            file f1 "host-1.wav" mono length 480000 capture k1 media missing
            file f2 "guest.wav" stereo length 1000 media missing
            capture k1 "USB Mic" device "usb-1" host time 123456789 sample time 1234.5 rate 48000.0 \
            measured 48000.1 latency 12 resampled from 44100.0 drift not corrected
            marker m2 "Intro" chapter at 48000
            marker m1 "Note" marker at 96000
            recording take 2 at 0 host time 987654321 armed host

            """
        #expect(try await dirigible("info", package.path) == CLIResult(status: 0, stdout: expected, stderr: ""))
    }

    @Test func infoPrintsTheJSON() async throws {
        let expected = """
            {
              "captures" : [
                {
                  "deviceName" : "USB Mic",
                  "deviceUID" : "usb-1",
                  "driftCorrected" : false,
                  "hostTimeNanos" : 123456789,
                  "id" : "k1",
                  "latency" : 12,
                  "measuredSampleRate" : 48000.1,
                  "nominalSampleRate" : 48000,
                  "resampledFromRate" : 44100,
                  "sampleTime" : 1234.5
                }
              ],
              "files" : [
                {
                  "capture" : "k1",
                  "id" : "f1",
                  "layout" : "mono",
                  "length" : 480000,
                  "media" : "missing",
                  "path" : "host-1.wav"
                },
                {
                  "id" : "f2",
                  "layout" : "stereo",
                  "length" : 1000,
                  "media" : "missing",
                  "path" : "guest.wav"
                }
              ],
              "markers" : [
                {
                  "id" : "m2",
                  "kind" : "chapter",
                  "name" : "Intro",
                  "position" : 48000
                },
                {
                  "id" : "m1",
                  "kind" : "marker",
                  "name" : "Note",
                  "position" : 96000
                }
              ],
              "recording" : {
                "armedTracks" : [
                  "host"
                ],
                "playheadFrame" : 0,
                "take" : 2,
                "takeStartHostTimeNanos" : 987654321
              },
              "sampleRate" : 48000,
              "tracks" : [
                {
                  "clips" : [
                    {
                      "file" : "f1",
                      "gain" : 0,
                      "id" : "c1",
                      "length" : 96000,
                      "offset" : 0,
                      "start" : 0
                    },
                    {
                      "file" : "f1",
                      "gain" : -6,
                      "id" : "c1@96000",
                      "length" : 384000,
                      "offset" : 96000,
                      "start" : 96000
                    }
                  ],
                  "gain" : -3.5,
                  "id" : "host",
                  "layout" : "mono",
                  "name" : "Host",
                  "route" : {
                    "channels" : [
                      1
                    ],
                    "device" : "BuiltIn"
                  }
                },
                {
                  "clips" : [
                    {
                      "file" : "f2",
                      "gain" : 0,
                      "id" : "c3",
                      "length" : 1000,
                      "offset" : 0,
                      "start" : 0
                    }
                  ],
                  "gain" : 0,
                  "id" : "guest",
                  "layout" : "stereo",
                  "name" : "Guest"
                }
              ]
            }

            """
        #expect(
            try await dirigible("info", package.path, "--json") == CLIResult(status: 0, stdout: expected, stderr: ""))
    }
}
