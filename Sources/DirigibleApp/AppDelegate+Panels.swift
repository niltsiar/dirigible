import AppKit
import DirigibleAudio
import DirigibleCore
import UniformTypeIdentifiers

extension AppDelegate {
    private static let sessionType = UTType(filenameExtension: "dirigible", conformingTo: .package) ?? .package

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

    /// Makes the package with `Studio.create` and shows it in a window. Returns the error.
    func createSession(at url: URL) async -> StudioError? {
        do throws(StudioError) {
            await open(
                url,
                created: try await Studio.create(
                    url, sampleRate: 48_000, recordings: recordings, peakCache: peakCache, log: log))
        } catch {
            return error
        }
        return nil
    }
}
