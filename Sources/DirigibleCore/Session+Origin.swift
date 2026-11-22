import Foundation

extension Session {
    /// The origin chain of the file of `clip`, top level first (decision 0057). Empty for a clip on
    /// a file with no origin, and for an unknown clip.
    public func origins(of clip: ClipID) -> [RenderOrigin] {
        self.clip(clip).map { origins(ofFile: $0.clip.file) } ?? []
    }

    /// The origin chain of `file`, top level first. Empty for a file with no origin.
    public func origins(ofFile file: FileID) -> [RenderOrigin] {
        var levels: [RenderOrigin] = []
        var next = files[file]?.origin
        while let origin = next {
            levels.append(origin)
            next = files[origin.source]?.origin
        }
        return levels
    }

    /// Each file that a clip of a track or of a bin plays, and each file in the chain of such a file:
    /// at each level the origin source or the drift source. Remove Unused Files keeps these files, so
    /// Restore Original and a second drift fix can go back to each source (decisions 0057 D7 and 0077 D2).
    var filesInUse: Set<FileID> {
        var used = clipFiles
        for file in used {
            var next = files[file]?.linkedSource
            while let source = next, used.insert(source).inserted { next = files[source]?.linkedSource }
        }
        return used
    }

    /// Removes each file of `ids` as `removeFile` does, each file before the file that it links to,
    /// so the order of the set does not matter. It throws `.fileIsSource` when a file outside `ids`
    /// names a file of `ids` as its source. A throw changes nothing.
    mutating func removeFiles(_ ids: Set<FileID>) throws(SessionError) {
        let ordered = ids.map { (id: $0, depth: linkDepth(of: $0)) }
            .sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.id < $1.id }
        var copy = self
        let used = clipFiles
        for file in ordered { try copy.removeFile(file.id, clipFiles: used) }
        self = copy
    }

    /// The number of link steps (`AudioFile.linkedSource`) from `file` to the end of its chain.
    private func linkDepth(of file: FileID) -> Int {
        var (depth, next) = (0, files[file]?.linkedSource)
        while let source = next {
            depth += 1
            next = files[source]?.linkedSource
        }
        return depth
    }

    /// The root of the chain of `file` and the sum of the origin offsets. A file with no origin
    /// gives itself and 0.
    func root(of file: FileID) -> (file: FileID, offset: Frames) {
        var root = (file: file, offset: Frames.zero)
        while let origin = files[root.file]?.origin { root = (origin.source, root.offset + origin.offset) }
        return root
    }

    /// The anchors of each transcript that `span` of `file` plays, read on the root of `file`
    /// (decision 0057 D11): each root anchor whose midpoint is in the span, clamped to it, in frames
    /// from the span start, with the same number. Each copy of words into another file uses it, so
    /// no copy stores a word outside its file. `only` limits the copy to one transcript.
    func copiedWords(from file: FileID, span: Range<Frames>, transcript only: TranscriptID? = nil)
        -> [TranscriptID: [Anchor]]
    {
        let root = self.root(of: file)
        let rootSpan = (span.lowerBound + root.offset)..<(span.upperBound + root.offset)
        return copiedWords(fromRoot: root.file, span: rootSpan, transcript: only) { $0 - rootSpan.lowerBound }
    }

    /// Each anchor of the root `file` whose midpoint is in `span`, clamped to it, with each end moved
    /// by `place`, which never decreases, and the same number. A drift fix (decision 0077 D3) gives the
    /// time map as `place`.
    private func copiedWords(
        fromRoot file: FileID, span: Range<Frames>, transcript only: TranscriptID? = nil,
        place: (Frames) -> Frames
    ) -> [TranscriptID: [Anchor]] {
        var copied: [TranscriptID: [Anchor]] = [:]
        for (id, transcript) in transcripts where only == nil || id == only {
            guard let anchors = transcript.words?[file]?.anchors(midpointIn: span), !anchors.isEmpty else { continue }
            copied[id] = anchors.map { anchor in
                let range = anchor.range.clamped(to: span)
                return Anchor(
                    number: anchor.number, range: place(range.lowerBound)..<place(range.upperBound), text: anchor.text)
            }
        }
        return copied
    }

    /// The transcripts with the words of each rendered file of `named` copied from its root, for an
    /// excerpt (decision 0057 D11). A file with no origin keeps its own words.
    func transcripts(copiedFor named: Set<FileID>) -> [TranscriptID: Transcript] {
        var copied = transcripts
        for id in named {
            guard let file = files[id], file.origin != nil else { continue }
            let words = copiedWords(from: id, span: .zero..<file.length)
            for transcript in copied.keys where copied[transcript]?.words != nil {
                copied[transcript]?.words?[id] = words[transcript].map(Anchors.init)
            }
        }
        return copied
    }

    /// Restore Original (decision 0057 D6): each clip moves to the root of its chain at the frame
    /// that it played, with the added gains taken off. A clip on a file with no origin stays.
    public mutating func restoreOriginals(_ clips: [ClipID]) throws(SessionError) {
        try lower(clips, levels: nil)
    }

    /// Moves each clip down `levels` levels of its chain, or to the root for nil. Each level gives
    /// file = source, offset + origin offset, gain - added gain (clamped to `Gain.range`), and the
    /// envelope and the ride moved by the origin offset. It refuses an unknown clip. A throw
    /// changes nothing.
    package mutating func lower(_ clips: [ClipID], levels: Int?) throws(SessionError) {
        var copy = self
        var rides = RideMaps()
        for id in clips {
            let (track, index) = try copy.position(of: id)
            let clip = copy.tracks[track].clips[index]
            var new = clip
            var left = levels ?? .max
            while left > 0, let origin = copy.files[new.file]?.origin, let source = copy.files[origin.source] {
                new.file = origin.source
                new.offset = new.offset + origin.offset
                new.gain = Gain(clamping: new.gain.dB - origin.addedGain.dB)!
                new.envelope = new.envelope.moved(by: origin.offset, fileLength: source.length)
                new.ride = rides.moved(new.ride, by: origin.offset, fileLength: source.length)
                left -= 1
            }
            guard new != clip else { continue }
            try copy.check(new, on: copy.tracks[track])
            copy.tracks[track].clips.replace(at: index, with: new)
        }
        self = copy
    }

    /// The origin rule of `addFile`: the source is another file of the pool with the same layout,
    /// and the range `offset ..< offset + file.length` is inside the source. A source that is in the
    /// pool cannot name the new file, so the chain ends.
    func check(_ origin: RenderOrigin, of file: AudioFile) throws(SessionError) {
        guard origin.source != file.id, let source = files[origin.source] else { throw .invalidOrigin(file.id) }
        // Both lengths are in `0...Frames.limit`, so the difference cannot overflow; an offset sum can.
        guard source.layout == file.layout, origin.offset >= .zero, origin.offset <= source.length - file.length
        else { throw .invalidOrigin(file.id) }
    }

    /// The drift rule of `addFile` and of the load step (decision 0077 D4). The last file frame can map
    /// to source frame `source.length`, because the converter writes up to 1 frame past the exact
    /// length. The ratio and the gain keep their ranges in their types. A file that names itself is
    /// not in the pool at `addFile`, and has a drift link at the load step, so it is refused.
    func check(_ drift: DriftOrigin, of file: AudioFile) throws(SessionError) {
        guard file.origin == nil, let source = files[drift.source],
            driftSourceFault(of: drift.source) == nil, source.layout == file.layout, drift.offset >= .zero,
            drift.sourceFrame(of: file.length - 1) <= Double(source.length.count)
        else { throw .invalidOrigin(file.id) }
    }

    /// The first fault that keeps `file` from being the source of a drift link (decision 0077 D4).
    /// Each caller passes the resample source of a clip file, `file.drift?.source ?? file`, so a
    /// second fix finds no fault. Nil for a plain file, and for a file that is not in the pool.
    public func driftSourceFault(of file: FileID) -> DriftSourceFault? {
        guard let record = files[file] else { return nil }
        if record.origin != nil { return .origin }
        if record.drift != nil { return .driftLink }
        return record.capture == nil ? nil : .capture
    }

    /// Adds the drift-corrected file `stem` at "<stem>.wav" (decision 0077 D3): `length` frames with
    /// the layout of the source and the link `drift`. The words of `played`, the file that the clip
    /// plays, go into the new file through the time map: new file frame to source frame to `played`
    /// frame. `played` is the source (a first fix) or another drift-corrected file of the same source
    /// (a second fix). It refuses another `played` (`.invalidOrigin`), a transcript that did not load
    /// (`.transcriptNotLoaded`), a taken ID or path (`.duplicateID`), and each refusal of `addFile`.
    /// A throw changes nothing.
    @discardableResult
    mutating func addDriftFile(stem: String, length: Frames, drift: DriftOrigin, wordsFrom played: FileID)
        throws(SessionError) -> FileID
    {
        let id = FileID(stem)
        let path = "\(stem).wav"
        guard files[id] == nil else { throw .duplicateID(stem) }
        guard !files.values.contains(where: { $0.path.lowercased() == path.lowercased() }) else {
            throw .duplicateID(path)
        }
        let unloaded = transcriptsNotLoaded.map(\.id)
        guard unloaded.isEmpty else { throw .transcriptNotLoaded(unloaded) }
        let first = played == drift.source ? nil : files[played]?.drift
        guard let source = files[drift.source], played == drift.source || first?.source == drift.source else {
            throw .invalidOrigin(id)
        }
        var copy = self
        try copy.addFile(AudioFile(id: id, path: path, layout: source.layout, length: length, drift: drift))
        let toPlayed = { (frame: Double) in first?.fileFrame(ofSource: frame) ?? Frames(Int(frame.rounded())) }
        let span = toPlayed(drift.sourceFrame(of: .zero))..<toPlayed(drift.sourceFrame(of: length))
        let place = { (frame: Frames) in
            let sourceFrame = first?.sourceFrame(of: frame) ?? Double(frame.count)
            return min(max(drift.fileFrame(ofSource: sourceFrame), .zero), length)
        }
        for (transcript, anchors) in copy.copiedWords(fromRoot: played, span: span, place: place) {
            copy.setWords(anchors, file: id, transcript: transcript)
        }
        self = copy
        return id
    }
}
