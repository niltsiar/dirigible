import Foundation

extension Session {
    func xmlDocument() -> XMLDocument {
        let root = element("session", ("version", String(fileVersion)), ("sampleRate", String(sampleRate)))
        let namespace = XMLNode(kind: .namespace)
        namespace.name = ""
        namespace.stringValue = sessionNamespace
        root.addNamespace(namespace)

        let captureList = element("captures")
        for capture in captures.values.sorted(by: { $0.id < $1.id }) {
            let node = element(
                "capture", ("id", capture.id.rawValue), ("deviceUID", capture.deviceUID),
                ("deviceName", capture.deviceName), ("hostTimeNanos", String(capture.hostTimeNanos)),
                ("sampleTime", text(capture.sampleTime)), ("nominalSampleRate", text(capture.nominalSampleRate)),
                ("measuredSampleRate", text(capture.measuredSampleRate)), ("latency", String(capture.latency)))
            if let rate = capture.resampledFromRate { add(("resampledFromRate", text(rate)), to: node) }
            if !capture.driftCorrected { add(("driftCorrected", "false"), to: node) }
            captureList.addChild(node)
        }
        root.addChild(captureList)

        let fileList = element("files")
        for file in files.values.sorted(by: { $0.id < $1.id }) {
            let node = element(
                "file", ("id", file.id.rawValue), ("path", file.path), ("channels", String(file.layout.channelCount)),
                ("length", file.length.description))
            if let capture = file.capture { add(("capture", capture.rawValue), to: node) }
            if let origin = file.origin { node.addChild(originElement(origin)) }
            fileList.addChild(node)
        }
        root.addChild(fileList)
        let rides = rideLists()
        if !rides.lists.isEmpty { root.addChild(rides.element) }

        let trackList = element("tracks")
        for track in tracks {
            let node = element(
                "track", ("id", track.id.rawValue), ("name", track.name), ("gain", text(track.gain.dB)),
                ("layout", track.layout.rawValue))
            // A flag is written only when on, so a track with none keeps its old text (0039).
            if track.isMuted { add(("muted", "true"), to: node) }
            if track.isSoloed { add(("soloed", "true"), to: node) }
            if track.isFollowTrack { add(("follow", "true"), to: node) }
            if let role = track.role { add(("role", role.rawValue), to: node) }
            switch track.route {
            case nil: break
            case .device(let uid, let channels):
                node.addChild(
                    element(
                        "route", ("device", uid), ("channels", channels.numbers.map(String.init).joined(separator: " "))
                    ))
            case .app(let bundleID): node.addChild(element("route", ("app", bundleID)))
            }
            for clip in track.clips {
                let clipNode = element(
                    "clip", ("id", clip.id.rawValue), ("file", clip.file.rawValue),
                    ("start", clip.start.description), ("offset", clip.offset.description),
                    ("length", clip.length.description), ("gain", text(clip.gain.dB)))
                // A fade of 0 is not written, so a clip with no fade keeps its version 1 text (0035).
                if clip.fades.fadeIn != .zero { add(("fadeIn", clip.fades.fadeIn.description), to: clipNode) }
                if clip.fades.fadeOut != .zero { add(("fadeOut", clip.fades.fadeOut.description), to: clipNode) }
                // A crossfade of 0 is not written either, so a clip with none keeps its old text (0036).
                if clip.crossfades.start != .zero {
                    add(("crossfadeIn", clip.crossfades.start.description), to: clipNode)
                }
                if clip.crossfades.end != .zero { add(("crossfadeOut", clip.crossfades.end.description), to: clipNode) }
                if let list = rides.lists[clip.id] { add(("ride", "r\(list)"), to: clipNode) }
                if !clip.envelope.isEmpty {
                    let envelope = element("envelope")
                    for point in clip.envelope.points {
                        envelope.addChild(
                            element("point", ("frame", point.frame.description), ("gain", text(point.gain.dB))))
                    }
                    clipNode.addChild(envelope)
                }
                node.addChild(clipNode)
            }
            trackList.addChild(node)
        }
        root.addChild(trackList)

        let markerList = element("markers")
        for marker in sortedMarkers {
            let node = element(
                "marker", ("id", marker.id.rawValue), ("name", marker.name),
                ("position", marker.position.description), ("kind", marker.kind.rawValue))
            // Each field is written only with a value, so a marker with neither keeps its old text.
            if let url = marker.url { add(("url", url.text), to: node) }
            if let image = marker.image { add(("image", image.name), to: node) }
            markerList.addChild(node)
        }
        root.addChild(markerList)
        if !episode.isEmpty { root.addChild(episodeElement(episode)) }
        if !transcripts.isEmpty { root.addChild(transcriptsElement()) }

        if let recording {
            let node = element(
                "recording", ("take", String(recording.take)), ("playheadFrame", recording.playheadFrame.description),
                ("takeStartHostTimeNanos", String(recording.takeStartHostTimeNanos)))
            if recording.isPreRoll { add(("preRoll", "true"), to: node) }
            for track in recording.armedTracks { node.addChild(element("arm", ("track", track.rawValue))) }
            root.addChild(node)
        }

        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"
        document.version = "1.0"
        return document
    }
}

