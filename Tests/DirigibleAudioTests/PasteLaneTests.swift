import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C9 (run `2026-10-28-favorites-bins`): a paste of the same package gives each lane with no target
/// track a new last track, named after the lane, with its layout. Tracks: Host (mono, clip "h"),
/// Guest (stereo, clip "g"), and Music (mono, no clip).
struct PasteLaneTests {
    let package: MixPackage
    let identity: PackageID?

    init() throws {
        package = try MixPackage()
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        identity = PackageID(lockFileOf: package.url)
        try package.session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 96_000))
        try package.session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .stereo, length: 96_000))
        try package.session.addTrack("host", name: "Host", layout: .mono)
        try package.session.place(Clip(id: "h", file: "f1", start: 0, offset: 0, length: 48_000), on: "host")
        try package.session.addTrack("guest", name: "Guest", layout: .stereo)
        try package.session.place(Clip(id: "g", file: "f2", start: 0, offset: 0, length: 48_000), on: "guest")
        try package.session.addTrack("music", name: "Music", layout: .mono)
    }

    func paste(_ excerpt: Excerpt, into session: Session, on target: PasteTarget) throws(PasteError)
        -> (session: Session, clips: [ClipID], tracks: [TrackID])
    {
        try pasteClipboard(
            Clipboard(excerpt, package: package.url, origin: identity), from: package.url, into: session,
            in: package.url, identity: identity, mode: .over(at: 96_000), on: target, freeBytes: { 0 })
    }

    @Test func missingLaneMakesTrack() throws {
        let excerpt = try package.session.excerpt(of: 0..<48_000, on: ["host", "guest"])

        // Case a: no selected track, and the source track of the Guest lane is gone.
        var gone = package.session
        try gone.removeTrack("guest")
        let a = try paste(excerpt, into: gone, on: .unselected)
        let aNew = try #require(a.session.tracks.last)
        #expect(a.tracks == ["host", aNew.id])
        #expect(a.session.tracks.map(\.id) == ["host", "music", aNew.id])
        #expect(aNew.name == "Guest" && aNew.layout == .stereo)
        #expect(aNew.clips.map(\.start) == [96_000] && aNew.clips.map(\.file) == ["f2"])

        // Case b: the last track is the first target, so the Guest lane gets a new last track.
        let b = try paste(excerpt, into: package.session, on: .extending(["music"]))
        let bNew = try #require(b.session.tracks.last)
        #expect(b.tracks == ["music", bNew.id])
        #expect(b.session.tracks.map(\.id) == ["host", "guest", "music", bNew.id])
        #expect(bNew.name == "Guest" && bNew.layout == .stereo)
        #expect(b.session.track("music")?.clips.map(\.start) == [96_000])

        // Control: with a target for each lane, no track is added.
        let enough = try paste(excerpt, into: package.session, on: .extending(["host", "guest"]))
        #expect(enough.tracks == ["host", "guest"])
        #expect(enough.session.tracks.map(\.id) == package.session.tracks.map(\.id))

        // Case c: an exact list stays exact.
        #expect(throws: PasteError.session(.trackCount(2))) {
            try paste(excerpt, into: package.session, on: .tracks(["music"]))
        }
    }
}
