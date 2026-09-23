import DirigibleCore
import Testing

struct SessionTests {
    let capture = Capture(
        id: "cap1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 1_000, sampleTime: 512,
        nominalSampleRate: 48_000, measuredSampleRate: 48_000.4, latency: 64)

    @Test func tracksKeepTheirOrderAndProperties() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.renameTrack("t2", to: "Remote")
        try session.setGain(Gain(dB: -3)!, track: "t2")

        #expect(session.tracks.map(\.id) == ["t1", "t2"])
        let guest = try #require(session.track("t2"))
        #expect(guest.name == "Remote")
        #expect(guest.gain == Gain(dB: -3))
        #expect(guest.layout == .stereo)
        #expect(guest.route == nil)
        #expect(guest.clips.isEmpty)

        try session.removeTrack("t1")
        #expect(session.tracks.map(\.id) == ["t2"])
    }

    @Test func aTrackIDIsUsedOnce() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        #expect(throws: SessionError.duplicateID("t1")) { try session.addTrack("t1", name: "Other", layout: .mono) }
    }

    @Test func editsOfAnUnknownTrackThrow() {
        var session = Session(sampleRate: 48_000)
        #expect(throws: SessionError.unknownTrack("t9")) { try session.renameTrack("t9", to: "X") }
        #expect(throws: SessionError.unknownTrack("t9")) { try session.removeTrack("t9") }
        #expect(throws: SessionError.unknownTrack("t9")) { try session.setRoute(nil, track: "t9") }
    }

    @Test func aRouteMatchesTheTrackLayout() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "usb-1", channels: .mono(2)), track: "t1")
        #expect(session.track("t1")?.route == Route(deviceUID: "usb-1", channels: .mono(2)))

        let before = session
        #expect(throws: SessionError.layoutMismatch("t1", .route)) {
            try session.setRoute(Route(deviceUID: "usb-1", channels: .stereo(1, 2)), track: "t1")
        }
        #expect(session == before)
    }

    @Test func aRouteChannelStartsAtOne() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .stereo)
        #expect(throws: SessionError.invalidRoute) {
            try session.setRoute(Route(deviceUID: "usb-1", channels: .stereo(0, 1)), track: "t1")
        }
    }

    @Test func aLayoutChangeSetsTheRouteInTheSameCall() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "usb-1", channels: .mono(1)), track: "t1")

        try session.setLayout(.stereo, route: Route(deviceUID: "usb-1", channels: .stereo(1, 2)), track: "t1")
        #expect(session.track("t1")?.layout == .stereo)
        #expect(session.track("t1")?.route == Route(deviceUID: "usb-1", channels: .stereo(1, 2)))

        #expect(throws: SessionError.layoutMismatch("t1", .route)) {
            try session.setLayout(.mono, route: Route(deviceUID: "usb-1", channels: .stereo(1, 2)), track: "t1")
        }
    }

    @Test func aFileRefersToAKnownCaptureInsideClips() throws {
        var session = Session(sampleRate: 48_000)
        let file = AudioFile(id: "f1", path: "t1-1-1.wav", layout: .mono, length: 480_000, capture: "cap1")
        #expect(throws: SessionError.unknownCapture("cap1")) { try session.addFile(file) }

        try session.addCapture(capture)
        try session.addFile(file)
        #expect(session.files["f1"] == file)
        #expect(session.captures["cap1"] == capture)

        for path in ["/tmp/a.wav", "../a.wav", "takes/../../a.wav", ""] {
            #expect(throws: SessionError.invalidPath(path)) {
                try session.addFile(AudioFile(id: "f2", path: path, layout: .mono, length: 10))
            }
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.addFile(AudioFile(id: "f3", path: "a.wav", layout: .mono, length: -1))
        }
    }

    @Test func addingAnEqualValueAgainChangesNothing() throws {
        var session = Session(sampleRate: 48_000)
        let file = AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 100, capture: "cap1")
        try session.addCapture(capture)
        try session.addFile(file)
        let before = session

        try session.addCapture(capture)
        try session.addFile(file)
        #expect(session == before)

        var other = capture
        other.deviceName = "Other"
        #expect(throws: SessionError.duplicateID("cap1")) { try session.addCapture(other) }
        #expect(throws: SessionError.duplicateID("f1")) {
            try session.addFile(AudioFile(id: "f1", path: "b.wav", layout: .mono, length: 100))
        }
    }

    @Test func aCaptureHasFiniteTimingAndPositiveRates() {
        var session = Session(sampleRate: 48_000)
        var bad: [Capture] = []
        for change: (inout Capture) -> Void in [
            { $0.measuredSampleRate = .nan }, { $0.nominalSampleRate = 0 }, { $0.sampleTime = .infinity },
            { $0.resampledFromRate = -44_100 },
        ] {
            var capture = capture
            change(&capture)
            bad.append(capture)
        }
        for capture in bad {
            #expect(throws: SessionError.invalidCapture("cap1")) { try session.addCapture(capture) }
        }
        #expect(session.captures.isEmpty)
    }

    @Test func aRemoveLeavesNoDanglingReference() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(capture)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 100, capture: "cap1"))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 5, armedTracks: ["t1"]))

        #expect(throws: SessionError.captureInUse("cap1")) { try session.removeCapture("cap1") }
        #expect(throws: SessionError.trackInRecording("t1")) { try session.removeTrack("t1") }

        try session.setRecording(nil)
        try session.removeTrack("t1")
        try session.removeFile("f1")
        try session.removeCapture("cap1")
        #expect(session == Session(sampleRate: 48_000))
    }

    @Test func aRecordingNamesKnownTracks() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        let recording = Recording(take: 3, playheadFrame: 96_000, takeStartHostTimeNanos: 7, armedTracks: ["t1", "t2"])
        #expect(throws: SessionError.unknownTrack("t2")) { try session.setRecording(recording) }
        #expect(session.recording == nil)

        try session.addTrack("t2", name: "Guest", layout: .mono)
        var late = recording
        late.playheadFrame = Frames.limit + 1
        #expect(throws: SessionError.frameOutOfRange) { try session.setRecording(late) }
        try session.setRecording(recording)
        #expect(session.recording == recording)
    }

    @Test func markersAreAddedChangedAndRemoved() throws {
        var session = Session(sampleRate: 48_000)
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 0, kind: .marker))
        try session.setMarker(Marker(id: "m2", name: "Chapter 1", position: 0, kind: .chapter))
        try session.setMarker(Marker(id: "m1", name: "Start", position: 48_000, kind: .chapter))

        #expect(session.markers["m1"] == Marker(id: "m1", name: "Start", position: 48_000, kind: .chapter))
        #expect(session.markers.count == 2)
        #expect(throws: SessionError.frameOutOfRange) {
            try session.setMarker(Marker(id: "m3", name: "X", position: -1, kind: .marker))
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.setMarker(Marker(id: "m3", name: "X", position: Frames.limit + 1, kind: .marker))
        }

        try session.removeMarker("m1")
        #expect(session.markers.keys.sorted() == ["m2"])
        #expect(throws: SessionError.unknownMarker("m1")) { try session.removeMarker("m1") }
    }
}
