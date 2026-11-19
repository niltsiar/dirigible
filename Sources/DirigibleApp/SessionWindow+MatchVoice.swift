import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

/// The reference of a Match Voice, as the window keeps it: the clip, the file frames of the learn
/// (nil: the whole clip), and the clip name at the time of the choice. File frames keep the
/// selected audio when an edit moves or slips the clip.
struct VoiceReference: Equatable {
    struct Span: Equatable {
        let file: FileID
        let frames: Range<Frames>
    }

    let clip: ClipID
    let span: Span?
    let name: String

    /// The reference that `selection` gives: a clip set of one clip, or a range on one track that
    /// lies inside one clip. A clip set of two clips, a range over a clip edge, over two tracks,
    /// and in a gap give nil.
    init?(_ selection: Selection, in session: Session) {
        switch selection {
        case .clips:
            let clips = selection.selectedClips(in: session)
            guard clips.count == 1, let clip = clips.first?.clip else { return nil }
            self.init(clip: clip.id, span: nil, name: session.name(of: clip))
        case .range(let marks):
            guard let held = marks.selection(in: session), held.tracks.count == 1,
                let clip = session.track(held.tracks[0])?.clips.first(where: {
                    $0.start <= held.range.lowerBound && held.range.upperBound <= $0.end
                })
            else { return nil }
            let first = clip.offset + (held.range.lowerBound - clip.start)
            let end = clip.offset + (held.range.upperBound - clip.start)
            self.init(clip: clip.id, span: Span(file: clip.file, frames: first..<end), name: session.name(of: clip))
        }
    }

    init(clip: ClipID, span: Span?, name: String) { (self.clip, self.span, self.name) = (clip, span, name) }

    /// The timeline frames of the learn in `session`: the clip range for the whole clip. Nil when
    /// the clip is gone, or no longer holds each frame of the span (a trim, a cut, a new file).
    func range(in session: Session) -> Range<Frames>? {
        guard let clip = session.clip(clip)?.clip else { return nil }
        guard let span else { return clip.range }
        guard clip.file == span.file, clip.offset <= span.frames.lowerBound,
            span.frames.upperBound <= clip.offset + clip.length
        else { return nil }
        return clip.start + (span.frames.lowerBound - clip.offset)..<clip.start + (span.frames.upperBound - clip.offset)
    }
}

/// What a Match Voice gave, for its banner: the tracks, and the largest boost and cut of their
/// curves at their amounts, to 0.1 dB.
struct VoiceMatchResult: Equatable {
    let tracks: Int
    let boost: Double
    let cut: Double
}

extension L10n {
    /// "+4.2 dB", or "0.0 dB". `text` gives the value of a key, so a test can read a table.
    static func matchDecibels(
        _ dB: Double, locale: Locale = .current, text: (L10n) -> String = { $0.text }
    ) -> String {
        String(format: text(.trackVolumeValue), ReadoutLayer.decibels(dB, locale: locale))
    }

    static func matchResult(_ result: VoiceMatchResult, text: (L10n) -> String = { $0.text }) -> String {
        String(
            format: text(.matchResult), locale: .current, result.tracks, matchDecibels(result.boost, text: text),
            matchDecibels(result.cut, text: text))
    }
}

/// Track > Match Voice and the same submenu of the track header menu (decision 0074).
extension SessionWindow {
    /// The reference of the last Use as Voice Reference, while its clip still holds the chosen audio.
    var activeVoiceReference: VoiceReference? {
        guard let voiceReference, let session = studio?.session, voiceReference.range(in: session) != nil else {
            return nil
        }
        return voiceReference
    }

    var canUseAsVoiceReference: Bool {
        importJob == nil && !dialogShowing
            && idleStudio.flatMap { VoiceReference(timeline.selection, in: $0.session) } != nil
    }

    /// Match Voice to the reference needs a reference, a target track of `MatchPlan.targets`, and a
    /// window that takes edits.
    func canMatchVoice(tracks: [TrackID]) -> Bool {
        guard importJob == nil, !dialogShowing, let studio = idleStudio, let reference = activeVoiceReference,
            let home = studio.session.clip(reference.clip)?.track
        else { return false }
        return !MatchPlan.targets(of: Set(tracks), home: home, in: studio.session).isEmpty
    }

    /// Bypass and Remove need an idle studio and a track with a match.
    func canChangeMatch(tracks: [TrackID]) -> Bool {
        idleStudio.map { studio in tracks.contains { studio.session.track($0)?.match != nil } } == true
    }

