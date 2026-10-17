import DirigibleAudio

/// A state of a header row: the short text that the row shows, and the full sentence for the
/// help tag and the VoiceOver label. The full sentence does not fit a row of 340 pt.
struct HeaderStateText: Equatable {
    let row: String
    let full: String

    /// An app track that gets no sound: the app may not have the permission.
    static func noSound(_ app: String) -> Self {
        Self(row: L10n.trackStateNoSoundShort.format(app), full: L10n.trackStateNoSound.format(app))
    }

    /// A listened track that plays no monitor sound (decision 0044), or nil.
    static func quiet(state: LiveTrack.State?, quiet: Bool, loopback: Bool) -> Self? {
        listenQuietText(state: state, quiet: quiet, loopback: loopback).map {
            Self(row: L10n.trackListenQuietShort.text, full: $0)
        }
    }
}
