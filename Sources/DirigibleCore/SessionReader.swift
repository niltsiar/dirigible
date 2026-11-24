import Foundation

extension Session {
    /// Checks the items of the package (`checkItems(of:)`), then reads `session.xml` and checks its
    /// pool paths (`checkPoolPaths`), then the words of each transcript from `Transcripts/`
    /// (decision 0055). The reader parses the XML into domain
    /// values, then builds the session through the same edits that the app uses, so each rule has
    /// one check. `loadsTranscript` gets the URL of each transcript file before its read: false
    /// keeps that transcript with no words, as a missing file does.
    public init(contentsOf package: URL, loadsTranscript: (URL) -> Bool = { _ in true }) throws(SessionFileError) {
        try checkItems(of: package)
        let data: Data
        do {
            data = try Data(contentsOf: package.appending(path: "session.xml"))
        } catch {
            throw .readFailed(errno: posixCode(of: error))
        }
        try self.init(xml: data)
        try checkPoolPaths(of: self, in: package)
        loadTranscripts(from: package, loads: loadsTranscript)
    }

    /// `newest` is the newest version that the reader accepts. A test gives a lower one to act as
    /// an older build.
    init(xml data: Data, newest: Int = sessionVersion) throws(SessionFileError) {
        guard let document = packageXML(data), let root = document.rootElement(),
            root.localName == "session", root.uri == sessionNamespace
        else { throw .malformedXML }

        let version: Int = try root.value("version")
        guard version <= newest else { throw .unsupportedVersion(version) }
        guard version >= 1 else { throw .invalidValue(element: "session", attribute: "version") }
        let sampleRate: Int = try root.value("sampleRate")
        guard sampleRate > 0 else { throw .invalidValue(element: "session", attribute: "sampleRate") }
        let archive = try root.optionalString("archive").map { value throws(SessionFileError) in
            guard version >= archiveSessionVersion, let archive = SessionArchive(rawValue: value) else {
                throw .invalidValue(element: "session", attribute: "archive")
            }
            return archive
        }

        var captures: [Capture] = []
        for node in root.children("captures", "capture") { captures.append(try Capture(node)) }
        var files: [AudioFile] = []
        var origins: [FileID: RenderOrigin] = [:]
        var drifts: [FileID: DriftOrigin] = [:]
        for node in root.children("files", "file") {
            let file = try AudioFile(node)
            files.append(file)
            let list = node.sessionElements("origin")
            guard list.count <= 1 else { throw .invalidValue(element: "origin", attribute: "count") }
            if let origin = list.first { origins[file.id] = try RenderOrigin(origin, version: version) }
            if let drift = try DriftOrigin(file: node, version: version) { drifts[file.id] = drift }
        }
        var rides = try RideLists(root, version: version)
        var tracks: [ParsedTrack] = []
        for node in root.children("tracks", "track") {
            tracks.append(try ParsedTrack(node, version: version, rides: &rides))
        }
        let bins = try ParsedBin.list(in: root, version: version, rides: &rides)
        try rides.checkAllNamed()
        var markers: [Marker] = []
        for node in root.children("markers", "marker") { markers.append(try Marker(node, version: version)) }
        let recording = try root.sessionElements("recording").first.map { node throws(SessionFileError) in
            try Recording(node, version: version)
        }
        let episode = try root.sessionElements("episode").first.map { node throws(SessionFileError) in
            guard version >= 6 else { throw .invalidValue(element: "episode", attribute: "version") }
            return try Episode(node)
        }
        var transcripts: [Transcript] = []
        if let list = root.sessionElements("transcripts").first {
            guard version >= 8 else { throw .invalidValue(element: "transcripts", attribute: "version") }
            for node in list.sessionElements("transcript") { transcripts.append(try Transcript(node)) }
        }
        let presets = try ExportPreset.list(in: root, version: version)

        self.init(sampleRate: sampleRate)
        self.archive = archive
        // The reader never refuses a stored name, so the presets skip the collision rule of the edit.
        exportPresets = presets
        do throws(SessionError) {
            for capture in captures { try addCapture(capture) }
            for file in files { try addFile(file) }
            try setOrigins(origins)
            try setDriftLinks(drifts)
            try addBins(bins)
            for track in tracks {
                try addTrack(track.id, name: track.name, layout: track.layout)
                try setGain(track.gain, track: track.id)
                try setRoute(track.route, track: track.id)
                try setClips(track.clips, on: track.id)
                if version <= 8, let clip = self.track(track.id)?.clips.seamlessCrossfade {
                    throw .crossfadeAtSeamlessJoin(clip)
                }
                try setMuted(track.isMuted, tracks: [track.id])
                try setSoloed(track.isSoloed, tracks: [track.id])
                try setFollowTrack(track.isFollowTrack, tracks: [track.id])
                try setRole(track.role, tracks: [track.id])
                if let match = track.match { try setMatch([track.id: match]) }
            }
            // setMarker replaces a marker with the same ID, so a file with two would lose one.
            var markerIDs: Set<MarkerID> = []
            for marker in markers {
                guard markerIDs.insert(marker.id).inserted else { throw .duplicateID(marker.id.rawValue) }
                try setMarker(marker)
            }
            try setRecording(recording)
            if let episode { setEpisode(episode) }
            for transcript in transcripts { try insertTranscript(transcript) }
        } catch {
            throw .invalidSession(error)
        }
    }
}

