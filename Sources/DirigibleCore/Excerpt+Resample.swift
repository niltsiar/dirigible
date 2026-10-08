import Foundation

extension Excerpt {
    /// The excerpt at `rate`, for a paste from a package of another rate (decision 0042). `lengths`
    /// gives the frame count of each converted file, by source file ID, and `gains` the gain that
    /// the conversion adds to a file (A11). Each edge b maps to round(b x rate / sampleRate): the
    /// start, the end, and the offset of each clip, and the excerpt length. A length is the scaled
    /// end minus the scaled start, so two touching clips still touch, and it stops at the end of
    /// the converted file. A fade rounds and then fits the length (0035). A crossfade rounds to an
    /// even count; both clips of a join have one value, so they keep one value, and it gets smaller
    /// only when the media handles of the converted file are too short (0036).
    public func resampled(to rate: Int, lengths: [FileID: Frames], gains: [FileID: Gain] = [:]) -> Excerpt {
        let old = sampleRate
        func scale(_ frames: Frames) -> Frames { Frames((2 * frames.count * rate + old) / (2 * old)) }
        func even(_ frames: Frames) -> Frames {
            let half = (frames.count * rate + old) / (2 * old)
            return Frames(2 * half)
        }
        var scaled = Excerpt(
            kind: kind, length: scale(length), lanes: lanes, sampleRate: rate,
            pool: files.mapValues { file in
                var file = file
                file.length = lengths[file.id] ?? scale(file.length)
                return file
            })
        for lane in scaled.lanes.indices {
            for index in scaled.lanes[lane].clips.indices {
                let clip = scaled.lanes[lane].clips[index]
                let fileLength = scaled.files[clip.file]?.length ?? scale(clip.offset + clip.length)
                let start = scale(clip.start)
                let offset = min(scale(clip.offset), fileLength)
                let length = min(scale(clip.end) - start, fileLength - offset)
                var crossfadeStart = even(clip.crossfades.start)
                var crossfadeEnd = even(clip.crossfades.end)
                crossfadeStart = min(crossfadeStart, Frames(2 * offset.count))
                crossfadeEnd = min(crossfadeEnd, Frames(2 * (fileLength - offset - length).count))
                var result = clip
                result.start = start
                result.offset = offset
                result.length = length
                result.fades = Fades(fadeIn: scale(clip.fades.fadeIn), fadeOut: scale(clip.fades.fadeOut))!
                    .fitted(to: length, keeping: .start)
                result.crossfades = Crossfades(valid: crossfadeStart, end: crossfadeEnd)
                if let gain = gains[clip.file], let sum = Gain(dB: clip.gain.dB + gain.dB) { result.gain = sum }
                scaled.lanes[lane].clips[index] = result
            }
        }
        return scaled
    }
}