extension Session {
    /// `<transcripts>` (decision 0055): one reference per transcript, loaded or not. The words
    /// are in `Transcripts/<file>.xml`.
    fileprivate func transcriptsElement() -> XMLElement {
        let list = element("transcripts")
        for transcript in transcripts.values.sorted(by: { $0.id < $1.id }) {
            list.addChild(
                element(
                    "transcript", ("id", transcript.id.description), ("name", transcript.name),
                    ("file", transcript.file.description)))
        }
        return list
    }
}

extension Session {
    /// `<rides>` (decision 0060): one `<ride id="r<n>">` for each distinct ride list, numbered from 1 in
    /// track and clip order, and the number of the list of each clip with a ride point. The text
    /// is the `<frame> <gain>` pairs with one space between numbers, each gain in `text(_:)`.
    fileprivate func rideLists() -> (lists: [ClipID: Int], element: XMLElement) {
        var distinct: [GainEnvelope] = []
        var lists: [ClipID: Int] = [:]
        for track in tracks {
            for clip in track.clips where !clip.ride.isEmpty {
                if let index = distinct.lastIndex(of: clip.ride) {
                    lists[clip.id] = index + 1
                } else {
                    distinct.append(clip.ride)
                    lists[clip.id] = distinct.count
                }
            }
        }
        let node = element("rides")
        for (index, ride) in distinct.enumerated() {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(ride.points.count * 16)
            for point in ride.points {
                if !bytes.isEmpty { bytes.append(32) }
                bytes += point.frame.description.utf8
                bytes.append(32)
                bytes += text(point.gain.dB).utf8
            }
            let list = XMLElement(name: "ride", stringValue: String(decoding: bytes, as: UTF8.self))
            add(("id", "r\(index + 1)"), to: list)
            node.addChild(list)
        }
        return (lists, node)
    }
}

/// `<origin source offset gain>` (decision 0057), with one element for each effect, in chain order.
private func originElement(_ origin: RenderOrigin) -> XMLElement {
    let node = element(
        "origin", ("source", origin.source.rawValue), ("offset", origin.offset.description),
        ("gain", text(origin.addedGain.dB)))
    for effect in origin.treatment.effects {
        switch effect {
        case .declip(let declip): node.addChild(element("declip", ("percent", String(declip.percent))))
        case .rumble(let rumble): node.addChild(element("rumble", ("hz", String(rumble.hertz))))
        case .hum(let hertz): node.addChild(element("hum", ("hz", String(hertz.rawValue))))
        case .noise(let amount): node.addChild(element("noise", ("decibels", String(amount.decibels))))
        case .deess(let deess):
            node.addChild(element("deess", ("hz", String(deess.hertz)), ("decibels", String(deess.decibels))))
        }
    }
    return node
}

/// `<episode>` (decision 0045): each set field as an attribute, and `summary` and `notes` as
/// element text, which keeps line breaks and tabs.
private func episodeElement(_ episode: Episode) -> XMLElement {
    let node = element("episode")
    let attributes: [(String, String?)] = [
        ("title", episode.title?.text), ("show", episode.show?.text), ("author", episode.author?.text),
        ("number", episode.number?.description), ("season", episode.season?.description),
        ("date", episode.date?.description), ("language", episode.language?.code),
        ("copyright", episode.copyright?.text), ("explicit", episode.explicit ? "true" : nil),
        ("episodeURL", episode.episodeURL?.text), ("feedURL", episode.feedURL?.text), ("guid", episode.guid?.text),
        ("artwork", episode.artwork?.name),
    ]
    for case (let name, let value?) in attributes { add((name, value), to: node) }
    for (name, value) in [("summary", episode.summary?.text), ("notes", episode.notes?.text)] {
        if let value { node.addChild(XMLElement(name: name, stringValue: value)) }
    }
    return node
}

private func element(_ name: String, _ attributes: (String, String)...) -> XMLElement {
    let node = XMLElement(name: name)
    for attribute in attributes { add(attribute, to: node) }
    return node
}

private func add(_ attribute: (name: String, value: String), to element: XMLElement) {
    let node = XMLNode(kind: .attribute)
    node.name = attribute.name
    node.stringValue = attribute.value
    element.addAttribute(node)
}

/// Whole numbers without a decimal point ("0", "48000"); other values in the shortest text that
/// reads back to the same `Double` ("48000.37").
private func text(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    return String(value)
}