private struct ParsedTrack {
    let id: TrackID
    let name: String
    let gain: Gain
    let layout: ChannelLayout
    let route: Route?
    let clips: [Clip]
    let isMuted: Bool
    let isSoloed: Bool
    let isFollowTrack: Bool
    let role: Track.Role?
    let match: VoiceMatch?

    init(_ node: XMLElement, version: Int, rides: inout RideLists) throws(SessionFileError) {
        id = TrackID(try node.string("id"))
        isMuted = try node.flag("muted", since: 5, version: version)
        isSoloed = try node.flag("soloed", since: 5, version: version)
        isFollowTrack = try node.flag("follow", since: followSessionVersion, version: version)
        role = try node.optionalString("role").map { word throws(SessionFileError) in
            // From version 11 on (decision 0060).
            guard version >= 11, let role = Track.Role(rawValue: word) else {
                throw .invalidValue(element: "track", attribute: "role")
            }
            return role
        }
        name = try node.string("name")
        gain = try node.gain("gain")
        guard let layout = ChannelLayout(rawValue: try node.string("layout")) else {
            throw .invalidValue(element: "track", attribute: "layout")
        }
        self.layout = layout
        route = try node.sessionElements("route").first.map { route throws(SessionFileError) in
            try Route(route, version: version)
        }
        let matches = node.sessionElements("match")
        guard matches.count <= 1 else { throw .invalidValue(element: "match", attribute: "count") }
        match = try matches.first.map { match throws(SessionFileError) in try VoiceMatch(match, version: version) }
        var clips: [Clip] = []
        for clip in node.sessionElements("clip") { clips.append(try Clip(clip, version: version, rides: &rides)) }
        self.clips = clips
    }
}

extension Clip {
    /// A `<clip>` of a track or of a bin item.
    init(_ node: XMLElement, version: Int, rides: inout RideLists) throws(SessionFileError) {
        self.init(
            id: ClipID(try node.string("id")), file: FileID(try node.string("file")), start: try node.frames("start"),
            offset: try node.frames("offset"), length: try node.frames("length"), gain: try node.gain("gain"),
            fades: try node.fades(version: version), crossfades: try node.crossfades(version: version),
            envelope: try node.envelope(version: version), ride: try rides.ride(of: node, version: version))
    }
}

extension Capture {
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        let resampled: Double? =
            node.optionalString("resampledFromRate") == nil ? nil : try node.value("resampledFromRate")
        let driftCorrected: Bool
        switch node.optionalString("driftCorrected") {
        case nil: driftCorrected = true
        case "false": driftCorrected = false
        default: throw .invalidValue(element: "capture", attribute: "driftCorrected")
        }
        self.init(
            id: CaptureID(try node.string("id")), deviceUID: try node.string("deviceUID"),
            deviceName: try node.string("deviceName"), hostTimeNanos: try node.value("hostTimeNanos"),
            sampleTime: try node.value("sampleTime"), nominalSampleRate: try node.value("nominalSampleRate"),
            measuredSampleRate: try node.value("measuredSampleRate"), latency: try node.value("latency"),
            resampledFromRate: resampled, driftCorrected: driftCorrected)
    }
}

extension AudioFile {
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        let channels: Int = try node.value("channels")
        guard let layout = ChannelLayout(channelCount: channels) else { throw .invalidChannelCount(channels) }
        self.init(
            id: FileID(try node.string("id")), path: try node.string("path"), layout: layout,
            length: try node.frames("length"), capture: node.optionalString("capture").map { CaptureID($0) })
    }
}

