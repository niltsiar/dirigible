import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Missing media, edits during play, and output faults in the Studio (timeline-playback criteria
/// 10, 11, 14, 15, 16, and 22). The fixture is in `StudioPlaybackTests`. Tolerance: ± 1e-4 with
/// a gain, ± 1e-6 without.
extension StudioPlaybackTests {
    var wav: URL { package.url.appending(path: "Clips/f1.wav") }

    func expectMix(_ out: [[Float]], _ mix: [[Float]], tolerance: Float = 1e-6, _ comment: Comment) {
        #expect(out.count == 2, comment)
        for (a, b) in zip(out, mix) { #expect(maxError(a, b) <= tolerance, comment) }
    }

    /// Sets the clip gain of `c1` to -6.0206 dB (0.5).
    func halve(_ studio: Studio) throws {
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setGain(Gain(dB: -6.0206)!, clip: "c1")
        }
    }

    // MARK: Criterion 14

    /// Control: a package with every file gives no entry.
    @Test func missingMediaShowsAtOpenAndClearsAtCheck() async throws {
        do {
            let whole = try await studio()
            #expect(whole.missingMedia == [:])
        }
        let aside = package.folder.url.appending(path: "f1.wav")
        try FileManager.default.moveItem(at: wav, to: aside)
        let studio = try await studio()
        #expect(studio.missingMedia == ["f1": .missing])

        try FileManager.default.moveItem(at: aside, to: wav)
        await studio.checkMedia()
        #expect(studio.missingMedia == [:])

        try FileManager.default.moveItem(at: wav, to: aside)
        await studio.checkMedia()
        #expect(studio.missingMedia == ["f1": .missing])
        try FileManager.default.moveItem(at: aside, to: wav)
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        #expect(studio.missingMedia == [:], "a play from stopped checks")
        await studio.perform(.playStop)
    }

    // MARK: Criterion 10

    @Test func anEditDuringPlayIsHeardWithinTheLookahead() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        expectMix(await studio.renderOffline(frames: 4800), try package.mix(0..<4800), "before the edit")

        try halve(studio)
        // The update task reaches the Player before the next pull.
        await Task.yield()
        let out = await studio.renderOffline(frames: 8 * 4800)

        expectMix(
            slice(out, 3 * 4800..<8 * 4800), try package.mix(19_200..<43_200, session: studio.session),
            tolerance: 1e-4, "5 chunks after the lookahead")
        #expect(maxError(out[0], try package.mix(4800..<43_200)[0]) > 1e-2, "the old level")
        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))
    }

    /// Space and K first, so the edit finds a Player (plan gate 1 item 2).
    @Test func anEditWhileAPlayWaitsForItsMediaCheckDoesNotDropThePlay() async throws {
        let gate = AsyncGate()
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await studio.perform(.pause)
        studio.environment.beforeMediaCheck = { await gate.wait() }

        let play = Task { @MainActor in await studio.perform(.playStop) }
        await gate.entered()
        try halve(studio)
        gate.open()
        await play.value

        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))
        expectMix(
            await studio.renderOffline(frames: 9600), try package.mix(0..<9600, session: studio.session),
            tolerance: 1e-4, "the edited mix")
    }

    /// A play that waits for its media check when a take starts never plays, and the take starts
    /// at the seek frame, not at the position of an earlier play (plan gate 1 item 3, gate 2
    /// item 1). With no earlier play, no Player exists when the take starts.
    @Test(arguments: [true, false])
    func aPlayWaitingForItsMediaCheckDoesNotPlayIntoATake(earlierPlay: Bool) async throws {
        let gate = AsyncGate()
        let studio = try await studio()
        if earlierPlay {
            await studio.perform(.seek(.start))
            await studio.perform(.playStop)
            _ = await studio.renderOffline(frames: 24_000)
            await studio.perform(.pause)
            #expect(studio.playhead == 24_000)
        }
        await studio.perform(.seek(.frame(12_000)))
        studio.environment.beforeMediaCheck = { await gate.wait() }

        let play = Task { @MainActor in await studio.perform(.playStop) }
        await gate.entered()
        _ = try await studio.startTake(armed: ["t1"], devices: [mic], hostTimeNanos: takeStart)
        gate.open()
        await play.value

        #expect(studio.session.recording?.playheadFrame == 12_000)
        #expect(studio.playback == .stopped)
        #expect(await studio.play.player?.reading().running != true, "the play went into the take")
        try await studio.stopRecording()
    }

    /// Space and K first, so the Player has the session before the take (plan gate 2 item 5).
    @Test func aPlayAfterATakeHearsTheTake() async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await studio.perform(.pause)
        await studio.perform(.seek(.end))
        _ = try await studio.startTake(armed: ["t1"], devices: [mic], hostTimeNanos: takeStart)
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 1, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()
        try await studio.stopRecording()
        #expect(studio.missingMedia == [:], "the finalize checks its new files")

        await studio.perform(.seek(.frame(48_000)))
        await studio.perform(.playStop)
        let out = await studio.renderOffline(frames: 4800)

        let mix = try package.mix(48_000..<52_800, session: studio.session)
        expectMix(out, mix, "the first chunk has the take")
        #expect(mix[0].contains { abs($0) > 0.1 }, "the take is not silence")
    }

    // MARK: Criterion 22

    /// Control: a stop and L again checks again.
    @Test func repeatedLDuringAShuttleChecksMediaOnce() async throws {
        let calls = StepCounter()
        let studio = try await studio()
        studio.environment.beforeMediaCheck = { _ = calls.next() }
        await studio.perform(.seek(.start))

        for _ in 0..<3 { await studio.perform(.forward) }
        #expect(calls.calls == 1)
        await studio.perform(.pause)
        await studio.perform(.forward)
        #expect(calls.calls == 2)
    }

    // MARK: Criteria 15 and 16

    /// Control: a change of another engine changes nothing.
    @Test func anOutputChangeStopsAtThePosition() async throws {
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4800)
        // A hang guard: 3 times the worst wait, 12.0 s (run test-pool-health, loops/s3-8.log).
        await until(limit: .seconds(36), "the poll did not read the position") { studio.playhead == 4800 }

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())
        try await Task.sleep(for: .milliseconds(200))
        #expect(studio.playback != .stopped && studio.playbackStop == nil)

        await studio.play.player?.postConfigurationChange()
        // A hang guard: 3 times the worst wait, 5.4 s (run test-pool-health, loops/base-9.log).
        await until(limit: .seconds(17), "the output change did not stop the play") { studio.playback == .stopped }
        #expect(studio.playbackStop == .outputChanged && studio.playhead == 4800)
    }

    /// A package that left its volume (here: deleted) stops the play with its own cause, at a
    /// play from stopped, at a shuttle change, and during a play. The last media state stays.
    /// Found by the code gate.
    @Test(arguments: ["from stopped", "shuttle", "during play"])
    func aPackageThatLeftStopsThePlayWithItsCause(when: String) async throws {
        let studio = try await studio()
        try FileManager.default.moveItem(at: wav, to: package.folder.url.appending(path: "f1.wav"))
        await studio.checkMedia()
        await studio.perform(.seek(.start))
        if when != "from stopped" {
            await studio.perform(.playStop)
            _ = await studio.renderOffline(frames: 4800)
        }

        try FileManager.default.removeItem(at: package.url)
        await studio.checkMedia()
        switch when {
        case "from stopped": await studio.perform(.playStop)
        case "shuttle": await studio.perform(.forward)
        default: _ = await studio.renderOffline(frames: 9600)
        }

        // A hang guard: 3 times the worst wait, 12.5 s (run test-pool-health, loops/s3q-20.log).
        await until(limit: .seconds(38), "the play did not stop") { studio.playback == .stopped }
        #expect(studio.playbackStop == .packageUnavailable)
        #expect(studio.missingMedia == ["f1": .missing], "the last media state")
    }

    /// A rename during a play: a file that first opens after the rename opens in the renamed
    /// package, not as missing at the old path (the stored package path of the feed).
    @Test func aRenameDuringAPlayReadsTheRenamedPackage() async throws {
        try package.addFile("f2", channels: [ramp(frames: 24_000, channel: 1)])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 24_000, offset: 0, length: 24_000)
        try package.session.write(to: package.url)
        let mix = try package.mix(0..<28_800)
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        var out = await studio.renderOffline(frames: 4800)

        let renamed = package.folder.url.appending(path: "Renamed.dirigible")
        try #require(rename(package.url.path, renamed.path) == 0)
        for (channel, more) in await studio.renderOffline(frames: 24_000).enumerated() { out[channel] += more }

        expectMix(out, mix, "f2 plays from the renamed package")
        #expect(studio.missingMedia == [:])
        #expect(studio.playback != .stopped)
    }

    /// A file that goes during a play: the poll merges the read fault of the Player into
    /// `missingMedia` (decision 0017: the poll writes it only when a reading has a fault).
    @Test func aFileThatGoesDuringAPlayShowsFromThePoll() async throws {
        try package.addFile("f2", channels: [ramp(frames: 24_000, channel: 1)])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 24_000, offset: 0, length: 24_000)
        try package.session.write(to: package.url)
        let studio = try await studio()
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4800)
        #expect(studio.missingMedia == [:])

        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/f2.wav"))
        _ = await studio.renderOffline(frames: 24_000)

        // A hang guard: 3 times the worst wait, 8.2 s (run test-pool-health, loops/s3-8.log).
        await until(limit: .seconds(25), "the poll shows the fault") { studio.missingMedia == ["f2": .missing] }
        #expect(studio.playback != .stopped, "the play goes on")
        await studio.perform(.playStop)
    }

    /// The timeline draws the playhead line from the instant of the last playhead write.
    @Test func aSeekSetsThePlayheadTime() async throws {
        let studio = try await studio()
        let before = ContinuousClock.now
        #expect(studio.playheadTime < before)

        await studio.perform(.seek(.frame(100)))

        #expect(studio.playheadTime >= before)
    }

    /// Criterion P29 (run 2026-10-28-pre-roll): a failed read of the output term does not refuse a
    /// plain play. The play runs with a manual term, the reading has the fault, and the journal has
    /// one line with it. Control: a read that works gives its term and no line.
    @Test(arguments: [true, false])
    func failedTermReadKeepsPlainPlay(fails: Bool) async throws {
        let logs = package.folder.url.appending(path: "logs")
        let studio = try await studio()
        studio.environment.log = startLog(in: logs)
        let fault = HALReadFault(read: .bufferFrames, status: kAudioHardwareNotRunningError)
        studio.environment.outputTerm = { _ in fails ? .failure(.read(fault)) : .success(.builtIn) }
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)

        #expect(studio.playback == .playing(Shuttle(direction: .forward, rate: .one)))
        let reading = try await reading(studio)
        if fails {
            #expect(reading.termFault == .read(fault))
            #expect(reading.term != .builtIn, "the term of a failed read is the presentation latency")
        } else {
            #expect(reading.term == .builtIn && reading.termFault == nil)
        }
        await studio.perform(.playStop)
        studio.log.drain()
        let lines = try journalLines(of: try #require(journalFiles(in: logs).first))
        let faults = lines.filter { $0.contains("\tdevice\toutput-term-fault\t") }
        #expect(faults.count == (fails ? 1 : 0), "lines: \(lines)")
        if fails {
            #expect(
                faults.first?.hasSuffix("fault=read\tread=buffer-frames\tproperty=fsiz\tstatus=stop/1937010544")
                    == true, "\(faults)")
        }
    }

    /// Control: a start that works plays and shows no stop.
    @Test(arguments: [true, false])
    func aStartFailureShowsOutputUnavailable(fails: Bool) async throws {
        let studio = try await studio()
        studio.environment.startEngine = { engine in
            if fails { throw NSError(domain: NSOSStatusErrorDomain, code: -10_851) }
            try engine.start()
        }
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)

        if fails {
            // The poll of the play shows the stop after a hop to the Player, which waits for a thread
            // of the pool. The limit is a hang guard, not a speed: 3 times the worst wait, 19.4 s
            // (run test-pool-health, loops/s3q-20.log).
            await until(limit: .seconds(59), "the failure did not stop the play") { studio.playback == .stopped }
            #expect(studio.playbackStop == .outputUnavailable(-10_851) && studio.playhead == 0)
        } else {
            try await Task.sleep(for: .milliseconds(200))
            #expect(studio.playback != .stopped && studio.playbackStop == nil)
        }
    }
}
