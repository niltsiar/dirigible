import Foundation

/// A run of clips, the stem of the file that a render made from its span (decision 0054), the
/// treatment as rendered, and the gain that the render adds to each clip of the run (decision 0057).
public struct RenderedRun: Hashable, Sendable {
    public let run: ClipRun
    public let stem: String
    public let treatment: Treatment
    public let addedGain: Gain

    public init(run: ClipRun, stem: String, treatment: Treatment, addedGain: Gain) {
        self.run = run
        self.stem = stem
        self.treatment = treatment
        self.addedGain = addedGain
    }
}

/// A clip that `Session.repoint` moved, and the file that it plays now.
public struct RenderedClip: Hashable, Sendable {
    public let clip: ClipID
    public let file: FileID

    public init(clip: ClipID, file: FileID) {
        self.clip = clip
        self.file = file
    }
}

extension Session {
    /// Moves the clips of `runs` onto the files that a render made from the spans of their runs
    /// (decision 0054). The caller writes the files and gives their stems. For each run, a new file
    /// "<stem>.wav" with the layout of the source file, the length of the span, the `capture` of
    /// the source, and the origin of the run (decision 0057), with no words. Each clip of the run
    /// points at that file at (old offset - run start), gets the added gain on its gain (clamped to
    /// `Gain.range`), and keeps its ID, start, length, fades, and crossfades. Its envelope and its
    /// ride keep the gain at each source frame (`GainEnvelope.moved`). The source files stay in the pool. The
    /// result lists each moved clip with its new file, in the order of `runs`, and inside a run in
    /// the order of `run.clips`.
    ///
    /// The runs must be the runs that `clipRuns(of:)` gives for the clips of all runs, else it
    /// throws `.frameOutOfRange`. A stem that a file of the pool has, an ID or a path, a stem that
    /// two runs share, and each other refusal of `addDerivedFile` throw too. A throw changes nothing,
    /// so a caller runs it before it writes a file.
    public mutating func repoint(_ runs: [RenderedRun]) throws(SessionError) -> [RenderedClip] {
        var copy = self
        let moved = try copy.repointing(runs)
        self = copy
        return moved
    }

    private mutating func repointing(_ runs: [RenderedRun]) throws(SessionError) -> [RenderedClip] {
        let found = try clipRuns(of: runs.flatMap(\.run.clips))
        guard found.count == runs.count, Set(found) == Set(runs.map(\.run)) else { throw .frameOutOfRange }
        var targets: [ClipID: (file: FileID, shift: Frames, length: Frames, gain: Gain)] = [:]
        var moved: [RenderedClip] = []
        var rides = RideMaps()
        for rendered in runs {
            let run = rendered.run
            guard let layout = files[run.file]?.layout else { throw .unknownFile(run.file) }
            let origin = RenderOrigin(
                source: run.file, offset: run.span.lowerBound, treatment: rendered.treatment,
                addedGain: rendered.addedGain)
            let file = try addDerivedFile(from: run, stem: rendered.stem, layout: layout, origin: origin)
            let length = run.span.upperBound - run.span.lowerBound
            for id in run.clips {
                targets[id] = (file, .zero - run.span.lowerBound, length, rendered.addedGain)
                moved.append(RenderedClip(clip: id, file: file))
            }
        }
        for track in tracks.indices {
            var edits: [(index: Int, clip: Clip)] = []
            for (index, clip) in tracks[track].clips.enumerated() {
                guard let target = targets[clip.id] else { continue }
                var new = clip
                new.file = target.file
                new.offset = clip.offset + target.shift
                new.gain = Gain(clamping: clip.gain.dB + target.gain.dB)!
                new.envelope = clip.envelope.moved(by: target.shift, fileLength: target.length)
                new.ride = rides.moved(clip.ride, by: target.shift, fileLength: target.length)
                try check(new, on: tracks[track])
                edits.append((index, new))
            }
            tracks[track].clips.replace(edits)
        }
        return moved
    }
}
