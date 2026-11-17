import DirigibleCore
import Foundation

/// The side of a Match Voice that has too little voice (decision 0074).
public enum MatchSide: Hashable, Sendable {
    case reference
    case track(TrackID)
}

extension Studio {
    /// The least gated voice of the reference and of each target track (decision 0074 D5).
    public nonisolated static let matchVoiceSeconds = 10

    /// Match Voice (decision 0074 D5): reads the reference clip `reference` (only `range`, in
    /// timeline frames, when given) and the clips of each track of `tracks` other than the
    /// reference, as the file and the clip gain, through `runReadJob` on `.matching`. Then it sets
    /// the match of each target track as one undo entry, with the name of the reference clip. A
    /// music or effects track is left out. A new match takes `amount`, else the default; a replace
    /// takes `amount`, else the amount of the track, and its bypass is off. It returns the new
    /// matches. An unknown clip or track throws before a read; no target throws `.noTargetTrack`;
    /// a range that is empty or not inside the clip throws `.rangeOutsideReference`; under 10 s of
    /// voice throws `.tooLittleVoice` for the first short side; a cancel `.matchCancelled`. Each
    /// throw changes nothing.
    @discardableResult
    public func matchVoice(
        reference: ClipID, range: Range<Frames>? = nil, tracks: Set<TrackID>, amount: VoiceMatch.Amount? = nil,
        agent: AgentName?, progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> [TrackID: VoiceMatch] {
        try checkIdle()
        guard let clip = session.clip(reference)?.clip else { throw .session(.unknownClip(reference)) }
        let span = range ?? clip.range
        guard !span.isEmpty, span.lowerBound >= clip.start, span.upperBound <= clip.end else {
            throw .rangeOutsideReference(clip: clip.range)
        }
        if let unknown = tracks.first(where: { session.track($0) == nil }) { throw .session(.unknownTrack(unknown)) }
        let targets = session.tracks.filter { tracks.contains($0.id) && $0.role != .music && $0.role != .effects }.map {
            track in
            (
                track.id,
                track.clips.filter { $0.id != reference }.map { VoicePart($0, $0.offset..<$0.offset + $0.length) }
            )
        }
        guard !targets.isEmpty else { throw .noTargetTrack }
        let source = VoicePart(
            clip, clip.offset + (span.lowerBound - clip.start)..<clip.offset + (span.upperBound - clip.start))
        let name = session.name(of: clip)
        return try await runReadJob(
            .matching, cancelled: .matchCancelled, agent: agent, progress: progress,
            read: { session, lock, progress, isCancelled in
                await readMatch(source, targets, of: session, lock: lock, progress: progress, isCancelled: isCancelled)
            },
            apply: { session, read throws(StudioError) in
                var matches: [TrackID: VoiceMatch] = [:]
                for (id, target) in read.targets {
                    let old = session.track(id)?.match
                    let curve = VoiceCurve.curve(
                        reference: read.reference, target: target, sampleRate: session.sampleRate)
                    do throws(VoiceMatch.Field) {
                        matches[id] = try VoiceMatch(
                            amount: amount ?? old?.amount ?? VoiceMatch.defaultAmount, reference: name,
                            curve: curve.decibels, targetPowers: target.powers)
                    } catch {
                        throw .session(.invalidText(name))
                    }
                }
                var matched = session
                do throws(SessionError) { try matched.setMatch(matches) } catch { throw .session(error) }
                return (matched, matches)
            })
    }

    /// Sets the amount of the match of each of `tracks` as one undo entry, with no audio read. A
    /// track with no match throws `noMatch` and changes nothing.
    public func setMatchAmount(_ amount: VoiceMatch.Amount, tracks: [TrackID], agent: AgentName?)
        throws(StudioError)
    {
        try edit(ripple: false, agent: agent) { session throws(SessionError) in
            try session.setMatchAmount(amount, tracks: tracks)
        }
    }

    /// Turns the bypass of the match of each of `tracks` on or off as one undo entry. A track with
    /// no match throws `noMatch` and changes nothing.
    public func setMatchBypassed(_ on: Bool, tracks: [TrackID], agent: AgentName?) throws(StudioError) {
        try edit(ripple: false, agent: agent) { session throws(SessionError) in
            try session.setMatchBypassed(on, tracks: tracks)
        }
    }

    /// Removes the match of each of `tracks` as one undo entry. A remove that changes nothing
    /// records no entry.
    public func removeMatch(tracks: [TrackID], agent: AgentName?) throws(StudioError) {
        try edit(ripple: false, agent: agent) { session throws(SessionError) in
            try session.removeMatch(tracks: tracks)
        }
    }

    /// Plays `amount` on the match of `track` during play, with no edit and no autosave: the drag
    /// of the match slider. The mouse-up makes the one edit, then `endPreview` ends the preview.
    /// Stopped, it sends nothing. A track with no match throws `noMatch`.
    public func previewMatchAmount(_ amount: VoiceMatch.Amount, track: TrackID) throws(StudioError) {
        try checkIdle()
        var checked = session
        do { try checked.setMatchAmount(amount, tracks: [track]) } catch { throw .session(error) }
        guard play.playback != .stopped else { return }
        play.matchPreview = (track, amount)
        sendSession()
    }
}

/// The spectra of one Match Voice read.
struct MatchRead: Sendable {
    let reference: BandSpectrum
    let targets: [(TrackID, BandSpectrum)]
}

extension VoicePart {
    /// The file frames `frames` of `clip`, with its clip gain.
    init(_ clip: Clip, _ frames: Range<Frames>) { self.init(file: clip.file, frames: frames, gain: clip.gain) }
}

/// The reference spectrum, then the spectrum of each target, off the main actor in the package
/// that `lock` holds now. A side with under 10 s of voice ends the read with `.tooLittleVoice`.
@concurrent nonisolated func readMatch(
    _ reference: VoicePart, _ targets: [(TrackID, [VoicePart])], of session: Session, lock: PackageLock,
    progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool
) async -> Result<MatchRead, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
    let length = { (part: VoicePart) in part.frames.upperBound.count - part.frames.lowerBound.count }
    let total = Double(max(1, length(reference) + targets.reduce(0) { $0 + $1.1.reduce(0) { $0 + length($1) } }))
    var done = 0
    let enough = { (spectrum: BandSpectrum, side: MatchSide) -> StudioError? in
        let needed = Studio.matchVoiceSeconds * session.sampleRate
        return spectrum.voiceFrames >= needed
            ? nil : .tooLittleVoice(side: side, seconds: spectrum.voiceFrames / session.sampleRate)
    }
    do throws(MatchReadError) {
        let read = { (parts: [VoicePart]) throws(MatchReadError) -> BandSpectrum in
            let before = done
            let spectrum = try voiceSpectrum(
                parts, in: session, package: package, progress: { progress(Double(before + $0) / total) },
                isCancelled: isCancelled)
            done += parts.reduce(0) { $0 + length($1) }
            return spectrum
        }
        let spectrum = try read([reference])
        if let refused = enough(spectrum, .reference) { return .failure(refused) }
        var spectra: [(TrackID, BandSpectrum)] = []
        for (id, parts) in targets {
            let target = try read(parts)
            if let refused = enough(target, .track(id)) { return .failure(refused) }
            spectra.append((id, target))
        }
        return .success(MatchRead(reference: spectrum, targets: spectra))
    } catch {
        return .failure(StudioError(error))
    }
}

extension StudioError {
    /// The error of a voice match read that stopped.
    package init(_ error: MatchReadError) {
        switch error {
        case .cancelled: self = .matchCancelled
        case .fault(let file, let fault): self = .matchFault(file, fault)
        case .descriptor(let code): self = .matchRead(code)
        }
    }
}
