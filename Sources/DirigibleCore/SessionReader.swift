import Foundation

extension Session {
    /// Reads `session.xml` from the package. The reader parses the XML into domain values, then
    /// builds the session through the same edits that the app uses, so each rule has one check.
    public init(contentsOf package: URL) throws(SessionFileError) {
        let data: Data
        do {
            data = try Data(contentsOf: package.appending(path: "session.xml"))
        } catch {
            throw .readFailed(errno: posixCode(of: error))
        }
        try self.init(xml: data)
    }

    /// `newest` is the newest version that the reader accepts. A test gives a lower one to act as
    /// an older build.
    init(xml data: Data, newest: Int = sessionVersion) throws(SessionFileError) {
        guard let document = try? XMLDocument(data: data), let root = document.rootElement(),
            root.localName == "session", root.uri == sessionNamespace
        else { throw .malformedXML }

        let version: Int = try root.value("version")
        guard version <= newest else { throw .unsupportedVersion(version) }
        guard version >= 1 else { throw .invalidValue(element: "session", attribute: "version") }
        let sampleRate: Int = try root.value("sampleRate")
        guard sampleRate > 0 else { throw .invalidValue(element: "session", attribute: "sampleRate") }

        var captures: [Capture] = []
        for node in root.children("captures", "capture") { captures.append(try Capture(node)) }
        var files: [AudioFile] = []
        for node in root.children("files", "file") { files.append(try AudioFile(node)) }
        var tracks: [ParsedTrack] = []
        for node in root.children("tracks", "track") { tracks.append(try ParsedTrack(node, version: version)) }
        var markers: [Marker] = []
        for node in root.children("markers", "marker") { markers.append(try Marker(node, version: version)) }
        let recording = try root.sessionElements("recording").first.map { node throws(SessionFileError) in
            try Recording(node)
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

        self.init(sampleRate: sampleRate)
        do throws(SessionError) {
            for capture in captures { try addCapture(capture) }
            for file in files { try addFile(file) }
            for track in tracks {
                try addTrack(track.id, name: track.name, layout: track.layout)
                try setGain(track.gain, track: track.id)
                try setRoute(track.route, track: track.id)
                try setClips(track.clips, on: track.id)
                try setMuted(track.isMuted, tracks: [track.id])
                try setSoloed(track.isSoloed, tracks: [track.id])
            }
            // setMarker replaces a marker with the same ID, so a file with two would lose one.
            var markerIDs: Set<MarkerID> = []
            for marker in markers {
                guard markerIDs.insert(marker.id).inserted else { throw .duplicateID(marker.id.rawValue) }
                try setMarker(marker)
            }
            try setRecording(recording)
            if let episode { setEpisode(episode) }
            for transcript in transcripts { try addTranscript(transcript) }
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

    init(_ node: XMLElement, version: Int) throws(SessionFileError) {
        id = TrackID(try node.string("id"))
        isMuted = try node.flag("muted", version: version)
        isSoloed = try node.flag("soloed", version: version)
        name = try node.string("name")
        gain = try node.gain("gain")
        guard let layout = ChannelLayout(rawValue: try node.string("layout")) else {
            throw .invalidValue(element: "track", attribute: "layout")
        }
        self.layout = layout
        route = try node.sessionElements("route").first.map { route throws(SessionFileError) in
            try Route(route, version: version)
        }
        var clips: [Clip] = []
        for clip in node.sessionElements("clip") {
            clips.append(
                Clip(
                    id: ClipID(try clip.string("id")), file: FileID(try clip.string("file")),
                    start: try clip.frames("start"), offset: try clip.frames("offset"),
                    length: try clip.frames("length"), gain: try clip.gain("gain"),
                    fades: try clip.fades(version: version), crossfades: try clip.crossfades(version: version)))
        }
        self.clips = clips
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
    /// One `<transcript>`. A line splits at its first three spaces. A number below 1, a start or an
    /// end that is not an integer, an end before the start, a second `<words>` of one file, and a
    /// transcript with no `<words>` are refused here; `Session.addTranscript` checks the rest.
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        guard let number = Int(try node.string("id")), number >= 1 else {
            throw .invalidValue(element: "transcript", attribute: "id")
        }
        var words: [FileID: Anchors] = [:]
        for element in node.sessionElements("words") {
            let file = FileID(try element.string("file"))
            guard words[file] == nil else { throw .invalidSession(.duplicateID(file.rawValue)) }
            var anchors: [Anchor] = []
            for line in (element.stringValue ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
                let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
                guard fields.count == 4, let number = Int(fields[0]), number >= 1, let start = Int(fields[1]),
                    let end = Int(fields[2])
                else { throw .invalidValue(element: "words", attribute: "line") }
                guard start <= end else { throw .invalidSession(.wordOutsideFile(file)) }
                anchors.append(Anchor(number: number, range: Frames(start)..<Frames(end), text: String(fields[3])))
            }
            words[file] = Anchors(anchors)
        }
        guard !words.isEmpty else { throw .invalidValue(element: "transcript", attribute: "words") }
        self.init(id: TranscriptID(number), name: try node.string("name"), words: words)
    }
}

extension Recording {
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        var armed: [TrackID] = []
        for arm in node.sessionElements("arm") { armed.append(TrackID(try arm.string("track"))) }
        self.init(
            take: try node.value("take"), playheadFrame: try node.frames("playheadFrame"),
            takeStartHostTimeNanos: try node.value("takeStartHostTimeNanos"), armedTracks: armed)
    }
}

extension XMLElement {
    fileprivate func children(_ list: String, _ name: String) -> [XMLElement] {
        sessionElements(list).first?.sessionElements(name) ?? []
    }

    /// Children by local name in the session namespace, so a prefixed file (`<d:tracks>`) reads too.
    fileprivate func sessionElements(_ name: String) -> [XMLElement] {
        elements(forLocalName: name, uri: sessionNamespace)
    }

    fileprivate func optionalString(_ attribute: String) -> String? {
        self.attribute(forName: attribute)?.stringValue
    }

    fileprivate func string(_ attribute: String) throws(SessionFileError) -> String {
        guard let value = self.attribute(forName: attribute)?.stringValue else {
            throw .missingAttribute(element: localName ?? "", attribute: attribute)
        }
        return value
    }

    fileprivate func value<T: LosslessStringConvertible>(_ attribute: String) throws(SessionFileError) -> T {
        guard let value = T(try string(attribute)) else { throw invalid(attribute) }
        return value
    }

    fileprivate func frames(_ attribute: String) throws(SessionFileError) -> Frames {
        Frames(try value(attribute) as Int)
    }

    fileprivate func gain(_ attribute: String) throws(SessionFileError) -> Gain {
        // An old file can hold a finite gain outside `Gain.range` (track fader run): it opens.
        guard let gain = Gain(clamping: try value(attribute)) else { throw invalid(attribute) }
        return gain
    }

    /// `fadeIn` and `fadeOut` from version 3 on (decision 0035). A missing one is 0. `Fades`
    /// refuses a negative value or a value over the limit.
    fileprivate func fades(version: Int) throws(SessionFileError) -> Fades {
        func length(_ attribute: String) throws(SessionFileError) -> Frames {
            guard optionalString(attribute) != nil else { return .zero }
            guard version >= 3 else { throw invalid(attribute) }
            return try frames(attribute)
        }
        let fadeIn = try length("fadeIn")
        let fadeOut = try length("fadeOut")
        guard let fades = Fades(fadeIn: fadeIn, fadeOut: fadeOut) else {
            throw invalid(Fades(fadeIn: fadeIn, fadeOut: .zero) == nil ? "fadeIn" : "fadeOut")
        }
        return fades
    }

    /// `crossfadeIn` and `crossfadeOut` from version 4 on (decision 0036). A missing one is 0.
    /// `Crossfades` refuses an odd or negative value or a value over the limit. `ClipLane` checks
    /// the pairing.
    fileprivate func crossfades(version: Int) throws(SessionFileError) -> Crossfades {
        func length(_ attribute: String) throws(SessionFileError) -> Frames {
            guard optionalString(attribute) != nil else { return .zero }
            guard version >= 4 else { throw invalid(attribute) }
            let value = try frames(attribute)
            guard Crossfades(start: value, end: .zero) != nil else { throw invalid(attribute) }
            return value
        }
        return Crossfades(start: try length("crossfadeIn"), end: try length("crossfadeOut"))!
    }

    /// `muted` and `soloed` from version 5 on (decision 0039): `true` or `false`. A missing one is
    /// false.
    fileprivate func flag(_ attribute: String, version: Int) throws(SessionFileError) -> Bool {
        guard let value = optionalString(attribute) else { return false }
        guard version >= 5, let flag = Bool(value) else { throw invalid(attribute) }
        return flag
    }

    private func invalid(_ attribute: String) -> SessionFileError {
        .invalidValue(element: localName ?? "", attribute: attribute)
    }
}
