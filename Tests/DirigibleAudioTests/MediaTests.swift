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
            checkMedia(package.session, package: package.url) == [
                "gone": .missing, "short": .short(Frames(real)), "text": .unreadable, "rate": .unreadable,
            ])
    }
}
