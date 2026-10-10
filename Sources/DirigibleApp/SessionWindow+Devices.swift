import AppKit
import DirigibleAudio
import DirigibleCore
import Observation

/// The monitor and device side of the session window (decision 0015).
extension SessionWindow {
    /// Sends the listened tracks and the meter request to the studio, which diffs them (decisions
    /// 0015 and 0044). The meter request is the armed tracks while Monitor Inputs is on, plus the
    /// listened tracks. A refused access turns Monitor Inputs and Monitor Track off.
    func updateMonitor() async {
        guard case .open(let studio) = phase else { return }
        do throws(StudioError) {
            try await withMicrophoneAccess(studio) { () async throws(StudioError) in
                let listening = listenedDeviceTracks(studio)
                try await studio.listen(to: listening)
                let request = studio.session.tracks.map(\.id).filter {
                    monitoring && armed.contains($0) || listening.contains($0)
                }
                try await studio.monitor(armed: request)
            }
        } catch .microphoneAccess(let access) {
            monitoring = false
            listened = []
            alert = .microphone(access)
        } catch {
            alert = .error(error)
        }
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
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

    /// Calls `updateMonitor()` at each change of the toggle, the armed tracks, the listened
    /// tracks, or the session (a route edit, an undo) while the window shows `studio`.
    func followMonitor(_ studio: Studio) {
        withObservationTracking {
            _ = (monitoring, armed, listened, studio.session)
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
