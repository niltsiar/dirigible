import Foundation

/// A recording session: the file pool, the tracks with their clips, and the markers.
/// Every edit keeps the invariants. An edit that throws leaves the session unchanged.
public struct Session: Hashable, Sendable {
    public let sampleRate: Int
    public private(set) var captures: [CaptureID: Capture] = [:]
    public private(set) var files: [FileID: AudioFile] = [:]
    /// In the order that the user sees.
    public internal(set) var tracks: [Track] = []
    public private(set) var markers: [MarkerID: Marker] = [:]
    /// Present while a take runs or waits for finalize (decision 0004).
    public internal(set) var recording: Recording?

    public init(sampleRate: Int) {
        precondition(sampleRate > 0, "A sample rate is positive")
        self.sampleRate = sampleRate
    }

    public func track(_ id: TrackID) -> Track? {
        tracks.first { $0.id == id }
    }

    // MARK: Captures and files

    /// Adding a capture that is equal to the one with its ID changes nothing. The sample time is
    /// finite and every rate is finite and positive: finalize divides by them.
    public mutating func addCapture(_ capture: Capture) throws(SessionError) {
        if let present = captures[capture.id] {
            guard present == capture else { throw .duplicateID(capture.id.rawValue) }
            return
        }
        try Self.checkText(capture.id.rawValue, capture.deviceUID, capture.deviceName)
        let rates =
            [capture.nominalSampleRate, capture.measuredSampleRate] + [capture.resampledFromRate].compactMap { $0 }
        guard capture.sampleTime.isFinite, rates.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw .invalidCapture(capture.id)
        }
        captures[capture.id] = capture
    }

    public mutating func removeCapture(_ id: CaptureID) throws(SessionError) {
        guard captures[id] != nil else { throw .unknownCapture(id) }
        guard !files.values.contains(where: { $0.capture == id }) else { throw .captureInUse(id) }
        captures[id] = nil
    }

    /// Adding a file that is equal to the one with its ID changes nothing.
    public mutating func addFile(_ file: AudioFile) throws(SessionError) {
        if let present = files[file.id] {
            guard present == file else { throw .duplicateID(file.id.rawValue) }
            return
        }
        try Self.checkText(file.id.rawValue, file.path)
        guard Self.isInsideClips(file.path) else { throw .invalidPath(file.path) }
        guard file.length.isInRange else { throw .frameOutOfRange }
        if let capture = file.capture, captures[capture] == nil { throw .unknownCapture(capture) }
        files[file.id] = file
    }

    public mutating func removeFile(_ id: FileID) throws(SessionError) {
        guard files[id] != nil else { throw .unknownFile(id) }
        guard !tracks.contains(where: { $0.clips.contains { $0.file == id } }) else { throw .fileInUse(id) }
        files[id] = nil
    }

    /// A relative path with no ".." component, so the file stays inside `Clips/`.
    private static func isInsideClips(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    // MARK: Tracks

    public mutating func addTrack(_ id: TrackID = TrackID(), name: String, layout: ChannelLayout) throws(SessionError) {
        try Self.checkText(id.rawValue, name)
        guard track(id) == nil else { throw .duplicateID(id.rawValue) }
        tracks.append(Track(id: id, name: name, layout: layout))
    }

    /// The call preset (F06): the mono tracks Host and Guest, in that order, Host on one channel
    /// of `hostDevice` and Guest on the app `guestApp`. A throw adds no track.
    public mutating func addCallTracks(
        host: TrackID, guest: TrackID, names: (host: String, guest: String),
        hostDevice: (uid: String, channel: Int)?, guestApp: String?
    ) throws(SessionError) {
        var copy = self
        try copy.addTrack(host, name: names.host, layout: .mono)
        try copy.addTrack(guest, name: names.guest, layout: .mono)
        if let hostDevice {
            try copy.setRoute(.device(uid: hostDevice.uid, channels: .mono(hostDevice.channel)), track: host)
        }
        if let guestApp { try copy.setRoute(.app(bundleID: guestApp), track: guest) }
        self = copy
    }

    /// Removes the track and its clips. The files stay in the pool.
    public mutating func removeTrack(_ id: TrackID) throws(SessionError) {
        let index = try trackIndex(id)
        try checkNotArmed(id)
        tracks.remove(at: index)
    }

    /// Finalize needs the tracks of a pending take as they were at the take start (decision 0012).
    private func checkNotArmed(_ id: TrackID) throws(SessionError) {
        if recording?.armedTracks.contains(id) == true { throw .trackInRecording(id) }
    }

    public mutating func renameTrack(_ id: TrackID, to name: String) throws(SessionError) {
        try Self.checkText(name)
        tracks[try trackIndex(id)].name = name
    }

    public mutating func setGain(_ gain: Gain, track id: TrackID) throws(SessionError) {
        tracks[try trackIndex(id)].gain = gain
    }

    /// An armed track keeps its route while `<recording>` exists (decision 0012).
    public mutating func setRoute(_ route: Route?, track id: TrackID) throws(SessionError) {
        let index = try trackIndex(id)
        try checkNotArmed(id)
        try Self.check(route, layout: tracks[index].layout, track: id)
        tracks[index].route = route
    }

    /// Changes the layout and the route in one call, so no step has a route of the other layout.
    /// A track with clips, and an armed track, keep their layout.
    public mutating func setLayout(_ layout: ChannelLayout, route: Route?, track id: TrackID) throws(SessionError) {
        let index = try trackIndex(id)
        try checkNotArmed(id)
        if layout != tracks[index].layout, !tracks[index].clips.isEmpty {
            throw .layoutMismatch(id, .trackHasClips)
        }
        try Self.check(route, layout: layout, track: id)
        tracks[index].layout = layout
        tracks[index].route = route
    }

    private static func check(_ route: Route?, layout: ChannelLayout, track: TrackID) throws(SessionError) {
        switch route {
        case nil: return
        case .device(let uid, let channels):
            try checkText(uid)
            guard channels.numbers.allSatisfy({ $0 >= 1 }) else { throw .invalidRoute }
            guard channels.layout == layout else { throw .layoutMismatch(track, .route) }
        case .app(let bundleID):
            try checkText(bundleID)
            guard !bundleID.isEmpty else { throw .invalidRoute }
        }
    }

    /// The `session.xml` version that holds this session (decision 0024 P6): 2 with an app
    /// route (decision 0029), else 1.
    public var fileVersion: Int {
        tracks.contains { if case .app = $0.route { true } else { false } } ? 2 : 1
    }

    /// XML 1.0 cannot hold the other control characters, and it reads tab, LF, and CR in an
    /// attribute back as spaces. Refusing them here keeps every saved session readable.
    static func checkText(_ texts: String...) throws(SessionError) {
        for text in texts where !text.unicodeScalars.allSatisfy(\.isStorableInSession) {
            throw .invalidText(text)
        }
    }

    func trackIndex(_ id: TrackID) throws(SessionError) -> Int {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw .unknownTrack(id) }
        return index
    }

    // MARK: Markers and recording

    /// Adds the marker, or replaces the marker with its ID.
    public mutating func setMarker(_ marker: Marker) throws(SessionError) {
        try Self.checkText(marker.id.rawValue, marker.name)
        guard marker.position.isInRange else { throw .frameOutOfRange }
        markers[marker.id] = marker
    }

    public mutating func removeMarker(_ id: MarkerID) throws(SessionError) {
        guard markers.removeValue(forKey: id) != nil else { throw .unknownMarker(id) }
    }

    /// Nil removes the recording.
    public mutating func setRecording(_ recording: Recording?) throws(SessionError) {
        if let recording, !Recording.takes.contains(recording.take) { throw .takeOutOfRange(recording.take) }
        if let recording, !recording.playheadFrame.isInRange { throw .frameOutOfRange }
        if let missing = recording?.armedTracks.first(where: { track($0) == nil }) {
            throw .unknownTrack(missing)
        }
        self.recording = recording
    }
}

