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
        lag: Int, drift: SyncDrift = .spread(0), headCut: Int = 0, replaced: [String] = []
    ) -> SyncMoved {
        SyncMoved(lag: Frames(lag), drift: drift, headCut: Frames(headCut), replaced: replaced, rate: 48_000)
    }

    func bannerText(_ moved: SyncMoved) -> String { moved.text(text: englishText, locale: Self.us) }

    /// The result sentences, then the sentences to check: the whole text of a sync.
    func text(_ moved: SyncMoved) -> String {
        let done = moved.doneText(text: englishText, locale: Self.us)
        return moved.needsCheck ? done + " " + bannerText(moved) : done
    }

    /// C20: the first sentence says "earlier" or "later" with a duration and no sign.
    @Test func theFirstSentenceSaysEarlierOrLater() {
        #expect(
            text(moved(lag: 5_904_000)).hasPrefix("Moved the clip 2 min 3.0 s later."),
            "\(text(moved(lag: 5_904_000)))")
        #expect(text(moved(lag: -163_200)).hasPrefix("Moved the clip 3.4 s earlier."), "\(text(moved(lag: -163_200)))")
        for lag in [5_904_000, -163_200, 1_439_000] {
            let first = text(moved(lag: lag)).components(separatedBy: ". ")[0]
            #expect(!first.contains("+") && !first.contains("-"), "a sign in \(first)")
        }
        #expect(
            text(moved(lag: 2_878_000)).hasPrefix("Moved the clip 1 min 0.0 s later."),
            "59.96 s rounds up to the minute")
    }

    /// C20: the lag change line over 20 ms, or the not-measured line, then the head cut line, then
    /// the clips that the move replaced. The banner has no match score.
    @Test func theSpreadTheHeadCutAndTheReplacedClipsFollow() {
        #expect(text(moved(lag: -163_200)) == "Moved the clip 3.4 s earlier.")
        #expect(
            text(moved(lag: -163_200, drift: .spread(2_880)))
                == "Moved the clip 3.4 s earlier. The lag changes by 60 ms across the clip.")
        #expect(
            text(moved(lag: -163_200, drift: .spread(960))) == "Moved the clip 3.4 s earlier.",
            "a spread of 20 ms or less has no line")
        #expect(
            text(moved(lag: -163_200, drift: .onePartMatched))
                == "Moved the clip 3.4 s earlier. Only one part of the clip matched, too few to measure the drift."
        )
        #expect(
            text(moved(lag: -163_200, drift: .clipTooShort))
                == "Moved the clip 3.4 s earlier. The clip is shorter than the 60 s that drift measuring needs.")
        #expect(
            text(moved(lag: -163_200, headCut: 288_000))
                == "Moved the clip 3.4 s earlier. Cut 6.0 s from the start of the clip to keep it inside the session.")
        #expect(
            text(moved(lag: -163_200, replaced: ["Part 2"]))
                == "Moved the clip 3.4 s earlier. The move replaced audio of Part 2.")
        #expect(
            text(moved(lag: -163_200, replaced: ["Part 2", "Music"]))
                == "Moved the clip 3.4 s earlier. The move replaced audio of Part 2 and Music.")
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

    /// C9 (k): a sync that moves the clip and has nothing to check shows no banner, because the clip is in
    /// its new place. VoiceOver hears the move once.
    @Test func aPlainSyncMoveShowsNoBannerAndIsAnnounced() async throws {
        let (model, studio) = try await open()
        let chrome = try #require(model.chrome)
        var heard: [String] = []
        chrome.announce = { text, _ in heard.append(text) }
        var draft = try #require(SyncDraft(clip: "C", in: studio.session))
        draft.correctsDrift = false

        await model.sync(draft)

        #expect(studio.session.clip("C")?.clip.start == 960_000 && model.alert == nil, "the clip did not move")
        #expect(model.syncReport == nil, "a plain move has a banner: \(String(describing: model.syncReport))")
        #expect(ChromeState.reportBanners(model, studio).isEmpty)
        #expect(
            heard.count == 1 && heard.first?.hasPrefix(leadText("announce.sync.later")) == true,
            "VoiceOver hears the move: \(heard)")
        await model.close()
    }

    /// C9 (k): a sync that replaces audio of another clip shows a warning banner with Undo. The banner
    /// holds the sentence to check and not the move.
    @Test func aSyncThatReplacesAudioShowsTheWarningWithUndo() async throws {
        let url = try await syncWindowPackage(in: folder.url, neighbor: true)
        let (model, studio, _, _) = try await openLanes(app, url)
        var draft = try #require(SyncDraft(clip: "C", in: studio.session))
        draft.correctsDrift = false

        await model.sync(draft)

        let banner = try #require(model.syncReport?.banner, "no banner")
        guard case .syncMoved(let moved, let revision?, _) = banner else {
            Issue.record("no banner with Undo: \(banner)")
            return
        }
        #expect(banner.kind == .warning, "\(banner.kind)")
        #expect(bannerText(moved) == "The move replaced audio of r.", "\(bannerText(moved))")
        #expect(model.canUndoAgentEdit(revision: revision))
        await model.close()
    }

    /// C9 (k): the banner of a head cut, and of a drift that was not corrected, is a warning that holds
    /// only the sentences to check.
    @Test func theBannerHoldsOnlyTheSentencesToCheck() {
        let cut = moved(lag: -163_200, headCut: 288_000)
        #expect(WindowBanner.syncMoved(cut, revision: 3, press: 1).kind == .warning)
        #expect(
            bannerText(cut) == "Cut 6.0 s from the start of the clip to keep it inside the session.",
            "\(bannerText(cut))")
        let drift = driftMoved(.notCorrected(.takeFile))
        #expect(WindowBanner.syncMoved(drift, revision: 3, press: 1).kind == .warning)
        #expect(
            bannerText(drift) == "The drift wasn't corrected. A take records on the session clock.",
            "\(bannerText(drift))")
        #expect(WindowBanner.syncMoved(moved(lag: -163_200), revision: 3, press: 1).kind == .info)
    }

    /// C20: the banner is a warning with Undo, it stays through a selection change and a play, and an edit
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
        #expect(banner.kind == .warning && banner.announcement == .medium)
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

    /// C20: a second sync with Correct drift off finds lag 0 and changes nothing. Its banner says that the
    /// clip is already in sync and has no Undo, and one undo still puts back the first sync.
    @Test func aSyncThatMovesNothingHasNoUndo() async throws {
        let (model, studio) = try await open()
        let before = studio.session
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        await model.sync(draft)
        let (synced, revision) = (studio.session, studio.sessionRevision)
        #expect(synced.clip("C")?.clip.start == 960_000 && studio.canUndo)

        var again = draft
        again.correctsDrift = false
        await model.sync(again)

        let banner = try #require(model.syncReport?.banner, "no banner after the second sync")
        guard case .syncMoved(let result, let shown, _) = banner else {
            Issue.record("not the result banner: \(banner)")
            return
        }
        let undo: Int? = shown
        #expect(result.lag == .zero && undo == nil, "the banner offers Undo: \(banner)")
        #expect(text(result).hasPrefix("The clip is already in sync."), "\(text(result))")
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
        #expect(
            banner
                == .syncNoMatch(
                    clip: "C", track: "t2", clipName: "c", trackName: "Guest", correctsDrift: true, press: 1),
            "\(banner)")
        #expect(banner.kind == .warning && model.alert == nil)
        #expect(
            syncNoMatchText(clip: "c", track: "Guest", text: englishText) == "Couldn't find a match for c on Guest.")
        #expect(studio.session == before && studio.sessionRevision == revision && !studio.canUndo)
        #expect(ChromeState.reportBanners(model, studio) == [banner])
        await model.close()
    }

    /// C21: the button of the banner opens the sheet again for the same clip, on a track other than the
    /// track that found no match. With no other track near the clip, the sheet keeps that track.
    @Test func chooseAnotherTrackOpensTheSheetAgain() async throws {
        for third in [true, false] {
            let url = try await syncWindowPackage(in: folder.url, unrelated: true, third: third)
            let (model, studio, _, _) = try await openLanes(app, url)
            model.timeline.selection = .clips(ClipSet("C"))
            let draft = try #require(SyncDraft(clip: "C", in: studio.session))
            #expect(draft.reference == "t2", "third \(third): the default track")
            await model.sync(draft)
            guard case .syncNoMatch(let clip, let track, _, _, let drift, _) = try #require(model.syncReport?.banner)
            else {
                Issue.record("third \(third): no no-match banner")
                return
            }
            #expect(model.syncDraft == nil && track == "t2")

            model.chooseAnotherSyncTrack(for: clip, after: track, correctsDrift: drift)

            let again = try #require(model.syncDraft, "third \(third): no sheet")
            #expect(again.clip == "C" && again.reference == (third ? "t3" : "t2"), "third \(third): \(again)")
            await model.close()
        }
    }

    /// Decision 0077 D12: the sheet that the button opens again keeps the Correct drift box of the
    /// sync that found no match, off or on.
    @Test func chooseAnotherTrackKeepsTheDriftBox() async throws {
        for box in [false, true] {
            let (model, studio) = try await open(unrelated: true)
            var draft = try #require(SyncDraft(clip: "C", in: studio.session))
            draft.correctsDrift = box
            await model.sync(draft)
            guard case .syncNoMatch(let clip, let track, _, _, let drift, _) = try #require(model.syncReport?.banner)
            else {
                Issue.record("box \(box): no no-match banner")
                return
            }

            model.chooseAnotherSyncTrack(for: clip, after: track, correctsDrift: drift)

            #expect(try #require(model.syncDraft, "box \(box): no sheet").correctsDrift == box, "box \(box)")
            await model.close()
        }
    }

    /// Sync on a studio that became busy while the sheet was open (an agent job) shows the busy alert,
    /// moves nothing, keeps the selection, and leaves the other job running.
    @Test func aSyncOnABusyStudioShowsTheBusyAlert() async throws {
        let (model, studio) = try await open()
        model.timeline.selection = .clips(ClipSet("C"))
        let before = studio.session
        let draft = try #require(SyncDraft(clip: "C", in: studio.session))
        studio.transport = .leveling

        await model.sync(draft)

        #expect(model.alert == .error(.busy), "\(String(describing: model.alert))")
        #expect(model.syncReport == nil && model.syncProgress == nil && studio.transport == .leveling)
        #expect(studio.session == before && model.timeline.selection == .clips(ClipSet("C")))
        studio.transport = .idle
        model.alert = nil
        await model.close()
    }

    /// C20: a sync that is cancelled shows no banner and no alert.
    @Test func aCancelShowsNothing() async throws {
        let (model, studio) = try await open()
        var draft = try #require(SyncDraft(clip: "C", in: studio.session))
        draft.correctsDrift = false
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
