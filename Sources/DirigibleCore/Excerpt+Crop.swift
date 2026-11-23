import Foundation

extension Excerpt {
    /// The excerpt with its files cut to the frames that its clips play, for a copy that keeps only
    /// those frames (a favorite, decision 0081). A clip plays its file range and half of each of its
    /// crossfades. Those extents of one file, each grown by `margin` and capped at the file, form one
    /// run where they touch or overlap, and each run start goes down to a multiple of `grid`. A run
    /// that is not the whole file gets a new record with the path of its file and the run length,
    /// and its clips move by the run start: the offset, the envelope, and the ride
    /// (`GainEnvelope.moved`). `spans` gives the file frames of each new record in its source file. The
    /// result has no transcript words: a bin item stores none.
    package func cropped(grid: Int, margin: Frames) -> (excerpt: Excerpt, spans: [FileID: Range<Frames>]) {
        var extents: [FileID: [Range<Frames>]] = [:]
        for clip in lanes.flatMap(\.clips) {
            guard let length = files[clip.file]?.length else { continue }
            let start = max(.zero, clip.offset - clip.crossfades.start.half - margin)
            let end = min(length, clip.offset + clip.length + clip.crossfades.end.half + margin)
            extents[clip.file, default: []].append(Frames(start.count / grid * grid)..<end)
        }
        var result = self
        result.transcripts = [:]
        var spans: [FileID: Range<Frames>] = [:]
        var runs: [FileID: [(id: FileID, span: Range<Frames>)]] = [:]
        for (file, ranges) in extents.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let record = files[file] else { continue }
            var merged: [Range<Frames>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            for (index, span) in merged.enumerated() {
                guard span != .zero..<record.length else {
                    runs[file, default: []].append((file, span))
                    continue
                }
                var id = FileID("\(file.rawValue)#\(index + 1)")
                while result.files[id] != nil { id = FileID("\(id.rawValue)#") }
                result.files[id] = AudioFile(
                    id: id, path: record.path, layout: record.layout, length: span.upperBound - span.lowerBound)
                spans[id] = span
                runs[file, default: []].append((id, span))
            }
        }
        var rides = RideMaps()
        for lane in result.lanes.indices {
            for index in result.lanes[lane].clips.indices {
                let clip = result.lanes[lane].clips[index]
                let first = max(.zero, clip.offset - clip.crossfades.start.half)
                guard let run = runs[clip.file]?.first(where: { $0.span.contains(first) }), run.id != clip.file
                else { continue }
                let (shift, length) = (.zero - run.span.lowerBound, run.span.upperBound - run.span.lowerBound)
                var moved = clip
                moved.file = run.id
                moved.offset = clip.offset + shift
                moved.envelope = clip.envelope.moved(by: shift, fileLength: length)
                moved.ride = rides.moved(clip.ride, by: shift, fileLength: length)
                result.lanes[lane].clips[index] = moved
            }
        }
        result.files = result.files.filter { id, _ in
            result.lanes.contains { $0.clips.contains { $0.file == id } }
        }
        return (result, spans)
    }

    /// The excerpt with `gains[file]` added to the gain of each clip of that file, clamped to
    /// `Gain.range`, as `resampled` adds the gain of a conversion (A11).
    package func adding(_ gains: [FileID: Gain]) -> Excerpt {
        var result = self
        for lane in result.lanes.indices {
            for index in result.lanes[lane].clips.indices {
                let clip = result.lanes[lane].clips[index]
                if let gain = gains[clip.file], let sum = Gain(clamping: clip.gain.dB + gain.dB) {
                    result.lanes[lane].clips[index].gain = sum
                }
            }
        }
        return result
    }
}
