import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Transport > Go to Take Time... (decision 0061, C15): the sheet takes a time from the record
/// start of a take and moves the playhead to the first timeline place of that take time.
@Suite(.serialized) @MainActor struct GoToTakeTimeTests {
    typealias Take = TakeSyncBannerTests.Take
    let sync: TakeSyncBannerTests
    static let second = 48_000

    init() throws { sync = try TakeSyncBannerTests() }

    /// Opens the sheet, types `text`, and clicks OK.
    func go(_ model: SessionWindow, _ text: String, take: Int? = nil) async throws {
        model.startTakeTime()
        try #require(model.takeTimeDraft != nil, "the sheet opens")
        model.takeTimeDraft?.text = text
        if let take { model.takeTimeDraft?.take = take }
        await model.goToTakeTime()
    }

    /// The first state: a user ripple insert of 5 s at 0 moves take 1 by 5 s, so take time
    /// 0:00:10 is at 0:00:15 on the timeline. The sheet closes.
    @Test func aTakeTimeMovesThePlayheadToItsEditedPlace() async throws {
        let (model, studio) = try await sync.open(try sync.oneTake())
        try studio.edit(ripple: true, agent: nil) { s throws(SessionError) in
            try s.rippleInsert(Frames(5 * Self.second), at: .zero, on: ["t1", "t2"])
        }
        #expect(model.canGoToTakeTime)

        try await go(model, "0:00:10")

        #expect(studio.playhead == Frames(15 * Self.second))
        #expect(model.takeTimeDraft == nil)
        await model.close()
    }

    /// No take audio: the item is off, and the command opens no sheet.
    @Test func noTakeAudioTurnsTheItemOff() async throws {
        let (model, _) = try await sync.open(try await timelinePackage(in: sync.folder.url, tracks: 1, seconds: 60))
        #expect(!model.canGoToTakeTime)
        model.startTakeTime()
        #expect(model.takeTimeDraft == nil)
        await model.close()
    }

    /// Code gate L3 item 3: one dialog at a time in a window. Each other dialog turns the item off,
    /// and the take time sheet turns Duck Music Under Speech and the exports off.
    @Test func anotherDialogTurnsTheItemOff() async throws {
        let (model, studio) = try await sync.open(try sync.oneTake())
        let dialogs: [(String, () -> Void)] = [
            ("the save panel", { model.exportStep = .choosing }),
            (
                "the export progress sheet",
                {
                    studio.exportJob = ExportJob(
                        number: 0, url: sync.folder.url, progress: 0.5, report: { _ in },
                        task: Task { .failure(.cancelled) })
                }
            ),
            ("the duck sheet", { model.duckDraft = DuckDraft(roles: studio.session) }),
            (
                "the unused files sheet",
                {
                    model.unusedFiles = try? UnusedFiles(scanning: studio.session, keptBy: [], in: studio.url)
                }
            ),
            ("an alert", { model.alert = .error(.busy) }),
        ]
        for (name, show) in dialogs {
            #expect(model.canGoToTakeTime, "before \(name)")
            show()
            #expect(!model.canGoToTakeTime, "\(name)")
            model.startTakeTime()
            #expect(model.takeTimeDraft == nil, "\(name)")
            (model.exportStep, studio.exportJob, model.duckDraft, model.unusedFiles, model.alert) = (
                nil, nil, nil, nil, nil
            )
            model.takeTimeDraft = nil
        }

        #expect(model.isOn(.duck) && model.isOn(.export))
        model.startTakeTime()
        #expect(model.takeTimeDraft != nil)
        #expect(!model.isOn(.duck), "the take time sheet")
        #expect(!model.isOn(.export) && !model.isOn(.exportSelection), "the take time sheet")
        await model.close()
    }

    /// During a take the item is off; after the take it is on again.
    @Test func duringATakeTheItemIsOff() async throws {
        let (model, studio) = try await sync.open(try sync.oneTake())
        studio.environment = sync.hal.environment
        await studio.perform(.seek(.frame(studio.session.end)))
        model.armed = ["t1"]
        #expect(model.canGoToTakeTime)

        await model.record()
        #expect(studio.transport == .recording(take: 2))
        #expect(!model.canGoToTakeTime)
        model.startTakeTime()
        #expect(model.takeTimeDraft == nil)

        await sync.hal.feed(seconds: 1)
        await model.stop()
        await until(limit: .seconds(30), "the take ends") { studio.transport == .idle && studio.lastTake != nil }
        #expect(model.canGoToTakeTime)
        await model.close()
    }

    /// A time that a ripple delete removed keeps the sheet, its text, and the playhead, and says
    /// why.
    @Test func aRemovedTimeKeepsTheSheet() async throws {
        let (model, studio) = try await sync.open(try sync.oneTake())
        try sync.cut(studio, 10..<12, on: ["t1", "t2"], agent: nil)
        let playhead = studio.playhead

        try await go(model, "0:00:11")

        #expect(model.takeTimeDraft == TakeTimeDraft(takes: [1], take: 1, text: "0:00:11", refusal: .removed))
        #expect(studio.playhead == playhead)
        await model.close()
    }

