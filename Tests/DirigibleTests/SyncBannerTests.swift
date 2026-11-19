import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criteria C20 and C21 of decision 0076: the result banner and the no-match banner of Tools > Sync Clip
/// to Track..., on the package of `syncWindowPackage`.
@Suite(.serialized) @MainActor struct SyncBannerTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    static let english = Result { try stringsTable("en") }
    static let us = Locale(identifier: "en_US")

    init() throws { folder = try TemporaryFolder() }

    func englishText(_ key: L10n) -> String { (try? Self.english.get())?[key.rawValue] ?? key.rawValue }

    func open(clipStart: Int = 5, unrelated: Bool = false) async throws -> (SessionWindow, Studio) {
        let url = try await syncWindowPackage(in: folder.url, clipStart: clipStart, unrelated: unrelated)
        let (model, studio, _, _) = try await openLanes(app, url)
        return (model, studio)
    }

    func moved(
        lag: Int, peak: Double = 0.98, drift: SyncDrift = .spread(0), headCut: Int = 0, replaced: [String] = []
    ) -> SyncMoved {
        SyncMoved(
            lag: Frames(lag), peak: peak, drift: drift, headCut: Frames(headCut), replaced: replaced, rate: 48_000)
    }

    func text(_ moved: SyncMoved) -> String { moved.text(text: englishText, locale: Self.us) }

    /// C20: the first sentence says "earlier" or "later" with a duration and no sign.
    @Test func theFirstSentenceSaysEarlierOrLater() {
        #expect(
            text(moved(lag: 5_904_000)).hasPrefix("Moved the clip 2 min 3.0 s later. "),
            "\(text(moved(lag: 5_904_000)))")
        #expect(text(moved(lag: -163_200)).hasPrefix("Moved the clip 3.4 s earlier. "), "\(text(moved(lag: -163_200)))")
        for lag in [5_904_000, -163_200, 1_439_000] {
            let first = text(moved(lag: lag)).components(separatedBy: ". ")[0]
            #expect(!first.contains("+") && !first.contains("-"), "a sign in \(first)")
        }
        #expect(
            text(moved(lag: 2_878_000)).hasPrefix("Moved the clip 1 min 0.0 s later. "),
            "59.96 s rounds up to the minute")
    }

    /// C20: the match sentence follows, then the lag change line over 20 ms, or the not-measured line
    /// with its cause, then the head cut line.
    @Test func theMatchTheSpreadAndTheHeadCutFollow() {
        #expect(text(moved(lag: -163_200)) == "Moved the clip 3.4 s earlier. Match score: 0.98.")
        #expect(
            text(moved(lag: -163_200, drift: .spread(2_880)))
                == "Moved the clip 3.4 s earlier. Match score: 0.98. The lag changes by 60 ms across the clip.")
        #expect(
            text(moved(lag: -163_200, drift: .spread(960)))
                == "Moved the clip 3.4 s earlier. Match score: 0.98.", "a spread of 20 ms or less has no line")
        #expect(
            text(moved(lag: -163_200, drift: .onePartMatched))
                == "Moved the clip 3.4 s earlier. Match score: 0.98. The drift was not measured: only one part of the clip matched."
        )
        #expect(
            text(moved(lag: -163_200, drift: .clipTooShort))
                == "Moved the clip 3.4 s earlier. Match score: 0.98. The drift was not measured: the clip is shorter than 60 s."
        )
        #expect(
            text(moved(lag: -163_200, headCut: 288_000))
                == "Moved the clip 3.4 s earlier. Match score: 0.98. Cut 6.0 s from the start of the clip, because it moved before the start of the session."
        )
        #expect(
            text(moved(lag: -163_200, replaced: ["Part 2"]))
                == "Moved the clip 3.4 s earlier. Match score: 0.98. The move replaced audio of Part 2.")
        #expect(
            text(moved(lag: -163_200, replaced: ["Part 2", "Music"]))
                == "Moved the clip 3.4 s earlier. Match score: 0.98. The move replaced audio of Part 2 and Music.")
    }

    /// C20: the banner names the clip that the move cuts, with its name from before the move. Clip `N`
    /// (file `r`, 23 to 30 s on Host) is under the new place of `C` (20 to 28 s).
    @Test func theBannerNamesTheClipThatTheMoveCuts() async throws {
        let url = try await syncWindowPackage(in: folder.url, neighbor: true)
        let (model, studio, _, _) = try await openLanes(app, url)

        await model.sync(try #require(SyncDraft(clip: "C", in: studio.session)))

        guard case .syncMoved(let moved, _, _) = try #require(model.syncReport?.banner) else {
            Issue.record("no result banner: \(String(describing: model.syncReport))")
            return
        }
        #expect(moved.replaced == ["r"], "\(moved)")
        #expect(text(moved).hasSuffix(" The move replaced audio of r."), "\(text(moved))")
        #expect(studio.session.clip("N")?.clip.range == Frames(28 * 48_000)..<Frames(30 * 48_000))
        await model.close()
    }

    /// C20: the banner is info with Undo, it stays through a selection change and a play, and an edit
    /// hides it. The key has its press number, so VoiceOver reads each result.
    @Test func theResultStaysUntilClosedOrTheNextEdit() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = .clips(ClipSet("C"))
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))

        await model.sync(draft)

        let banner = try #require(model.syncReport?.banner, "no result banner")
        guard case .syncMoved(let result, let revision, _) = banner else {
            Issue.record("not the result banner: \(banner)")
            return
        }
        #expect(result.lag == 720_000 && revision == studio.sessionRevision)
        #expect(banner.kind == .info && banner.announcement == .medium)
        #expect(ChromeState.reportBanners(model, studio) == [banner])
        model.timeline.selection = .none
        await studio.perform(.seek(.frame(96_000)))
        #expect(ChromeState.reportBanners(model, studio) == [banner], "a selection change or a seek hid it")
        model.edit(ripple: false) { session throws(SessionError) in try session.renameTrack("t1", to: "Other") }
        #expect(ChromeState.reportBanners(model, studio).isEmpty, "an edit left the banner")
        await model.close()
    }

    /// C20: Undo on the banner puts the clip back in one step and hides the banner.
    @Test func undoOnTheResultUndoesTheSync() async throws {
        let (model, studio) = try await open()
        let before = studio.session
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        await model.sync(draft)
        #expect(studio.session.clip("C")?.clip.start == 960_000)
        guard case .syncMoved(_, let revision?, _) = try #require(model.syncReport?.banner) else {
            Issue.record("no result banner")
            return
        }
        #expect(model.canUndoAgentEdit(revision: revision))

        model.undoAgentEdit(revision: revision)

        #expect(studio.session == before && !studio.canUndo, "the undo is not one step")
        #expect(ChromeState.reportBanners(model, studio).isEmpty)
        await model.close()
    }

    /// C20: a second sync finds lag 0 and changes nothing. Its banner says that the clip is already in
    /// sync and has no Undo, and one undo still puts back the first sync.
    @Test func aSyncThatMovesNothingHasNoUndo() async throws {
        let (model, studio) = try await open()
        let before = studio.session
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        await model.sync(draft)
        let (synced, revision) = (studio.session, studio.sessionRevision)
        #expect(synced.clip("C")?.clip.start == 960_000 && studio.canUndo)

        await model.sync(draft)

        let banner = try #require(model.syncReport?.banner, "no banner after the second sync")
        guard case .syncMoved(let result, let shown, _) = banner else {
            Issue.record("not the result banner: \(banner)")
            return
        }
        let undo: Int? = shown
        #expect(result.lag == .zero && undo == nil, "the banner offers Undo: \(banner)")
        #expect(text(result).hasPrefix("The clip is already in sync. Match score: "), "\(text(result))")
        #expect(banner.kind == .info && model.alert == nil)
        #expect(ChromeState.reportBanners(model, studio) == [banner])
        #expect(studio.session == synced && studio.sessionRevision == revision, "the second sync changed the session")
        model.undo()
        #expect(studio.session == before && !studio.canUndo, "one undo did not put back the first sync")
        await model.close()
    }

    /// C21: no match names the clip and the track, changes nothing, and has a warning kind.
    @Test func noMatchNamesTheClipAndTheTrack() async throws {
        let (model, studio) = try await open(unrelated: true)
        let before = studio.session
        let revision = studio.sessionRevision
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))

        await model.sync(draft)

        let banner = try #require(model.syncReport?.banner, "no banner")
        #expect(banner == .syncNoMatch(clip: "C", clipName: "c", trackName: "Guest", press: 1), "\(banner)")
        #expect(banner.kind == .warning && model.alert == nil)
        #expect(
            syncNoMatchText(clip: "c", track: "Guest", text: englishText) == "No match: c was not found on Guest.")
        #expect(studio.session == before && studio.sessionRevision == revision && !studio.canUndo)
        #expect(ChromeState.reportBanners(model, studio) == [banner])
        await model.close()
    }

    /// C21: the button of the banner opens the sheet again for the same clip, on the default track.
    @Test func chooseAnotherTrackOpensTheSheetAgain() async throws {
        let (model, studio) = try await open(unrelated: true)
        model.timeline.selection = .clips(ClipSet("C"))
        await model.sync(try #require(SyncDraft(clip: "C", in: studio.session)))
        guard case .syncNoMatch(let clip, _, _, _) = try #require(model.syncReport?.banner) else {
            Issue.record("no no-match banner")
            return
        }
        #expect(model.syncDraft == nil)

        model.chooseAnotherSyncTrack(for: clip)

        #expect(model.syncDraft?.clip == "C", "\(String(describing: model.syncDraft))")
        await model.close()
    }

    /// C20: a sync that is cancelled shows no banner and no alert.
    @Test func aCancelShowsNothing() async throws {
        let (model, studio) = try await open()
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }
        let syncing = Task { await model.sync(draft) }
        await gate.entered()
        #expect(model.syncProgress != nil && studio.transport == .syncing)
        model.cancelReadJob()
        gate.open()
        await syncing.value
        #expect(model.syncReport == nil && model.alert == nil && model.syncProgress == nil)
        #expect(studio.session.clip("C")?.clip.start == 240_000)
        await model.close()
    }
}
