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
    /// The episode metadata of the exports (decision 0045). Empty by default.
    public private(set) var episode = Episode()
    /// The imported transcripts (decision 0055). `words` shows them.
    var transcripts: [TranscriptID: Transcript] = [:]

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
        if let origin = file.origin { try check(origin, of: file) }
        files[file.id] = file
    }

    /// Sets the origins after all files, so the file order of `session.xml` does not matter
    /// (decision 0057 D9). It refuses each origin that `addFile` refuses, and a cycle. A throw
    /// changes nothing.
    mutating func setOrigins(_ origins: [FileID: RenderOrigin]) throws(SessionError) {
        var copy = self
        for (id, origin) in origins {
            guard copy.files[id] != nil else { throw .unknownFile(id) }
            copy.files[id]?.origin = origin
        }
        for file in copy.files.values {
            guard let origin = file.origin else { continue }
            try copy.check(origin, of: file)
            var seen: Set<FileID> = [file.id]
            var next = origin.source
            while let up = copy.files[next]?.origin {
                guard seen.insert(next).inserted else { throw .invalidOrigin(file.id) }
                next = up.source
            }
        }
        self = copy
    }

    /// Removes the file record and the transcript words of the file, and a transcript with no word
    /// left (decision 0055). It refuses a file that a clip uses or that an origin names (decision 0057).
    public mutating func removeFile(_ id: FileID) throws(SessionError) {
        guard files[id] != nil else { throw .unknownFile(id) }
        guard !tracks.contains(where: { $0.clips.contains { $0.file == id } }) else { throw .fileInUse(id) }
        if let named = files.values.filter({ $0.origin?.source == id }).map(\.id).min() {
            throw .fileIsSource(id, of: named)
        }
        files[id] = nil
        for transcript in transcripts.keys { setWords([], file: id, transcript: transcript) }
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

    /// An unknown track throws and changes nothing.
    public mutating func setMuted(_ on: Bool, tracks ids: [TrackID]) throws(SessionError) {
        for index in try ids.map(trackIndex) { tracks[index].isMuted = on }
    }

    /// An unknown track throws and changes nothing.
    public mutating func setSoloed(_ on: Bool, tracks ids: [TrackID]) throws(SessionError) {
        for index in try ids.map(trackIndex) { tracks[index].isSoloed = on }
    }

    /// An unknown track throws and changes nothing.
    public mutating func setFollowTrack(_ on: Bool, tracks ids: [TrackID]) throws(SessionError) {
        for index in try ids.map(trackIndex) { tracks[index].isFollowTrack = on }
    }

    /// Nil removes the role. An unknown track throws and changes nothing.
    public mutating func setRole(_ role: Track.Role?, tracks ids: [TrackID]) throws(SessionError) {
        for index in try ids.map(trackIndex) { tracks[index].role = role }
    }

    /// A copy with mute and solo off on each track: the mix of the duck, `silences`, and
    /// `nearest_pause` (decisions 0039 and 0062).
    public var ignoringMuteAndSolo: Session {
        var copy = self
        for index in copy.tracks.indices { (copy.tracks[index].isMuted, copy.tracks[index].isSoloed) = (false, false) }
        return copy
    }

    /// The tracks that the mix reads: in `ids` (nil: all tracks) and heard, in session order.
    /// An empty result is silence, never all tracks.
    public func heardTracks(in ids: Set<TrackID>?) -> [Track] {
        tracks.filter { (ids?.contains($0.id) ?? true) && isHeard($0) }
    }

    /// The tracks of `ids` (nil: all tracks) that are in the session and not heard: the count of
    /// the export notes.
    public func unheardCount(in ids: Set<TrackID>?) -> Int {
        tracks.filter { ids?.contains($0.id) ?? true }.count - heardTracks(in: ids).count
    }

    /// Not muted, and no track is soloed or this track is soloed (decision 0039): the one rule.
    private func isHeard(_ track: Track) -> Bool {
        !track.isMuted && (track.isSoloed || !tracks.contains(where: \.isSoloed))
    }

    /// The `session.xml` version that holds this session (decision 0024 P6): from 12 on, the largest
    /// version of the present features: `matchSessionVersion` with a voice match (decision 0074),
    /// `rideSessionVersion` with a ride point, `followSessionVersion`
    /// with a follow track (decision 0073), `preRollSessionVersion` with a pre-roll `<recording>`, 14
    /// with a repair effect in a file origin (decision 0064), 13 with a hum removal in a file origin
    /// (decision 0054), 12 with a file origin (0057); else 11 with a track role, else 10 with a gain
    /// envelope point (decision 0060), else 9 with a crossfade at a seamless join (decision 0036), else
    /// 8 with a transcript (decision 0055), else 7 with a marker URL or image, else 6 with episode data
    /// (decision 0045), else 5 with a muted or soloed track (decision 0039), else 4 with a crossfade
    /// (decision 0036), else 3 with a fade (decision 0035), else 2 with an app route (decision 0029),
    /// else 1.
    public var fileVersion: Int {
        let features = [
            tracks.contains { $0.match != nil } ? matchSessionVersion : nil,
            tracks.contains { $0.clips.contains { !$0.ride.isEmpty } } ? rideSessionVersion : nil,
            tracks.contains(where: \.isFollowTrack) ? followSessionVersion : nil,
            recording?.isPreRoll == true ? preRollSessionVersion : nil,
            files.values.compactMap { $0.origin?.treatment.fileVersion }.max(),
        ]
        if let version = features.compactMap({ $0 }).max() { return version }
        if tracks.contains(where: { $0.role != nil }) { return 11 }
        if tracks.contains(where: { $0.clips.contains { !$0.envelope.isEmpty } }) { return 10 }
        if tracks.contains(where: { $0.clips.seamlessCrossfade != nil }) { return 9 }
        if !transcripts.isEmpty { return 8 }
        if markers.values.contains(where: { $0.url != nil || $0.image != nil }) { return 7 }
        if !episode.isEmpty { return 6 }
        if tracks.contains(where: { $0.isMuted || $0.isSoloed }) { return 5 }
        if tracks.contains(where: { $0.clips.contains { $0.crossfades != .zero } }) { return 4 }
        if tracks.contains(where: { $0.clips.contains { $0.fades != .zero } }) { return 3 }
        return tracks.contains { if case .app = $0.route { true } else { false } } ? 2 : 1
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

    /// The markers by position, then by ID: the order of the session file, the overview, and the chapters.
    public var sortedMarkers: [Marker] { markers.values.sorted { ($0.position, $0.id) < ($1.position, $1.id) } }

    /// Adds the marker, or replaces the marker with its ID. It refuses a URL over
    /// `Marker.maximumURLBytes` UTF-8 bytes.
    public mutating func setMarker(_ marker: Marker) throws(SessionError) {
        try Self.checkText(marker.id.rawValue, marker.name)
        guard marker.position.isInRange else { throw .frameOutOfRange }
        guard (marker.url?.text.utf8.count ?? 0) <= Marker.maximumURLBytes else { throw .markerURLTooLong }
        markers[marker.id] = marker
    }

    /// The fields validate at their types, so this edit cannot fail.
    public mutating func setEpisode(_ episode: Episode) {
        self.episode = episode
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
