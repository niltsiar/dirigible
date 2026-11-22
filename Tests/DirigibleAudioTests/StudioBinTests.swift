import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The bins of an open studio (F22): each bin edit is one undo entry, and a paste of a bin item
/// gives the clips of a Copy and Paste of the same range at the add.
@MainActor
struct StudioBinTests {
    /// Track t1 with clip A (gain -6 dB) and the later clip C at 96000, and track t2 with clip B
    /// (fade-in 480, fade-out 960), all on one tone file, open in a studio.
    private static func open() async throws -> (studio: Studio, package: MixPackage) {
        let package = try MixPackage()
        try package.addFile("take1-mic", channels: [sine(seconds: 3, rate: 48_000)])
        try package.addTrack("t1", clip: "A", file: "take1-mic", start: 0, offset: 0, length: 48_000)
        try package.addTrack("t2", clip: "B", file: "take1-mic", start: 12_000, offset: 4_000, length: 24_000)
        try package.session.place(
            Clip(id: "C", file: "take1-mic", start: 96_000, offset: 0, length: 4_800), on: "t1")
        try package.session.setGain(try #require(Gain(dB: -6)), clip: "A")
        try package.session.setFades(["B": try #require(Fades(fadeIn: 480, fadeOut: 960))])
        try package.session.write(to: package.url)
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        return (studio, package)
    }

    /// C8. The item of the range 6000..<30000 of t1 and t2 pastes the clips that a Copy and Paste of
    /// that range at the add gives, also after the source clips are deleted. Insert moves the later
    /// clip C of t1 by the item length, 24000.
    @Test func pasteFromBinMatchesCopyPaste() async throws {
        let (studio, _) = try await Self.open()
        let excerpt = try studio.session.excerpt(of: 6_000..<30_000, on: ["t1", "t2"])
        let item = try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addItem(excerpt, named: "Answer", to: try session.addBin(named: "Show"))
        }
        let added = studio.session
        try studio.edit(ripple: false) { session throws(SessionError) in try session.removeClips(["A", "B"]) }

        for mode in [PasteMode.over(at: 200_000), .insert(at: 60_000)] {
            let before = studio.session
            var reference = added
            try reference.removeClips(["A", "B"])
            let expected = try reference.paste(excerpt, mode: mode, on: ["t1", "t2"])

            let pasted = try #require(
                try studio.pasteInPlace(try studio.clipboard(of: item), mode: mode, on: .tracks(["t1", "t2"])))

            #expect(!expected.isEmpty && pasted.clips == expected && pasted.tracks == ["t1", "t2"], "\(mode)")
            for id in expected {
                let same = studio.session.clip(id).map { [$0.clip] } == reference.clip(id).map { [$0.clip] }
                #expect(same, "clip \(id) of \(mode) has the file, offset, length, gain, and fades of a Copy and Paste")
            }
            let gain = expected.compactMap { studio.session.clip($0)?.clip.gain }
            #expect(gain.contains(try #require(Gain(dB: -6))), "the gain of A survives in the item")
            if case .insert = mode {
                #expect(studio.session.clip("C")?.clip.start == 120_000, "Insert moves C by 24000")
            }
            try studio.undo()
            #expect(studio.session == before, "one undo removes the paste")
        }
        await studio.settle()
    }

    /// C6. Each bin edit is one undo entry, and Undo gives back the bins before it.
    @Test func binEditIsOneUndo() async throws {
        let (studio, _) = try await Self.open()
        let excerpt = try studio.session.excerpt(of: ["A"])
        let bin = try studio.edit(ripple: false) { session throws(SessionError) in try session.addBin(named: "Show") }
        let item = try studio.edit(ripple: false) { session throws(SessionError) in
            try session.addItem(excerpt, named: "A", to: bin)
        }
        for name in ["renameBin", "addBin", "renameItem", "removeItem", "removeBin"] {
            let (before, revision) = (studio.session, studio.sessionRevision)
            try studio.edit(ripple: false) { session throws(SessionError) in
                switch name {
                case "renameBin": try session.renameBin(bin, to: "Intros")
                case "addBin": try session.addBin("b2", named: "Later")
                case "renameItem": try session.renameItem(item, to: "Sting")
                case "removeItem": try session.removeItem(item)
                default: try session.removeBin(bin)
                }
            }
            #expect(studio.session.bins != before.bins && studio.sessionRevision == revision + 1, "\(name) is one edit")
            try studio.undo()
            #expect(studio.session.bins == before.bins, "one undo gives back the bins before \(name)")
            try studio.redo()
        }
        #expect(studio.session.bins.map(\.name) == ["Later"])
        await studio.settle()
    }

    /// An unknown item throws `.unknownBinItem` and gives no clipboard.
    @Test func anUnknownItemGivesNoClipboard() async throws {
        let (studio, _) = try await Self.open()
        #expect(throws: StudioError.session(.unknownBinItem("ghost"))) { try studio.clipboard(of: BinItemID("ghost")) }
        await studio.settle()
    }
}
