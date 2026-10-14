import AVFoundation
import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The banner Cancel of a window stops an agent job that runs in its studio (decision 0049, C16).
/// Track t1 has clip c1 of 10 s of noise, so a level has 8 blocks.
@Suite(.serialized) @MainActor struct SessionWindowAgentJobTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// Opens the window, and holds a level of its studio before its second block.
    func open() async throws -> (SessionWindow, Studio, BlockHold) {
        let (model, studio, _, _) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 1, seconds: 10, noise: true))
        let hold = BlockHold()
        studio.environment.loudnessBlock = { hold.step() }
        return (model, studio, hold)
    }

    /// C16: the Cancel of the level banner ends a level of an agent: no gain change, no undo entry.
    @Test func aWindowCancelEndsAnAgentLevel() async throws {
        let (model, studio, hold) = try await open()
        defer { hold.release() }
        let agent = AgentName(title: "Test Agent", clientName: nil)
        let level = Task { () async -> StudioError? in
            do throws(StudioError) {
                _ = try await studio.level(["c1"], .eachClip, agent: agent)
                return nil
            } catch {
                return error
            }
        }
        await until("the level holds") { hold.held }
        #expect(studio.transport == .leveling, "\(studio.transport)")

        model.cancelLevel()
        hold.release()

        let error = await level.value
        #expect(error == .levelCancelled, "\(String(describing: error))")
        #expect(studio.session.clip("c1")?.clip.gain == .zero && !studio.canUndo, "a cancelled level changed a gain")
        #expect(studio.transport == .idle)
        await model.close()
    }

    /// A level of the window that its banner Cancel ends shows no alert and changes no gain.
    @Test func aCancelledWindowLevelShowsNoAlert() async throws {
        let (model, studio, hold) = try await open()
        defer { hold.release() }
        let level = Task { await model.level(.eachClip) }
        await until("the level holds") { hold.held }

        model.cancelLevel()
        hold.release()
        await level.value

        #expect(model.alert == nil, "a cancelled level shows \(String(describing: model.alert))")
        #expect(studio.session.clip("c1")?.clip.gain == .zero && !studio.canUndo, "a cancelled level changed a gain")
        await model.close()
    }
}

extension SessionWindowAgentJobTests {
    /// Writes 4 s of a mono sine at 48 kHz beside the package: three blocks of the conversion.
    func source() throws -> URL {
        let url = folder.url.appending(path: "Voice.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000))
        buffer.frameLength = 192_000
        for frame in 0..<192_000 { buffer.floatChannelData![0][frame] = Float(0.1 * sin(Double(frame) / 8)) }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        return url
    }

    /// C16: an agent import has no import job in the window. The banner bar shows the progress of
    /// the studio, and the banner Cancel ends the import: no clip, no undo entry, no new file.
    @Test func aWindowCancelEndsAnAgentImport() async throws {
        let (model, studio, _) = try await open()
        let hold = BlockHold()
        defer { hold.release() }
        studio.environment.importStep = { hold.step() }
        let (url, clips) = (try source(), studio.url.appending(path: "Clips"))
        let names = try FileManager.default.contentsOfDirectory(atPath: clips.path)
        let agent = AgentName(title: "Test Agent", clientName: nil)
        let imported = Task { () async -> StudioError? in
            do throws(StudioError) {
                _ = try await studio.importAudio(url, to: ImportTarget(track: nil, start: 0), agent: agent) { _ in }
                return nil
            } catch {
                return error
            }
        }
        await until("the import holds") { hold.held }
        await until("the bar shows no progress") { model.importBarProgress > 0 }
        #expect(model.importJob == nil, "an agent import has no job of the window")

        model.cancelImport()
        hold.release()

        let error = await imported.value
        #expect(error == .audioImport(.cancelled), "\(String(describing: error))")
        #expect(studio.session.tracks.count == 1 && !studio.canUndo, "a cancelled import added a clip")
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path) == names, "a file stays")
        await model.close()
    }

    /// G24: the job of the window comes first, so a paste or a chain shows its own fraction.
    @Test func aPasteBarShowsThePasteProgress() async throws {
        let (model, studio, _) = try await open()
        studio.importProgress = 0.9
        model.importJob = ImportJob(progress: 0.25, visible: true)
        #expect(model.importBarProgress == 0.25, "\(model.importBarProgress)")
        model.importJob = nil
        #expect(model.importBarProgress == 0.9, "\(model.importBarProgress)")
        await model.close()
    }
}

/// Holds a job once, at its third block step: after the first block and its progress.
final class BlockHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var steps = 0

    var held: Bool { lock.withLock { steps >= 3 } }

    func step() {
        let hold = lock.withLock {
            steps += 1
            return steps == 3
        }
        if hold { semaphore.wait() }
    }

    /// A second release leaves the semaphore at 1, which no later step reads.
    func release() { semaphore.signal() }
}