extension Unicode.Scalar {
    /// The one text rule of the session file (decision 0012): false for U+0000...U+001F,
    /// U+FFFE, and U+FFFF. XML 1.0 cannot hold them, or reads tab, LF, and CR back as spaces.
    public var isStorableInSession: Bool { value >= 0x20 && value != 0xFFFE && value != 0xFFFF }
}

public enum SessionError: Error, Hashable, Sendable {
    /// The part of a track whose layout does not match.
    public enum LayoutConflict: Hashable, Sendable {
        case file(FileID)
        case route
        case trackHasClips
    }

    case duplicateID(String)
    case unknownCapture(CaptureID)
    case unknownFile(FileID)
    case unknownTrack(TrackID)
    case unknownClip(ClipID)
    case unknownMarker(MarkerID)
    case captureInUse(CaptureID)
    case invalidCapture(CaptureID)
    case fileInUse(FileID)
    case trackInRecording(TrackID)
    case layoutMismatch(TrackID, LayoutConflict)
    /// A device channel less than 1, or an empty app ID.
    case invalidRoute
    case invalidPath(String)
    case invalidText(String)
    case frameOutOfRange
    /// A take number that is not a stem part of decision 0012 (1 to 9 digits).
    case takeOutOfRange(Int)
    case clipOutsideFile(ClipID)
    case overlap(ClipID, ClipID)
    case frameOutsideClip(ClipID, Frames)
    /// A paste names a track count that is not the lane count of its excerpt, which this case holds.
    case trackCount(Int)
}
