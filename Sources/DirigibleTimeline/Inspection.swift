import DirigibleCore
import Foundation

/// The values of the clips that the selection touches (the clips of `Marks.touchedClips`), for
/// the inspector (run 11b-2).
public struct ClipInspection: Equatable, Sendable {
    /// One value for every clip, or `mixed` when two clips differ.
    public enum Shown<Value: Equatable & Sendable>: Equatable, Sendable {
        case value(Value)
        case mixed

        func merged(with value: Value) -> Shown { self == .value(value) ? self : .mixed }
    }

    /// In session order: the track order, then the clip order.
    public let clips: [ClipID]
    /// The clip name for one clip, else nil.
    public let name: String?
    public let gain: Shown<Gain>
    public let fadeIn: Shown<Frames>
    public let fadeOut: Shown<Frames>

    /// Nil with no selection or no clip in it. One pass over the clips of the selected tracks.
    public init?(selection: Selection, session: Session) {
        let touched =
            switch selection {
            case .range(let marks): marks.touchedClips(in: session)?.map { $0.lane[$0.index] } ?? []
            case .clips: selection.selectedClips(in: session).map(\.clip)
            }
        guard let first = touched.first else { return nil }
        var (gain, fadeIn, fadeOut) = (
            Shown.value(first.gain), Shown.value(first.fades.fadeIn), Shown.value(first.fades.fadeOut)
        )
        for clip in touched.dropFirst() {
            gain = gain.merged(with: clip.gain)
            fadeIn = fadeIn.merged(with: clip.fades.fadeIn)
            fadeOut = fadeOut.merged(with: clip.fades.fadeOut)
        }
        clips = touched.map(\.id)
        name = touched.count == 1 ? Self.name(of: first, in: session) : nil
        (self.gain, self.fadeIn, self.fadeOut) = (gain, fadeIn, fadeOut)
    }

    /// The name of a clip: the path of its file without ".wav" (the clip label of the lanes).
    public static func name(of clip: Clip, in session: Session) -> String {
        let path = session.files[clip.file]?.path ?? clip.file.rawValue
        return path.hasSuffix(".wav") ? String(path.dropLast(4)) : path
    }

    /// A typed gain: an optional sign (+, -, or U+2212), digits, and an optional "." or "," with
    /// digits, in each language (probe P2: a locale parse reads "-6,5" in English as -6). Nil
    /// for any other text.
    public static func decibels(_ text: String) -> Double? {
        let text = normalized(text)
        guard text.wholeMatch(of: /[+-]?[0-9]+([.,][0-9]+)?/) != nil else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: "."))
    }

    /// A typed fade in ms: an optional sign and digits only, so "1.500" is never 1.5 ms. Nil for
    /// any other text.
    public static func milliseconds(_ text: String) -> Double? {
        let text = normalized(text)
        guard text.wholeMatch(of: /[+-]?[0-9]+/) != nil else { return nil }
        return Double(text)
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{2212}", with: "-")
    }

    /// The gain `dB`, clamped to `Gain.levelLimit` and rounded to 0.1 dB (ties away from 0), for
    /// each clip of `clips` whose gain changes. A clip that is gone drops out. Nil with no change.
    public static func gains(_ dB: Double, for clips: [ClipID], in session: Session) -> [ClipID: Gain]? {
        let clamped = min(max(dB, -Gain.levelLimit), Gain.levelLimit)
        // Gain(dB:) is nil only for NaN, which no parse gives.
        guard let gain = Gain(dB: (clamped * 10).rounded() / 10) else { return nil }
        let ids = Set(clips)
        var result: [ClipID: Gain] = [:]
        for track in session.tracks {
            for clip in track.clips where ids.contains(clip.id) && clip.gain != gain { result[clip.id] = gain }
        }
        return result.isEmpty ? nil : result
    }

    /// The fade of `edge` at `ms` whole ms, for each clip of `clips` whose fades change. The value
    /// clamps in Double to 0...the clip length before the Int conversion, then stops at the room of
    /// the edge (the rule of the fade handle). A clip that is gone, or that has a crossfade at
    /// `edge`, drops out. Nil with no change.
    public static func fades(_ edge: Fades.Edge, ms: Double, for clips: [ClipID], in session: Session)
        -> [ClipID: Fades]?
    {
        let frames = (ms * Double(session.sampleRate) / 1000).rounded()
        let ids = Set(clips)
        var result: [ClipID: Fades] = [:]
        for track in session.tracks {
            for clip in track.clips where ids.contains(clip.id) {
                let value = Frames(Int(min(max(frames, 0), Double(clip.length.count))))
                if let new = clip.fades(setting: edge, to: value), new != clip.fades {
                    result[clip.id] = new
                }
            }
        }
        return result.isEmpty ? nil : result
    }
}
