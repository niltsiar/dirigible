import AppKit
import DirigibleAudio
import DirigibleCore
import Foundation
import Observation

/// The running transcription job of a window: its request, its stage, its start, and the host of
/// the firewall hint.
struct TranscribeJobShown: Equatable {
    let request: TranscribeRequest
    var stage: TranscribeProgress?
    let since: ContinuousClock.Instant
    /// The host that the firewall hint names, while the download gets no byte; else nil.
    var hint: String?

    /// The second line of the banner: "No data from huggingface.co yet. A firewall can block the
    /// download."
    var hintText: String? { hint.map { L10n.transcribeBannerFirewall.format($0) } }

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

/// The firewall hint of the model download (U13, U19).
enum TranscribeHint {
    /// The time with no byte before the hint shows. It is far under the 60 s request limit.
    static let delay = Duration.seconds(10)
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
    /// Returns at `since` plus `TranscribeHint.delay`, or at a cancel. Tests give their own wait.
    @ObservationIgnored var hintWait: @MainActor (_ since: ContinuousClock.Instant) async -> Void = { since in
        try? await Task.sleep(until: since + TranscribeHint.delay, clock: .continuous)
    }
    /// The chunk instants of the download of the running job.
    @ObservationIgnored var download: DownloadActivity?
    @ObservationIgnored var hintTask: Task<Void, Never>?
    /// The open panel of a model file on a window: the picked file, else nil. Tests give their own.
    @ObservationIgnored var pickModelFile: @MainActor (_ parent: NSWindow?) async -> URL? = {
        await TranscribeState.livePickModelFile(in: $0)
    }
    /// The open panel and the check of Choose Model File... in the sheet.
    @ObservationIgnored var checkTask: Task<Void, Never>?
    /// The status read of the kept file at the sheet open.
    @ObservationIgnored var keptTask: Task<Void, Never>?
    /// The open panel of Locate... and Choose Model File... of a job alert.
    @ObservationIgnored var pickTask: Task<Void, Never>?
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
        let defaults = app?.defaults
        let language = TranscribeLanguages.first(
            stored: defaults?.string(forKey: TranscribeDraft.languageKey),
            appLanguage: Bundle.main.preferredLocalizations.first)
        transcribe.draft = TranscribeDraft(
            tracks: session.tracks.map {
                TranscribeDraft.Choice(id: $0.id, name: $0.name, words: session.words(on: [$0.id]).count)
            },
            selected: track ?? timeline.selection.headerTracks(in: session).first, onDisk: onDisk, language: language,
            kept: KeptModelFile.load(for: language, from: defaults),
            remembered: TranscribeModelMemory.entry(for: language, in: defaults))
        readKeptFile()
    }

    /// Cancel and Escape of the sheet: they stop a check of a model file.
    func cancelTranscribeSheet() {
        endModelFileWork()
        transcribe.draft = nil
    }

    /// The default button of the sheet: closes it and starts the job.
    func startTranscribe(_ draft: TranscribeDraft) {
        endModelFileWork()
        transcribe.draft = nil
        draft.remember(in: app?.defaults)
        if let request = draft.request { start(request) }
    }

    /// The Transcribe Again button of the stop banner.
    func transcribeAgain() {
        guard canTranscribe, case .stopped(let request, _, _) = transcribe.notice else { return }
        start(request)
    }

    /// Cancel of the job banner: the job ends at its next stop check and writes nothing.
    /// The task cancel also reaches a job that has not joined the studio yet.
    func cancelTranscribe() {
        studio?.cancelTranscription()
        transcribe.task?.cancel()
    }

    /// Starts the job of `request`. `Studio.transcribe` refuses a busy studio, also one that started
    /// another job while the sheet or the model file panel was open. A busy studio shows the busy alert.
    func start(_ request: TranscribeRequest) {
        guard !dialogShowing, transcribe.job == nil, importJob == nil, case .open(let studio) = phase else { return }
        commitDrafts()
        transcribe.notice = nil
        // The download comes first, and a stalled download sends no progress: show it from the start.
        var missing = false
        if case .catalog(let model) = request.model {
            missing = !FileManager.default.fileExists(
                atPath: transcribe.modelFolder().appending(path: model.fileName).path)
        }
        transcribe.job = TranscribeJobShown(request: request, stage: missing ? .download(0) : nil, since: .now)
        let download = DownloadActivity()
        transcribe.download = download
        transcribe.task = Task { [weak self] in
            do throws(StudioError) {
                let report = try await studio.transcribe(
                    track: request.track, language: request.language, model: request.model, download: download
                ) { [weak self] stage in
                    self?.transcribe.job?.stage = stage
                    if case .download = stage { self?.waitForHint() }
                    // A passed check is kept whatever the end of the job (C10).
                    if case .checked(let record) = stage, case .file(let url, _) = request.model {
                        self?.keepModelFile(url, record, for: request.choice)
                    }
                }
                if report.id == nil { self?.notify(in: studio) { .noWords(revision: $0, press: $1) } }
            } catch .transcriptionYielded {
                self?.notify(in: studio) { .stopped(request, revision: $0, press: $1) }
            } catch .transcriptionCancelled {
                self?.chrome?.announce(L10n.transcribeCanceled.text, .medium)
            } catch {
                self?.alert = .transcribe(error, request)
            }
            self?.transcribe.hintTask?.cancel()
            self?.transcribe.hintTask = nil
            self?.transcribe.download = nil
            self?.transcribe.job = nil
            self?.transcribe.task = nil
        }
    }

    /// The firewall hint (U19, U27): after `TranscribeHint.delay` with no chunk, the banner names the
    /// host. A chunk during the wait runs the wait again. The first chunk after the hint removes it
    /// and starts the wait again. The wait ends with the download stage.
    private func waitForHint() {
        guard transcribe.hintTask == nil, let download = transcribe.download else { return }
        let start = ContinuousClock.now
        transcribe.hintTask = Task { [weak self] in
            while let wait = self?.transcribe.hintWait, !Task.isCancelled {
                let seen = download.lastChunk
                await wait(seen ?? start)
                guard let self, !Task.isCancelled, transcribe.download === download,
                    case .download(let fraction)? = transcribe.job?.stage, fraction < 1
                else { return }
                // The armed body sits in `download` until a chunk comes, so it holds the download weakly.
                let armed = download.onNextChunk(ifNoChunkSince: seen) { [weak self, weak download] in
                    guard let download else { return }
                    Task { @MainActor [weak self] in self?.chunkAfterHint(download) }
                }
                if armed, case .catalog(let model)? = transcribe.job?.request.model {
                    transcribe.job?.hint = model.url.host()
                    return
                }
            }
        }
    }

    private func chunkAfterHint(_ download: DownloadActivity) {
        guard transcribe.download === download else { return }
        transcribe.job?.hint = nil
        transcribe.hintTask = nil
        waitForHint()
    }

    /// Shows the notice of `make` at the session revision now, with a new press number.
    private func notify(in studio: Studio, _ make: (_ revision: Int, _ press: Int) -> TranscribeNotice) {
        transcribe.presses += 1
        transcribe.notice = make(studio.sessionRevision, transcribe.presses)
    }
}
