import DirigibleAudio
import DirigibleCore
import Foundation

/// The JSON contract for scripts and agents (decision 0011). Keys are sorted. An absent optional
/// value is left out. Tracks keep the session order and clips the lane order. Files and captures
/// sort by ID, markers by position and then ID.
struct SessionView: Encodable {
    struct CaptureView: Encodable {
        let id: String
        let deviceUID: String
        let deviceName: String
        let hostTimeNanos: UInt64
        let sampleTime: Double
        let nominalSampleRate: Double
        let measuredSampleRate: Double
        let latency: Int
        let resampledFromRate: Double?
        let driftCorrected: Bool
    }

    struct FileView: Encodable {
        let id: String
        let path: String
        let layout: String
        let length: Int
        let capture: String?
        /// "ok", "missing", "short", or "unreadable" (decision 0016).
        let media: String
        /// The real length of a short file.
        let mediaLength: Int?
    }

    struct RouteView: Encodable {
        let device: String
        let channels: [Int]
    }

    struct ClipView: Encodable {
        let id: String
        let file: String
        let start: Int
        let offset: Int
        let length: Int
        let gain: Double
    }

    struct TrackView: Encodable {
        let id: String
        let name: String
        let gain: Double
        let layout: String
        let route: RouteView?
        let clips: [ClipView]
    }

    struct MarkerView: Encodable {
        let id: String
        let name: String
        let position: Int
        let kind: String
    }

    struct RecordingView: Encodable {
        let take: Int
        let playheadFrame: Int
        let takeStartHostTimeNanos: UInt64
        let armedTracks: [String]
    }

    let sampleRate: Int
    let captures: [CaptureView]
    let files: [FileView]
    let tracks: [TrackView]
    let markers: [MarkerView]
    let recording: RecordingView?

    init(_ session: Session, media: [FileID: MediaFault]) {
        sampleRate = session.sampleRate
        captures = session.sortedCaptures.map {
            CaptureView(
                id: $0.id.rawValue, deviceUID: $0.deviceUID, deviceName: $0.deviceName, hostTimeNanos: $0.hostTimeNanos,
                sampleTime: $0.sampleTime, nominalSampleRate: $0.nominalSampleRate,
                measuredSampleRate: $0.measuredSampleRate, latency: $0.latency, resampledFromRate: $0.resampledFromRate,
                driftCorrected: $0.driftCorrected)
        }
        files = session.sortedFiles.map {
            FileView(
                id: $0.id.rawValue, path: $0.path, layout: $0.layout.rawValue, length: $0.length.count,
                capture: $0.capture?.rawValue, media: media[$0.id].map(\.word) ?? "ok",
                mediaLength: media[$0.id].flatMap(\.length))
        }
        tracks = session.tracks.map { track in
            TrackView(
                id: track.id.rawValue, name: track.name, gain: track.gain.dB, layout: track.layout.rawValue,
                route: track.route.map { RouteView(device: $0.deviceUID, channels: $0.channels.numbers) },
                clips: track.clips.map {
                    ClipView(
                        id: $0.id.rawValue, file: $0.file.rawValue, start: $0.start.count, offset: $0.offset.count,
                        length: $0.length.count, gain: $0.gain.dB)
                })
        }
        markers = session.sortedMarkers.map {
            MarkerView(id: $0.id.rawValue, name: $0.name, position: $0.position.count, kind: $0.kind.rawValue)
        }
        recording = session.recording.map {
            RecordingView(
                take: $0.take, playheadFrame: $0.playheadFrame.count, takeStartHostTimeNanos: $0.takeStartHostTimeNanos,
                armedTracks: $0.armedTracks.map(\.rawValue))
        }
    }

    func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }
}

/// The text summary of `info`: one line for the session, then one line for each object.
func summary(of session: Session, name: String, media: [FileID: MediaFault]) -> String {
    var lines = ["\(name): \(session.sampleRate) Hz"]
    for track in session.tracks {
        var line = "track \(track.id) \(quoted(track.name)) \(track.layout.rawValue) \(track.gain)"
        if let route = track.route {
            line +=
                " route \(quoted(route.deviceUID)) \(route.channels.numbers.map(String.init).joined(separator: ","))"
        }
        lines.append(line)
        for clip in track.clips {
            lines.append(
                "  clip \(clip.id) file \(clip.file) start \(clip.start) offset \(clip.offset) length \(clip.length) "
                    + "\(clip.gain)")
        }
    }
    for file in session.sortedFiles {
        let capture = file.capture.map { " capture \($0)" } ?? ""
        let state = media[file.id].map { " media \($0.word)" + ($0.length.map { " \($0)" } ?? "") } ?? ""
        lines.append(
            "file \(file.id) \(quoted(file.path)) \(file.layout.rawValue) length \(file.length)\(capture)\(state)")
    }
    for capture in session.sortedCaptures {
        var line =
            "capture \(capture.id) \(quoted(capture.deviceName)) device \(quoted(capture.deviceUID)) "
            + "host time \(capture.hostTimeNanos) sample time \(capture.sampleTime) "
            + "rate \(capture.nominalSampleRate) measured \(capture.measuredSampleRate) latency \(capture.latency)"
        if let rate = capture.resampledFromRate { line += " resampled from \(rate)" }
        if !capture.driftCorrected { line += " drift not corrected" }
        lines.append(line)
    }
    for marker in session.sortedMarkers {
        lines.append("marker \(marker.id) \(quoted(marker.name)) \(marker.kind.rawValue) at \(marker.position)")
    }
    if let recording = session.recording {
        let armed = recording.armedTracks.map(\.rawValue).joined(separator: ",")
        lines.append(
            "recording take \(recording.take) at \(recording.playheadFrame) "
                + "host time \(recording.takeStartHostTimeNanos) armed \(armed)")
    }
    return lines.map { $0 + "\n" }.joined()
}

/// Quotes and escapes free text, so a quote or a space in a name keeps one line readable.
private func quoted(_ text: String) -> String { String(reflecting: text) }

extension MediaFault {
    fileprivate var word: String {
        switch self {
        case .missing: "missing"
        case .short: "short"
        case .unreadable: "unreadable"
        }
    }

    fileprivate var length: Int? {
        if case .short(let frames) = self { return frames.count }
        return nil
    }
}

extension Session {
    fileprivate var sortedCaptures: [Capture] { captures.values.sorted { $0.id < $1.id } }
    fileprivate var sortedFiles: [AudioFile] { files.values.sorted { $0.id < $1.id } }
    fileprivate var sortedMarkers: [Marker] { markers.values.sorted { ($0.position, $0.id) < ($1.position, $1.id) } }
}
