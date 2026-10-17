import AppKit
import SwiftUI

/// The sheet of Help > Report a Problem... (decision 0059): what the report holds and does not
/// hold, then Cancel and Save Report.... Return saves and Escape cancels. It has no check box:
/// the list of the groups only shows what is included.
struct ReportSheet: View {
    let answer: (Bool) -> Void
    @State private var showsGroups = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.reportTitle.key).font(.headline)
            Text(L10n.reportPrivacy.key).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showsGroups) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.groups, id: \.self) { group in
                        Text(group.key).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text(L10n.reportIncludedShow.key)
            }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { answer(false) }.keyboardShortcut(.cancelAction)
                Button(L10n.reportSave.key) { answer(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440)
    }

    static let groups: [L10n] = [
        .reportIncludedLogs, .reportIncludedCrashes, .reportIncludedDevices, .reportIncludedSummary,
    ]
}

/// The sheet of a collect that takes more than a moment: a labeled spinner and Cancel.
struct ReportProgressSheet: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small).accessibilityLabel(Text(L10n.reportProgress.key))
            Text(L10n.reportProgress.key)
            Spacer()
            Button(L10n.alertCancel.key, action: cancel).keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

/// The unclean-end notice in a banner row (decision 0059): Report a Problem... and Not Now.
struct UncleanNoticeBanner: View {
    let app: AppDelegate

    var body: some View {
        BannerRow(kind: .info, text: L10n.noticeUncleanText.text) {
            Button(L10n.menuHelpReport.key) { app.reportProblem() }
            Button(L10n.noticeUncleanLater.key) { app.uncleanNotice.dismiss() }
        }
    }
}

/// The windows of the report flow. A host window gets a sheet; with no host the sheet is a window
/// of its own, and the first one is app-modal.
@MainActor enum ReportWindows {
    /// Shows the report sheet and calls `done` with true for Save Report.... `done` runs after the
    /// sheet is gone, so a save panel can open at once.
    static func sheet(on host: NSWindow?, done: @escaping @MainActor (Bool) -> Void) {
        var saves = false
        let window = make()
        window.contentViewController = NSHostingController(
            rootView: ReportSheet { [weak window] choice in
                saves = choice
                guard let window else { return }
                if let host { host.endSheet(window) } else { NSApp.stopModal() }
            })
        if let host {
            host.beginSheet(window) { _ in done(saves) }
        } else {
            window.title = L10n.reportTitle.text
            window.center()
            NSApp.runModal(for: window)
            window.orderOut(nil)
            done(saves)
        }
    }

    /// Shows the progress sheet and returns the call that hides it.
    static func progress(on host: NSWindow?, cancel: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let window = make()
        window.contentViewController = NSHostingController(rootView: ReportProgressSheet(cancel: cancel))
        if let host {
            host.beginSheet(window)
            return { host.endSheet(window) }
        }
        window.title = L10n.reportTitle.text
        window.center()
        window.makeKeyAndOrderFront(nil)
        return { window.orderOut(nil) }
    }

    /// The save panel: the Desktop and the name `name`. It asks before it replaces a file.
    static func save(on host: NSWindow?, name: String, done: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = name
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.canCreateDirectories = true
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { done($0 == .OK ? panel.url : nil) }
        if let host {
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// The alert of a report that was not written: the folder and the cause.
    static func fail(on host: NSWindow?, folder: String, cause: String) {
        let alert = NSAlert()
        alert.messageText = L10n.reportErrorWrite.format(folder, cause)
        if let host { alert.beginSheetModal(for: host) } else { alert.runModal() }
    }

    private static func make() -> NSWindow {
        let window = NSWindow()
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        return window
    }
}
