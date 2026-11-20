import AppKit

extension ExportPanel {
    /// The panel follows the Files pop-up and the format. A split panel has no type, so it adds no
    /// extension and asks nothing about the prefix file; its name field is a prefix, and its button
    /// says Export. One File gives back the label and the button of `nameLabel` and `button`.
    @MainActor static func follow(_ settings: ExportSettings, _ panel: NSSavePanel, nameLabel: String, button: String) {
        let split = settings.files != .one
        panel.allowedContentTypes = split ? [] : [settings.contentType]
        if split { panel.nameFieldStringValue = SplitTarget.prefix(of: panel.nameFieldStringValue) }
        panel.nameFieldLabel = split ? L10n.panelExportPrefix.text : nameLabel
        panel.prompt = split ? L10n.alertExportConfirm.text : button
    }

    /// The set that the panel answered: its folder and the prefix of the name. Nil at One File.
    @MainActor static func splitTarget(_ settings: ExportSettings, _ url: URL) -> SplitTarget? {
        settings.files.kind.map {
            SplitTarget(
                kind: $0, folder: url.deletingLastPathComponent(), prefix: SplitTarget.prefix(of: url.lastPathComponent)
            )
        }
    }
}
