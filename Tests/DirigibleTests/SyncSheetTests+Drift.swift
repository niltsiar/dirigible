import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Decision 0077 D12: the Correct drift box of the Sync Clip to Track sheet, on the package
/// of `syncWindowPackage`. Clip "K" on track Host plays the file that each test adds, at 15 s.
extension SyncSheetTests {
    static let takeLine = "A take records on the session clock."

    /// Adds the file `file` and clip "K" that plays all of it, 8 s long, after clip "C" on Host.
    static func addK(_ file: AudioFile, to session: inout Session) throws {
        try session.addFile(file)
        try session.place(
            Clip(id: "K", file: file.id, start: Frames(15 * 48_000), offset: 0, length: file.length), on: "t1")
    }

    static func capture(_ id: String) -> Capture {
        Capture(
            id: CaptureID(id), deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 0, sampleTime: 0,
            nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0)
    }

    /// The box is on when the sheet opens, with no line under it, and the sync uses the drift run.
    @Test func theDriftBoxIsOnWhenTheSheetOpens() async throws {
        let (model, studio, _) = try await open()
        model.timeline.selection = select("C")
        model.run(.syncClip)
        let draft = try #require(model.syncDraft, "the command opened no sheet")
        #expect(draft.correctsDrift, "the box is off at open")
        #expect(!draft.driftIsBlocked(in: studio.session))
        #expect(draft.driftLine(in: studio.session, text: englishText) == nil)
        #expect(draft.usesDrift(in: studio.session))
        await model.close()
    }

    /// A take file is on the session clock, so the box is off, disabled, and has the line. A box that
    /// a caller sets on still gives no drift run.
    @Test func theDriftBoxIsOffForATakeClip() async throws {
        let (model, studio, _) = try await open { session in
            try session.addCapture(Self.capture("tk"))
            try Self.addK(
                AudioFile(id: "tk", path: "tk.wav", layout: .mono, length: 384_000, capture: CaptureID("tk")),
                to: &session)
        }
        var draft = try #require(SyncDraft(clip: "K", in: studio.session))
        #expect(!draft.correctsDrift, "the box is on for a take")
        #expect(draft.driftIsBlocked(in: studio.session))
        #expect(draft.driftLine(in: studio.session, text: englishText) == Self.takeLine)
        draft.correctsDrift = true
        #expect(!draft.usesDrift(in: studio.session), "a take gets the drift run")
        await model.close()
    }

    /// A split half of a take has a capture and is no take file: the box is off as for a take.
    @Test func theDriftBoxIsOffForASplitHalfOfATake() async throws {
        let (model, studio, _) = try await open { session in
            try session.addCapture(Self.capture("tk"))
            try Self.addK(
                AudioFile(id: "half", path: "half.wav", layout: .mono, length: 384_000, capture: CaptureID("tk")),
                to: &session)
        }
        #expect(studio.session.files["half"]?.isTakeFile == false)
        let draft = try #require(SyncDraft(clip: "K", in: studio.session))
        #expect(!draft.correctsDrift && draft.driftIsBlocked(in: studio.session))
        #expect(draft.driftLine(in: studio.session, text: englishText) == Self.takeLine)
        await model.close()
    }

    /// Only a capture disables the box. A drift-corrected clip (the resample source is a plain file)
    /// and a rendered clip (the result gives the cause) keep it on.
    @Test func theDriftBoxIsOnForADriftCorrectedClip() async throws {
        let ratio = try #require(DriftRatio(1.0001))
        let link = DriftOrigin(source: "c", offset: 0, ratio: ratio, addedGain: .zero)
        let (model, studio, _) = try await open { session in
            try Self.addK(
                AudioFile(id: "c drift", path: "c drift.wav", layout: .mono, length: 383_000, drift: link),
                to: &session)
        }
        let corrected = try #require(SyncDraft(clip: "K", in: studio.session))
        #expect(corrected.correctsDrift && !corrected.driftIsBlocked(in: studio.session))
        #expect(corrected.driftLine(in: studio.session, text: englishText) == nil)
        await model.close()

        let render = RenderOrigin(source: "c", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        let (rendered, renderedStudio, _) = try await open { session in
            try Self.addK(
                AudioFile(id: "c noise", path: "c noise.wav", layout: .mono, length: 384_000, origin: render),
                to: &session)
        }
        let draft = try #require(SyncDraft(clip: "K", in: renderedStudio.session))
        #expect(draft.correctsDrift && !draft.driftIsBlocked(in: renderedStudio.session))
        await rendered.close()
    }

    /// The box picks the run. On, the sync is `Studio.correctDrift`: the 8 s clip is under 5 min, so it
    /// moves by the lag and the banner gives the cause. Off, it is the 0076 sync, and a plain move shows no banner.
    @Test func theBoxPicksTheRun() async throws {
        for on in [true, false] {
            let (model, studio, _) = try await open()
            var draft = try #require(SyncDraft(clip: "C", in: studio.session))
            draft.correctsDrift = on
            await model.sync(draft)
            #expect(studio.session.clip("C")?.clip.start == 960_000 && model.alert == nil, "box \(on)")
            guard on else {
                #expect(model.syncReport == nil, "box off: a plain move has a banner")
                await model.close()
                continue
            }
            guard case .syncMoved(let moved, _, _) = try #require(model.syncReport?.banner) else {
                Issue.record("box \(on): no result banner, alert \(String(describing: model.alert))")
                return
            }
            #expect(moved.outcome == .notCorrected(.clipTooShort), "box \(on): \(moved)")
            await model.close()
        }
    }
}
