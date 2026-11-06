import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The readout of the Shift-Command roll and slip drags (decision 0020, criterion C28).
@Suite(.serialized) @MainActor struct RollSlipReadoutTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// The edit name and the signed whole ms at 48 kHz, in the number format of the language.
    /// Controls: a text with the frame count ("Roll 24000") or with no sign ("Roll 500 ms") fails.
    @Test func theReadoutNamesTheEditAndTheOffset() throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        func text(_ readout: GestureReadout, _ table: [String: String], _ locale: String) -> String {
            ReadoutLayer.text(readout, rate: 48_000, locale: Locale(identifier: locale)) { table[$0.rawValue] ?? "" }
        }
        #expect(text(.roll(24_000), en, "en") == "Roll +500 ms")
        #expect(text(.slip(-24_000), en, "en") == "Slip -500 ms")
        #expect(text(.roll(0), en, "en") == "Roll 0 ms")
        #expect(text(.roll(24), en, "en") == "Roll +1 ms", "rounded to the nearest ms")
        #expect(text(.roll(-1), en, "en") == "Roll 0 ms", "no -0")
        #expect(text(.roll(24_000), es, "es") == "Punto de edición +500 ms")
        #expect(text(.slip(-24_000), es, "es") == "Contenido -500 ms")
        #expect(text(.roll(59_232_000), en, "en") == "Roll +1,234,000 ms", "the grouping of the language")
        #expect(text(.roll(59_232_000), es, "es") == "Punto de edición +1.234.000 ms")
    }

    /// C28: the readout layer shows during a drag of `standaloneLanes` and hides at the mouse-up.
    @Test func theReadoutLeavesWithTheDrag() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 20), app: app)
        try studio.edit(ripple: false) { s throws(SessionError) in _ = try s.splitClips(at: [460_800], on: ["t1"]) }
        let (window, view) = standaloneLanes(model, studio)
        func send(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws {
            let event = try mouse(
                type, NSPoint(x: x, y: y), in: view, flags: type == .leftMouseDown ? [.shift, .command] : [])
            switch type {
            case .leftMouseDown: view.lanes.mouseDown(with: event)
            case .leftMouseDragged: view.lanes.mouseDragged(with: event)
            default: view.lanes.mouseUp(with: event)
            }
        }
        try send(.leftMouseDown, 898, 10)
        try send(.leftMouseDragged, 948, 10)
        #expect(!view.lanes.readout.isHidden)
        #expect((view.lanes.readout.string as? String) == L10n.timelineReadoutRoll.text)
        try send(.leftMouseUp, 948, 10)
        #expect(view.lanes.readout.isHidden)
        try send(.leftMouseDown, 500, 30)
        try send(.leftMouseDragged, 450, 30)
        #expect((view.lanes.readout.string as? String) == L10n.timelineReadoutSlip.text)
        try send(.leftMouseUp, 450, 30)
        #expect(view.lanes.readout.isHidden)
        window.close()
        await model.close()
    }
}
