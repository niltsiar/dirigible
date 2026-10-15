import DirigibleCore
import Foundation

public struct ExportOptions: Hashable, Sendable {
    public var format: ExportFormat
    public var layout: ChannelLayout
    public var rate: ExportRate
    /// Nil: no gain and no limiter.
    public var loudness: LoudnessTarget?
    /// The title of the chapter that an M4A export adds at the range start when the episode has no
    /// title and no show name. Only `DirigibleApp` reads `L10n` (decision 0010), so the app gives
    /// its text here; the CLI and MCP keep the English default.
    public var introTitle: String

    public init(
        format: ExportFormat, layout: ChannelLayout, rate: ExportRate, loudness: LoudnessTarget? = nil,
        introTitle: String = "Intro"
    ) {
        self.format = format
        self.layout = layout
        self.rate = rate
        self.loudness = loudness
        self.introTitle = introTitle
    }

    /// The output of `dirigible render`: 32-bit float stereo CAF at the session rate.
    public static let render = ExportOptions(format: .floatCAF, layout: .stereo, rate: .session)
}

public struct ExportResult: Hashable, Sendable {
    /// The faults of the files that the source read.
    public let faults: [FileID: MediaFault]
    /// Nil for an export with no loudness target.
    public let loudness: LoudnessReport?
    /// The chapters of the range that the file does not have, because each starts at the time of
    /// the chapter before it, or an M4A chapter starts at or after the end of the audio. Empty for
    /// a format with no chapters.
    public let droppedChapters: [Marker]
    /// The M4A has chapters with an image and chapters with none, and the episode has no artwork, so
    /// the file has no chapter images.
    public let chapterImagesOmitted: Bool
}

public enum ExportError: Error, Hashable, Sendable {
    /// An item is at the target. It did not change.
    case exists
    /// An item is at this path, the name of a chapter image beside a chapters file. Nothing was
    /// written.
    case chapterImageExists(String)
    /// AAC at a file rate above 48 kHz (probe P5), or MP3 at a file rate other than 32, 44.1, or
    /// 48 kHz (decision 0034). No file was made.
    case rateNotSupported(Int)
    /// A create, format, write, or close of the file gave this status.
    case writeFailed(OSStatus)
    /// The move to the target gave this errno.
    case moveFailed(Int32)
    /// A write gave -40 with errno ENOSPC (probe P8).
    case diskFull
    /// An audio file did not open because the process had no free descriptor (this errno).
    case openFailed(Int32)
    /// The package source threw: the lock lost the package.
    case packageUnavailable
    /// The artwork file of the episode (this path in the package) is not in the package, it is
    /// not downloaded (decision 0045), or a PNG of an M4A export does not decode. No file was made.
    case artworkMissing(String)
    /// The image file of this chapter is not in the package, it is not downloaded, or a PNG of an
    /// M4A export does not decode. `rate` is the session rate of its position. No file was made.
    case chapterImageMissing(Marker, rate: Int)
    /// The cancel check was true at a chunk.
    case cancelled
    /// The range of an MP3 export has this count of chapters, over `maximumChapters`. No file was
    /// made.
    case tooManyChapters(Int)
    /// The ID3 tag of an MP3 export is over `maximumTagSize` bytes. No file was made.
    case tagTooLarge
    /// The range of an MP3 export with chapters is over `maximumChapterMilliseconds`, the last
    /// time of an ID3 chapter. No file was made.
    case chaptersTooLong
}

extension ExportError {
    /// The error of a failed atomic write of a small file. Foundation gives the POSIX errno under
    /// the CocoaError (probe-errno of run 2026-10-09-chapters-export). ENOSPC is a full disk.
    /// Another errno came from the temporary file or the rename, so it is `.moveFailed`. An error
    /// with no POSIX cause gives EIO. No errno goes into `.writeFailed`, which holds an OSStatus.
    init(writing error: any Error) {
        guard let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
            cause.domain == NSPOSIXErrorDomain
        else {
            self = .moveFailed(EIO)
            return
        }
        self = cause.code == Int(ENOSPC) ? .diskFull : .moveFailed(Int32(cause.code))
    }
}

public enum BitDepth: Int, Hashable, Sendable, CaseIterable {
    case bits16 = 16
    case bits24 = 24
}

/// The bit rates in kbit/s of a lossy export. AAC takes each for mono and stereo at 44.1 and
/// 48 kHz (probe P5); MP3 at 32, 44.1, and 48 kHz (decision 0034).
public enum BitRate: Int, Hashable, Sendable, CaseIterable {
    case k64 = 64
    case k96 = 96
    case k128 = 128
    case k160 = 160
    case k192 = 192
    case k256 = 256
}

/// A bit depth goes only with WAV or FLAC, a bit rate only with AAC or MP3. `.floatCAF` is the
/// 32-bit float CAF of `dirigible render`; the app does not offer it (decision 0019). MP3 goes
/// through LAME (decision 0034).
public enum ExportFormat: Hashable, Sendable {
    case wav(BitDepth)
    case flac(BitDepth)
    case aac(BitRate)
    case mp3(BitRate)
    case floatCAF
}

public enum ExportRate: Hashable, Sendable, CaseIterable {
    case session, hz44100, hz48000

    /// The file rate in Hz for a session at `sessionRate`.
    func hertz(session sessionRate: Int) -> Int {
        switch self {
        case .session: sessionRate
        case .hz44100: 44_100
        case .hz48000: 48_000
        }
    }
}

/// A loudness target of decision 0008. A mono export is 3 LU lower than a stereo export.
public enum LoudnessTarget: String, CaseIterable, Hashable, Sendable {
    case podcast, speech, ebu, atsc

    public func integrated(for layout: ChannelLayout) -> LUFS {
        let stereo: Double =
            switch self {
            case .podcast: -16
            case .speech: -18
            case .ebu: -23
            case .atsc: -24
            }
        return LUFS(value: layout == .stereo ? stereo : stereo - 3)
    }
}

/// A range with at least one frame inside `0...Frames.limit`, and nil (every track) or a set
/// with at least one track.
public struct ExportSource: Hashable, Sendable {
    public let range: Range<Frames>
    public let tracks: Set<TrackID>?

    public init?(range: Range<Frames>, tracks: Set<TrackID>? = nil) {
        guard range.lowerBound >= .zero, range.upperBound <= .limit, !range.isEmpty, tracks?.isEmpty != true else {
            return nil
        }
        self.range = range
        self.tracks = tracks
    }
}

/// The loudness of an export with a target (decision 0032). The output values are those of the
/// written file as macOS decodes it, for an AAC or MP3 file; else those of the limited signal at
/// the session rate.
public struct LoudnessReport: Hashable, Sendable {
    public let target: LUFS
    /// The mix before the gain. Nil when no block passes the gates: then the gain is 0 dB.
    public let measured: LUFS?
    /// The gain that the file got. It is `target - measured` plus the limiter loss that the search
    /// made up, with no limit.
    public let gain: Gain
    /// The loudness of the file after the gain, the limiter, and the encoder.
    public let output: LUFS?
    /// The true peak of the file in dBTP. Nil only for digital silence: a 16-bit export has
    /// dither, so it is never silent.
    public let truePeak: Double?

    /// The gain is over the ±20 dB limit of auto-level (decision 0008). The export does not
    /// limit it (0032), so the window shows it as a warning.
    public var exceedsLevelLimit: Bool { abs(gain.dB) > Gain.levelLimit }
}