    /// Keeps the clip, or the range inside one clip, of the selection as the reference of the
    /// next match. A selection that gives none beeps.
    func useAsVoiceReference() {
        guard importJob == nil, !dialogShowing, let studio = idleStudio else { return }
        guard let reference = VoiceReference(timeline.selection, in: studio.session) else { return beep() }
        voiceReference = reference
    }

    /// Matches `tracks` to the reference as one undo step, with a banner for the result or the
    /// refusal. The banner Cancel changes nothing, and VoiceOver says the cancel text.
    func matchVoice(tracks: [TrackID]) async {
        guard canMatchVoice(tracks: tracks), let studio = idleStudio, let reference = voiceReference,
            let range = reference.range(in: studio.session), let home = studio.session.clip(reference.clip)?.track
        else { return }
        voiceMatchReport = nil
        commitDrafts()
        matchingTracks = Set(MatchPlan.targets(of: Set(tracks), home: home, in: studio.session).map(\.id))
        matchProgress = 0
        defer { (matchingTracks, matchProgress) = ([], nil) }
        do throws(StudioError) {
            let matches = try await studio.matchVoice(
                reference: reference.clip, range: range, tracks: Set(tracks), agent: nil
            ) { [weak self] fraction in self?.matchProgress = fraction }
            let extremes = matches.values.map { $0.extremes(at: $0.amount) }
            matchPresses += 1
            let result = VoiceMatchResult(
                tracks: matches.count, boost: extremes.map(\.boost).max() ?? 0, cut: extremes.map(\.cut).min() ?? 0)
            voiceMatchReport = ToolBannerShown(
                banner: .voiceMatched(result, press: matchPresses), revision: studio.sessionRevision)
        } catch {
            switch error {
            case .matchCancelled: chrome?.announce(L10n.matchCanceled.text, .medium)
            case .tooLittleVoice, .noTargetTrack, .rangeOutsideReference, .matchRead, .matchFault:
                matchPresses += 1
                voiceMatchReport = ToolBannerShown(
                    banner: .voiceMatchRefused(L10n.message(for: error, session: studio.session), press: matchPresses),
                    revision: studio.sessionRevision)
            default: alert = .error(error)
            }
        }
    }

    /// One edit for the tracks that have a match: a track with no match stays as it is.
    func setMatchBypassed(_ on: Bool, tracks: [TrackID]) {
        let held = tracks.filter { studio?.session.track($0)?.match != nil }
        guard !held.isEmpty else { return }
        edit(ripple: false) { session throws(SessionError) in try session.setMatchBypassed(on, tracks: held) }
    }

    func removeMatch(tracks: [TrackID]) {
        edit(ripple: false) { session throws(SessionError) in try session.removeMatch(tracks: tracks) }
    }

    /// A slider drag step: the Player plays `percent` with no edit and no autosave. During a take
    /// or with no play it does nothing.
    func previewMatchAmount(_ percent: Int, track: TrackID) {
        guard let amount = VoiceMatch.Amount(percent) else { return }
        try? studio?.previewMatchAmount(amount, track: track)
    }

    /// The slider mouse-up: one edit with `percent`, then the end of the preview, so a later edit
    /// or an undo plays the session amount. Returns true for an edit.
    @discardableResult func commitMatchAmount(_ percent: Int, track: TrackID) -> Bool {
        defer { studio?.endPreview() }
        guard let studio, let amount = VoiceMatch.Amount(percent),
            studio.session.track(track)?.match.map({ $0.amount != amount }) == true
        else { return false }
        return edit(ripple: false) { session throws(SessionError) in
            try session.setMatchAmount(amount, tracks: [track])
        } != nil
    }

    /// The reset of a double-click on the slider whose first click made the edit of session
    /// revision `revision`: the reset joins that edit. After another edit, it is an edit of its own.
    func resetMatchAmount(_ track: TrackID, joining revision: Int) {
        let amount = VoiceMatch.defaultAmount
        guard let studio = idleStudio, studio.sessionRevision == revision else {
            edit(ripple: false) { session throws(SessionError) in try session.setMatchAmount(amount, tracks: [track]) }
            return
        }
        do throws(StudioError) {
            try studio.amend { session throws(SessionError) in try session.setMatchAmount(amount, tracks: [track]) }
        } catch {
            alert = .error(error)
        }
    }
}
