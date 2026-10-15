import Foundation

/// The clips of one file whose written spans touch or overlap, and the union of those spans in the
/// frames of the file (decision 0056).
public struct ClipRun: Hashable, Sendable {
    public let file: FileID
    public let span: Range<Frames>
    public let clips: [ClipID]
}

extension Session {
    /// The runs of `clips`, by file, then by span start. The written span of a clip is its file range
    /// plus `max(10 s, half the crossfade)` at each edge, capped at the file. No layout check: a
    /// split refuses a mono clip itself. A clip named twice counts once. An unknown clip throws
    /// `.unknownClip`, and a clip whose file has no record throws `.unknownFile`.
    package func clipRuns(of clips: [ClipID]) throws(SessionError) -> [ClipRun] {
        var spans: [(clip: Clip, span: Range<Frames>)] = []
        let handle = Frames(10 * sampleRate)
        var seen: Set<ClipID> = []
        for id in clips where seen.insert(id).inserted {
            guard let clip = clip(id)?.clip else { throw .unknownClip(id) }
            guard let length = files[clip.file]?.length else { throw .unknownFile(clip.file) }
            let start = max(.zero, clip.offset - max(handle, clip.crossfades.start.half))
            let end = min(length, clip.offset + clip.length + max(handle, clip.crossfades.end.half))
            spans.append((clip, start..<end))
        }
        spans.sort { ($0.clip.file.rawValue, $0.span.lowerBound) < ($1.clip.file.rawValue, $1.span.lowerBound) }
        var runs: [ClipRun] = []
        for (clip, span) in spans {
            if let last = runs.last, last.file == clip.file, span.lowerBound <= last.span.upperBound {
                let end = max(last.span.upperBound, span.upperBound)
                runs[runs.count - 1] = ClipRun(
                    file: clip.file, span: last.span.lowerBound..<end, clips: last.clips + [clip.id])
            } else {
                runs.append(ClipRun(file: clip.file, span: span, clips: [clip.id]))
            }
        }
        return runs
    }

    /// Adds the file `stem` at "<stem>.wav", made from `run.span` of `run.file`: the span length,
    /// the capture of the source, and the words of the span (decision 0056). It refuses an unknown
    /// source (`.unknownFile`), an empty span or a span past the source (`.frameOutOfRange`), a
    /// transcript that did not load (`.transcriptNotLoaded`), a taken ID, an equal record too, or a
    /// path that another record has in any case (`.duplicateID`), and each refusal of `addFile`. A
    /// throw changes nothing. No layout check: the caller owns it.
    @discardableResult
    mutating func addDerivedFile(from run: ClipRun, stem: String, layout: ChannelLayout) throws(SessionError) -> FileID
    {
        guard let source = files[run.file] else { throw .unknownFile(run.file) }
        let span = run.span
        guard !span.isEmpty, span.lowerBound >= .zero, span.upperBound <= source.length else { throw .frameOutOfRange }
        let unloaded = transcriptsNotLoaded.map(\.id)
        guard unloaded.isEmpty else { throw .transcriptNotLoaded(unloaded) }
        let id = FileID(stem)
        guard files[id] == nil else { throw .duplicateID(stem) }
        let path = "\(stem).wav"
        guard !files.values.contains(where: { $0.path.lowercased() == path.lowercased() }) else {
            throw .duplicateID(path)
        }
        let length = span.upperBound - span.lowerBound
        try addFile(AudioFile(id: id, path: path, layout: layout, length: length, capture: source.capture))
        copyWords(of: run.file, span: span, shift: .zero - span.lowerBound, to: [id])
        return id
    }
}
