import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The media check of decisions 0003 and 0016 (timeline-playback criterion 4).
struct MediaTests {
    @Test func checkMediaNamesEachFault() throws {
        let package = try MixPackage()
        for id: FileID in ["whole", "gone", "short"] { try package.addFile(id, channels: [ramp(frames: 6000)]) }
        try package.addFile("rate", channels: [ramp(frames: 6000)], rate: 44_100)
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/gone.wav"))
        let real = try package.truncate("short", toBytes: 9000)
        let text = package.url.appending(path: "Clips/text.wav")
        try Data("not audio".utf8).write(to: text)
        try package.session.addFile(AudioFile(id: "text", path: "text.wav", layout: .mono, length: 6000))

        #expect(real > 0 && real < 6000)
        #expect(
            try checkMedia(package.session, package: package.url) == [
                "gone": .missing, "short": .short(Frames(real)), "text": .unreadable, "rate": .unreadable,
            ])
    }

    /// Plan gate 2 item 3: the stamp of the peak cache comes from the descriptor that the open
    /// read, in nanoseconds.
    @Test func openMediaGivesTheStampOfItsDescriptor() throws {
        let package = try MixPackage()
        try package.addFile("a", channels: [ramp(frames: 6000)])
        let clips = package.url.appending(path: "Clips")

        let opened = try openMedia(try #require(package.session.files["a"]), in: clips, rate: 48_000)

        var info = stat()
        #expect(stat(clips.appending(path: "a.wav").path, &info) == 0)
        #expect(
            opened.stamp
                == FileStamp(
                    size: Int64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec
                ))
        #expect(opened.stamp?.nanoseconds != 0)
        let gone = AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 6000)
        #expect(try openMedia(gone, in: clips, rate: 48_000).stamp == nil)
    }

    /// Mute and solo C2b: an export source skips the missing file of a muted track. The check
    /// with no source (the play and the open) still reports it.
    @Test func aMutedTrackWithAMissingFileHasNoFault() throws {
        let package = try MixPackage()
        for id: FileID in ["f1", "f2"] { try package.addFile(id, channels: [ramp(frames: 6000)]) }
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 6000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 6000)
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/f1.wav"))
        try package.session.setMuted(true, tracks: ["t1"])
        let source = try #require(ExportSource(range: 0..<6000))

        #expect(try checkMedia(package.session, package: package.url, source: source) == [:], "the export skips t1")
        #expect(try checkMedia(package.session, package: package.url) == ["f1": .missing], "the play still sees it")
    }

    /// C21: a pool file that is a FIFO is unreadable, and its open does not wait for a writer.
    @Test func aFIFOPoolFileIsUnreadableAtOnce() async throws {
        let package = try MixPackage()
        try package.addFile("whole", channels: [ramp(frames: 6000)])
        try package.session.addFile(AudioFile(id: "a", path: "a.wav", layout: .mono, length: 6000))
        let fifo = package.url.appending(path: "Clips/a.wav")
        try makeFIFO(at: fifo)
        let (session, url) = (package.session, package.url)

        let value = await valueWithNoWriter(of: fifo) {
            Result { () throws(POSIXError) in try checkMedia(session, package: url) }
        }
        let faults = try #require(value)

        #expect(faults == .success(["a": .unreadable]))
    }
}
