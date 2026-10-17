import CoreAudio

/// The journal lines of the HAL calls of a writer (decision 0059). Each call that can block writes
/// its begin line first, so a call that never returns leaves it in the file.
extension DeviceWriter {
    /// `hal.attach` between `device attach-begin` and `device attach` with the ms and the status.
    func loggedAttach(_ input: DeviceInput) throws(HALError) -> Detach {
        let span = log.begin(.device, "attach-begin", ["device": .text(name), "uid": .uid(tracks.device.uid)])
        do throws(HALError) {
            let detach = try hal.attach(input)
            span.end("attach", ["device": .text(name), "status": .status(noErr)])
            return detach
        } catch {
            span.end("attach", level: .error, fields: [("device", .text(name))] + error.journalFields)
            throw error
        }
    }

    /// `hal.makeTap` between `tap create-begin` (the app and its process count) and `tap create`.
    /// The live tap writes the aggregate lines between them.
    func loggedTap(_ found: AppFound, app: String) throws(HALError) -> (
        id: AudioObjectID, device: InputDevice, teardown: Detach
    ) {
        let span = log.begin(
            .tap, "create-begin", ["app": .text(app), "processes": .number(Int64(found.key.processes.count))])
        do throws(HALError) {
            let tap = try hal.makeTap(found, log)
            span.end("create", ["status": .status(noErr)])
            return tap
        } catch {
            span.end("create", level: .error, fields: error.journalFields)
            throw error
        }
    }
}

/// The journal lines of the events of a writer on its queue (decision 0059). A listener posts the
/// event and logs nothing.
extension DeviceWriter {
    /// One line for each event that the queue handles. `posts` is the count of device-list posts
    /// that this handler serves.
    func note(_ event: Event, posts: Int) {
        let device = DiagnosticValue.text(name)
        switch event {
        case .rate(let rate): log.note(.device, "rate", ["device": device, "rate": .number(Int64(rate.rounded()))])
        case .layout(let channels):
            log.note(
                .device, "layout",
                ["device": device, "channels": .text(channels.map(String.init).joined(separator: ","))])
        case .alive(let alive): log.note(.device, "alive", ["device": device, "alive": .text("\(alive)")])
        case .devicesChanged:
            log.note(.device, "devices-changed", ["device": device, "coalesced": .number(Int64(posts))])
        }
    }

    /// `device come-back` with the try number since the loss, its outcome, and the backoff after
    /// it; then `device back` when the try attached.
    func noteComeBack(attached: Bool) {
        let wait = comeBacks.backoff / .milliseconds(1)
        log.note(
            .device, "come-back",
            [
                "device": .text(name), "try": .number(Int64(comeBacks.tries)),
                "outcome": .text(comeBacks.outcome?.rawValue ?? "none"), "wait_ms": .milliseconds(wait),
            ])
        if attached { log.note(.device, "back", ["device": .text(name)]) }
    }

    /// A detach or a teardown that failed: a late IOProc call can still use its ring bytes.
    func countFailedDetach() {
        failedDetaches += 1
        log.note(
            .device, "detach-failed", level: .error, ["device": .text(name), "count": .number(Int64(failedDetaches))])
    }

    /// The `device input-gap` and `device dropped` lines that are due at `now`. `force` writes each
    /// count that waits, at the end of the writer.
    func noteLimitedLines(at now: ContinuousClock.Instant, force: Bool = false) {
        if let gaps = tracks.inputGaps.take(at: now, force: force) {
            log.note(
                .device, "input-gap",
                ["device": .text(name), "frames": .number(gaps.sum), "count": .number(Int64(gaps.count))])
        }
        if let drops = drops.take(at: now, force: force) {
            log.note(
                .device, "dropped",
                [
                    "device": .text(name), "total": .number(Int64(droppedFrames)), "new": .number(drops.sum),
                    "count": .number(Int64(drops.count)),
                ])
        }
    }
}

extension HALError {
    /// The fields of a failed call: the case, and the status when the case has one.
    var journalFields: [(key: String, value: DiagnosticValue)] {
        switch self {
        case .status(let status): [("status", .status(status))]
        case .unsupportedFormat: [("error", .text("unsupportedFormat"))]
        case .undone(let status): [("error", .text("undone")), ("status", .status(status))]
        case .undoFailed: [("error", .text("undoFailed"))]
        }
    }
}

/// Why a writer is lost: an IsAlive event, a device-list event (a new object, or no app output),
/// a layout with no routed channel, the watchdog, or an attach that did not attach.
enum LossCause: String {
    case alive, list, layout
    case noRecord = "no-record"
    case attachFailed = "attach-failed"
}

/// At most one journal line each second for one kind of event of a writer (decision 0059). The
/// first event opens a window, and the line at its end has the count and the sum of its events.
struct LineLimit {
    static let window = Duration.seconds(1)
    private var start: ContinuousClock.Instant?
    private var count = 0
    private var sum: Int64 = 0

    mutating func add(_ amount: Int64, at now: ContinuousClock.Instant) {
        if start == nil { start = now }
        count += 1
        sum += amount
    }

    /// The count and the sum of a window that ended by `now`, and with `force` of an open window.
    /// Nil when no line is due.
    mutating func take(at now: ContinuousClock.Instant, force: Bool = false) -> (count: Int, sum: Int64)? {
        guard let start, force || now - start >= Self.window else { return nil }
        defer { self = LineLimit() }
        return (count, sum)
    }
}
