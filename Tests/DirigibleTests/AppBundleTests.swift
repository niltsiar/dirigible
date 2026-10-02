import Foundation
import Testing

@testable import DirigibleApp

/// Checks the app bundle that `scripts/bundle.sh` builds. `make test-app` builds the bundle
/// and sets `DIRIGIBLE_APP` to its path, so these tests never read a stale bundle.
/// Without the variable they fail: `make test` skips this suite by name instead.
struct AppBundleTests {
    let app: URL

    init() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DIRIGIBLE_APP"], "Run through make test-app")
        app = URL(filePath: path)
    }

    var executable: String { app.appending(path: "Contents/MacOS/Dirigible").path }

    @Test func infoPlistDeclaresSonomaAndMicrophoneUse() throws {
        let plist = try propertyList(at: "Contents/Info.plist")

        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(plist["CFBundleExecutable"] as? String == "Dirigible")
        #expect(
            plist["CFBundleIdentifier"] as? String == "com.delineas.dirigible",
            "the bundle ID is com.delineas.dirigible")
        let micReason = try #require(plist["NSMicrophoneUsageDescription"] as? String)
        #expect(!micReason.isEmpty)
    }

    @Test func permissionTextsAreInEnglishWithSpanishTranslation() throws {
        let plist = try propertyList(at: "Contents/Info.plist")
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(plist["CFBundleLocalizations"] as? [String] == ["en", "es"])
        #expect(
            plist["NSMicrophoneUsageDescription"] as? String
                == "Dirigible records audio from your microphones and audio interfaces.")

        let spanish = try propertyList(at: "Contents/Resources/es.lproj/InfoPlist.strings")
        #expect(
            spanish["NSMicrophoneUsageDescription"] as? String
                == "Dirigible graba el audio de tus micrófonos e interfaces de audio.")
    }

    /// A session is a document package (decision 0003): Finder shows it as one file.
    @Test func sessionIsAPackageDocumentWithASpanishName() throws {
        let plist = try propertyList(at: "Contents/Info.plist")

        let types = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types[0]["UTTypeIdentifier"] as? String == "com.delineas.dirigible.session")
        #expect(types[0]["UTTypeDescription"] as? String == "Dirigible Session")
        #expect(types[0]["UTTypeConformsTo"] as? [String] == ["com.apple.package", "public.composite-content"])
        let tags = try #require(types[0]["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["dirigible"])

        let documents = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(documents.count == 1)
        #expect(documents[0]["CFBundleTypeName"] as? String == "Dirigible Session")
        #expect(documents[0]["CFBundleTypeRole"] as? String == "Editor")
        #expect(documents[0]["LSHandlerRank"] as? String == "Owner")
        #expect(documents[0]["LSTypeIsPackage"] as? Bool == true)
        #expect(documents[0]["LSItemContentTypes"] as? [String] == ["com.delineas.dirigible.session"])

        let spanish = try propertyList(at: "Contents/Resources/es.lproj/InfoPlist.strings")
        #expect(spanish["Dirigible Session"] as? String == "Sesión de Dirigible")
    }

    /// The UI tables are in the bundle (decision 0010). The English table is the control: the
    /// same key gives a different value, so the Spanish value comes from `es.lproj`.
    @Test func uiStringsResolveInEnglishAndSpanish() throws {
        let bundle = try #require(Bundle(url: app))
        #expect(Set(bundle.localizations).isSuperset(of: ["en", "es"]))
        let spanish = try propertyList(at: "Contents/Resources/es.lproj/Localizable.strings")
        let english = try propertyList(at: "Contents/Resources/en.lproj/Localizable.strings")
        #expect(spanish["menu.record.start"] as? String == "Grabar")
        #expect(english["menu.record.start"] as? String == "Record")
    }

    @Test func binaryRunsOnSonomaOnIntelAndAppleSilicon() throws {
        #expect(try run("/usr/bin/lipo", "-archs", executable).split(separator: " ").sorted() == ["arm64", "x86_64"])

        let minimums = try run("/usr/bin/vtool", "-show-build", executable)
            .split(separator: "\n").filter { $0.contains("minos") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(minimums == ["minos 14.0", "minos 14.0"])
    }

    /// The command-line tool is not in the bundle (decision 0011).
    @Test func bundleHoldsOneExecutable() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: app.appending(path: "Contents/MacOS").path)
        #expect(names == ["Dirigible"])
    }

    @Test func bundleSignatureIsValid() throws {
        _ = try run("/usr/bin/codesign", "--verify", "--strict", app.path)
    }

    /// The app icon (decision 0026): the bundle has the asset that the Info.plist names, at
    /// 1024 px, with the light, dark, and tinted appearance slots of macOS 26. actool writes
    /// these slots for any .icon, so this test does not prove the art of each look; the files of
    /// `make icon-preview` show it.
    @Test func appIconIsInTheBundleForSonomaAndLiquidGlass() throws {
        let plist = try propertyList(at: "Contents/Info.plist")
        let name = try #require(plist["CFBundleIconName"] as? String, "Info.plist names the AppIcon asset")
        #expect(name == "AppIcon", "Info.plist names the AppIcon asset")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon", "Info.plist names the AppIcon icns")

        let resources = app.appending(path: "Contents/Resources")
        let car = resources.appending(path: "Assets.car").path
        #expect(FileManager.default.fileExists(atPath: car), "the bundle has Assets.car")
        #expect(
            FileManager.default.fileExists(atPath: resources.appending(path: "AppIcon.icns").path),
            "the bundle has AppIcon.icns")

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let iconset = folder.appending(path: "x.iconset")
        _ = try run("/usr/bin/iconutil", "-c", "iconset", car, name, "-o", iconset.path)
        let largest = iconset.appending(path: "icon_512x512@2x.png").path
        let width = try run("/usr/bin/sips", "-g", "pixelWidth", largest)
            .split(separator: "\n").last?.split(separator: " ").last
        #expect(width == "1024", "Assets.car has the AppIcon asset at 1024 px")

        let info = try run("/usr/bin/assetutil", "--info", car)
        #expect(
            info.contains("NSAppearanceNameAqua") && info.contains("NSAppearanceNameDarkAqua")
                && info.contains("ISAppearanceTintable"),
            "Assets.car has the light, dark, and tinted appearance slots")
        #expect(info.contains("\"PlatformVersion\" : \"14.0\""), "Assets.car targets macOS 14.0")
    }

    /// The user guide: an HTML page that `scripts/guide-html.swift` makes from `docs/guide.md`.
    /// Each image resolves to a file in `Guide/images/`, and each anchor link names a heading id.
    @Test func theGuideIsInTheBundleWithItsImages() throws {
        let guide = app.appending(path: "Contents/Resources/Guide/guide.html")
        #expect(AppDelegate.guideURL(in: try #require(Bundle(url: app))).path == guide.path, "Help opens this file")
        let html = try String(contentsOf: guide, encoding: .utf8)
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("<h1 id=\"dirigible-user-guide\">Dirigible user guide</h1>"))
        #expect(html.contains("<table>"))

        let images = guide.deletingLastPathComponent().appending(path: "images").path + "/"
        let sources = html.matches(of: #/src="([^"]+)"/#).map { String($0.1) }
        #expect(!sources.isEmpty, "the guide shows an image")
        for source in sources {
            let file = try #require(URL(string: source, relativeTo: guide)).standardizedFileURL
            #expect(file.path.hasPrefix(images), "src \(source) is outside Guide/images/")
            #expect(FileManager.default.fileExists(atPath: file.path), "src \(source) names no file")
        }

        let ids = Set(html.matches(of: #/ id="([^"]+)"/#).map { String($0.1) })
        for link in html.matches(of: #/href="([^"]+)"/#).map({ String($0.1) }) {
            if link.hasPrefix("#") {
                #expect(ids.contains(String(link.dropFirst())), "no heading for \(link)")
            } else {
                #expect(link.hasPrefix("https://"), "the bundled guide cannot open \(link)")
            }
        }
    }

    private func propertyList(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appending(path: path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}

/// Runs a tool and returns its trimmed output. A nonzero exit throws `ToolFailure`.
func run(_ tool: String, _ arguments: String...) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
        throw ToolFailure(command: ([tool] + arguments).joined(separator: " "), output: text)
    }
    return text
}

struct ToolFailure: Error, CustomStringConvertible {
    let command: String
    let output: String
    var description: String { "\(command) failed: \(output)" }
}
