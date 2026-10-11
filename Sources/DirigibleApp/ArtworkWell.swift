import AppKit
import DirigibleAudio
import SwiftUI
import UniformTypeIdentifiers

/// An image with Choose… and Remove: the episode artwork and the chapter image. It takes a dropped
/// JPEG or PNG file. A separate view, so a key in a field does not read the image again.
struct ArtworkWell: View {
    let url: URL?
    /// The prefix of the accessibility identifiers, for example `episode.artwork`.
    let identifier: String
    /// The accessibility label with an image and with no image.
    let label: L10n
    let noneLabel: L10n
    let set: (URL) -> Void
    let choose: () -> Void
    let remove: () -> Void
    /// The image of `url`, read once for each path and not at each body pass.
    @State private var image: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if url != nil, let image {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .accessibilityLabel(Text(url == nil ? noneLabel.key : label.key))
            .task(id: url) { image = url.flatMap { NSImage(contentsOf: $0) } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                set(first)
                return true
            }
            // One width for both buttons: the width of the longer label (C23).
            VStack(alignment: .leading, spacing: 6) {
                Button(action: choose) {
                    Text(L10n.episodeArtworkChoose.key).frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("\(identifier).choose")
                Button(action: remove) {
                    Text(L10n.episodeArtworkRemove.key).frame(maxWidth: .infinity)
                }
                .disabled(url == nil)
                .accessibilityIdentifier("\(identifier).remove")
            }
            .fixedSize()
        }
    }
}

extension SessionWindow {
    /// Choose… of an image well: the open panel as a sheet of the window, then `set`.
    func chooseImage(_ set: @escaping (URL) -> Void) {
        guard canImport, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.beginSheetModal(for: window) { answer in
            if answer == .OK, let url = panel.url { set(url) }
        }
    }

    /// Copies an image into the package through `run`, as an import: the banner shows the file
    /// name and Cancel. A refusal shows an alert.
    func importImage(_ run: @escaping (Studio) async throws(StudioError) -> Void) {
        guard canImport, let studio = idleStudio else { return beep() }
        importJob = ImportJob()
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                try await run(studio)
            } catch .audioImport(.cancelled) {
            } catch {
                self?.alert = .error(error)
            }
            self?.importJob = nil
        }
    }
}
