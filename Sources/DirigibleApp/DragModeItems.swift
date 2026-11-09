import DirigibleTimeline
import SwiftUI

/// The items of Edit > Drag Mode: one checkmark item for each mode, with no key.
struct DragModeItems: View {
    let app: AppDelegate

    var body: some View {
        ForEach(DragMode.allCases, id: \.self) { mode in Toggle(mode.title.key, isOn: checked(mode)) }
    }

    /// A click on the item of the current mode keeps the mode.
    func checked(_ mode: DragMode) -> Binding<Bool> {
        Binding(
            get: { app.dragMode == mode },
            set: { if $0 { app.dragMode = mode } })
    }
}

extension DragMode {
    var title: L10n {
        switch self {
        case .overwrite: .menuEditDragModeOverwrite
        case .noOverlap: .menuEditDragModeNoOverlap
        case .crossfade: .menuEditDragModeCrossfade
        case .shuffle: .menuEditDragModeShuffle
        }
    }
}
