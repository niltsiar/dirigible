// The stored export values (decision 0002): the session reader parses them, so they live here.
// The DSP extensions (`ExportRate.hertz(session:)`, `LoudnessTarget.integrated(for:)`) stay in
// DirigibleAudio.

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
}

/// A loudness target of decision 0008. A mono export is 3 LU lower than a stereo export.
public enum LoudnessTarget: String, CaseIterable, Hashable, Sendable {
    case podcast, speech, ebu, atsc
}
