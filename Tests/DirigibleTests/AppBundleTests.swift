import Foundation
import Testing

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

    private func propertyList(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appending(path: path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    private func run(_ tool: String, _ arguments: String...) throws -> String {
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
}

struct ToolFailure: Error, CustomStringConvertible {
    let command: String
    let output: String
    var description: String { "\(command) failed: \(output)" }
}
