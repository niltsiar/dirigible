import DirigibleCore
import DirigibleTimeline
import Foundation
import SwiftUI

extension InspectorView {
    /// The read-only Effects row (decision 0057, C10): the label, then the effects of the clips.
    /// Clips with no render have no row.
    @ViewBuilder func effectsRow(_ inspection: ClipInspection) -> some View {
        if let effects = Self.effectsText(inspection.clips, in: studio.session) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.inspectorEffects.key)
                Text(verbatim: effects).foregroundStyle(.secondary).lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The effects of the render chain of each clip, the first render first, for example "Reduce
    /// Noise 12 dB". Mixed when two clips differ, also a render and a plain clip; nil when no clip
    /// is on a rendered file.
    static func effectsText(
        _ clips: [ClipID], in session: Session, text: (L10n) -> String = { $0.text }
    ) -> String? {
        let files = Dictionary(
            session.tracks.flatMap(\.clips).map { ($0.id, $0.file) }, uniquingKeysWith: { a, _ in a })
        let chains = clips.map { clip in
            files[clip].map { session.origins(ofFile: $0).reversed().flatMap(\.treatment.effects) } ?? []
        }
        guard chains.contains(where: { !$0.isEmpty }) else { return nil }
        guard let first = chains.first, chains.allSatisfy({ $0 == first }) else { return text(.inspectorMixed) }
        return first.map { effect in
            switch effect {
            case .noise(let noise): String(format: text(.inspectorEffectNoise), locale: .current, noise.decibels)
            }
        }.joined(separator: ", ")
    }
}
