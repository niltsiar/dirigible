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

    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.path).filter { $0.hasSuffix(".tmp") }
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
    @Test func exportWritesEachFormat() throws {
        let clean = CLIResult(status: 0, stdout: "", stderr: "")
        #expect(try package.run("export", "PKG", "--out", out("a.wav").path, "--bits", "16") == clean)
        #expect(try package.run("export", "PKG", "--out", out("b.flac").path) == clean)
        #expect(
            try package.run(
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
    @Test func exportOfASelection() throws {
        let clean = CLIResult(status: 0, stdout: "", stderr: "")
        let range = ["--from", "1000", "--to", "5000"]

        #expect(
            try package.run(["export", "PKG", "--out", out("both.wav").path, "--track", "t1", "--track", "t2"] + range)
                == clean)
        #expect(try package.run(["export", "PKG", "--out", out("t2.wav").path, "--track", "t2"] + range) == clean)

        #expect(try facts(out("both.wav")).frames == 4000)
        #expect(try peak(out("both.wav")) > 0.4)
        #expect(try peak(out("t2.wav")) == 0)
    }

    /// Criterion 31: a usage error gives exit 64 and no file.
    @Test(arguments: [
        ["--out", "x.mp3"], ["--out", "x.m4a", "--bits", "16"], ["--out", "x.wav", "--bitrate", "96"],
        ["--out", "x.m4a", "--bitrate", "320"], ["--out", "x.wav", "--rate", "32000"],
        ["--out", "x.wav", "--track", "t9"], ["--out", "x.wav", "--from", "5000", "--to", "5000"],
    ])
    func exportRefusals(arguments: [String]) throws {
        let name = try #require(arguments.firstIndex(of: "--out")).advanced(by: 1)
        var arguments = arguments
        arguments[name] = out(arguments[name]).path

        let result = try package.run(["export", "PKG"] + arguments)

        #expect(result.status == 64, "\(result)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: package.folder.path) == ["Show.dirigible"])
    }

    /// Criterion 31: an existing output stays, unless `--replace`.
    @Test func exportReplace() throws {
        let target = out("mix.wav")
        let bytes = Data("keep".utf8)
        try bytes.write(to: target)

        let refused = try package.run("export", "PKG", "--out", target.path)

        #expect(refused == CLIResult(status: 2, stdout: "", stderr: "Error: \(target.path) exists.\n"))
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try package.run("export", "PKG", "--out", target.path, "--replace").status == 0)
        #expect(try facts(target).frames == 21_000)
        #expect(try temporaryFiles() == [])
    }

    /// Criterion 32: a file with a fault in the range gives exit 2 with its path and no file. A
    /// missing file outside the range does not count. `--allow-missing` exports and warns.
    @Test func exportMissingMedia() throws {
        try package.edit { session in
            try session.place(Clip(id: "c2", file: "gone", start: 0, offset: 0, length: 20_000), on: "t2")
        }
        let target = out("mix.wav")

        let refused = try package.run("export", "PKG", "--out", target.path)

        #expect(refused.status == 2 && refused.stdout == "")
        #expect(
            refused.stderr
                == "Error: file gone \"gone.wav\" is missing. Use --allow-missing to export its clips as silence.\n")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(
            try package.run("export", "PKG", "--out", target.path, "--from", "20000")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        try FileManager.default.removeItem(at: target)
        let allowed = try package.run("export", "PKG", "--out", target.path, "--allow-missing")
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
    @Test func aFaultThatOnlyTheExportFindsFailsIt() throws {
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

        let failed = try package.run("export", "PKG", "--out", target.path)

        #expect(
            failed
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: file bad \"bad.caf\" cannot be read; its clips in \(target.path) are silence. "
                        + "Use --allow-missing to accept it.\n"))
        #expect(try facts(target).frames == 21_000)
        #expect(
            try package.run("export", "PKG", "--out", out("allowed.wav").path, "--allow-missing")
                == CLIResult(
                    status: 0, stdout: "",
                    stderr: "Warning: file bad \"bad.caf\" cannot be read; its clips render as silence.\n"))
    }

    /// Criterion 31: AAC takes 48 kHz at most (probe P5). A 96 kHz session exports AAC with
    /// `--rate 48000`.
    @Test func exportAACInA96kHzSession() throws {
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

        let refused = try package.run("export", "PKG", "--out", target.path)

        #expect(
            refused
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot write \(target.path) at 96000 Hz. Use --rate 44100 or --rate 48000.\n"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try package.run("export", "PKG", "--out", target.path, "--rate", "48000").status == 0)
        #expect(try facts(target).rate == 48_000)
    }
}
