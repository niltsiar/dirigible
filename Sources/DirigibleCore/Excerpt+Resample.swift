import Foundation

extension Excerpt {
    /// The excerpt at `rate`, for a paste from a package of another rate (decision 0042). `lengths`
    /// gives the frame count of each converted file, by source file ID, and `gains` the gain that
    /// the conversion adds to a file (A11). Each edge b maps to round(b x rate / sampleRate): the
    /// start, the end, and the offset of each clip, and the excerpt length. A length is the scaled
    /// end minus the scaled start, so two touching clips still touch, and it stops at the end of
    /// the converted file. A crossfade rounds to an even count, one value for both clips of a join: the
    /// least of that count, the two media handles, and the room of each clip (0036). A crossfade
    /// with no join drops. A fade rounds and then fits the room beside the crossfades (0035). Each
    /// transcript word edge scales as a clip edge and stops at the end of the converted file (0055).
    public func resampled(to rate: Int, lengths: [FileID: Frames], gains: [FileID: Gain] = [:]) -> Excerpt {
        let old = sampleRate
        func scale(_ frames: Frames) -> Frames { Frames((2 * frames.count * rate + old) / (2 * old)) }
        /// An even count: 2 x the scaled half, rounded.
        func even(_ frames: Frames) -> Frames { Frames(2 * ((frames.count * rate + old) / (2 * old))) }
        var scaled = Excerpt(
            kind: kind, length: scale(length), lanes: lanes, sampleRate: rate,
            pool: files.mapValues { file in
                var file = file
                file.length = lengths[file.id] ?? scale(file.length)
                return file
            })
        for lane in scaled.lanes.indices {
            let source = lanes[lane].clips
            var clips = source.map { clip in
                let fileLength = scaled.files[clip.file]?.length ?? scale(clip.offset + clip.length)
                let start = scale(clip.start)
                let offset = min(scale(clip.offset), fileLength)
                var result = clip
                (result.start, result.offset) = (start, offset)
                result.length = min(scale(clip.end) - start, fileLength - offset)
                result.crossfades = .zero
                if let gain = gains[clip.file], let sum = Gain(clamping: clip.gain.dB + gain.dB) { result.gain = sum }
                return result
            }
            // A seamless source join (a split) stays seamless: the right clip goes on from the file
            // frame where the left clip ends, and keeps its scaled end.
            for index in clips.indices.dropLast()
            where source[index].end == source[index + 1].start && source[index].isSeamless(with: source[index + 1]) {
                let (a, end) = (clips[index], clips[index + 1].end)
                let fileLength = scaled.files[a.file]?.length ?? (a.offset + a.length + clips[index + 1].length)
                clips[index + 1].offset = a.offset + a.length
                clips[index + 1].length = min(end - clips[index + 1].start, fileLength - clips[index + 1].offset)
            }
            // One value for each join, so both clips keep it (0036): the least of the scaled value,
            // each media handle, and the room of each clip beside its other edge.
            for index in clips.indices.dropLast() where source[index].end == source[index + 1].start {
                let value = source[index].crossfades.end
                guard value > .zero, value == source[index + 1].crossfades.start else { continue }
                let (a, b) = (clips[index], clips[index + 1])
                let fileA = scaled.files[a.file]?.length ?? (a.offset + a.length)
                let half = [
                    even(value).half, fileA - (a.offset + a.length), b.offset, a.length - a.crossfades.start.half,
                    b.length - even(source[index + 1].crossfades.end).half,
                ].min()!
                let length = Frames(2 * max(0, half.count))
                clips[index].crossfades = Crossfades(valid: a.crossfades.start, end: length)
                clips[index + 1].crossfades = Crossfades(valid: length, end: .zero)
            }
            for index in clips.indices {
                let clip = clips[index]
                let room = clip.length - clip.crossfades.start.half - clip.crossfades.end.half
                clips[index].fades = Fades(
                    fadeIn: scale(source[index].fades.fadeIn), fadeOut: scale(source[index].fades.fadeOut))!
                    .fitted(to: max(.zero, room), keeping: .start)
            }
            scaled.lanes[lane].clips = clips
        }
        // Each word edge scales as a clip edge and stops at the end of the converted file.
        scaled.transcripts = transcripts.mapValues { transcript in
            var moved = transcript
            moved.words = Dictionary(
                uniqueKeysWithValues: transcript.words.map { file, anchors in
                    let length = scaled.files[file]?.length ?? .limit
                    let words = anchors.all.map { anchor in
                        let start = min(scale(anchor.range.lowerBound), length)
                        let end = max(start, min(scale(anchor.range.upperBound), length))
                        return Anchor(number: anchor.number, range: start..<end, text: anchor.text)
                    }
                    return (file, Anchors(words))
                })
            return moved
        }
        return scaled
    }
}
