import DirigibleCore

extension Studio {
    public enum Transport: Hashable, Sendable {
        case idle
        case recording(take: Int)
        case finalizing(take: Int)
        /// A placement (decision 0021) converts and saves this segment.
        case placing(SegmentName)
        /// Cmd-L measures the clips and saves their gains (decision 0031).
        case leveling
        /// Tools > Duck Music Under Speech... and the `duck` tool read the speech and save the
        /// music envelopes (decision 0060).
        case ducking
        /// Level Over Time reads the clips and saves their ride layers (decision 0060).
        case riding
        /// Match Voice reads the reference clip and the target tracks and saves their matches
        /// (decision 0074).
        case matching
        /// Tools > Find Silences... reads the silences of the scan tracks (decision 0066).
        case findingSilences
        /// An import converts a file and saves the session (decision 0040).
        case importing(ImportRun)
    }
}
