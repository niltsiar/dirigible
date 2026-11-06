import DirigibleCore
import Foundation

extension SessionError {
    /// No `default` case: a new error case does not compile until it has a message.
    package var message: String {
        switch self {
        case .duplicateID(let id): "the ID \"\(id)\" is already used."
        case .unknownCapture(let id): "no capture \"\(id)\"."
        case .unknownFile(let id): "no file \"\(id)\"."
        case .unknownTrack(let id): "no track \"\(id)\"."
        case .unknownClip(let id): "no clip \"\(id)\"."
        case .unknownMarker(let id): "no marker \"\(id)\"."
        case .captureInUse(let id): "capture \"\(id)\" is used by a file."
        case .invalidCapture(let id):
            "capture \"\(id)\" has a sample time that is not finite or a rate that is not positive."
        case .fileInUse(let id): "file \"\(id)\" is used by a clip."
        case .fileIsSource(let id, let file): "file \"\(id)\" is the source of rendered file \"\(file)\"."
        case .invalidOrigin(let id): "file \"\(id)\" has an origin that names no matching source range."
        case .trackInRecording(let id): "track \"\(id)\" is armed in the recording."
        case .layoutMismatch(let track, .file(let file)):
            "file \"\(file)\" does not have the layout of track \"\(track)\"."
        case .layoutMismatch(let track, .route): "the route does not have the layout of track \"\(track)\"."
        case .layoutMismatch(let track, .trackHasClips): "track \"\(track)\" has clips, so its layout cannot change."
        case .invalidRoute: "the route has a channel number less than 1 or an empty app ID."
        case .invalidPath(let path): "the path \"\(path)\" is not inside Clips/."
        case .invalidText(let text): "the text \(String(reflecting: text)) has a control character."
        case .frameOutOfRange: "a frame is negative or more than 2^40."
        case .markerURLTooLong: Marker.urlTooLongText
        case .takeOutOfRange(let take): "take \(take) is not in 1...999999999."
        case .clipOutsideFile(let id): "clip \"\(id)\" is not inside its file."
        case .overlap(let clip, let other): "clip \"\(clip)\" overlaps clip \"\(other)\"."
        case .frameOutsideClip(let id, let frame): "frame \(frame) is not inside clip \"\(id)\"."
        case .pointOutsideClip(let id, let frame, let range):
            "frame \(frame) is not inside clip \"\(id)\", which plays the timeline frames "
                + "\(range.lowerBound)..<\(range.upperBound)."
        case .fadeOutsideClip(let id, let length):
            "the fades and crossfades of clip \"\(id)\" are longer than the clip (\(length) frames)."
        case .crossfadeOutsideFile(let id, let needed):
            "clip \"\(id)\" needs \(needed) frames of audio past its edge in its file for this crossfade."
        case .crossfadeWithoutJoin(let id): "no clip touches the crossfade edge of clip \"\(id)\"."
        case .crossfadeAtSeamlessJoin(let id):
            "session.xml is from an older version of Dirigible that cannot hold a crossfade between clip \"\(id)\" "
                + "and the next clip, which play one piece of audio. Remove crossfadeOut from that clip and crossfadeIn "
                + "from the next clip in session.xml."
        case .crossfadeAtEqualGains(let id):
            "clip \"\(id)\" and the next clip play one piece of audio at one gain at each frame, the envelope "
                + "included, with no fade at the join, so a crossfade there changes nothing."
        case .fadeAtCrossfade(let id):
            "clip \"\(id)\" has a crossfade at that edge, so it cannot also have a fade there."
        case .trackCount(let count): "the excerpt has \(count) tracks, so give \(count) different target tracks."
        case .laneOutOfRange(let id): "the lane offset moves clip \"\(id)\" past the first or the last track."
        case .otherSampleRate(let rate): "the excerpt is at \(rate) Hz, another rate than this session."
        case .foreignFile(let id): "file \"\(id)\" of the excerpt is another file in this session."
        case .unknownWord(let occurrence):
            "no word \(occurrence) on the timeline: it is not there now, or an edit changed it. Read the words again, "
                + "then cut."
        case .wordOutsideFile(let id): "a transcript word of file \"\(id)\" is not inside the file."
        case .nothingToCut: "the words have no audio to cut."
        case .noWordOnTrack(let id): "no word of the transcript is over a clip of track \"\(id)\"."
        case .noTakeAudio(let id, let take): "The track \(id) has no audio of take \(take) with a take time."
        case .transcriptNotLoaded(let ids):
            ids.count == 1
                ? "transcript \(ids[0]) did not load: its file is missing or damaged. Import the transcript again."
                : "transcripts \(ids.map(\.description).joined(separator: ", ")) did not load: their files are missing "
                    + "or damaged. Import the transcripts again."
        case .chapterOutOfRange(let place):
            "chapter \(place) starts at a frame that is negative or more than 2^40."
        case .chapterImageNotKept(let markers):
            "the import would drop the image of "
                + markers.map { "\"\($0.name)\" at \($0.position)" }.joined(separator: ", ")
                + ". The file has no chapter at the same time. Remove the chapter first, or add one at that time to "
                + "the file."
        case .nothingToHeal: "no join to heal."
        case .noSpeechTrack: "no speech track: give a track the dialogue role, or name the speech tracks."
        case .noDuckedTrack: "no track to duck: give a track the music role, or name the tracks to duck."
        case .trackInBothDuckLists(let id): "track \"\(id)\" is a speech track and a track to duck."
        case .noSpeech(let scope, let threshold, let unread):
            "no speech over \(String(format: "%.1f", threshold)) dBFS in the timeline frames "
                + "\(scope.lowerBound)..<\(scope.upperBound), so the duck changed nothing."
                + (unread.isEmpty
                    ? "" : " Speech files that did not read: \(unread.map(\.rawValue).joined(separator: ", ")).")
        case .duckRangePastEnd(let range, let end):
            "the range \(range.lowerBound)..<\(range.upperBound) starts at or after the session end at frame "
                + "\(end), so the duck changed nothing."
        case .notStereo(let id): "clip \"\(id)\" is on a mono track, so it has no two sides to split."
        case .fillTooManyClips(let needed):
            "the fill makes \(needed) clips, more than the limit of \(Session.fillClipLimit). Give a shorter range "
                + "or a longer clipboard."
        case .emptyExcerpt: "the excerpt has no frames: give a range or clips with audio."
        case .noJoin(let id): "no clip touches the end of clip \"\(id)\", so it has no join to roll."
        }
    }
}

