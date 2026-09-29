import Foundation
import Testing

/// Checks the DMG that `scripts/dmg.sh` builds. `make test-dmg` mounts the DMG read-only and
/// sets `DIRIGIBLE_DMG` to the DMG and `DIRIGIBLE_APP` to the app in the mounted volume.
/// Without the variables they fail: `make test` skips this suite by name instead.
struct DiskImageTests {
    let dmg: URL
    let app: URL
    var root: URL { app.deletingLastPathComponent() }

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        dmg = URL(filePath: try #require(environment["DIRIGIBLE_DMG"], "Run through make test-dmg"))
        app = URL(filePath: try #require(environment["DIRIGIBLE_APP"], "Run through make test-dmg"))
    }

    @Test func fileNameHasTheAppVersion() throws {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let short = try #require(plist["CFBundleShortVersionString"] as? String)
        #expect(dmg.lastPathComponent == "Dirigible-\(short).dmg", "the DMG name has the app version")
    }

    @Test func imageIsUDZO() throws {
        #expect(try run("/usr/bin/hdiutil", "imageinfo", "-format", dmg.path) == "UDZO", "the DMG is UDZO")
    }

    @Test func rootHoldsTheAppAndAnApplicationsLink() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        #expect(names == ["Applications", "Dirigible.app"], "the root holds the app and an Applications link")
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: "Applications").path)
        #expect(link == "/Applications", "Applications links to /Applications")
    }

    @Test func volumeIsNamedDirigible() throws {
        let name = try root.resourceValues(forKeys: [.volumeNameKey]).volumeName
        #expect(name == "Dirigible", "the volume is named Dirigible")
    }

    /// Finder shows `.VolumeIcon.icns` when the root has the custom icon flag: bit 0x04 of
    /// byte 8 of the Finder info.
    @Test func volumeIconIsTheAppIcon() throws {
        let appIcon = try #require(
            FileManager.default.contents(atPath: app.appending(path: "Contents/Resources/AppIcon.icns").path),
            "the app has AppIcon.icns")
        #expect(
            FileManager.default.contents(atPath: root.appending(path: ".VolumeIcon.icns").path) == appIcon,
            "the volume icon is the app icon")

        var info = [UInt8](repeating: 0, count: 32)
        let size = getxattr(root.path, "com.apple.FinderInfo", &info, info.count, 0, 0)
        #expect(size == 32 && info[8] & 0x04 != 0, "the volume has the custom icon flag")
    }

    /// The app in the DMG is the ad-hoc build of `make dmg` in `build/dmg-app/`, not a copy
    /// with the signature of the developer.
    @Test func appIsTheBuiltAppWithAnAdHocSignature() throws {
        let built = dmg.deletingLastPathComponent().appending(path: "dmg-app/Dirigible.app")
        // codesign -d fails on an app with no signature. The asserts then fail with their messages.
        let copy = (try? run("/usr/bin/codesign", "-d", "--verbose=4", app.path)) ?? ""
        let original = try run("/usr/bin/codesign", "-d", "--verbose=4", built.path)
        let hash = { (text: String) in text.split(separator: "\n").filter { $0.hasPrefix("CDHash=") } }
        #expect(!hash(copy).isEmpty && hash(copy) == hash(original), "the app in the DMG is the built app")
        #expect(copy.contains("Signature=adhoc"), "the app in the DMG has an ad-hoc signature")
    }
}
