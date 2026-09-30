import AppKit
import SwiftUI

/// The content of the start window (decision 0027), in the Xcode layout: the app and the New
/// Session form. It reads `StartModel` and calls it, with no logic of its own.
struct StartView: View {
    let model: StartModel
    @FocusState private var focus: StartField?

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text(L10n.startTitle.key)
                .font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.startVersion.format(Self.version)).foregroundStyle(.secondary).padding(.top, 2)
            Spacer(minLength: 16)
            newSession
            Spacer(minLength: 16)
            Button(L10n.startOpenOther.key) { model.openOther() }.buttonStyle(.link).disabled(model.creating)
        }
        .padding(.horizontal, 40).padding(.top, 36).padding(.bottom, 20)
        .frame(width: 640, height: 420)
        .onAppear { focus = model.focus }
        .onChange(of: model.focus) { focus = model.focus }
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
            Label(L10n.startFolder.format(model.folderText), systemImage: "folder")
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(alignment: .top, spacing: 16) {
                Text(L10n.startHint.key).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    model.create()
                } label: {
                    Text(L10n.startCreate.key).frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.creating)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    /// The test runner has no app version.
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
