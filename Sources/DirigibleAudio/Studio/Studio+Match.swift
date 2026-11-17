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
    /// timeline frames, when given) and the clips of each target track of `tracks`, as the file and
    /// the clip gain, through `runReadJob` on `.matching`. Then it sets the match of each target
    /// track as one undo entry, with the name of the reference clip. A music or effects track and
    /// the track of the reference clip are left out. A new match takes `amount`, else the default;
    /// a replace takes `amount`, else the amount of the track, and its bypass is off. It returns the new
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
        let plan = try MatchPlan(reference: reference, range: range, tracks: tracks, in: session)
        return try await runReadJob(
            .matching, cancelled: .matchCancelled, agent: agent, progress: progress,
            read: { session, lock, progress, isCancelled in
                await readMatch(plan, of: session, lock: lock, progress: progress, isCancelled: isCancelled)
            },
            apply: { session, read throws(StudioError) in try plan.apply(read, amount: amount, to: session) })
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
package struct MatchRead: Sendable {
    let reference: BandSpectrum
    let targets: [(TrackID, BandSpectrum)]
}

extension VoicePart {
    /// The file frames `frames` of `clip`, with its clip gain.
    init(_ clip: Clip, _ frames: Range<Frames>) { self.init(file: clip.file, frames: frames, gain: clip.gain) }
}

/// What a Match Voice reads and where it stores: the checked inputs of `Studio.matchVoice` and of
/// the command and the tool on a closed package, so one rule gives one refusal for each input.
package struct MatchPlan: Sendable {
    let name: String
    let source: VoicePart
    let targets: [(TrackID, [VoicePart])]

    /// The checks of `Studio.matchVoice`, in its order after the busy check: the clip, the range
    /// (empty, or not inside the clip), the tracks, and a target left. The track of the reference
    /// clip is no target.
    package init(
        reference: ClipID, range: Range<Frames>?, tracks: Set<TrackID>, in session: Session
    ) throws(StudioError) {
        guard case (let clip, let home)? = session.clip(reference) else { throw .session(.unknownClip(reference)) }
        let span = range ?? clip.range
        guard !span.isEmpty, span.lowerBound >= clip.start, span.upperBound <= clip.end else {
            throw .rangeOutsideReference(clip: clip.range)
        }
        if let unknown = tracks.first(where: { session.track($0) == nil }) { throw .session(.unknownTrack(unknown)) }
        targets = Self.targets(of: tracks, home: home, in: session).map { track in
            (track.id, track.clips.map { VoicePart($0, $0.offset..<$0.offset + $0.length) })
        }
        guard !targets.isEmpty else { throw .noTargetTrack }
        source = VoicePart(
            clip, clip.offset + (span.lowerBound - clip.start)..<clip.offset + (span.upperBound - clip.start))
        name = session.name(of: clip)
    }

    /// The tracks of `tracks` that a match with the reference clip on track `home` reads and sets,
    /// in session order: not `home`, and no music or effects track.
    package static func targets(of tracks: Set<TrackID>, home: TrackID, in session: Session) -> [Track] {
        session.tracks.filter { tracks.contains($0.id) && $0.id != home && $0.role != .music && $0.role != .effects }
    }

    /// The reference spectrum, then the spectrum of each target, in the package at `package`. A
    /// side with under 10 s of voice ends the read with `.tooLittleVoice`. It reads the disk, so
    /// never call it on the main actor in the app.
    package func read(
        of session: Session, package: URL, progress: @escaping @Sendable (Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> Result<MatchRead, StudioError> {
        let length = { (part: VoicePart) in part.frames.upperBound.count - part.frames.lowerBound.count }
        let total = Double(
            max(1, length(source) + targets.reduce(0) { $0 + $1.1.reduce(0) { $0 + length($1) } }))
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
            let spectrum = try read([source])
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

    /// `session` with the match of each target set from `read`: `amount`, else the amount of the
    /// track, else the default, and the bypass off. It gives the new matches too.
    package func apply(
        _ read: MatchRead, amount: VoiceMatch.Amount?, to session: Session
    ) throws(StudioError) -> (Session, [TrackID: VoiceMatch]) {
        var matches: [TrackID: VoiceMatch] = [:]
        for (id, target) in read.targets {
            let old = session.track(id)?.match
            let curve = VoiceCurve.curve(reference: read.reference, target: target, sampleRate: session.sampleRate)
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
    }
}

/// `plan.read` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func readMatch(
    _ plan: MatchPlan, of session: Session, lock: PackageLock,
    progress: @escaping @Sendable (Double) -> Void, isCancelled: @escaping @Sendable () -> Bool
) async -> Result<MatchRead, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
    return plan.read(of: session, package: package, progress: progress, isCancelled: isCancelled)
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
