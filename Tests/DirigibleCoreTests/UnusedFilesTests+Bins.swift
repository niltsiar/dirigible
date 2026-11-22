import Foundation
import Testing

@testable import DirigibleCore

/// F22: a clip of a bin item holds its file, as a clip of a track (decision 0024; run
/// `2026-10-28-favorites-bins`, criterion C4).
extension UnusedFilesTests {
    /// C4. Remove Unused Files keeps a WAV that only a bin clip uses, and lists it after the item goes.
    /// Control: with `filesInUse` over the track clips only, the first scan lists `bin.wav`.
    @Test func binClipHoldsFile() throws {
        var session = try Self.session([("u", "used.wav"), ("b", "bin.wav")], used: ["u", "b"])
        let bin = try session.addBin(named: "Bin")
        try session.addItem(try session.excerpt(of: ["c-b"]), named: "Take", to: bin, id: "i")
        try session.removeClips(["c-b"])
        try plant("used.wav")
        try plant("bin.wav")

        #expect(Self.paths(try scan(session)).isEmpty, "the bin clip holds bin.wav")
        try session.removeItem("i")
        #expect(Self.paths(try scan(session)) == ["bin.wav"])
    }
}
