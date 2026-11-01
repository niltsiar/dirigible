import DirigibleAudio
import Foundation

/// Choose Model File..., the kept file, the check line, and Locate... of Tools > Transcribe
/// Track... (decision 0065 D8, UI council U15 to U22).
extension SessionWindow {
    /// A choice in the Model pop-up. Choose Model File... and a missing kept file open the panel;
    /// another entry stops a running check.
    func selectModel(_ entry: ModelEntry) {
        guard let draft = transcribe.draft else { return }
        if entry == .choose || (entry == .file && draft.keptMissing) {
            chooseModelFile()
            return
        }
        stopModelCheck()
        transcribe.draft?.check = nil
        transcribe.draft?.beforeChoice = nil
        transcribe.draft?.select(entry)
    }

    /// The open panel of the sheet. A picked file runs the sheet check; a Cancel gives back the
    /// entry before.
    func chooseModelFile() {
        guard let draft = transcribe.draft else { return }
        stopModelCheck()
        transcribe.keptTask?.cancel()
        let before = draft.beforeChoice ?? draft.model
        transcribe.draft?.beforeChoice = before
        transcribe.draft?.check = nil
        transcribe.draft?.model = .choose
        let pick = transcribe.pickModelFile
        transcribe.checkTask = Task { [weak self] in
            let url = await pick()
            guard !Task.isCancelled else { return }
            guard let url else {
                self?.endChoice(before, line: nil)
                return
            }
            await self?.checkModelFile(url, before: before)
        }
    }

    /// Stops the open panel task and the helper of a sheet check.
    func stopModelCheck() {
        transcribe.checkTask?.cancel()
        transcribe.checkTask = nil
    }

    /// The sheet check (U17): a read run of the studio, so a take start in any window and
    /// `settle()` stop it. A pass keeps the file; a refusal keeps nothing.
    private func checkModelFile(_ url: URL, before: ModelEntry) async {
        guard let studio else { return }
        let status = await FileStatus.read(url)
        guard !Task.isCancelled else { return }
        transcribe.draft?.check = .running(name: url.lastPathComponent, byteCount: status?.byteCount ?? 0)
        do throws(StudioError) {
            let checked = try await studio.checkModelFile(url, passed: nil)
            guard !Task.isCancelled else { return }
            guard case .file(let record) = checked.source, let status else { return endChoice(before, line: nil) }
            let kept = KeptModelFile(url: url, status: status, passed: record)
            kept.store(in: app?.defaults)
            transcribe.draft?.kept = kept
            transcribe.draft?.keptMissing = false
            transcribe.draft?.beforeChoice = nil
            transcribe.draft?.select(.file)
            let line = ModelCheckLine.passed(record.facts)
            transcribe.draft?.check = line
            chrome?.announce(line.text, .medium)
            transcribe.checkTask = nil
        } catch .transcriptionCancelled, .readClosed {
            // A pop-up change, Cancel, or the close of the window: the caller already moved on.
        } catch .readYielded {
            endChoice(before, line: .refused(L10n.sheetTranscribeCheckTake.text))
        } catch .busy {
            endChoice(before, line: .refused(L10n.sheetTranscribeCheckBusy.text))
        } catch {
            endChoice(before, line: .refused(L10n.message(for: error)))
        }
    }

    /// The end of a choice with no new file: the entry before, and the refusal line, if any.
    private func endChoice(_ before: ModelEntry, line: ModelCheckLine?) {
        transcribe.checkTask = nil
        guard transcribe.draft != nil else { return }
        transcribe.draft?.beforeChoice = nil
        transcribe.draft?.select(before)
        transcribe.draft?.check = line
        if let line { chrome?.announce(line.text, .medium) }
    }

    /// The kept file at the sheet open (C24): its status, off the main actor. A missing file shows
    /// as "(missing)". A new byte count or date hashes the file once as a read run of the studio
    /// (`Studio.hashModelFile`): the same hash keeps the record with the new status, another hash
    /// or a read error drops the record, and a refusal or a stop keeps the record as it is. It
    /// stores only over the record that it started from: a pick during the hash stays.
    func readKeptFile() {
        guard let kept = transcribe.draft?.kept else { return }
        transcribe.keptTask?.cancel()
        transcribe.keptTask = Task { [weak self] in
            let status = await FileStatus.read(kept.url)
            guard let self, transcribe.draft?.kept == kept else { return }
            guard let status else { return transcribe.draft?.keptFileIsMissing() ?? () }
            guard status != kept.status, let studio else { return }
            var updated = kept
            (updated.byteCount, updated.modified) = (status.byteCount, status.modified)
            do throws(StudioError) {
                if try await studio.hashModelFile(kept.url) != kept.passed?.sha256 { updated.passed = nil }
            } catch .transcription(.modelFile(.unreadable)) {
                updated.passed = nil
            } catch {
                return
            }
            guard KeptModelFile.load(from: app?.defaults) == kept else { return }
            updated.store(in: app?.defaults)
            if transcribe.draft?.kept == kept { transcribe.draft?.kept = updated }
        }
    }

    /// Keeps the file of a job whose check passed (C10), whatever the end of the job.
    func keepModelFile(_ url: URL, _ record: PassedModelFile) {
        let defaults = app?.defaults
        Task {
            guard let status = await FileStatus.read(url) else { return }
            KeptModelFile(url: url, status: status, passed: record).store(in: defaults)
        }
    }

    /// Locate... and Choose Model File... of a job alert (C27, C28): the open panel, then `request`
    /// with the picked file, so the job checks it.
    func startWithPickedFile(_ request: TranscribeRequest) {
        let pick = transcribe.pickModelFile
        Task { [weak self] in
            guard let url = await pick() else { return }
            self?.start(
                TranscribeRequest(
                    track: request.track, trackName: request.trackName, language: request.language,
                    model: .file(url, passed: nil)))
        }
    }
}
