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

    init(xml data: Data) throws(SessionFileError) {
        guard let document = try? XMLDocument(data: data), let root = document.rootElement(),
            root.localName == "session", root.uri == sessionNamespace
        else { throw .malformedXML }

        let version: Int = try root.value("version")
        guard version <= sessionVersion else { throw .unsupportedVersion(version) }
        guard version >= 1 else { throw .invalidValue(element: "session", attribute: "version") }
        let sampleRate: Int = try root.value("sampleRate")
        guard sampleRate > 0 else { throw .invalidValue(element: "session", attribute: "sampleRate") }

        var captures: [Capture] = []
        for node in root.children("captures", "capture") { captures.append(try Capture(node)) }
        var files: [AudioFile] = []
        for node in root.children("files", "file") { files.append(try AudioFile(node)) }
        var tracks: [ParsedTrack] = []
        for node in root.children("tracks", "track") { tracks.append(try ParsedTrack(node)) }
        var markers: [Marker] = []
        for node in root.children("markers", "marker") { markers.append(try Marker(node)) }
        let recording = try root.elements(forName: "recording").first.map { node throws(SessionFileError) in
            try Recording(node)
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
            }
            // setMarker replaces a marker with the same ID, so a file with two would lose one.
            var markerIDs: Set<MarkerID> = []
            for marker in markers {
                guard markerIDs.insert(marker.id).inserted else { throw .duplicateID(marker.id.rawValue) }
                try setMarker(marker)
            }
            try setRecording(recording)
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

    init(_ node: XMLElement) throws(SessionFileError) {
        id = TrackID(try node.string("id"))
        name = try node.string("name")
        gain = try node.gain("gain")
        guard let layout = ChannelLayout(rawValue: try node.string("layout")) else {
            throw .invalidValue(element: "track", attribute: "layout")
        }
        self.layout = layout
        route = try node.elements(forName: "route").first.map { route throws(SessionFileError) in
            try Route(route)
        }
        var clips: [Clip] = []
        for clip in node.elements(forName: "clip") {
            clips.append(
                Clip(
                    id: ClipID(try clip.string("id")), file: FileID(try clip.string("file")),
                    start: try clip.frames("start"), offset: try clip.frames("offset"),
                    length: try clip.frames("length"), gain: try clip.gain("gain")))
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
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        let parts = try node.string("channels").split(separator: " ")
        let numbers = parts.compactMap { Int($0) }
        let channels: Channels
        switch (numbers.count, parts.count) {
        case (1, 1): channels = .mono(numbers[0])
        case (2, 2): channels = .stereo(numbers[0], numbers[1])
        default: throw .invalidValue(element: "route", attribute: "channels")
        }
        self.init(deviceUID: try node.string("device"), channels: channels)
    }
}

extension Marker {
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        guard let kind = Kind(rawValue: try node.string("kind")) else {
            throw .invalidValue(element: "marker", attribute: "kind")
        }
        self.init(
            id: MarkerID(try node.string("id")), name: try node.string("name"), position: try node.frames("position"),
            kind: kind)
    }
}

extension Recording {
    fileprivate init(_ node: XMLElement) throws(SessionFileError) {
        var armed: [TrackID] = []
        for arm in node.elements(forName: "arm") { armed.append(TrackID(try arm.string("track"))) }
        self.init(
            take: try node.value("take"), playheadFrame: try node.frames("playheadFrame"),
            takeStartHostTimeNanos: try node.value("takeStartHostTimeNanos"), armedTracks: armed)
    }
}

extension XMLElement {
    fileprivate func children(_ list: String, _ name: String) -> [XMLElement] {
        elements(forName: list).first?.elements(forName: name) ?? []
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
        guard let gain = Gain(dB: try value(attribute)) else { throw invalid(attribute) }
        return gain
    }

    private func invalid(_ attribute: String) -> SessionFileError {
        .invalidValue(element: localName ?? "", attribute: attribute)
    }
}
