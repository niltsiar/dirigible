import CoreAudio
import DirigibleCore

/// The attach of a writer on its queue (decision 0013): the device lookup or the app tap, the
/// ring, and `hal.attach`.
extension DeviceWriter {
    /// A new `DeviceInput` for the device as the lookup finds it now. The routed channels are
    /// checked before a ring exists, and a ring of an attach that threw is used again. At the
    /// keep limit it attaches no more, and it reports `.retryStopped` once. A try that makes a tap
    /// or calls `hal.attach` and does not attach opens a come-back window.
    func attach() -> Bool {
        guard lifecycle.state != .abandoned else { return false }
        var outcome = ComeBackSchedule.Outcome.absent
        defer { comeBacks.tried(outcome, at: .now) }
        guard kept < keepLimit else {
            if !retryStopped {
                retryStopped = true
                for arm in tracks.arms { report(.state(take: tracks.take, arm: arm, .retryStopped, status: nil)) }
            }
            return false
        }
        guard failedDetaches < Self.failedDetachLimit, let found = find(&outcome) else { return false }
        tracks.use(found.device)
        let capacity = CaptureRing.capacity(for: found.device, seconds: ringSeconds)
        if let spare, spare.capacity != capacity {
            spare.deallocate()
            self.spare = nil
        }
        let ring = spare ?? CaptureRing(capacity: capacity, rate: found.device.nominalRate)
        spare = nil
        ring.setRate(found.device.nominalRate)
        let input = DeviceInput(id: found.id, ring: ring, writer: self)
        let detachAll: Detach
        outcome = .failed
        do throws(HALError) {
            let detach = try loggedAttach(input)
            let teardown = found.teardown
            // Each step runs; the detach is clean only when both are (A6). The IOProc goes first:
            // an aggregate destroy with a live IOProc gives late calls (probe P12).
            detachAll = { [detach(), teardown()].allSatisfy { $0 } }
        } catch .undoFailed {
            _ = found.teardown()
            keep(input, clean: false)
            return false
        } catch .undone {
            // A listener call can still be in progress, as after a clean detach.
            keep(input, clean: found.teardown())
            return false
        } catch {
            spare = ring
            if !found.teardown() { countFailedDetach() }
            return false
        }
        // A stop that gave up the writer during the attach gets no record from it.
        let before = lifecycle.attach()
        guard before != .abandoned else {
            keep(input, clean: detachAll())
            return false
        }
        self.input = (input, detachAll, found.key)
        phase = .running
        lastValid = .now
        hasRecord = false
        outcome = .attached
        if before == .notAttached { reportFirst() }
        return true
    }

    /// The first report of the writer, at its first attach: `.recording` for a device, and for an
    /// app `.waitingForApp` while it has no process. It replaces the state of the take start.
    private func reportFirst() {
        appState = input?.key?.processes.isEmpty == true ? .waitingForApp : .recording
        for arm in tracks.arms { report(.state(take: tracks.take, arm: arm, appState, status: nil)) }
    }

    /// The device as the lookup finds it now with the routed channels. For an app, a new tap and
    /// aggregate of its processes now (decision 0030); a device has no teardown.
    private func find(_ outcome: inout ComeBackSchedule.Outcome) -> Found? {
        guard let app else {
            guard let found = hal.lookUp(tracks.device.uid), tracks.hasRoutedChannels(found.device) else { return nil }
            return (found.id, found.device, { true }, nil)
        }
        let layout = ChannelLayout(channelCount: tracks.routedWidth) ?? .mono
        guard let found = hal.lookUpApp(app, layout) else { return nil }
        outcome = .failed
        guard let tap = try? loggedTap(found, app: app) else { return nil }
        guard tracks.hasRoutedChannels(tap.device) else {
            if !tap.teardown() { countFailedDetach() }
            return nil
        }
        return (tap.id, tap.device, tap.teardown, AppKey(processes: found.key.processes, output: found.output))
    }
}
