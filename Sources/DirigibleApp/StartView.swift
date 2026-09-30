import AppKit
import SwiftUI

/// The content of the start window (decision 0027), in the Xcode layout: the app and the New
/// Session form on the left, the recent sessions on the right. It reads `StartModel` and calls
/// it, with no logic of its own.
struct StartView: View {
    let model: StartModel
    @FocusState private var focus: StartField?

    var body: some View {
        HStack(spacing: 0) {
            welcome
            Divider()
            recent
        }
        .frame(width: 700, height: 420)
        .onAppear { focus = model.focus }
        .onChange(of: model.focus) { focus = model.focus }
        .onChange(of: model.name) { model.nameShown() }
        .onChange(of: focus) { if let focus { model.focusChanged(to: focus, by: NSApp.currentEvent) } }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text(L10n.startTitle.key)
                .font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.startVersion.format(Self.version)).foregroundStyle(.secondary).padding(.top, 2)
            Spacer(minLength: 16)
            newSession
        }
        .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 28)
        .frame(width: 420)
    }

    /// Create is not a default button: a default button takes Return before the recent list
    /// sees it (decision 0027). Return in the name field creates through `onSubmit`.
    private var newSession: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.startNew.key).font(.headline)
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.startName.key)
                TextField(L10n.startName.key, text: Binding(get: { model.name }, set: { model.edit($0) }))
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name).onSubmit { model.create() }
            }
            if let message = model.refusal?.message {
                Text(message.key).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Label(L10n.startFolder.format(model.folderText), systemImage: "folder")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(L10n.startChange.key) { model.changeFolder() }.controlSize(.small).disabled(model.creating)
            }
            .font(.callout)
            HStack(alignment: .top, spacing: 16) {
                Text(L10n.startHint.key).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.create()
                } label: {
                    Text(L10n.startCreate.key).frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.creating || model.refusal != nil)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Return in the list opens the selection through `onKeyPress` (macOS 14). It returns
    /// `.handled`, so the list does not also run the primary action for Return (M4 probe). The
    /// primary action opens a row at a double-click, and for each other input that runs it, with no
    /// event filter. A single click selects the row. A gesture on the row blocked that selection (M4).
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.startRecent.key).font(.headline).padding(.horizontal, 16).padding(.top, 16)
                .padding(.bottom, 6)
            // The list shows also with no rows, so the focus can go to it before the rows come.
            List(model.rows, selection: Binding(get: { model.selection }, set: { model.select($0) })) { row in
                RecentRowView(row: row)
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: URL.self) { _ in
            } primaryAction: { urls in
                guard let url = urls.first else { return }
                Task { await model.open(url) }
            }
            .focused($focus, equals: .list)
            .onKeyPress(.return) {
                model.openSelection()
                return .handled
            }
            .overlay {
                if model.rowsLoaded && model.rows.isEmpty {
                    Text(L10n.startRecentNone.key).foregroundStyle(.secondary)
                }
            }
            Divider()
            Button(L10n.startOpenOther.key) { model.openOther() }.disabled(model.creating).padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.secondary)
    }

    /// The test runner has no app version.
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// One recent session: the name and its folder, or "Not found", dimmed, for a package that the
/// check did not find. The row still opens.
private struct RecentRowView: View {
    let row: RecentRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Group {
                    if row.exists { Text(row.folder) } else { Text(L10n.startRecentMissing.key) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(row.exists ? 1 : 0.5)
    }
}
