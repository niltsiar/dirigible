import DirigibleCore
import Foundation
import Testing

/// `dirigible clip restore` (decision 0057, run render-link C6). Track "t" (mono) has clip "A"
/// (+5 dB) on "f NR NR", a render of "f NR", which is a render of "f"; and clip "P" on the plain
/// file "g". No WAV is on the disk: a restore reads no audio.
struct ClipRestoreCommandTests {
    let package: TemporaryPackage

    init() throws { package = try TemporaryPackage(try Self.rendered()) }

    static func rendered() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t", name: "Host", layout: .mono)
        let noise = Treatment(.noise(.standard))
        let files = [
            AudioFile(id: "f", path: "f.wav", layout: .mono, length: 1_000_000),
            AudioFile(id: "g", path: "g.wav", layout: .mono, length: 1_000_000),
            AudioFile(
                id: "f NR", path: "f NR.wav", layout: .mono, length: 500_000,
                origin: RenderOrigin(
                    source: "f", offset: 100_000, treatment: noise, addedGain: try #require(Gain(dB: 1)))),
            AudioFile(
                id: "f NR NR", path: "f NR NR.wav", layout: .mono, length: 200_000,
                origin: RenderOrigin(
                    source: "f NR", offset: 50_000, treatment: noise, addedGain: try #require(Gain(dB: 2)))),
        ]
        for file in files { try session.addFile(file) }
        let gain = try #require(Gain(dB: 5))
        try session.place(Clip(id: "A", file: "f NR NR", start: 0, offset: 10_000, length: 48_000, gain: gain), on: "t")
        try session.place(Clip(id: "P", file: "g", start: 100_000, offset: 0, length: 48_000), on: "t")
        return session
    }

    /// C6. The clip goes to the root of its chain at the frame that it played, with the added
    /// gains taken off. The command writes the ID of each restored clip and saves.
    @Test func restoreMovesToTheRoot() async throws {
        let result = try await dirigible("clip", "restore", package.path, "A", "P")

        #expect(result == CLIResult(status: 0, stdout: "A\n", stderr: ""))
        let session = try package.read()
        let gain = try #require(Gain(dB: 2))
        #expect(
            session.clip("A")?.clip == Clip(id: "A", file: "f", start: 0, offset: 160_000, length: 48_000, gain: gain))
        #expect(session.clip("P")?.clip.file == "g")
        #expect(session.files["f NR NR"]?.origin?.source == "f NR", "the rendered files stay in the pool")
    }

    /// C6. With no rendered clip, the command writes "No rendered clip.", exits 0, and does not
    /// save.
    @Test func noRenderedClipSavesNothing() async throws {
        let before = try package.xml()

        let result = try await dirigible("clip", "restore", package.path, "P")

        #expect(result == CLIResult(status: 0, stdout: "No rendered clip.\n", stderr: ""))
        #expect(try package.xml() == before)
    }

    /// C6. An unknown clip exits 1 and changes nothing; a clip given twice exits 64.
    @Test func refusalsChangeNothing() async throws {
        let before = try package.xml()

        let unknown = try await dirigible("clip", "restore", package.path, "A", "X")
        let twice = try await dirigible("clip", "restore", package.path, "A", "A")

        #expect(unknown == CLIResult(status: 1, stdout: "", stderr: "Error: no clip \"X\".\n"))
        #expect(twice.status == 64 && twice.stderr.contains("Clip \"A\" is given twice."), "\(twice)")
        #expect(try package.xml() == before)
    }
}
