import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// A show template for the tests of `dirigible create --template` and the `template` argument of
/// `session_create` (T8, T13). It has track "t" with clip "c" of "used.wav" (a real WAV), the file
/// "spare" with its capture "k2" and no clip, a capture "orphan" that no file names, a transcript,
/// and an episode title. `Show.dirigible` is the template and `New.dirigible` is the target.
struct TemplateShow {
    let template: TemporaryPackage
    var target: URL { template.folder.appending(path: "New.dirigible") }

    init(pendingTake: Bool = false) throws {
        var session = Session(sampleRate: 44_100)
        for id in ["k1", "k2", "orphan"] {
            try session.addCapture(
                Capture(
                    id: CaptureID(id), deviceUID: "usb", deviceName: "USB", hostTimeNanos: 1, sampleTime: 0,
                    nominalSampleRate: 44_100, measuredSampleRate: 44_100, latency: 0))
        }
        try session.addFile(AudioFile(id: "used", path: "used.wav", layout: .mono, length: 44_100, capture: "k1"))
        try session.addFile(AudioFile(id: "spare", path: "spare.wav", layout: .mono, length: 44_100, capture: "k2"))
        try session.addTrack("t", name: "Host", layout: .mono)
        try session.place(Clip(id: "c", file: "used", start: 0, offset: 0, length: 44_100), on: "t")
        var episode = Episode()
        try episode.set(.title, text: "Episode 1")
        try episode.set(.show, text: "The Show")
        session.setEpisode(episode)
        let json = #"{"words":[{"word":"hello","start":0.1,"end":0.3}]}"#
        try session.importTranscript(try TranscriptFile(data: Data(json.utf8)), name: "t.json", track: "t", at: 0)
        if pendingTake {
            try session.setRecording(
                Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["t"]))
        }
        template = try TemporaryPackage(session)
        try Self.writeWAV(template.url.appending(path: "Clips/used.wav"))
        try Data(repeating: 7, count: 2_000).write(to: template.url.appending(path: "Clips/spare.wav"))
    }

    /// One second of a 440 Hz tone at 44.1 kHz, mono.
    static func writeWAV(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for i in 0..<44_100 { buffer.floatChannelData![0][i] = 0.25 * Float(sin(Double(i) * 0.0626)) }
        try file.write(from: buffer)
    }

    /// The names in the folder of the template: no staging folder or lock file stays.
    var folderNames: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: template.folder.path).sorted()) ?? []
    }

    /// The names under `Transcripts/` of the package at `url`.
    static func transcriptFiles(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "Transcripts").path)) ?? []
    }
}

/// `dirigible create --template` (decision 0079, T8 and T13).
struct CreateTemplateTests {
    @Test func createWithATemplateCopiesTheShow() async throws {
        let show = try TemplateShow()

        let result = try await dirigible("create", show.target.path, "--template", show.template.path)

        #expect(result == CLIResult(status: 0, stdout: "", stderr: ""))
        let new = try Session(contentsOf: show.target)
        #expect(new == (try Session(contentsOf: show.template.url).newEpisode().session))
        #expect(new.sampleRate == 44_100, "the rate of the template")
        #expect(new.episode.show?.text == "The Show" && new.episode.title == nil, "the show stays and the title goes")
        #expect(
            try Data(contentsOf: show.target.appending(path: "Clips/used.wav"))
                == Data(contentsOf: show.template.url.appending(path: "Clips/used.wav")))
        #expect(!FileManager.default.fileExists(atPath: show.target.appending(path: "Clips/spare.wav").path))
        #expect(show.folderNames == ["New.dirigible", "Show.dirigible"])
        let newInfo = try await dirigible("info", show.target.path, "--json", "--compact")
        let templateInfo = try await dirigible("info", show.template.path, "--json", "--compact")
        #expect(newInfo.status == 0 && newInfo.stdout == templateInfo.stdout)
    }

    @Test func templateAndSampleRateExitSixtyFour() async throws {
        let show = try TemplateShow()

        let result = try await dirigible(
            "create", show.target.path, "--template", show.template.path, "--sample-rate", "48000")

        #expect(result.status == 64, "\(result)")
        #expect(show.folderNames == ["Show.dirigible"])
    }

    @Test func noTemplateAndNoRateExitSixtyFour() async throws {
        let show = try TemplateShow()

        let result = try await dirigible("create", show.target.path)

        #expect(result.status == 64, "\(result)")
        #expect(show.folderNames == ["Show.dirigible"])
    }

    @Test func anExistingTargetExitsTwo() async throws {
        let show = try TemplateShow()
        try FileManager.default.createDirectory(at: show.target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: show.target.appending(path: "mine.txt"))

        let result = try await dirigible("create", show.target.path, "--template", show.template.path)

        #expect(result == CLIResult(status: 2, stdout: "", stderr: "Error: \(show.target.path) exists.\n"))
        #expect(try Data(contentsOf: show.target.appending(path: "mine.txt")) == Data("keep".utf8))
        #expect(show.folderNames == ["New.dirigible", "Show.dirigible"])
    }

    @Test func aPendingTakeTemplateExitsTwo() async throws {
        let show = try TemplateShow(pendingTake: true)

        let result = try await dirigible("create", show.target.path, "--template", show.template.path)

        #expect(result.status == 2 && result.stdout.isEmpty, "\(result)")
        #expect(errorText(result) == "\(show.template.path) has a take that is not finalized.", "\(result)")
        #expect(show.folderNames == ["Show.dirigible"])
    }

    @Test func aNewerTemplateExitsTwo() async throws {
        let show = try TemplateShow()
        let xml = show.template.sessionXML
        let text = try String(contentsOf: xml, encoding: .utf8).replacing(#/ version="\d+"/#, with: #" version="9999""#)
        try Data(text.utf8).write(to: xml)
        let before = try show.template.xml()

        let result = try await dirigible("create", show.target.path, "--template", show.template.path)

        #expect(result.status == 2 && result.stdout.isEmpty, "\(result)")
        #expect(errorText(result).contains("was made by a newer version of Dirigible"), "\(result)")
        #expect(try show.template.xml() == before, "the template does not change")
        #expect(show.folderNames == ["Show.dirigible"])
    }

    @Test func theCommandDropsTheTranscript() async throws {
        let show = try TemplateShow()
        #expect(TemplateShow.transcriptFiles(show.template.url).count == 1, "control: the template has a transcript")

        let result = try await dirigible("create", show.target.path, "--template", show.template.path)

        #expect(result.status == 0, "\(result)")
        #expect(TemplateShow.transcriptFiles(show.target).isEmpty)
        let new = try Session(contentsOf: show.target)
        #expect(new.words().isEmpty)
        #expect(new.captures.keys.map(\.rawValue) == ["k1"], "the unused file and the orphan capture are gone")
    }
}
