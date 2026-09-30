import AppKit
import SwiftUI

/// The content of the start window (decision 0027).
struct StartView: View {
    let openOther: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(L10n.startTitle.key).font(.title)
            Text(L10n.startVersion.format(Self.version)).foregroundStyle(.secondary)
            Button(L10n.startOpenOther.key, action: openOther)
        }
        .frame(width: 640, height: 400)
    }

    /// The test runner has no app version.
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
