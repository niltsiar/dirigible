import AVFoundation
import DirigibleCore

/// The test seam of the live take (decision 0013): closures and values, no protocol. `live`
/// calls the system.
struct CaptureEnvironment: Sendable {
    var hal: DeviceHAL
    /// The journal of the front end (decision 0059). `live` has `disabled`; `Studio.open` sets it.
    var log = DiagnosticLog.disabled
    /// A running device with no valid record for this long is lost (the watchdog).
    var silenceLimit: Duration
    /// The watchdog limit from an attach to the first valid record of that appearance. A device
    /// (for example a Bluetooth headset) can need seconds to start its IO.
    var firstRecordLimit: Duration
    /// Nil when the access is granted.
    var microphoneAccess: @Sendable () -> MicrophoneAccess?
    /// False on macOS 14.0 and 14.1: no process taps, so no app route records (A14).
    var tapsAvailable = processTapsAvailable
    /// The free bytes of the volume of the package. Called off the main actor.
    var freeBytes: @Sendable (PackageLock) -> Int64
    var diskCheckInterval: Duration
    /// The ring length of each device appearance.
    var ringSeconds: Double = 10
    /// The limit of the device writer waits of a take start, from `begin`.
    var startLimit = Duration.seconds(10)
    /// The limit of the writer waits of a stop, from the stop call, and of a Retry Finalize.
    var stopLimit = Duration.seconds(10)
    /// The autosave write of a session into the package that the lock holds. Returns the package
    /// path that it wrote. Called off the main actor. It is async, so a test holds a write with an
    /// async wait and blocks no thread of the concurrency pool.
    var saveSession: @Sendable (Session, PackageLock) async throws(SessionFileError) -> URL
    /// The output of each Listener (decision 0044). No default, so each direct init names it;
    /// tests give `.offline()`.
    var listenOutput: ListenOutput
    /// A step before each finalize and each placement (decision 0021). Tests hold a finalize or a
    /// placement with it and suspend, so no thread of the concurrency pool waits; `live` does
    /// nothing.
    var beforeFinalize: @Sendable () async -> Void = {}
    /// A step at the block reads of each placement (decision 0021). Tests hold a placement or
    /// check its thread with it; `live` has none.
    var placeRead: ReadFault?
    /// The output of the Player that the next play makes (decision 0016). Tests render offline;
    /// `DIRIGIBLE_AUDIO_OUTPUT=none` gives `.paced` (`live(environment:)`).
    var playerOutput: Player.Output = .device
    /// A step before the Player stop of a take start and of a pre-roll take end, off the main
    /// actor. Tests hold it.
    var beforePlayerStop: @Sendable () async -> Void = {}
    /// A step of a take start before the device lookup, off the main actor. Tests hold the start
    /// with it and suspend, so no thread of the concurrency pool waits; `live` does nothing. The
    /// step passes its `#isolation`, so a test hook runs on the thread of the step.
    var beforeLookUp: @Sendable (isolated (any Actor)?) async -> Void = { _ in }
    /// A step of a test take start (`Studio.startTake`) before its save, off the main actor.
    /// Tests check its thread with it; `live` does nothing. It passes its `#isolation`, as
    /// `beforeLookUp`.
    var beforeStartSave: @Sendable (isolated (any Actor)?) async -> Void = { _ in }
    /// The wait of a timed take until `clock`, the clock of H_T (`hostNanos`), reaches the host
    /// time of its stop (decision 0048). The host clock stands still in a system sleep and the sleep
    /// clock does not, so each wake reads `clock` again. A cancel ends the wait. Tests hold it with
    /// a gate, so no wall clock races a check.
    var takeStop: @Sendable (_ stop: UInt64, _ clock: @Sendable () -> UInt64) async -> Void = { stop, clock in
        while case let now = clock(), now < stop {
            do { try await Task.sleep(for: .nanoseconds(stop - now)) } catch { return }
        }
    }
    /// A step of a take start after the take begins, before the app attach. Tests hold it to stop
    /// the take before the start returns; `live` does nothing.
    var afterStart: @Sendable () async -> Void = {}
    /// The sleep assertion of a take start, on the main actor. Tests read the journal in it.
    var makeSleepAssertion: @Sendable () -> SleepAssertion = { SleepAssertion() }
    /// A step of a take start before the save of `<recording>`, off the main actor. Tests read the
    /// journal in it.
    var beforeTakeSave: @Sendable () async -> Void = {}
    /// A step at the start of each media check of `Studio.checkMedia` and `Studio.exportFaults`, off the main actor. Tests
    /// hold the check with it and suspend, so no thread of the concurrency pool waits.
    var beforeMediaCheck: @Sendable () async -> Void = {}
    /// Finds the speed unit of the Player (decision 0052). Tests give one that finds nothing.
    var speedUnit: SpeedUnitLookup = findSpeedUnit
    /// Starts the engine of the Player. Tests give one that throws.
    var startEngine: @Sendable (AVAudioEngine) throws -> Void = { try $0.start() }
    /// Reads the output term of each play start of the Player (decision 0070). Tests give a fake
    /// term or a failed read; nil (`live`) reads the HAL on the device output.
    var outputTerm: OutputTermRead?
    /// The host clock in nanoseconds of a pre-roll take start and of the Player (decision 0070).
    /// Tests give a fixed one.
    var hostNanos: @Sendable () -> UInt64 = hostNanosNow
    /// A step before each block of a peak compute (decision 0017), isolated to the actor of the
    /// compute (nil: none). Tests count, hold, or slow the blocks with it.
    var beforePeakBlock: @Sendable (isolated (any Actor)?) async -> Void = { _ in }
    /// A step on the thread of each WAV read of a peak pass: at each file start (the open and the
    /// cache read) and after each block read. Tests check that it is never the main thread.
    var peakRead: @Sendable () -> Void = {}
    /// A step of the raw sweep job (decision 0071) on the main actor: `.first` and `.turn`. Tests
    /// count or hold the steps with it.
    var beforeRawStep: @Sendable (RawSweepStep) async -> Void = { _ in }
    /// A step on the read thread of the raw sweep job: `.segment(n)` before each segment of the
    /// header scan, `.block(n)` before each WAV block. Tests record the QoS of the thread, or hold
    /// the read, with it.
    var rawReadStep: @Sendable (RawSweepStep) -> Void = { _ in }
    /// The flush of each file of a raw removal: the path, then the errno or nil. Tests fail it.
    var rawFlush: @Sendable (String) -> Int32? = { fullFlush(path: $0) }
    /// A step on the export thread at each cancel check: each chunk and once after the close
    /// (decision 0019). Tests record the thread and the QoS with it, or hold or slow the export.
    var exportChunk: @Sendable () -> Void = {}
    /// The clone choice of a template copy (decision 0079): a test gives false for a data copy.
    var templateCanClone: @Sendable (URL, URL) -> Bool = { cloneWorks($0, into: $1) }
    /// A step on the copy thread between the check of a path and its copy: tests hold a template copy with it.
    var templateBeforeCopy: @Sendable (String) -> Void = { _ in }
    /// A step on the copy thread at each write of a template data copy: the path and the bytes.
    var templateWritten: @Sendable (String, Int64) -> Void = { _, _ in }
    /// A step on the import thread at each cancel check (decision 0040). Tests record the thread
    /// with it, or hold or slow the import.
    var importStep: @Sendable () -> Void = {}
    /// A step after the work of a file import returns, before its run reads the cancel flag
    /// (decision 0049). Tests cancel there.
    var importWorkDone: @Sendable () async -> Void = {}
    /// A fault or a thread record at the block reads of a clip render (decision 0054); `live` has
    /// none.
    var clipRenderRead: ReadFault?
    /// A step after the render of a clip render returns, before its run reads the cancel flag
    /// (decision 0049). Tests hold or cancel the render there.
    var clipRenderWorkDone: @Sendable () async -> Void = {}
    /// The reason of the activity that each blocking run holds (decision 0040). Tests set a UUID
    /// text, so the IOPM list of the process shows the activity of one studio.
    var blockingRunReason = "Dirigible imports or changes audio files"
    /// A step on the thread of each block of `Studio.measureLoudness` and of the read of a level or
    /// a duck (`Studio.runReadJob`, decision 0049). Tests hold the read with it.
    var loudnessBlock: @Sendable () -> Void = {}
    /// The engine part of a transcription job (decision 0065 D6), on the GCD thread of the job.
    /// `live` runs one `WhisperEngine`; tests give a scripted closure.
    var transcribe: TranscribeEngine = liveTranscribe
    /// The model check of a job on its GCD thread: `checked(in:)` on the model folder. Tests give
    /// one that needs no catalog file.
    var checkModel: @Sendable (WhisperModel, URL) -> CheckedModel? = { $0.checked(in: $1) }
    /// The check of a model file of the user on the GCD thread of a job (decision 0065, D8): the
    /// file, the record of its last passed check, and the stop check. `live` starts the helper of
    /// `ModelFileCheck.helper(executable:)`; tests give a stub helper.
    var checkModelFile:
        @Sendable (URL, PassedModelFile?, @Sendable () -> Bool) throws(ModelFileCheckError) -> CheckedModel = {
            url, passed, stop throws(ModelFileCheckError) in
            try ModelFileCheck.run(url, passed: passed, stop: stop)
        }
    /// The SHA-256 of a kept model file of the user for the Transcribe sheet, on the GCD thread of
    /// its read run, with the stop check of the run (decision 0065, D8, C24). Tests count or hold it.
    var hashModelFile: @Sendable (URL, @Sendable () -> Bool) throws(ModelFileCheckError) -> String = {
        url, stop throws(ModelFileCheckError) in try OpenModelFile(url).sha256(stop: stop)
    }
    /// A step after a passed check of a model file of the user, before the engine part. Tests
    /// start a take there.
    var modelFileCheckDone: @Sendable () async -> Void = {}
    /// The model folder and the download of a job (decision 0065 D2). Tests give their own.
    var modelStore = WhisperModelStore.live
    /// The reason of the activity of a transcription job. Tests set a UUID text.
    var transcribeReason = "Dirigible transcribes audio"
    /// A step after the engine part of a job returns, before the end turn reads the stop flags.
    /// Tests start a take or hold the job there.
    var transcribeWorkDone: @Sendable () async -> Void = {}

