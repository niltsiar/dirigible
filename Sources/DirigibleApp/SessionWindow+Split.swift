import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// Tools > Split Stereo to Mono (decision 0053): a blocking studio run with the banner of an
/// import after 0.5 s, as a paste. The stereo clips of the selection become clips on two new mono
/// tracks.
extension SessionWindow {
    /// Splits the stereo clips of the selection. The new tracks end with the suffixes of the UI
    /// language. A split that runs past the banner wait shows the banner with the progress and
    /// Cancel, and VoiceOver reads its start and its end. At the end, the selection is the new
    /// clips. A cancel shows nothing and adds no track; another error shows its alert.
    func splitStereo() {
        guard importJob == nil, let studio = idleStudio else { return }
        let clips = timeline.selection.stereoClips(in: studio.session)
        guard !clips.isEmpty else { return }
        // A blocking run: a typed name that waits for it is lost (run 13c, plan gate 2 item 1).
        commitDrafts()
        importJob = ImportJob(visible: false)
        let wait = bannerWait
        let shown = Task { [weak self] in
            await wait()
            guard let self, !Task.isCancelled, importJob != nil else { return }
            importJob?.visible = true
            chrome?.announce(L10n.splitBanner.text, .high)
        }
        let names = (left: L10n.splitSuffixLeft.text, right: L10n.splitSuffixRight.text)
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                let parts = try await studio.splitStereo(clips, names: names) { [weak self] in
                    self?.importProgressed($0)
                }
                shown.cancel()
                if let set = ClipSet(Set(parts.flatMap { [$0.left, $0.right] })) {
                    self?.timeline.selection = .clips(set)
                }
                if self?.importJob?.visible == true { self?.chrome?.announce(L10n.splitDone.text, .high) }
            } catch .split(.cancelled) {
                shown.cancel()
            } catch {
                shown.cancel()
                self?.alert = .error(error)
            }
            self?.importJob = nil
        }
    }
}
