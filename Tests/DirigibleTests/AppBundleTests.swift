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

    @Test func permissionTextsAreTranslatedInEachLanguage() throws {
        let plist = try propertyList(at: "Contents/Info.plist")
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(plist["CFBundleLocalizations"] as? [String] == AppLanguage.allCases.map(\.rawValue))
        #expect(
            plist["NSMicrophoneUsageDescription"] as? String
                == "Dirigible records audio from your microphones and audio interfaces.")

        // A12: the System Audio Recording prompt of an app track (decision 0030).
        #expect(
            plist["NSAudioCaptureUsageDescription"] as? String
                == "Dirigible records the sound of the apps that you pick as track sources, for example a call.")

        let spanish = try propertyList(at: "Contents/Resources/es.lproj/InfoPlist.strings")
        #expect(
            spanish["NSMicrophoneUsageDescription"] as? String
                == "Dirigible graba el audio de tus micrófonos e interfaces de audio.")
        #expect(
            spanish["NSAudioCaptureUsageDescription"] as? String
                == "Dirigible graba el sonido de las apps que eliges como fuente de una pista, por ejemplo una llamada."
        )

        let english = [
            "NSMicrophoneUsageDescription": plist["NSMicrophoneUsageDescription"] as? String,
            "NSAudioCaptureUsageDescription": plist["NSAudioCaptureUsageDescription"] as? String,
            "Dirigible Session": "Dirigible Session",
        ]
        for language in AppLanguage.allCases.map(\.rawValue) where language != "en" {
            let table = try propertyList(at: "Contents/Resources/\(language).lproj/InfoPlist.strings")
            for (key, value) in english {
                let text = table[key] as? String ?? ""
                #expect(!text.isEmpty, "\(language) \(key) has no text")
                #expect(text != value, "\(language) \(key) is the English text")
            }
        }
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
    @Test func uiStringsResolveInEachLanguage() throws {
        let bundle = try #require(Bundle(url: app))
        #expect(Set(bundle.localizations).isSuperset(of: AppLanguage.allCases.map(\.rawValue)))
        let spanish = try propertyList(at: "Contents/Resources/es.lproj/Localizable.strings")
        let english = try propertyList(at: "Contents/Resources/en.lproj/Localizable.strings")
        let record = ["de": "Aufnehmen", "en": "Record", "es": "Grabar", "fr": "Enregistrer", "it": "Registra"]
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try propertyList(at: "Contents/Resources/\(language).lproj/Localizable.strings")
            #expect(table["menu.record.start"] as? String == record[language], "\(language) menu.record.start")
        }
        // App sources (A7, A9, A14, A15).
        let texts: [(key: String, en: String, es: String)] = [
            ("track.state.waiting.app", "Waiting for %@", "Esperando a %@"),
            (
                "track.state.no.sound",
                // The pane name differs on macOS 14 and 15, so the text names the button, not the pane.
                "No sound from %1$@. If %1$@ plays sound, click Privacy… and allow Dirigible to record system audio.",
                "No hay sonido de %1$@. Si %1$@ reproduce sonido, haz clic en Privacidad… y permite que Dirigible "
                    + "grabe el audio del sistema."
            ),
            ("track.no.sound.settings", "Open Privacy Settings", "Abrir los ajustes de privacidad"),
            // The short title of the header button; the full name above is its help and AX label.
            ("track.no.sound.privacy", "Privacy…", "Privacidad…"),
            ("track.route.apps", "Apps", "Apps"),
            // Run 1b of the record monitor (A27): the meter item does not say "monitor".
            ("menu.record.monitor", "Input Levels", "Niveles de entrada"),
            ("toolbar.monitor", "Levels", "Niveles"),
            (
                "track.state.retry.stopped", "Stopped retrying. Turn Input Levels off and on.",
                "Se dejó de reintentar. Reinicia Niveles de entrada."
            ),
            // Code gate round 1, item 1: the loopback text of a header row.
            (
                "track.listen.loopback",
                "No monitor sound: the output can feed this input. Choose another output.",
                "Sin sonido de monitor: la salida puede llegar a esta entrada. Elige otra salida."
            ),
            // B9: the Monitor button of a header row.
            ("track.monitor.label", "Monitor %@", "Monitorizar %@"),
            (
                "track.monitor.help",
                "Monitor Track (%@): hear the input in your headphones. Option-click: all device tracks.",
                "Monitorizar pista (%@): oye la entrada en los auriculares. Opción-clic: todas las pistas de dispositivo."
            ),
            ("track.route.apps.unavailable", "Needs macOS 14.2 or later", "Necesita macOS 14.2 o posterior"),
            // MP3 run criterion 14.
            ("panel.export.format.mp3", "MP3", "MP3"),
            // Beta fixes criterion V5.
            ("menu.app.about", "About Dirigible", "Acerca de Dirigible"),
            (
                "error.export.rate", "This format cannot be exported at %lld Hz. Select 44.1 kHz or 48 kHz.",
                "Este formato no se puede exportar a %lld Hz. Elige 44,1 kHz o 48 kHz."
            ),
        ]
        for text in texts {
            #expect(english[text.key] as? String == text.en, "en \(text.key)")
            #expect(spanish[text.key] as? String == text.es, "es \(text.key)")
        }
    }

    @Test func binaryRunsOnSonomaOnIntelAndAppleSilicon() throws {
        try expectUniversalForSonoma(executable)
    }

    /// The dirigible tool is in Contents/Helpers: `dirigible` and `Dirigible` are one file on a
    /// volume that ignores case (decision 0011).
    @Test func macOSFolderHoldsOnlyTheApp() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: app.appending(path: "Contents/MacOS").path)
        #expect(names == ["Dirigible"])
    }

    @Test func bundleSignatureIsValid() throws {
        _ = try run("/usr/bin/codesign", "--verify", "--strict", "--deep", app.path)
    }

    /// The dirigible tool of a DMG user (decision 0011): universal, signed with its own
    /// identifier, with no `@rpath/` library. It runs through a symbolic link with no file next
    /// to it, takes the package lock of an edit, and answers an MCP `initialize`.
    @Test func helperToolIsUniversalSignedAndRuns() throws {
        let helper = app.appending(path: "Contents/Helpers/dirigible").path
        try expectUniversalForSonoma(helper)
        #expect(try run("/usr/bin/codesign", "-dv", helper).contains("Identifier=com.delineas.dirigible.cli"))
        #expect(try !run("/usr/bin/otool", "-L", helper).contains("@rpath/"))

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appending(path: "bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "bin/dirigible").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: helper)
        let session = folder.appending(path: "S.dirigible").path
        _ = try run(link, "--help")
        _ = try run(link, "create", session, "--sample-rate", "48000")
        _ = try run(link, "track", "add", session, "--name", "A", "--layout", "mono")
        _ = try run(link, "info", session)
        let plist = try propertyList(at: "Contents/Info.plist")
        let version = plist["CFBundleShortVersionString"] as? String
        #expect(try run(link, "--version") == version, "the tool has the app version")

        let initialize =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","#
            + #""capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        let answer = try run(link, "mcp", input: initialize + "\n")
        #expect(answer.contains(#""id":1"#) && answer.contains("serverInfo"), "initialize answer: \(answer)")
    }

    private func expectUniversalForSonoma(_ binary: String) throws {
        #expect(try run("/usr/bin/lipo", "-archs", binary).split(separator: " ").sorted() == ["arm64", "x86_64"])

        let minimums = try run("/usr/bin/vtool", "-show-build", binary)
            .split(separator: "\n").filter { $0.contains("minos") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(minimums == ["minos 14.0", "minos 14.0"], "\(binary)")
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

    /// The agent skill (decision 0051): `skill show` of the helper wrote it before the signature,
    /// and `skill path` of the helper names it.
    @Test func theBundleHasTheSkill() throws {
        let helper = app.appending(path: "Contents/Helpers/dirigible").path
        let skill = app.appending(path: "Contents/Resources/skills/dirigible/SKILL.md")
        let text = try String(contentsOf: skill, encoding: .utf8)
        // run() trims the output, and the skill text ends in one newline.
        #expect(text == (try run(helper, "skill", "show")) + "\n", "SKILL.md differs from skill show")
        #expect(text.hasPrefix("---\nname: dirigible\n"))
        let real = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
        #expect(try run(helper, "skill", "path") == real(skill))
        _ = try run("/usr/bin/codesign", "--verify", "--strict", "--deep", app.path)
    }

    /// The user guide: an HTML page that `scripts/guide-html.swift` makes from `docs/guide.md`.
    /// Each image resolves to a file in `Guide/images/`, and each anchor link names a heading id.
    @Test func theGuideIsInTheBundleWithItsImages() throws {
        // make test-dmg reads the app under /var, a link to /private/var: compare real paths.
        let real = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
        let guide = app.appending(path: "Contents/Resources/Guide/guide.html")
        #expect(real(AppDelegate.guideURL(in: try #require(Bundle(url: app)))) == real(guide), "Help opens this file")
        let html = try String(contentsOf: guide, encoding: .utf8)
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("<h1 id=\"dirigible-user-guide\">Dirigible user guide</h1>"))
        #expect(html.contains("<table>"))

        let images = real(guide.deletingLastPathComponent().appending(path: "images")) + "/"
        let sources = html.matches(of: #/src="([^"]+)"/#).map { String($0.1) }
        #expect(!sources.isEmpty, "the guide shows an image")
        for source in sources {
            let file = real(try #require(URL(string: source, relativeTo: guide)))
            #expect(file.hasPrefix(images), "src \(source) is outside Guide/images/")
            #expect(FileManager.default.fileExists(atPath: file), "src \(source) names no file")
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

    /// The app links LAME statically, so the bundle holds the LGPL text and a LAME notice
    /// (decisions 0007 and 0034). The notice names the commit of the source of this build.
    @Test func theLAMELicenseIsInTheBundle() throws {
        let resources = app.appending(path: "Contents/Resources")
        let license = try String(contentsOf: resources.appending(path: "LAME-COPYING.txt"), encoding: .utf8)
        #expect(license.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("GNU LIBRARY GENERAL PUBLIC LICENSE"))
        let notice = try String(contentsOf: resources.appending(path: "LAME-NOTICE.txt"), encoding: .utf8)
        for text in ["LAME 4.0", "LGPL", "https://github.com/niltsiar/dirigible"] {
            #expect(notice.contains(text), "the notice names \(text)")
        }
        #expect(notice.contains(#/Source commit: [0-9a-f]{40}/#), "the notice names the source commit")
    }

    /// Criteria V1 and V2: `CFBundleVersion` stays 1, because Launch Services opens a session
    /// package in the registered copy with the highest value. `DirigibleCommit` holds the short
    /// hash of the source, with `-dirty` when the notice says that the tree had changes. In a git
    /// work tree, the hash is also the hash of HEAD. `CFBundleShortVersionString` is the output of
    /// `scripts/version.sh` (the nearest annotated version tag), with the same dirty mark.
    @Test func theBundleNamesItsSourceCommit() throws {
        let plist = try propertyList(at: "Contents/Info.plist")
        #expect(plist["CFBundleVersion"] as? String == "1")
        let commit = try #require(plist["DirigibleCommit"] as? String)
        let value = try #require(commit.wholeMatch(of: #/([0-9a-f]{7,40})(-dirty)?/#), "DirigibleCommit is \(commit)")
        let notice = try String(
            contentsOf: app.appending(path: "Contents/Resources/LAME-NOTICE.txt"), encoding: .utf8)
        let source = try #require(notice.firstMatch(of: #/Source commit: ([0-9a-f]{40})(, with uncommitted changes)?/#))
        #expect(source.1.hasPrefix(value.1), "the notice has \(source.1)")
        #expect((value.2 != nil) == (source.2 != nil), "the dirty mark of \(commit) and of the notice")
        let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        if let head = try? run("/usr/bin/git", "-C", repo.path, "rev-parse", "HEAD") {
            #expect(head.hasPrefix(value.1), "HEAD is \(head)")
        }
        let version = try #require(plist["CFBundleShortVersionString"] as? String)
        let tagged = try run(repo.appending(path: "scripts/version.sh").path, repo.path)
        #expect(version == tagged + (value.2 == nil ? "" : "-dirty"), "the version is \(version), the tag \(tagged)")
    }

    private func propertyList(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appending(path: path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }
}

/// Runs a tool and returns its trimmed output. A nonzero exit throws `ToolFailure`. The tool
/// reads `input` on stdin, and then the end of stdin.
func run(_ tool: String, _ arguments: String..., input: String = "") throws -> String {
    let process = Process()
    let output = Pipe()
    let stdin = Pipe()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = output
    try process.run()
    if !input.isEmpty {
        // A tool that exits before it reads must fail on its exit status, not kill the test
        // process with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    }
    try stdin.fileHandleForWriting.close()
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