extension SessionFileError {
    /// No `default` case: a new error case does not compile until it has a message.
    package func message(package: String, file name: String = "session.xml") -> String {
        let file = "\(package)/\(name)"
        return switch self {
        case .malformedXML: "\(file) is not a Dirigible session file."
        case .unsupportedVersion(let version):
            "\(file) was made by a newer version of Dirigible (session version \(version)). This build reads version "
                + "\(sessionVersion) or lower."
        case .invalidChannelCount(let count): "\(file) has a file with \(count) channels."
        case .missingAttribute(let element, let attribute):
            "\(file) has a \(element) element with no \(attribute) attribute."
        case .invalidValue(let element, let attribute):
            "\(file) has a \(element) element with a bad \(attribute) value."
        case .invalidSession(let error): "\(file) breaks a session rule: \(error.message)"
        case .readFailed(let code): "cannot read \(file): \(String(cString: strerror(code)))."
        case .writeFailed(let step, let code): "cannot write \(file) (\(step)): \(String(cString: strerror(code)))."
        case .wouldNotReadBack: "the new session would not read back, so \(file) did not change. This is a bug."
        case .locked: "\(package) is open in Dirigible."
        case .packageMoved:
            "\(package) moved to another volume or was deleted, so \(package)/session.xml did not change."
        case .exists: "\(package) exists."
        }
    }
}
