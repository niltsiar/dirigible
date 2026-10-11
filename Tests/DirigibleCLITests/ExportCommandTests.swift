import AVFoundation
import AudioToolbox
import DirigibleCore
import Foundation
import Testing

/// `dirigible export` (export run criteria 31 and 32, decision 0019). The package of
/// `RenderCommandTests`: track `t1` with a ramp of `f1.wav` at frames 1000..<21 000; the session
/// ends at 21 000.
struct ExportCommandTests {
    let package: TemporaryPackage

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 20_000))
        try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 20_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 1000, offset: 0, length: 20_000), on: "t1")
        package = try TemporaryPackage(session)
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/f1.wav"), frames: 20_000)
    }

    func out(_ name: String) -> URL { package.folder.appending(path: name) }

    func temporaryFiles(in folder: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (folder ?? package.folder).path).filter {
            $0.hasSuffix(".tmp")
        }
    }

    /// The format ID, the channels, the rate, and the frames of an audio file.
    func facts(_ url: URL) throws -> (format: AudioFormatID, channels: UInt32, rate: Double, frames: Int64) {
        let file = try AVAudioFile(forReading: url)
        let description = file.fileFormat.streamDescription.pointee
        return (description.mFormatID, description.mChannelsPerFrame, description.mSampleRate, file.length)
    }

    /// The largest absolute sample of a file.
    func peak(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (0..<Int(buffer.format.channelCount)).flatMap { channel in
            UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))
        }.map(abs).max() ?? 0
    }

    /// Criterion 31: the extension gives the format, and the options apply.
    @Test func exportWritesEachFormat() async throws {
        let clean = CLIResult(status: 0, stdout: "", stderr: "")
        #expect(try await package.run("export", "PKG", "--out", out("a.wav").path, "--bits", "16") == clean)
        #expect(try await package.run("export", "PKG", "--out", out("b.flac").path) == clean)
        #expect(
            try await package.run(
                "export", "PKG", "--out", out("c.m4a").path, "--bitrate", "96", "--mono", "--rate", "44100") == clean)

        let wav = try facts(out("a.wav"))
        #expect(wav.format == kAudioFormatLinearPCM && wav.channels == 2 && wav.rate == 48_000 && wav.frames == 21_000)
        #expect(try AVAudioFile(forReading: out("a.wav")).fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        let flac = try facts(out("b.flac"))
        #expect(flac.format == kAudioFormatFLAC && flac.channels == 2 && flac.rate == 48_000 && flac.frames == 21_000)
        let aac = try facts(out("c.m4a"))
        #expect(aac.format == kAudioFormatMPEG4AAC && aac.channels == 1 && aac.rate == 44_100)
        #expect(abs(aac.frames - 19_294) <= 1, "\(aac.frames) frames")
        #expect(try temporaryFiles() == [])
    }

    /// Criterion 31: `--from`, `--to`, and `--track` give the source. Control: t2 has no clip, so
    /// an export of t2 alone is silence.
    @Test func exportOfASelection() async throws {
        let clean = CLIResult(status: 0, stdout: "", stderr: "")
        let range = ["--from", "1000", "--to", "5000"]

        #expect(
            try await package.run(
                ["export", "PKG", "--out", out("both.wav").path, "--track", "t1", "--track", "t2"] + range)
                == clean)
        #expect(
            try await package.run(["export", "PKG", "--out", out("t2.wav").path, "--track", "t2"] + range) == clean)

        #expect(try facts(out("both.wav")).frames == 4000)
        #expect(try peak(out("both.wav")) > 0.4)
        #expect(try peak(out("t2.wav")) == 0)
    }

    /// Criterion 31: a usage error gives exit 64 and no file.
    @Test(arguments: [
        ["--out", "x.ogg"], ["--out", "x.m4a", "--bits", "16"], ["--out", "x.wav", "--bitrate", "96"],
        ["--out", "x.mp3", "--bits", "16"], ["--out", "x.mp3", "--bitrate", "320"],
        ["--out", "x.m4a", "--bitrate", "320"], ["--out", "x.wav", "--rate", "32000"],
        ["--out", "x.wav", "--track", "t9"], ["--out", "x.wav", "--from", "5000", "--to", "5000"],
    ])
    func exportRefusals(arguments: [String]) async throws {
        let name = try #require(arguments.firstIndex(of: "--out")).advanced(by: 1)
        var arguments = arguments
        arguments[name] = out(arguments[name]).path

        let result = try await package.run(["export", "PKG"] + arguments)

        #expect(result.status == 64, "\(result)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.folder.path) == ["Show.dirigible"])
    }

    /// Criterion 31: an existing output stays, unless `--replace`.
    @Test func exportReplace() async throws {
        let target = out("mix.wav")
        let bytes = Data("keep".utf8)
        try bytes.write(to: target)

        let refused = try await package.run("export", "PKG", "--out", target.path)

        #expect(refused == CLIResult(status: 2, stdout: "", stderr: "Error: \(target.path) exists.\n"))
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try await package.run("export", "PKG", "--out", target.path, "--replace").status == 0)
        #expect(try facts(target).frames == 21_000)
        #expect(try temporaryFiles() == [])
    }

    /// Criterion 32: a file with a fault in the range gives exit 2 with its path and no file. A
    /// missing file outside the range does not count. `--allow-missing` exports and warns.
    @Test func exportMissingMedia() async throws {
        try package.edit { session in
            try session.place(Clip(id: "c2", file: "gone", start: 0, offset: 0, length: 20_000), on: "t2")
        }
        let target = out("mix.wav")

        let refused = try await package.run("export", "PKG", "--out", target.path)

        #expect(refused.status == 2 && refused.stdout == "")
        #expect(
            refused.stderr
                == "Error: file gone \"gone.wav\" is missing. Use --allow-missing to export its clips as silence.\n")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(
            try await package.run("export", "PKG", "--out", target.path, "--from", "20000")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        try FileManager.default.removeItem(at: target)
        let allowed = try await package.run("export", "PKG", "--out", target.path, "--allow-missing")
        #expect(
            allowed
                == CLIResult(
                    status: 0, stdout: "",
                    stderr: "Warning: file gone \"gone.wav\" is missing; its clips render as silence.\n"))
        #expect(try facts(target).frames == 21_000)
    }

    /// Code gate 1, item 5: a FLAC CAF with bad packets opens, so the media check finds it whole,
    /// but its read fails during the export (probe g1-corrupt). Exit 2 with its path; the output
    /// has its clips as silence. With `--allow-missing`: exit 0 and one warning line.
    @Test func aFaultThatOnlyTheExportFindsFailsIt() async throws {
        let bad = package.url.appending(path: "Clips/bad.caf")
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            ]
            let file = try AVAudioFile(forWriting: bad, settings: settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 20_000))
            buffer.frameLength = 20_000
            for i in 0..<20_000 { buffer.floatChannelData![0][i] = 0.5 * sin(Float(i) * 0.13) }
            try file.write(from: buffer)
        }
        var bytes = try Data(contentsOf: bad)
        bytes.replaceSubrange(bytes.count / 3..<bytes.count, with: Data(repeating: 0x5A, count: bytes.count * 2 / 3))
        try bytes.write(to: bad)
        try package.edit { session in
            try session.addFile(AudioFile(id: "bad", path: "bad.caf", layout: .mono, length: 20_000))
            try session.place(Clip(id: "c2", file: "bad", start: 0, offset: 0, length: 20_000), on: "t2")
        }
        let target = out("mix.wav")

        let failed = try await package.run("export", "PKG", "--out", target.path)

        #expect(
            failed
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: file bad \"bad.caf\" cannot be read; its clips in \(target.path) are silence. "
                        + "Use --allow-missing to accept it.\n"))
        #expect(try facts(target).frames == 21_000)
        #expect(
            try await package.run("export", "PKG", "--out", out("allowed.wav").path, "--allow-missing")
                == CLIResult(
                    status: 0, stdout: "",
                    stderr: "Warning: file bad \"bad.caf\" cannot be read; its clips render as silence.\n"))
    }

    /// Criterion 31: AAC takes 48 kHz at most (probe P5). A 96 kHz session exports AAC with
    /// `--rate 48000`. MP3 run criterion 13: MP3 refuses 96 kHz the same way.
    @Test func exportAACAndMP3InA96kHzSession() async throws {
        var session = Session(sampleRate: 96_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 9600))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 9600), on: "t1")
        let package = try TemporaryPackage(session)
        // The file closes at the end of the block, before the export reads it.
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 1))
            let file = try AVAudioFile(
                forWriting: package.url.appending(path: "Clips/f1.wav"), settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600))
            buffer.frameLength = 9600
            try file.write(from: buffer)
        }
        let target = package.folder.appending(path: "mix.m4a")

        let refused = try await package.run("export", "PKG", "--out", target.path)

        #expect(
            refused
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot write \(target.path) at 96000 Hz. Use --rate 44100 or --rate 48000.\n"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try await package.run("export", "PKG", "--out", target.path, "--rate", "48000").status == 0)
        #expect(try facts(target).rate == 48_000)
        let mp3 = package.folder.appending(path: "mix.mp3")
        #expect(
            try await package.run("export", "PKG", "--out", mp3.path)
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot write \(mp3.path) at 96000 Hz. Use --rate 44100 or --rate 48000.\n"))
        #expect(!FileManager.default.fileExists(atPath: mp3.path))
    }

    /// A package with a 4 s mono WAV at 48 kHz on track t1.
    static func fourSeconds() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 192_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 192_000), on: "t1")
        let package = try TemporaryPackage(session)
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/f1.wav"), frames: 192_000)
        return package
    }

    /// MP3 run criterion 13: `.mp3` with `--bitrate`, `--mono`, `--rate`, and `--loudness`.
    @Test func exportWritesMP3() async throws {
        let package = try Self.fourSeconds()
        let plain = package.folder.appending(path: "c.mp3")
        let loud = package.folder.appending(path: "d.mp3")

        let result = try await package.run(
            "export", "PKG", "--out", plain.path, "--bitrate", "64", "--mono", "--rate", "44100")
        let podcast = try await package.run("export", "PKG", "--out", loud.path, "--loudness", "podcast")

        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        let mp3 = try facts(plain)
        #expect(
            mp3.format == kAudioFormatMPEGLayer3 && mp3.channels == 1 && mp3.rate == 44_100 && mp3.frames == 176_400,
            "\(mp3)")
        #expect(podcast.status == 0 && podcast.stdout.hasPrefix("loudness "), "\(podcast)")
        #expect(try facts(loud).channels == 2)
    }

    /// MP3 run criterion 12: a write that the file size limit cuts short. The limit (in 1024-byte
    /// blocks of /bin/sh) is under the full size S, so the last write is partial and the next write
    /// gives EFBIG. SIGXFSZ is ignored, so the write returns -1 and the export exits 2.
    @Test func aShortMP3WriteFailsTheExport() async throws {
        let package = try Self.fourSeconds()
        let full = package.folder.appending(path: "full.mp3")
        #expect(try await package.run("export", "PKG", "--out", full.path).status == 0)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: full.path)[.size] as? Int)
        let target = package.folder.appending(path: "short.mp3")
        let binary = Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent().appending(
            path: "dirigible")

        let result = try await dirigible(
            shell: #"trap "" XFSZ; ulimit -f "$1"; exec "$2" export "$3" --out "$4""#, "sh", String((size - 1) / 1024),
            binary.path, package.path, target.path)

        #expect(result.status == 2 && result.stderr.contains("(status -40)"), "a short MP3 write gives \(result)")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try temporaryFiles(in: package.folder) == [])
    }

    /// Mute and solo C9 e: an export with an unheard track prints one warning line on stderr; the
    /// file and stdout do not change. An export of the heard tracks alone prints nothing.
    @Test func anExportWithAMutedTrackPrintsANote() async throws {
        try package.edit { try $0.setMuted(true, tracks: ["t2"]) }
        let one = "Warning: 1 track is muted or not soloed and is not in the export.\n"
        #expect(
            try await package.run("export", "PKG", "--out", out("a.wav").path)
                == CLIResult(status: 0, stdout: "", stderr: one))
        #expect(try peak(out("a.wav")) > 0.4, "t1 is in the file")
        #expect(
            try await package.run("export", "PKG", "--out", out("b.wav").path, "--track", "t1")
                == CLIResult(status: 0, stdout: "", stderr: ""), "the source has no unheard track")

        try package.edit { session in
            try session.addTrack("t3", name: "Music", layout: .mono)
            try session.setMuted(false, tracks: ["t2"])
            try session.setSoloed(true, tracks: ["t1"])
        }
        let two = "Warning: 2 tracks are muted or not soloed and are not in the export.\n"
        #expect(
            try await package.run("export", "PKG", "--out", out("c.wav").path)
                == CLIResult(status: 0, stdout: "", stderr: two))
    }

    /// C5f of run 2026-10-11-chapters-in-file. "C" starts at the millisecond of "B": the M4A
    /// leaves it out, and stderr names it.
    @Test func aDroppedChapterPrintsAWarning() async throws {
        try package.edit { session in
            try session.setMarker(Marker(id: "a", name: "A", position: 1_000, kind: .chapter))
            try session.setMarker(Marker(id: "b", name: "B", position: 5_000, kind: .chapter))
            try session.setMarker(Marker(id: "c", name: "C", position: 5_010, kind: .chapter))
        }
        #expect(
            try await package.run("export", "PKG", "--out", out("a.m4a").path)
                == CLIResult(
                    status: 0, stdout: "",
                    stderr:
                        "Warning: chapter \"C\" at 5010 starts at the time of another chapter; the file leaves it out.\n"
                ))
        let groups = try await AVURLAsset(url: out("a.m4a")).loadChapterMetadataGroups(
            withTitleLocale: Locale(identifier: "en"), containingItemsWithCommonKeys: [])
        #expect(groups.count == 3, "groups \(groups.count): the added chapter at 0, A, and B")
    }

    /// Mute and solo C9 e: with no heard track, the warning says that the file is silent.
    @Test func anExportWithNoHeardTrackPrintsTheSilentNote() async throws {
        try package.edit { try $0.setMuted(true, tracks: ["t1", "t2"]) }
        let silent = "Warning: no track is heard; the file is silent.\n"
        #expect(
            try await package.run("export", "PKG", "--out", out("a.wav").path)
                == CLIResult(status: 0, stdout: "", stderr: silent))
        #expect(try peak(out("a.wav")) == 0, "the file is silent")
    }

    /// C4, C5f: an MP3 export gets the chapters of the core list in its ID3 tag, with no added
    /// chapter at 0, and a warning for the chapter that it leaves out.
    @Test func anMP3GetsTheChapterTag() async throws {
        try package.edit { session in
            try session.setMarker(Marker(id: "a", name: "A", position: 1_000, kind: .chapter))
            try session.setMarker(Marker(id: "b", name: "B", position: 5_000, kind: .chapter))
            try session.setMarker(Marker(id: "c", name: "C", position: 5_000, kind: .chapter))
        }
        #expect(
            try await package.run("export", "PKG", "--out", out("a.mp3").path)
                == CLIResult(
                    status: 0, stdout: "",
                    stderr:
                        "Warning: chapter \"C\" at 5000 starts at the time of another chapter; the file leaves it out.\n"
                ))
        let bytes = [UInt8](try Data(contentsOf: out("a.mp3")).prefix(4_096))
        let hasTag = bytes.starts(with: Array("ID3".utf8))
        #expect(hasTag, "no ID3 tag")
        let chap = Array("CHAP".utf8)
        let count = (0..<(bytes.count - 4)).count { Array(bytes[$0..<($0 + 4)]) == chap }
        #expect(count == 2, "CHAP frames \(count)")
    }
}
