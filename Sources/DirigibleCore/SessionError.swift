public enum SessionError: Error, Hashable, Sendable {
    /// The part of a track whose layout does not match.
    public enum LayoutConflict: Hashable, Sendable {
        case file(FileID)
        case route
        case trackHasClips
    }

    case duplicateID(String)
    case unknownCapture(CaptureID)
    case unknownFile(FileID)
    case unknownTrack(TrackID)
    case unknownClip(ClipID)
    case unknownMarker(MarkerID)
    case captureInUse(CaptureID)
    case invalidCapture(CaptureID)
    case fileInUse(FileID)
    /// The first file is the source of the origin of the second file (decision 0057).
    case fileIsSource(FileID, of: FileID)
    /// The origin of the file names no other file of the pool with its layout, or a range past it.
    case invalidOrigin(FileID)
    case trackInRecording(TrackID)
    case layoutMismatch(TrackID, LayoutConflict)
    /// A device channel less than 1, or an empty app ID.
    case invalidRoute
    case invalidPath(String)
    case invalidText(String)
    case frameOutOfRange
    /// The marker URL is over `Marker.maximumURLBytes` UTF-8 bytes.
    case markerURLTooLong
    /// A take number that is not a stem part of decision 0012 (1 to 9 digits).
    case takeOutOfRange(Int)
    case clipOutsideFile(ClipID)
    case overlap(ClipID, ClipID)
    case frameOutsideClip(ClipID, Frames)
    /// A gain point at this timeline frame is outside the clip window, which this case holds
    /// (decision 0060).
    case pointOutsideClip(ClipID, Frames, Range<Frames>)
    /// The fades and the crossfade halves of the clip are more than its length, which this case
    /// holds (decisions 0035 and 0036).
    case fadeOutsideClip(ClipID, length: Frames)
    /// The file of the clip has fewer than `needed` frames past the clip edge for half the
    /// crossfade there (decision 0036).
    case crossfadeOutsideFile(ClipID, needed: Frames)
    /// No clip touches the crossfade edge of the clip with the same crossfade length (decision 0036).
    case crossfadeWithoutJoin(ClipID)
    /// A file of version 8 or lower has a crossfade at the end of this clip, and the clip after it
    /// plays on from the same file frame: these versions refused such a crossfade (decision 0036).
    case crossfadeAtSeamlessJoin(ClipID)
    /// A new crossfade at the end of this clip, where the clip after it plays on from the same file
    /// frame at the same gain, with no fade at the join: it changes no sample (decision 0036).
    case crossfadeAtEqualGains(ClipID)
    /// The clip has a fade and a crossfade at one edge (decision 0036).
    case fadeAtCrossfade(ClipID)
    /// A paste names a track count that is not the lane count of its excerpt, which this case holds.
    case trackCount(Int)
    /// A nudge with a lane offset puts this clip past the first or the last track (decision 0038).
    case laneOutOfRange(ClipID)
    /// A paste names a file whose record differs from the record of this ID in the session: the
    /// excerpt comes from another pool (decision 0042).
    case foreignFile(FileID)
    /// A paste of an excerpt at this sample rate into a session at another rate: the excerpt needs
    /// `Excerpt.resampled` first (decision 0042).
    case otherSampleRate(Int)
    /// A cut names a word that is not on the timeline now, or whose anchor starts at another file
    /// frame (decision 0055).
    case unknownWord(WordOccurrence)
    /// An import found no word over a clip of the track (decision 0055).
    case noWordOnTrack(TrackID)
    /// A take-time import found no clip of the track with a file of this take (decision 0061).
    case noTakeAudio(TrackID, Int)
    /// A word of this file starts before 0 or ends past the file length (decision 0055).
    case wordOutsideFile(FileID)
    /// A cut names only words with no audio (decision 0055).
    case nothingToCut
    /// The files of these transcripts did not load, so a cut could join words across hidden ones
    /// (decision 0055).
    case transcriptNotLoaded([TranscriptID])
    /// The frame of chapter `place` (from 1) of a chapters import is negative or more than
    /// `Frames.limit`.
    case chapterOutOfRange(place: Int)
    /// A chapters import with `replacing` would drop the image of each of these chapters: the file
    /// has no chapter at the time of each.
    case chapterImageNotKept([Marker])
    /// A heal found no join of two clips that play on in one file at one gain at each frame, the
    /// envelope included, with no fade at the join.
    case nothingToHeal
    /// A ripple would move a clip of a follow track onto the next clip before it (decision 0073):
    /// the moved clip, then the clip under it.
    case followOverlap(ClipID, ClipID)
    /// Each track of a ripple follows, and the edit names none, so no lane would be cut (decision 0073).
    case noRippleTrack
    /// A duck has no speech track: no track has the dialogue role, and the caller named none
    /// (decision 0060).
    case noSpeechTrack
    /// A duck has no track to duck: no track has the music role, and the caller named none.
    case noDuckedTrack
    /// A duck names this track as a speech track and as a track to duck.
    case trackInBothDuckLists(TrackID)
    /// A duck found no speech over the threshold in dBFS in the scope, in timeline frames. `unread`
    /// names the speech files that did not read. It changes nothing.
    case noSpeech(Range<Frames>, threshold: Double, unread: [FileID] = [])
    /// A duck range starts at or after the session end, so it holds no frame to read (decision
    /// 0060). It changes nothing.
    case duckRangePastEnd(Range<Frames>, end: Frames)
    /// A split names a clip on a mono track (decision 0053). It changes nothing.
    case notStereo(ClipID)
    /// A fill would make `needed` new clips, more than `Session.fillClipLimit` (decision 0053). It
    /// changes nothing.
    case fillTooManyClips(needed: Int)
    /// A fill of an excerpt with no frames (decision 0053). It changes nothing.
    case emptyExcerpt
    /// A roll names a clip with no clip that touches its end, so it has no join to move. It
    /// changes nothing.
    case noJoin(ClipID)
}
