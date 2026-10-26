import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Reduce Noise in the session window (decision 0054).
@MainActor struct ReduceNoiseWindowTests {
    /// C10 and C14: each render error shows its key, a full disk the space text, a transcript that
    /// did not load the text that names it, and another session refusal the session text.
    @Test func eachRenderErrorShowsItsKey() {
        let cases: [(ClipRenderError, String)] = [
            (.space(needed: 2, free: 1), L10n.errorDenoiseSpace.text),
            (.write(file: "Clips/f1 NR.wav", errno: ENOSPC), L10n.errorDenoiseSpace.text),
            (.write(file: "Clips/f1 NR.wav", errno: EIO), L10n.errorDenoiseWrite.format(Int(EIO))),
            (.sourceUnreadable(file: "f1.wav", errno: EIO), L10n.errorDenoiseUnreadable.format("f1.wav", Int(EIO))),
            (.sourceMissing(file: "f1.wav"), L10n.errorDenoiseMissing.format("f1.wav")),
            (.notDownloaded(file: "f1.wav"), L10n.errorDenoiseNotDownloaded.format("f1.wav")),
            (.trackRole(clip: "c1", role: .music), L10n.errorDenoiseTrackRole.text),
            (.effectUnavailable(status: -3000), L10n.errorDenoiseUnavailable.format(-3000)),
            (.engine(status: -10868), L10n.errorDenoiseEngine.format(-10868)),
            (.session(.transcriptNotLoaded([TranscriptID(1)])), L10n.errorTranscriptUnloaded.text),
            (.session(.unknownClip("c1")), L10n.errorSessionOther.text),
        ]
        for (error, text) in cases {
            #expect(L10n.message(for: .clipRender(error)) == text, "\(error)")
        }
        #expect(L10n.message(for: .clipRenderYielded) == L10n.errorDenoiseYielded.text)
    }
}
