import DirigibleAudio
import DirigibleCore
import Foundation
import Observation

/// The running transcription job of a window: its request, its stage, and its start.
struct TranscribeJobShown: Equatable {
    let request: TranscribeRequest
    var stage: TranscribeProgress?
    let since: ContinuousClock.Instant

    /// "Downloading the speech model... 42 %" or "Transcribing Host... 42 %".
    var text: String {
        switch stage {
        case .download(let fraction): L10n.transcribeBannerDownload.format(Self.percent(fraction))
        case .transcribe(let fraction): L10n.transcribeBannerRunning.format(request.trackName, Self.percent(fraction))
        case .check, .checked, nil: L10n.transcribeBannerRunning.format(request.trackName, 0)
        }
    }

    var fraction: Double {
        switch stage {
        case .download(let fraction), .transcribe(let fraction): min(1, max(0, fraction))
        case .check, .checked, nil: 0
        }
    }

    private static func percent(_ fraction: Double) -> Int { Int((min(1, max(0, fraction)) * 100).rounded(.down)) }
}

/// What a finished job leaves in the window until the next edit (decision 0065, UI council C-7).
enum TranscribeNotice: Equatable {
    /// A take started. Transcribe Again runs `request` again.
    case stopped(TranscribeRequest, revision: Int, press: Int)
    /// The job kept no word, so the track is unchanged.
    case noWords(revision: Int, press: Int)
}

/// The Transcribe state of a window. Its own object, so a progress tick wakes only the banner.
@Observable @MainActor final class TranscribeState {
    var draft: TranscribeDraft?
    var job: TranscribeJobShown?
    var notice: TranscribeNotice?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var presses = 0
    /// Tests give their own folder.
    @ObservationIgnored var modelFolder: () -> URL = { WhisperModelStore.folder() }
}

/// Tools > Transcribe Track... (decision 0065): the sheet starts a job of the studio beside the
/// write chain. The window stays editable while it runs.
extension SessionWindow {
    /// The item is off with a dialog, a job, an import, a pending take, a take, or no track.
    var canTranscribe: Bool {
        !dialogShowing && transcribe.job == nil && canImport && idleStudio?.session.tracks.isEmpty == false
    }

    /// Opens the sheet on `track`, else the first selected track, else the first track.
    func transcribeTrack(_ track: TrackID? = nil) {
        guard canTranscribe, let studio = idleStudio else { return }
        commitDrafts()
        transcribe.notice = nil
        let session = studio.session
        let folder = transcribe.modelFolder()
        let onDisk = Set(
            TranscribeDraft.models.filter {
                FileManager.default.fileExists(atPath: folder.appending(path: $0.fileName).path)
            })
        let language = TranscribeLanguages.first(
            stored: app?.defaults?.string(forKey: TranscribeDraft.languageKey),
            appLanguage: Bundle.main.preferredLocalizations.first)
        transcribe.draft = TranscribeDraft(
            tracks: session.tracks.map {
                TranscribeDraft.Choice(id: $0.id, name: $0.name, words: session.words(on: [$0.id]).count)
            },
            selected: track ?? timeline.selection.headerTracks(in: session).first, onDisk: onDisk, language: language)
    }

    func cancelTranscribeSheet() { transcribe.draft = nil }

    /// The default button of the sheet: closes it and starts the job.
    func startTranscribe(_ draft: TranscribeDraft) {
        transcribe.draft = nil
        draft.remember(in: app?.defaults)
        start(draft.request)
    }

    /// The Transcribe Again button of the stop banner.
    func transcribeAgain() {
        guard case .stopped(let request, _, _) = transcribe.notice else { return }
        start(request)
    }

    /// Cancel of the job banner: the job ends at its next stop check and writes nothing.
    /// The task cancel also reaches a job that has not joined the studio yet.
    func cancelTranscribe() {
        studio?.cancelTranscription()
        transcribe.task?.cancel()
    }

    private func start(_ request: TranscribeRequest) {
        guard canTranscribe, let studio = idleStudio else { return }
        commitDrafts()
        transcribe.notice = nil
        // The download comes first, and a stalled download sends no progress: show it from the start.
        let missing = !FileManager.default.fileExists(
            atPath: transcribe.modelFolder().appending(path: request.model.fileName).path)
        transcribe.job = TranscribeJobShown(request: request, stage: missing ? .download(0) : nil, since: .now)
        transcribe.task = Task { [weak self] in
            do throws(StudioError) {
                let report = try await studio.transcribe(
                    track: request.track, language: request.language, model: .catalog(request.model)
                ) { [weak self] in self?.transcribe.job?.stage = $0 }
                if report.id == nil { self?.notify(in: studio) { .noWords(revision: $0, press: $1) } }
            } catch .transcriptionYielded {
                self?.notify(in: studio) { .stopped(request, revision: $0, press: $1) }
            } catch .transcriptionCancelled {
                self?.chrome?.announce(L10n.transcribeCanceled.text, .medium)
            } catch {
                self?.alert = .error(error)
            }
            self?.transcribe.job = nil
            self?.transcribe.task = nil
        }
    }

    /// Shows the notice of `make` at the session revision now, with a new press number.
    private func notify(in studio: Studio, _ make: (_ revision: Int, _ press: Int) -> TranscribeNotice) {
        transcribe.presses += 1
        transcribe.notice = make(studio.sessionRevision, transcribe.presses)
    }
}
