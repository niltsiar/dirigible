import DirigibleAudio
import SwiftUI

/// The content of a session window. It reads `SessionWindow` and `Studio` and sends the actions
/// back; it keeps no copy of the take state.
struct SessionView: View {
    let model: SessionWindow

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 320)
            .alert(
                Text(verbatim: model.alert.map(\.text) ?? ""),
                isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
                presenting: model.alert
            ) { alert in
                switch alert {
                case .confirmStopAndClose:
                    Button(L10n.alertCloseRecordingConfirm.key, role: .destructive) { Task { await model.close() } }
                    Button(L10n.alertCancel.key, role: .cancel) {}
                case .confirmUnsavedClose:
                    Button(L10n.alertCloseUnsavedConfirm.key, role: .destructive) { model.closeAnyway() }
                    Button(L10n.alertCancel.key, role: .cancel) { model.cancelUnsavedClose() }
                case .error, .microphone:
                    Button(L10n.alertOK.key, role: .cancel) {}
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .opening:
            ProgressView(model.recovering ? L10n.windowRecovering.key : L10n.windowOpening.key)
        case .failed(let error):
            VStack(spacing: 12) {
                Text(verbatim: L10n.message(for: error))
                Button(L10n.windowTryAgain.key) { model.open(recovering: model.recovering) }
            }
        case .open(let studio), .closing(let studio?):
            Text(verbatim: studio.session.tracks.map(\.name).joined(separator: ", "))
        case .closing(nil), .closed:
            EmptyView()
        }
    }
}

extension WindowAlert {
    var text: String {
        switch self {
        case .error(let error): L10n.message(for: error)
        case .microphone(let access): L10n.message(for: .microphoneAccess(access))
        case .confirmStopAndClose: L10n.alertCloseRecording.text
        case .confirmUnsavedClose: L10n.alertCloseUnsaved.text
        }
    }
}
