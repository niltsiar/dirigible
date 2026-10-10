import Foundation
import os

/// What a Listener tells its owner (decision 0044): it plays, or it plays no sound (the device is
/// absent, the output failed, a stop or a detach failed, or the keep limit).
enum ListenReport: Sendable, Equatable { case playing, quiet }

/// The record monitor of one device (decision 0044). It attaches a listen IOProc to the device
/// and starts an output unit that plays the ring of that appearance. While the device is absent
/// or the output fails, it tries again each `retryInterval`. No take step touches it. Its control
/// state is confined to its serial queue, so it is `@unchecked Sendable`.
final class Listener: @unchecked Sendable {
    enum Event: Sendable {
        case rate(Double)
        case alive(Bool)
    }

    /// The appearances that the Listener gave up (kept for the process life), the rings of them
    /// whose bytes it freed, and the retries that it scheduled.
    struct Counts: Equatable, Sendable {
        var kept = 0
        var freed = 0
        var retries = 0
    }

    /// The kept appearances of one Listener: about 200 bytes each, as a monitor (decision 0015).
    static let keepLimit = 64

    /// The state that `mute` and `setMap` change from any thread: the map, the mute, and the ring
    /// of the current appearance. A new ring takes the map and the mute.
    private struct Shared {
        var map: ChannelMap
        var muted = false
        var ring: ListenRing?
    }

    /// One appearance that plays: its input, the detach of its IOProc, the stop of its unit.
    private struct Appearance {
        let input: ListenInput
        let detach: Detach
        var stop: Detach
        let inputBlock: Int
    }

    private enum Phase { case waiting, playing, off }

    private let uid: String
    private let hal: DeviceHAL
    private let output: ListenOutput
    private let report: @Sendable (ListenReport) -> Void
    private let retryInterval: Duration
    private let keepLimit: Int
    private let queue: DispatchQueue
    private let shared: OSAllocatedUnfairLock<Shared>
    private var phase = Phase.waiting
    private var current: Appearance?
    private var counts = Counts()
    private var reported: ListenReport?

    init(
        uid: String, map: ChannelMap, hal: DeviceHAL, output: ListenOutput,
        report: @escaping @Sendable (ListenReport) -> Void, retryInterval: Duration = .seconds(1),
        keepLimit: Int = Listener.keepLimit
    ) {
        self.uid = uid
        self.hal = hal
        self.output = output
        self.report = report
        self.retryInterval = retryInterval
        self.keepLimit = keepLimit
        shared = OSAllocatedUnfairLock(initialState: Shared(map: map))
        queue = DispatchQueue(label: "Dirigible.Listener.\(uid)")
    }

    /// The first attach try. A device that is absent waits.
    func start() { queue.async { [self] in tryStart() } }

    /// The next push of the current ring and each new ring uses `map`, with no restart.
    func setMap(_ map: ChannelMap) {
        shared.withLock {
            $0.map = map
            $0.ring?.setMap(map)
        }
    }

    /// Zeros from the next render, on any thread, also for the ring of a later retry.
    func mute() {
        shared.withLock {
            $0.muted = true
            $0.ring?.mute()
        }
    }

    /// Mutes, then on the queue stops the unit, detaches, and removes the speaker listeners. No
    /// report and no retry comes after it. A second call does nothing.
    func off() async {
        mute()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if phase != .off {
                    end(stopped: current?.stop() ?? true)
                    phase = .off
                }
                done.resume()
            }
        }
    }

    /// A device listener passes its own input. An event of an input that is not the current one
    /// does nothing.
    func post(_ event: Event, from sender: ListenInput) {
        queue.async { [self] in
            guard phase == .playing, let current, current.input === sender else { return }
            switch event {
            case .rate(let rate): restart(rate: rate)
            case .alive(false):
                end(stopped: current.stop())
                wait()
            case .alive(true): break
            }
        }
    }

    func counts() async -> Counts {
        await withCheckedContinuation { done in queue.async { [self] in done.resume(returning: counts) } }
    }

    /// A new appearance with a new ring: attach, then the output. At the keep limit, it tries no
    /// more until the next on.
    private func tryStart() {
        guard phase == .waiting, counts.kept < keepLimit else { return }
        guard let found = hal.lookUp(uid) else { return wait() }
        let rate = found.device.nominalRate
        let ring = ListenRing(rate: rate, inputBlock: 512, pull: 512)
        shared.withLock {
            ring.setMap($0.map)
            if $0.muted { ring.mute() }
            $0.ring = ring
        }
        let input = ListenInput(id: found.id, ring: ring, listener: self)
        let attached: (inputBlock: Int, detach: Detach)
        do throws(HALError) {
            attached = try hal.attachListen(input)
        } catch .undone {
            keep(input, clean: true)
            return wait()
        } catch .undoFailed {
            keep(input, clean: false)
            return wait()
        } catch {
            // No IOProc and no listener exist, so no call can reach the ring.
            shared.withLock { $0.ring = nil }
            ring.deallocate()
            return wait()
        }
        output.watch(ring)
        do throws(HALError) {
            let stop = try output.start(ring, rate, attached.inputBlock)
            current = Appearance(input: input, detach: attached.detach, stop: stop, inputBlock: attached.inputBlock)
            phase = .playing
            send(.playing)
        } catch {
            output.unwatch(ring)
            keep(input, clean: attached.detach())
            wait()
        }
    }

    /// A5: a clean stop is a barrier (probe P9), so the next start flushes the ring and makes a
    /// new rule at the new rate. A failed stop keeps the unit and the ring with their frames.
    private func restart(rate: Double) {
        guard var playing = current else { return }
        let stopped = playing.stop()
        if stopped {
            do throws(HALError) {
                playing.stop = try output.start(playing.input.ring, rate, playing.inputBlock)
                current = playing
                return
            } catch {}
        }
        end(stopped: stopped)
        wait()
    }

    /// Detaches the current appearance, removes its speaker listeners, and keeps it. `stopped`
    /// is the result of its unit stop.
    private func end(stopped: Bool) {
        guard let playing = current else { return }
        let detached = playing.detach()
        output.unwatch(playing.input.ring)
        keep(playing.input, clean: stopped && detached)
        current = nil
    }

    /// Keeps `input` and its ring context for the process life (decision 0013 Detach): a listener
    /// call can still be in progress. Only with no IOProc call and no render left are the ring
    /// bytes freed.
    private func keep(_ input: ListenInput, clean: Bool) {
        _ = Unmanaged.passRetained(input)
        counts.kept += 1
        if clean {
            input.ring.deallocateBytes()
            counts.freed += 1
        }
        shared.withLock { $0.ring = nil }
    }

    private func wait() {
        phase = .waiting
        send(.quiet)
        // At the keep limit, no retry: the next on makes a new Listener.
        guard counts.kept < keepLimit else { return }
        counts.retries += 1
        queue.asyncAfter(deadline: .now() + retryInterval / .seconds(1)) { [weak self] in self?.tryStart() }
    }

    private func send(_ value: ListenReport) {
        guard value != reported else { return }
        reported = value
        report(value)
    }
}
