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

    /// Removes the track and its clips. The files stay in the pool.
    public mutating func removeTrack(_ id: TrackID) throws(SessionError) {
        let index = try trackIndex(id)
        if recording?.armedTracks.contains(id) == true { throw .trackInRecording(id) }
        tracks.remove(at: index)
    }

    public mutating func renameTrack(_ id: TrackID, to name: String) throws(SessionError) {
        try Self.checkText(name)
        tracks[try trackIndex(id)].name = name
    }

    public mutating func setGain(_ gain: Gain, track id: TrackID) throws(SessionError) {
        tracks[try trackIndex(id)].gain = gain
    }

    public mutating func setRoute(_ route: Route?, track id: TrackID) throws(SessionError) {
        let index = try trackIndex(id)
        try Self.check(route, layout: tracks[index].layout, track: id)
        tracks[index].route = route
    }

    /// Changes the layout and the route in one call, so no step has a route of the other layout.
    /// A track with clips keeps its layout.
    public mutating func setLayout(_ layout: ChannelLayout, route: Route?, track id: TrackID) throws(SessionError) {
        let index = try trackIndex(id)
        if layout != tracks[index].layout, !tracks[index].clips.isEmpty {
            throw .layoutMismatch(id, .trackHasClips)
        }
        try Self.check(route, layout: layout, track: id)
        tracks[index].layout = layout
        tracks[index].route = route
    }

    private static func check(_ route: Route?, layout: ChannelLayout, track: TrackID) throws(SessionError) {
        guard let route else { return }
        try checkText(route.deviceUID)
        guard route.channels.numbers.allSatisfy({ $0 >= 1 }) else { throw .invalidRoute }
        guard route.channels.layout == layout else { throw .layoutMismatch(track, .route) }
    }

    /// XML 1.0 cannot hold the other control characters, and it reads tab, LF, and CR in an
    /// attribute back as spaces. Refusing them here keeps every saved session readable.
    static func checkText(_ texts: String...) throws(SessionError) {
        for text in texts
        where text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0xFFFE || $0.value == 0xFFFF }) {
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
        if let recording, !recording.playheadFrame.isInRange { throw .frameOutOfRange }
        if let missing = recording?.armedTracks.first(where: { track($0) == nil }) {
            throw .unknownTrack(missing)
        }
        self.recording = recording
    }
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
    case invalidRoute
    case invalidPath(String)
    case invalidText(String)
    case frameOutOfRange
    case clipOutsideFile(ClipID)
    case overlap(ClipID, ClipID)
    case frameOutsideClip(ClipID, Frames)
}
