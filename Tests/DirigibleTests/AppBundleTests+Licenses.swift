import CryptoKit
import Foundation
import Testing

extension AppBundleTests {
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

    /// The app links whisper.cpp statically, so the bundle holds its MIT license, and the Silero
    /// VAD model of whisper.cpp ships as a resource (decision 0065). The model and the YaRN code
    /// in ggml each carry an MIT notice, so the bundle holds a license file for each.
    @Test func theWhisperLicenseAndTheVADModelAreInTheBundle() throws {
        let resources = app.appending(path: "Contents/Resources")
        let license = try String(contentsOf: resources.appending(path: "whisper.cpp-LICENSE.txt"), encoding: .utf8)
        #expect(license.hasPrefix("MIT License"))
        #expect(license.contains("Copyright (c) 2023-2026 The ggml authors"))
        let sileroLicense = try String(contentsOf: resources.appending(path: "silero-vad-LICENSE.txt"), encoding: .utf8)
        #expect(sileroLicense.hasPrefix("MIT License"))
        #expect(sileroLicense.contains("Copyright (c) 2020-present Silero Team"))
        let yarnLicense = try String(contentsOf: resources.appending(path: "yarn-LICENSE.txt"), encoding: .utf8)
        #expect(yarnLicense.hasPrefix("MIT License"))
        #expect(yarnLicense.contains("Copyright (c) 2023 Jeffrey Quesnelle and Bowen Peng"))
        let model = try Data(contentsOf: resources.appending(path: "ggml-silero-v6.2.0.bin"))
        #expect(model.count == 885_098)
        let hash = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")
    }
}
