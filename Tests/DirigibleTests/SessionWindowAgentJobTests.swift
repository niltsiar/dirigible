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

    /// Opens the window, and holds each level of its studio before its second block.
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

/// Holds a measure once, at its third block step: after the first block and its progress.
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
