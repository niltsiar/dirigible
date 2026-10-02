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
        try session.setRoute(Route.device(uid: "usb-1", channels: .mono(2)), track: "t1")
        #expect(session.track("t1")?.route == Route.device(uid: "usb-1", channels: .mono(2)))

        let before = session
        #expect(throws: SessionError.layoutMismatch("t1", .route)) {
            try session.setRoute(Route.device(uid: "usb-1", channels: .stereo(1, 2)), track: "t1")
        }
        #expect(session == before)
    }

    @Test func aRouteChannelStartsAtOne() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .stereo)
        #expect(throws: SessionError.invalidRoute) {
            try session.setRoute(Route.device(uid: "usb-1", channels: .stereo(0, 1)), track: "t1")
        }
    }

    /// A1: an app route has no channels. The track layout picks a mono or a stereo mixdown.
    @Test func anAppRouteFitsAMonoAndAStereoTrack() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Guest", layout: .mono)
        try session.addTrack("t2", name: "Music", layout: .stereo)
        try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t1")
        try session.setRoute(.app(bundleID: "com.google.Chrome"), track: "t2")
        #expect(session.track("t1")?.route == .app(bundleID: "us.zoom.xos"), "mono app route")
        #expect(session.track("t2")?.route == .app(bundleID: "com.google.Chrome"), "stereo app route")
    }

    /// A1: `setRoute` refuses an empty bundle ID and text with a control character (0003).
    @Test func anAppRouteRefusesAnEmptyIDAndAControlCharacter() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Guest", layout: .mono)
        let before = session
        #expect(throws: SessionError.invalidRoute) { try session.setRoute(.app(bundleID: ""), track: "t1") }
        #expect(throws: SessionError.invalidText("a\u{1}b")) {
            try session.setRoute(.app(bundleID: "a\u{1}b"), track: "t1")
        }
        #expect(session == before, "a refused app route changes nothing")
    }

    @Test func aLayoutChangeSetsTheRouteInTheSameCall() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route.device(uid: "usb-1", channels: .mono(1)), track: "t1")

        try session.setLayout(.stereo, route: Route.device(uid: "usb-1", channels: .stereo(1, 2)), track: "t1")
        #expect(session.track("t1")?.layout == .stereo)
        #expect(session.track("t1")?.route == Route.device(uid: "usb-1", channels: .stereo(1, 2)))

        #expect(throws: SessionError.layoutMismatch("t1", .route)) {
            try session.setLayout(.mono, route: Route.device(uid: "usb-1", channels: .stereo(1, 2)), track: "t1")
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

    /// XML 1.0 cannot hold these characters, or reads them back as spaces.
    /// The one text rule of the session file (decision 0012): capture code uses it too.
    @Test func theTextRuleRefusesControlCharactersAndNonCharacters() {
        for value: UInt32 in [0x00, 0x09, 0x1F, 0xFFFE, 0xFFFF] {
            #expect(!Unicode.Scalar(value)!.isStorableInSession, "U+\(String(value, radix: 16))")
        }
        for value: UInt32 in [0x20, 0x7F, 0xE9, 0xFFFD, 0x1F399] {
            #expect(Unicode.Scalar(value)!.isStorableInSession, "U+\(String(value, radix: 16))")
        }
    }

    @Test(arguments: ["a\u{0B}b", "a\u{0}b", "a\nb", "a\tb", "a\rb", "a\u{FFFE}b", "a\u{FFFF}b"])
    func textThatXMLCannotHoldIsRefused(text: String) throws {
        var session = Session(sampleRate: 48_000)
        #expect(throws: SessionError.invalidText(text)) {
            try session.addTrack(TrackID(text), name: "A", layout: .mono)
        }
        try session.addTrack("t1", name: "A", layout: .mono)
        #expect(throws: SessionError.invalidText(text)) { try session.renameTrack("t1", to: text) }
        #expect(throws: SessionError.invalidText(text)) {
            try session.setRoute(Route.device(uid: text, channels: .mono(1)), track: "t1")
        }
        #expect(throws: SessionError.invalidText(text)) {
            try session.setMarker(Marker(id: "m1", name: text, position: 0, kind: .marker))
        }
        var device = capture
        device.deviceName = text
        #expect(throws: SessionError.invalidText(text)) { try session.addCapture(device) }
        #expect(throws: SessionError.invalidText(text)) {
            try session.addFile(AudioFile(id: "f1", path: text, layout: .mono, length: 10))
        }
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 10))
        #expect(throws: SessionError.invalidText(text)) {
            try session.place(Clip(id: ClipID(text), file: "f1", start: 0, offset: 0, length: 10), on: "t1")
        }
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 10), on: "t1")
        #expect(throws: SessionError.invalidText(text)) { try session.split("c1", at: 5, rightID: ClipID(text)) }
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

    @Test func anArmedTrackKeepsItsRouteAndLayout() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 5, armedTracks: ["t1"]))
        let before = session
        let route = Route.device(uid: "usb-1", channels: .mono(1))

        #expect(throws: SessionError.trackInRecording("t1")) { try session.setRoute(route, track: "t1") }
        #expect(throws: SessionError.trackInRecording("t1")) {
            try session.setLayout(.stereo, route: nil, track: "t1")
        }
        #expect(session == before)

        try session.setRoute(route, track: "t2")
        try session.setLayout(.stereo, route: nil, track: "t2")
        #expect(session.track("t2")?.layout == .stereo)
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

    /// A take number is a stem part of decision 0012: 1 to 9 digits.
    @Test(arguments: [0, -1, 1_000_000_000, Int.max])
    func aTakeNumberOutsideTheStemRangeIsRefused(take: Int) throws {
        var session = Session(sampleRate: 48_000)
        let recording = Recording(take: take, playheadFrame: 0, takeStartHostTimeNanos: 7, armedTracks: [])
        #expect(throws: SessionError.takeOutOfRange(take)) { try session.setRecording(recording) }
        #expect(session.recording == nil)

        try session.setRecording(
            Recording(take: 999_999_999, playheadFrame: 0, takeStartHostTimeNanos: 7, armedTracks: []))
        #expect(session.recording?.take == 999_999_999)
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

    // MARK: B1a, the call preset

    /// Host then Guest, mono, with their routes, after the tracks that exist.
    @Test(arguments: [0, 3]) func addCallTracksAppendsHostAndGuest(existing: Int) throws {
        var session = Session(sampleRate: 48_000)
        for index in 0..<existing { try session.addTrack(TrackID("t\(index)"), name: "T", layout: .mono) }
        try session.addCallTracks(
            host: "host", guest: "guest", names: (host: "Host", guest: "Guest"), hostDevice: (uid: "mic", channel: 2),
            guestApp: "us.zoom.xos")
        #expect(session.tracks.count == existing + 2, "not two new tracks")
        let (host, guest) = (session.tracks[existing], session.tracks[existing + 1])
        #expect(host.id == "host" && host.name == "Host" && host.layout == .mono)
        #expect(host.route == .device(uid: "mic", channels: .mono(2)), "the Host route")
        #expect(guest.id == "guest" && guest.name == "Guest" && guest.layout == .mono)
        #expect(guest.route == .app(bundleID: "us.zoom.xos"), "the Guest route")
    }

    /// No route: two tracks with no route.
    @Test func addCallTracksWithNoRoutes() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCallTracks(
            host: "h", guest: "g", names: (host: "Host", guest: "Guest"), hostDevice: nil, guestApp: nil)
        #expect(session.tracks.map(\.name) == ["Host", "Guest"])
        #expect(session.tracks.allSatisfy { $0.route == nil && $0.layout == .mono })
    }

    /// Control: a bad route or a used ID throws, and no track is added.
    @Test func aBadCallRouteAddsNoTrack() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t0", name: "T", layout: .mono)
        let names = (host: "Host", guest: "Guest")
        #expect(throws: SessionError.invalidRoute) {
            try session.addCallTracks(host: "h", guest: "g", names: names, hostDevice: nil, guestApp: "")
        }
        #expect(session.tracks.map(\.id) == ["t0"], "an empty app ID added a track")
        #expect(throws: SessionError.invalidRoute) {
            try session.addCallTracks(
                host: "h", guest: "g", names: names, hostDevice: (uid: "mic", channel: 0), guestApp: nil)
        }
        #expect(session.tracks.map(\.id) == ["t0"], "channel 0 added a track")
        #expect(throws: SessionError.duplicateID("t0")) {
            try session.addCallTracks(host: "t0", guest: "g", names: names, hostDevice: nil, guestApp: nil)
        }
        #expect(session.tracks.map(\.id) == ["t0"], "a used ID added a track")
    }
}