    /// A time that a cold open copies is in two places: the playhead goes to the first, the copy
    /// at the head of the session, not to the take at 10 s.
    @Test func aTimeInTwoPlacesGoesToTheFirst() async throws {
        let url = try sync.package([
            Take(number: 1, playhead: 10, clips: [("t1", 10, 0, 60), ("t2", 10, 0, 60), ("t1", 0, 30, 1)])
        ])
        let (model, studio) = try await sync.open(url)
        #expect(studio.takeMap.map.sync[1] == .inSync(offset: 10 * Self.second), "the cold open is a copy")

        try await go(model, "30.5")

        #expect(studio.playhead == Frames(Self.second / 2))
        await model.close()
    }

    /// Two takes: the popup lists both, and starts at the take under the playhead, else at the
    /// first. The time goes to the place of the take of the popup.
    @Test func twoTakesNameEachTakeInThePopup() async throws {
        let url = try sync.package([
            Take(number: 1, playhead: 0, clips: [("t1", 0, 0, 60), ("t2", 0, 0, 60)]),
            Take(number: 2, playhead: 120, clips: [("t1", 120, 0, 60), ("t2", 120, 0, 60)]),
        ])
        let (model, studio) = try await sync.open(url)
        await studio.perform(.seek(.frame(Frames(130 * Self.second))))
        model.startTakeTime()
        #expect(model.takeTimeDraft == TakeTimeDraft(takes: [1, 2], take: 2))
        model.takeTimeDraft = nil

        await studio.perform(.seek(.frame(Frames(90 * Self.second))))
        model.startTakeTime()
        #expect(model.takeTimeDraft == TakeTimeDraft(takes: [1, 2], take: 1), "a gap under the playhead")
        model.takeTimeDraft = nil

        try await go(model, "0:05", take: 2)
        #expect(studio.playhead == Frames(125 * Self.second))
        #expect(
            String(format: sync.englishText(.sheetTakeTimeItem), 2) == "Take 2", "the popup names the take")
        await model.close()
    }

    /// A text that does not parse keeps the sheet and its text, and shows the format.
    @Test func aTextThatDoesNotParseKeepsTheSheet() async throws {
        let (model, studio) = try await sync.open(try sync.oneTake())
        await studio.perform(.seek(.frame(Frames(Self.second))))

        try await go(model, "0:1x")

        #expect(model.takeTimeDraft == TakeTimeDraft(takes: [1], take: 1, text: "0:1x", refusal: .format))
        #expect(studio.playhead == Frames(Self.second))
        await model.close()
    }

    /// Cancel (Esc) closes the sheet and keeps the playhead and the session.
    @Test func cancelChangesNothing() async throws {
        let (model, studio) = try await sync.open(try sync.oneTake())
        let (playhead, revision) = (studio.playhead, studio.sessionRevision)
        model.startTakeTime()
        model.takeTimeDraft?.text = "0:00:10"

        model.takeTimeDraft = nil

        #expect(studio.playhead == playhead && studio.sessionRevision == revision)
        await model.close()
    }

    /// The field rounds to the frame, half away from zero: 1:02.345 is take frame 2992560 at
    /// 48 kHz and 2749414.5, so 2749415, at 44.1 kHz. Each form gives the same frame.
    @Test func theFieldRoundsToTheFrame() {
        for text in ["1:02.345", "0:01:02.345", "62.345"] {
            #expect(takeFrame(text, rate: 48_000) == 2_992_560, "\(text)")
            #expect(takeFrame(text, rate: 44_100) == 2_749_415, "\(text)")
        }
        #expect(takeFrame("1:02:03", rate: 48_000) == 3723 * 48_000)
        #expect(takeFrame("7", rate: 48_000) == 7 * 48_000)
        #expect(takeFrame(" 0:10.5 ", rate: 48_000) == 504_000)
        // Code gate L3 item 4: a comma is a decimal mark too, as in the Spanish inspector line, and
        // a leading minus gives a time before the record start, rounded half away from zero.
        #expect(takeFrame("21:07,500", rate: 48_000) == 1267 * 48_000 + 24_000)
        #expect(takeFrame("-0.2", rate: 48_000) == -9_600)
        #expect(takeFrame("-0,2", rate: 48_000) == -9_600)
        #expect(takeFrame("-1:02.345", rate: 44_100) == -2_749_415)
        #expect(takeFrame("-5", rate: 48_000) == -5 * 48_000)
        for text in [
            "", "1:60", "1:02:60", "1:60:00", "0:1x", "1.2345", "1,2345", ":10", "10:", "1:2:3:4", "1e3", "-", "--5",
            "+5", "1,2.3", "1.2,3", "- 5", "5-",
        ] {
            #expect(takeFrame(text, rate: 48_000) == nil, "\(text)")
        }
        #expect(takeFrame(String(repeating: "9", count: 30), rate: 48_000) == nil, "no overflow")
    }

    /// A seeded round trip with the time display: the stopped clock of each frame at a whole
    /// millisecond reads back as that frame.
    @Test func theTimeDisplayTextReadsBack() {
        var random = SplitMix(seed: 61)
        for _ in 0..<500 {
            let frames = Int.random(in: 0..<36_000_000, using: &random) * 48
            let text = timeDisplayText(Frames(frames), rate: 48_000, playing: false)
            #expect(takeFrame(text, rate: 48_000) == frames, "\(text)")
        }
    }
}