extension Route {
    /// `<route device channels/>`, or `<route app/>` from version 2 on (decision 0029). An app
    /// route with a device or channels, or in a version 1 file, is refused.
    fileprivate init(_ node: XMLElement, version: Int) throws(SessionFileError) {
        if let app = node.optionalString("app") {
            guard version >= 2, node.optionalString("device") == nil, node.optionalString("channels") == nil else {
                throw .invalidValue(element: "route", attribute: "app")
            }
            self = .app(bundleID: app)
            return
        }
        let parts = try node.string("channels").split(separator: " ")
        let numbers = parts.compactMap { Int($0) }
        let channels: Channels
        switch (numbers.count, parts.count) {
        case (1, 1): channels = .mono(numbers[0])
        case (2, 2): channels = .stereo(numbers[0], numbers[1])
        default: throw .invalidValue(element: "route", attribute: "channels")
        }
        self = .device(uid: try node.string("device"), channels: channels)
    }
}

extension Marker {
    /// `url` and `image` need version 7, and each parses through its type.
    fileprivate init(_ node: XMLElement, version: Int) throws(SessionFileError) {
        guard let kind = Kind(rawValue: try node.string("kind")) else {
            throw .invalidValue(element: "marker", attribute: "kind")
        }
        func parse<T>(_ name: String, _ make: (String) throws(EpisodeFieldError) -> T) throws(SessionFileError) -> T? {
            guard let text = node.optionalString(name) else { return nil }
            guard version >= 7, let value = try? make(text) else {
                throw .invalidValue(element: "marker", attribute: name)
            }
            return value
        }
        self.init(
            id: MarkerID(try node.string("id")), name: try node.string("name"), position: try node.frames("position"),
            kind: kind, url: try parse("url", WebURL.init), image: try parse("image", ArtworkName.init))
    }
}

extension Episode {
    /// Each field parses through its type, so the reader and the edits keep one rule.
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        self.init()
        func parse<T>(_ name: String, _ make: (String) throws(EpisodeFieldError) -> T?) throws(SessionFileError) -> T? {
            guard let text = node.optionalString(name) else { return nil }
            do throws(EpisodeFieldError) { return try make(text) } catch {
                throw .invalidValue(element: "episode", attribute: name)
            }
        }
        func element(_ name: String) -> EpisodeNotes? {
            node.sessionElements(name).first?.stringValue.flatMap(EpisodeNotes.init)
        }
        title = try parse("title", EpisodeLine.init)
        show = try parse("show", EpisodeLine.init)
        author = try parse("author", EpisodeLine.init)
        number = try parse("number") { text throws(EpisodeFieldError) in try EpisodeNumber(text: text) }
        season = try parse("season") { text throws(EpisodeFieldError) in try EpisodeNumber(text: text) }
        date = try parse("date", CalendarDate.init)
        language = try parse("language", LanguageCode.init)
        copyright = try parse("copyright", EpisodeLine.init)
        switch node.optionalString("explicit") {
        case nil, "false": explicit = false
        case "true": explicit = true
        default: throw .invalidValue(element: "episode", attribute: "explicit")
        }
        summary = element("summary")
        notes = element("notes")
        episodeURL = try parse("episodeURL", WebURL.init)
        feedURL = try parse("feedURL", WebURL.init)
        guid = try parse("guid", EpisodeLine.init)
        artwork = try parse("artwork", ArtworkName.init)
    }
}

extension Transcript {
    /// One `<transcript>` reference, with no words: `Session.resolveTranscripts` gives them. An ID
    /// below 1 and a `file` that is not the canonical text of a UUID are refused here.
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        guard let number = Int(try node.string("id")), number >= 1 else {
            throw .invalidValue(element: "transcript", attribute: "id")
        }
        guard let file = TranscriptFileName(try node.string("file")) else {
            throw .invalidValue(element: "transcript", attribute: "file")
        }
        self.init(id: TranscriptID(number), name: try node.string("name"), file: file, words: nil)
    }
}

extension Recording {
    /// `preRoll` is `true` from `preRollSessionVersion` on, else absent.
    fileprivate init(_ node: XMLElement, version: Int) throws(SessionFileError) {
        var armed: [TrackID] = []
        for arm in node.sessionElements("arm") { armed.append(TrackID(try arm.string("track"))) }
        let preRoll = node.optionalString("preRoll")
        guard preRoll == nil || (version >= preRollSessionVersion && preRoll == "true") else {
            throw .invalidValue(element: "recording", attribute: "preRoll")
        }
        self.init(
            take: try node.value("take"), playheadFrame: try node.frames("playheadFrame"),
            takeStartHostTimeNanos: try node.value("takeStartHostTimeNanos"), armedTracks: armed,
            isPreRoll: preRoll != nil)
    }
}