    static let live = live(output: .live)

    /// The live environment. An output of `noDevice` (`DIRIGIBLE_AUDIO_OUTPUT=none`) plays and
    /// monitors to no device (decision 0016, amended); any other value plays to the device.
    static func live(output: AudioOutputSetting) -> CaptureEnvironment {
        let noDevice = output == .noDevice
        var built = CaptureEnvironment(
            hal: .live, silenceLimit: .seconds(2), firstRecordLimit: .seconds(10),
            microphoneAccess: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: nil
                case .notDetermined: .notDetermined
                case .restricted: .restricted
                default: .denied
                }
            },
            freeBytes: { $0.freeBytes() }, diskCheckInterval: .seconds(1),
            saveSession: { session, lock throws(SessionFileError) in try session.write(under: lock) },
            listenOutput: noDevice ? .offline() : .live)
        if noDevice { built.playerOutput = .paced }
        return built
    }
}

/// One step of the raw sweep job (decision 0071).
enum RawSweepStep: Hashable, Sendable {
    /// Before the first read of a run of the job.
    case first
    /// Before segment n (0-based, in name order) of the header scan.
    case segment(Int)
    /// Before block n (0-based) of an audio read.
    case block(Int)
    /// Before the job asks for the turn of one removal.
    case turn
}
