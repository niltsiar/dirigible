import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Split Stereo to Mono in the session window (decision 0053).
@MainActor struct SplitStereoWindowTests {
    /// C7 and C20: each split error shows its key, a full disk the space text, a transcript that
    /// did not load the text that names it, and another session refusal the session text.
    @Test func eachSplitErrorShowsItsKey() {
        let cases: [(SplitError, String)] = [
            (.space(needed: 2, free: 1), L10n.errorSplitSpace.text),
            (.write(file: "Clips/f1 L.wav", errno: ENOSPC), L10n.errorSplitSpace.text),
            (.write(file: "Clips/f1 L.wav", errno: EIO), L10n.errorSplitWrite.format(Int(EIO))),
            (.sourceUnreadable(file: "f1.wav", errno: EIO), L10n.errorSplitUnreadable.format("f1.wav", Int(EIO))),
            (.sourceMissing(file: "f1.wav"), L10n.errorSplitMissing.format("f1.wav")),
            (.session(.transcriptNotLoaded([TranscriptID(1)])), L10n.errorTranscriptUnloaded.text),
            (.session(.notStereo("c1")), L10n.errorSessionOther.text),
        ]
        for (error, text) in cases {
            #expect(L10n.message(for: .split(error)) == text, "\(error)")
        }
        #expect(L10n.message(for: .splitYielded) == L10n.errorSplitYielded.text)
    }
}
