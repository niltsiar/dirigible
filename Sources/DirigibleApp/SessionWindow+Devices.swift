import DirigibleAudio
import DirigibleCore
import Observation

/// The monitor and device side of the session window (decision 0015).
extension SessionWindow {
    /// Sends the request of the toggle and the armed tracks to the studio, which diffs it
    /// (decision 0015). A refused access turns the toggle off.
    func updateMonitor() async {
        guard case .open(let studio) = phase else { return }
        do throws(StudioError) {
            try await withMicrophoneAccess(studio) { () async throws(StudioError) in
                let request = monitoring ? studio.session.tracks.map(\.id).filter(armed.contains) : []
                try await studio.monitor(armed: request)
            }
        } catch .microphoneAccess(let access) {
            monitoring = false
            alert = .microphone(access)
        } catch {
            alert = .error(error)
        }
    }

    /// Runs `body`. When it throws an undecided access, it shows the macOS prompt and runs `body`
    /// once more after a grant (decision 0013). The prompt waits for the user; a close can end
    /// the window meanwhile, so `body` runs again only in an open window with the same studio.
    func withMicrophoneAccess(_ studio: Studio, _ body: () async throws(StudioError) -> Void)
        async throws(StudioError)
    {
        do throws(StudioError) {
            try await body()
        } catch .microphoneAccess(let access) {
            switch microphoneStep(access) {
            case .request:
                guard await requestMicrophoneAccess() else { throw .microphoneAccess(.denied) }
                guard case .open(let current) = phase, current === studio else { return }
                try await body()
            case .privacyLink: throw .microphoneAccess(access)
            }
        }
    }

    /// Calls `updateMonitor()` at each change of the toggle, the armed tracks, or the session
    /// (a route edit, an undo) while the window shows `studio`.
    func followMonitor(_ studio: Studio) {
        withObservationTracking {
            _ = (monitoring, armed, studio.session)
        } onChange: { [weak self, weak studio] in
            Task { @MainActor in
                guard let self, let studio, self.studio === studio else { return }
                self.followMonitor(studio)
                await self.updateMonitor()
            }
        }
    }
}

enum MicrophoneStep: Equatable {
    case request
    case privacyLink
}

/// Only an undecided access can change through the prompt (decision 0013).
func microphoneStep(_ access: MicrophoneAccess) -> MicrophoneStep {
    access == .notDetermined ? .request : .privacyLink
}

/// The routes of a device: mono 1 to n, then the stereo pairs (1, 2), (3, 4), and so on.
func routeOptions(channelCount: Int) -> [Route.Channels] {
    (0..<max(0, channelCount)).map { .mono($0 + 1) }
        + stride(from: 1, to: channelCount, by: 2).map { .stereo($0, $0 + 1) }
}
