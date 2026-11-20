import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible export-stems` (criteria C1, C2, C5, C9, and C15). Tracks Host and Guest (dialogue),
/// Bed (music), and Sting (no role), each at -12 dB with a clip of `f1.wav` at 0..<20000.
struct StemsCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 20_000))
        try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 20_000))
        let tracks: [(TrackID, String, Track.Role?)] = [
            ("h", "Host", .dialogue), ("g", "Guest", .dialogue), ("b", "Bed", .music), ("s", "Sting", nil),
        ]
        for (id, name, role) in tracks {
            try session.addTrack(id, name: name, layout: .mono)
            try session.place(Clip(id: ClipID(id.rawValue), file: "f1", start: 0, offset: 0, length: 20_000), on: id)
            if let role { try session.setRole(role, tracks: [id]) }
            // The four tracks sum under full scale, so no mix line.
            try session.setGain(#require(Gain(dB: -12)), track: id)
        }
        package = try TemporaryPackage(session)
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/f1.wav"), frames: 20_000)
    }

    func out(_ name: String) -> URL { package.folder.appending(path: name) }

    func items(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// C1: one file for each heard track, in session order; a muted track and a track that is not
    /// soloed get no file.
    @Test func trackStemsAreOneFileForEachHeardTrack() async throws {
        let all = try await package.run("export-stems", "PKG", "--out", out("all").path)
        #expect(
            all
                == CLIResult(
                    status: 0, stdout: "01 Host.wav\th\n02 Guest.wav\tg\n03 Bed.wav\tb\n04 Sting.wav\ts\n", stderr: ""))
        #expect(items(out("all")) == ["01 Host.wav", "02 Guest.wav", "03 Bed.wav", "04 Sting.wav"])
        try package.edit { try $0.setMuted(true, tracks: ["b"]) }
        let muted = try await package.run("export-stems", "PKG", "--out", out("muted").path)
        #expect(muted.status == 0 && muted.stdout == "01 Host.wav\th\n02 Guest.wav\tg\n03 Sting.wav\ts\n")
        #expect(muted.stderr == "Warning: 1 track is muted or not soloed and is not in the export.\n")
        try package.edit { try $0.setSoloed(true, tracks: ["h"]) }
        let solo = try await package.run("export-stems", "PKG", "--out", out("solo").path, "--format", "flac")
        #expect(solo.status == 0 && items(out("solo")) == ["01 Host.flac"])
    }

    /// C2: one file for each role, then the tracks with no role; the line of a file names its tracks.
    @Test func roleStemsNameTheirTracks() async throws {
        let result = try await package.run("export-stems", "PKG", "--out", out("roles").path, "--by", "role")
        #expect(
            result == CLIResult(status: 0, stdout: "Dialogue.wav\th\tg\nMusic.wav\tb\nNo Role.wav\ts\n", stderr: ""))
        #expect(items(out("roles")) == ["Dialogue.wav", "Music.wav", "No Role.wav"])
    }

    /// C2: with no role on a heard track of the set, one file and one note, exit 0.
    @Test func roleStemsWithNoRoleSetGiveANote() async throws {
        let result = try await package.run(
            "export-stems", "PKG", "--out", out("none").path, "--by", "role", "--track", "s")
        #expect(
            result
                == CLIResult(
                    status: 0, stdout: "No Role.wav\ts\n",
                    stderr: "Note: no heard track of the set has a role, so one file holds them all.\n"))
        #expect(items(out("none")) == ["No Role.wav"])
    }

    /// C5: no stem with a clip in the range exits 1 and makes no folder, no staging folder, and no
    /// lock file.
    @Test func noStemWithAClipExitsOneAndMakesNoFolder() async throws {
        let result = try await package.run(
            "export-stems", "PKG", "--out", out("late").path, "--from", "30000", "--to", "40000")
        #expect(
            result
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: No track of the set has a clip in the range. No folder was made.\n"))
        #expect(items(package.folder) == ["Show.dirigible"])
    }

    /// C6: an `--out` that exists exits 2, and the item does not change.
    @Test func anExistingOutExitsTwoAndDoesNotChange() async throws {
        try FileManager.default.createDirectory(at: out("stems"), withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: out("stems/keep.txt"))
        let result = try await package.run("export-stems", "PKG", "--out", out("stems").path)
        #expect(result == CLIResult(status: 2, stdout: "", stderr: "Error: \(out("stems").path) exists.\n"))
        #expect(items(out("stems")) == ["keep.txt"] && items(package.folder) == ["Show.dirigible", "stems"])
    }

    /// C9: a usage error exits 64 and writes nothing. A missing file of a heard track exits 2 and
    /// names the path; with `--allow-missing`, exit 0 and a warning. A muted track is not read.
    @Test func argumentRefusalsAndMissingFiles() async throws {
        for arguments in [
            ["--format", "mp3"], ["--bits", "20"], ["--by", "stem"], ["--rate", "22050"],
            ["--from", "500", "--to", "100"],
            ["--track", "nope"],
        ] {
            let result = try await package.run(["export-stems", "PKG", "--out", out("bad").path] + arguments)
            #expect(result.status == 64, "\(arguments): \(result)")
        }
        let inside = try await package.run("export-stems", "PKG", "--out", package.url.appending(path: "stems").path)
        #expect(inside.status == 64)
        let long = try await package.run("export-stems", "PKG", "--out", out(String(repeating: "s", count: 207)).path)
        #expect(long.status == 64 && long.stderr.contains("over 206 bytes"), "\(long)")
        #expect(items(package.folder) == ["Show.dirigible"])
        try package.edit { session in
            try session.addTrack("m", name: "Missing", layout: .mono)
            try session.place(Clip(id: "cm", file: "gone", start: 0, offset: 0, length: 20_000), on: "m")
            try session.setMuted(true, tracks: ["m"])
        }
        let muted = try await package.run("export-stems", "PKG", "--out", out("muted").path)
        #expect(muted.status == 0, "a muted track is not read: \(muted)")
        try package.edit { try $0.setMuted(false, tracks: ["m"]) }
        let refused = try await package.run("export-stems", "PKG", "--out", out("refused").path)
        #expect(refused.status == 2 && refused.stderr.contains("gone.wav") && !refused.stderr.contains("Warning"))
        #expect(!items(package.folder).contains("refused"))
        let allowed = try await package.run("export-stems", "PKG", "--out", out("allowed").path, "--allow-missing")
        #expect(allowed.status == 0 && allowed.stderr.contains("Warning: file gone"), "\(allowed)")
        #expect(items(out("allowed")).count == 5)
    }

    /// C15: a stem over 0 dBFS gets one warning line, and the mix line follows.
    @Test func aStemOverFullScaleGivesAWarningLine() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for (index, value) in [Float(0), 1.5, -0.5, 0].enumerated() { buffer.floatChannelData![0][index] = value }
        do {
            let file = try AVAudioFile(
                forWriting: package.url.appending(path: "Clips/loud.wav"), settings: format.settings)
            try file.write(from: buffer)
        }
        try package.edit { session in
            try session.addFile(AudioFile(id: "loud", path: "loud.wav", layout: .mono, length: 4))
            try session.addTrack("l", name: "Loud", layout: .mono)
            try session.place(Clip(id: "cl", file: "loud", start: 0, offset: 0, length: 4), on: "l")
        }
        let result = try await package.run(
            "export-stems", "PKG", "--out", out("loud").path, "--track", "l", "--track", "h", "--to", "4")
        #expect(result.status == 0, "\(result)")
        #expect(
            result.stderr.hasPrefix("Warning: 02 Loud.wav is over 0 dBFS (peak +")
                && result.stderr.contains("Warning: the mix of the stems is over 0 dBFS"), "\(result.stderr)")
        #expect(!result.stderr.contains("01 Host.wav is over"))
    }
}
