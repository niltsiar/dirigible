import Foundation

extension Session {
    /// The origin chain of the file of `clip`, top level first (decision 0057). Empty for a clip on
    /// a file with no origin, and for an unknown clip.
    public func origins(of clip: ClipID) -> [RenderOrigin] {
        guard let file = self.clip(clip)?.clip.file else { return [] }
        var levels: [RenderOrigin] = []
        var next = files[file]?.origin
        while let origin = next {
            levels.append(origin)
            next = files[origin.source]?.origin
        }
        return levels
    }

    /// Each file that a clip plays, and each file in the origin chain of such a file. Remove Unused
    /// Files keeps these files, so Restore Original can go back to each source (decision 0057).
    var filesInUse: Set<FileID> {
        var used = Set(tracks.flatMap { $0.clips.map(\.file) })
        for file in used {
            var next = files[file]?.origin
            while let origin = next, used.insert(origin.source).inserted { next = files[origin.source]?.origin }
        }
        return used
    }

    /// Removes each file of `ids` as `removeFile` does, each rendered file before its source, so the
    /// order of the set does not matter. It throws `.fileIsSource` when a file outside `ids` names a
    /// file of `ids` as its source. A throw changes nothing.
    mutating func removeFiles(_ ids: Set<FileID>) throws(SessionError) {
        func depth(_ id: FileID) -> Int {
            var (count, next) = (0, files[id]?.origin)
            while let origin = next { (count, next) = (count + 1, files[origin.source]?.origin) }
            return count
        }
        let ordered = ids.map { (id: $0, depth: depth($0)) }
            .sorted { $0.depth != $1.depth ? $0.depth > $1.depth : $0.id < $1.id }
        var copy = self
        for file in ordered { try copy.removeFile(file.id) }
        self = copy
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
    /// no copy stores a word outside its file.
    func copiedWords(from file: FileID, span: Range<Frames>) -> [TranscriptID: [Anchor]] {
        let root = self.root(of: file)
        let rootSpan = (span.lowerBound + root.offset)..<(span.upperBound + root.offset)
        var copied: [TranscriptID: [Anchor]] = [:]
        for (id, transcript) in transcripts {
            guard let anchors = transcript.words?[root.file]?.anchors(midpointIn: rootSpan), !anchors.isEmpty
            else { continue }
            copied[id] = anchors.map { anchor in
                let range = anchor.range.clamped(to: rootSpan)
                return Anchor(
                    number: anchor.number,
                    range: (range.lowerBound - rootSpan.lowerBound)..<(range.upperBound - rootSpan.lowerBound),
                    text: anchor.text)
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
    /// envelope moved by the origin offset. It refuses an unknown clip. A throw changes nothing.
    package mutating func lower(_ clips: [ClipID], levels: Int?) throws(SessionError) {
        var copy = self
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
        guard source.layout == file.layout, origin.offset >= .zero, origin.offset + file.length <= source.length
        else { throw .invalidOrigin(file.id) }
    }
}
