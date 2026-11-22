import AppKit
import DirigibleAudio
import DirigibleCore
import UniformTypeIdentifiers

extension AppDelegate {
    static let sessionType = UTType(filenameExtension: "dirigible", conformingTo: .package) ?? .package

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.sessionType]
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in for url in urls { await self?.open(url) } }
        }
    }

    /// File > New Session: the start window with the focus in the name field (decision 0027).
    func newSession() { showStart(focus: .name) }

    /// Makes the package with `Studio.create` and shows it in a window: a copy of `template` with its
    /// `progress`, else an empty session. A cancel of the calling task ends the copy. Returns the error.
    func createSession(
        at url: URL, template: URL? = nil, progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async -> StudioError? {
        do throws(StudioError) {
            await open(
                url,
                created: try await Studio.create(
                    url, source: template.map { .template($0) } ?? .rate(48_000), recordings: recordings,
                    peakCache: peakCache, log: log, copyJobs: copyJobs, progress: progress))
        } catch {
            return error
        }
        return nil
    }
}
