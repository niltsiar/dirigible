import DirigibleAudio
import DirigibleCore
import Foundation

/// The text summary of `info`: one line for the session, then one line for each object, then the
/// sync line of each take with audio, the line of each anchor fault (decision 0061), and the `raw`
/// line of each segment that has its CAF (decision 0071).
package func summary(
    of session: Session, name: String, media: [FileID: MediaFault], takeMap: TakeMapRead,
    raw: [SegmentName: RawVerdict]
) -> String {
    var lines = ["\(name): \(session.sampleRate) Hz"]
    for track in session.tracks {
        var line = "track \(track.id) \(quoted(track.name)) \(track.layout.rawValue) \(track.gain)"
        switch track.route {
        case nil: break
        case .device(let uid, let channels):
            line += " route \(quoted(uid)) \(channels.numbers.map(String.init).joined(separator: ","))"
        case .app(let bundleID): line += " route app \(quoted(bundleID))"
        }
        if track.isMuted { line += " muted" }
        if track.isSoloed { line += " soloed" }
        if let role = track.role { line += " role \(role.rawValue)" }
        lines.append(line)
        for clip in track.clips {
            lines.append(
                "  clip \(clip.id) file \(clip.file) start \(clip.start) offset \(clip.offset) length \(clip.length) "
                    + "\(clip.gain)"
                    + (clip.fades == .zero ? "" : " fade in \(clip.fades.fadeIn), out \(clip.fades.fadeOut)")
                    + (clip.crossfades.start == .zero ? "" : " crossfade in \(clip.crossfades.start)")
                    + (clip.crossfades.end == .zero ? "" : " crossfade out \(clip.crossfades.end)")
                    + envelopeText(of: clip))
        }
    }
    for file in session.sortedFiles {
        let capture = file.capture.map { " capture \($0)" } ?? ""
        let state = media[file.id].map { " media \($0.word)" + ($0.length.map { " \($0)" } ?? "") } ?? ""
        lines.append(
            "file \(file.id) \(quoted(file.path)) \(file.layout.rawValue) length \(file.length)\(capture)"
                + "\(originText(of: file))\(state)")
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
        var line = "marker \(marker.id) \(quoted(marker.name)) \(marker.kind.rawValue) at \(marker.position)"
        if let url = marker.url { line += " url \(quoted(url.text))" }
        if let image = marker.image { line += " image \(quoted(image.path))" }
        lines.append(line)
    }
    if let recording = session.recording {
        let armed = recording.armedTracks.map(\.rawValue).joined(separator: ",")
        let preRoll = recording.isPreRoll ? " pre-roll" : ""
        lines.append(
            "recording take \(recording.take) at \(recording.playheadFrame) "
                + "host time \(recording.takeStartHostTimeNanos) armed \(armed)\(preRoll)")
    }
    lines += TakeWork.syncLines(takeMap.map.sync, sampleRate: session.sampleRate)
    lines += takeMap.faults.map { TakeWork.faultLine($0.error) }
    lines += raw.sorted { $0.key < $1.key }.map { "raw \($0.key.stem) kept: \($0.value.keptReason)" }
    return lines.map { $0 + "\n" }.joined()
}

/// The gain points of a clip in the `info` text: the points inside the clip window as
/// `<timeline frame>:<dB>`, as `clip envelope` takes them, the count of the points outside it, and
/// with a point outside, the gain at the first and the last frame of the window.
private func envelopeText(of clip: Clip) -> String {
    let inside = clip.pointsInWindow
    let outside = clip.envelope.points.count - inside.count
    var parts = inside.isEmpty ? [] : [" envelope " + inside.map { "\($0.frame):\($0.gain.dB)" }.joined(separator: " ")]
    if outside > 0 {
        parts.append("\(inside.isEmpty ? " " : ", ")\(outside) \(outside == 1 ? "point" : "points") outside the clip")
        let edges = clip.windowEdges
        parts.append(", window edges \(edges.first.frame):\(edges.first.dB) \(edges.last.frame):\(edges.last.dB)")
    }
    return parts.joined()
}

/// Quotes and escapes free text, so a quote or a space in a name keeps one line readable.
private func quoted(_ text: String) -> String { String(reflecting: text) }
