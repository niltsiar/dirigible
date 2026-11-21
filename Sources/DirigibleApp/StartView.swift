import AppKit
import SwiftUI

/// The content of the start window (decision 0027), in the Xcode layout: the app and the New
/// Session form on the left, the recent sessions on the right. It reads `StartModel` and calls
/// it, with no logic of its own.
struct StartView: View {
    let model: StartModel
    @FocusState private var focus: StartField?

    var body: some View {
        VStack(spacing: 0) {
            if let app = model.noticeApp {
                // The window has a fixed width: the text wraps at it and the row grows.
                UncleanNoticeBanner(app: app).frame(width: 700).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 0) {
                welcome
                Divider()
                recent
            }
            .frame(width: 700, height: 420)
        }
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
            // Only with a template in Templates/ (decision 0079).
            if model.showsTemplates { templatePicker }
            if let progress = model.createProgress { copying(progress) } else { folderRow }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The Template pop-up: None, each template by name, and Show Templates in Finder.
    private var templatePicker: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.sessionTemplateLabel.key)
            Picker(
                selection: Binding(get: { model.templateChoice }, set: { model.choose($0) }),
                content: {
                    Text(L10n.sessionTemplateNone.key).tag(StartModel.TemplateChoice.none)
                    ForEach(model.templates, id: \.self) { url in
                        Text(verbatim: url.deletingPathExtension().lastPathComponent)
                            .tag(StartModel.TemplateChoice.template(url))
                    }
                    Divider()
                    Text(L10n.sessionTemplateShowFinder.key).tag(StartModel.TemplateChoice.showInFinder)
                },
                label: { Text(L10n.sessionTemplateLabel.key) }
            )
            .labelsHidden().id(model.popUpRefresh).disabled(model.creating)
        }
    }

    /// The bar and Cancel of a template create while its copy runs (T19).
    private func copying(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.startTemplateCopying.key).font(.callout).foregroundStyle(.secondary)
            HStack {
                ProgressView(value: progress)
                Button(L10n.alertCancel.text) { model.cancelCreate() }.disabled(!model.canCancelCreate)
            }
        }
    }

    // Change… and Create are one stack of one width, beside the folder and the hint (P5).
    private var folderRow: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.startFolder.format(model.folderText), systemImage: "folder").font(.callout)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(L10n.startHint.key).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Button {
                    model.changeFolder()
                } label: {
                    Text(L10n.startChange.key).frame(maxWidth: .infinity)
                }
                .disabled(model.creating)
                Button {
                    model.create()
                } label: {
                    Text(L10n.startCreate.key).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).disabled(model.creating || model.refusal != nil)
            }
            .fixedSize()
        }
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
