import Atomics
import CMainStack
import Foundation

/// The name of one code address: the symbol with its offset, and the image path.
struct FrameName: Sendable {
    let symbol: String?
    let image: String?
}

/// Writes `hang` lines when the main thread does not answer (decision 0059). A timer on the
/// watchdog queue pings the watched queue, and `HangRule` decides each line. No line goes through
/// the watched queue, so the lines reach the file while it is blocked.
public final class HangWatchdog: Sendable {
    private let watch: Watch

    private init(watch: Watch) { self.watch = watch }

    /// Pings the main queue and walks the main thread, with the shipped limits.
    @MainActor public static func start(log: DiagnosticLog) -> HangWatchdog {
        start(log: log, ping: .main, thread: ms_thread_current(), limits: HangLimits(), namer: dladdrName)
    }

    /// Starts the image list and the timer. The handlers are made in this nonisolated function,
    /// so no closure takes the isolation of a caller (0013 Callbacks).
    static func start(
        log: DiagnosticLog, ping: DispatchQueue, thread: ms_thread, limits: HangLimits,
        namer: @escaping @Sendable (UInt) -> FrameName,
        images: @escaping @Sendable () -> [(key: String, value: DiagnosticValue)] = imageFields
    ) -> HangWatchdog {
        ms_images_start()
        let watch = Watch(log: log, ping: ping, thread: thread, limits: limits, namer: namer, images: images)
        let nanos = Int(limits.interval / .nanoseconds(1))
        watch.timer.schedule(deadline: .now(), repeating: .nanoseconds(nanos), leeway: .nanoseconds(nanos / 10))
        watch.timer.setEventHandler { tick(watch) }
        watch.timer.activate()
        return HangWatchdog(watch: watch)
    }

    /// Cancels the timer and stops the rule on the watchdog queue, so a handler that runs after
    /// the cancel writes nothing. Then waits for a burst to end at its next pause, so no `hang`
    /// line comes after the return.
    public func stop() {
        watch.timer.cancel()
        watch.queue.sync { watch.rule.stop() }
        watch.stopped.store(true, ordering: .releasing)
        watch.wake.signal()
        watch.burstQueue.sync {}
    }

    private static func tick(_ watch: Watch) {
        switch watch.rule.tick(now: .now) {
        case .ping: watch.ping.async { answer(watch) }
        case .hangStart(let late, let takesBurst):
            watch.log.note(.hang, "start", ["late_ms": .milliseconds(late / .milliseconds(1))])
            guard takesBurst else { break }
            watch.burstQueue.async(qos: .userInteractive, flags: .enforceQoS) { burst(watch) }
        case .hangEnd, nil: break
        }
    }

    /// Runs on the watched queue: it takes the time there and writes on the watchdog queue.
    private static func answer(_ watch: Watch) {
        let now = HangInstant.now
        watch.queue.async {
            guard case .hangEnd(let blocked, let slept) = watch.rule.answered(now: now) else { return }
            watch.log.note(
                .hang, "end",
                [
                    "blocked_ms": .milliseconds(blocked / .milliseconds(1)),
                    "slept_ms": .milliseconds(slept / .milliseconds(1)),
                ])
        }
    }

    /// The images line, then the raw stacks, then the names. The first walk comes before the
    /// images line, so a hang that ends while that line is written still gives one stack of the
    /// block. A thread that holds the dyld lock blocks `dladdr`, so no dyld call runs before the
    /// last stack line. The walks run on a user-interactive queue, so the suspend stays short when
    /// each core is busy (probe Q4c).
    private static func burst(_ watch: Watch) {
        guard !watch.isStopped else { return }
        let capacity = 128
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        defer { frames.deallocate() }
        var stacks: [[UInt]] = []
        for number in 1...watch.limits.burstStacks {
            if number > 1 {
                _ = watch.wake.wait(timeout: .now() + watch.limits.burstPause / .seconds(1))
                guard !watch.isStopped else { return }
            }
            let walk = ms_walk(watch.thread, frames, Int32(capacity))
            let stack = Array(UnsafeBufferPointer(start: frames, count: Int(walk.count)))
            if number == 1 { watch.log.note(.hang, "images", fields: watch.images()) }
            stacks.append(stack)
            var fields: [(key: String, value: DiagnosticValue)] = [
                ("n", .number(Int64(number))), ("suspend_us", .text(String(format: "%.1f", microseconds(walk)))),
            ]
            if walk.status != KERN_SUCCESS { fields.append(("status", .number(Int64(walk.status)))) }
            fields.append(("frames", .text(stack.map(hex).joined(separator: ","))))
            watch.log.note(.hang, "stack", fields: fields)
        }
        var distinct: [(stack: [UInt], numbers: [Int])] = []
        for (index, stack) in stacks.enumerated() {
            if let found = distinct.firstIndex(where: { $0.stack == stack }) {
                distinct[found].numbers.append(index + 1)
            } else {
                distinct.append((stack, [index + 1]))
            }
        }
        for (stack, numbers) in distinct {
            guard !watch.isStopped else { return }
            watch.log.note(.hang, "names", fields: nameFields(stack, numbers: numbers, namer: watch.namer))
        }
    }

    /// The header address, the slide, and the UUID of each image of the list.
    private static func imageFields() -> [(key: String, value: DiagnosticValue)] {
        var list: [String] = []
        var header: UInt = 0
        var slide = 0
        var uuid = [UInt8](repeating: 0, count: 16)
        for index in 0..<ms_images_count() where ms_image_at(index, &header, &slide, &uuid) {
            list.append("\(hex(header)):\(hex(UInt(bitPattern: slide))):\(uuidText(uuid))")
        }
        var fields: [(key: String, value: DiagnosticValue)] = [("count", .number(Int64(list.count)))]
        let dropped = ms_images_dropped()
        if dropped > 0 { fields.append(("dropped", .number(Int64(dropped)))) }
        return fields + [("list", .text(list.joined(separator: ",")))]
    }

    /// The names of one stack. A return address is named at the address before it, inside the
    /// call. An image path in the home folder starts with `~`.
    private static func nameFields(_ stack: [UInt], numbers: [Int], namer: (UInt) -> FrameName)
        -> [(key: String, value: DiagnosticValue)]
    {
        let named = stack.enumerated().map { index, address in namer(index == 0 || address == 0 ? address : address - 1)
        }
        var images: [String] = []
        for image in named.compactMap(\.image) where !images.contains(image) { images.append(image) }
        let home = NSHomeDirectory() + "/"
        return [
            ("stacks", .text(numbers.map(String.init).joined(separator: ","))),
            ("names", .text(named.map { $0.symbol ?? "?" }.joined(separator: "|"))),
            (
                "images",
                .text(images.map { $0.hasPrefix(home) ? "~/" + $0.dropFirst(home.count) : $0 }.joined(separator: "|"))
            ),
        ]
    }
}

/// The state of one watchdog. Only `queue` reads and writes `rule`.
private final class Watch: @unchecked Sendable {
    let log: DiagnosticLog
    let ping: DispatchQueue
    let thread: ms_thread
    let limits: HangLimits
    let namer: @Sendable (UInt) -> FrameName
    let images: @Sendable () -> [(key: String, value: DiagnosticValue)]
    /// User-interactive, so a loaded Mac delays the ticks less.
    let queue = DispatchQueue(label: "Dirigible.Watchdog", qos: .userInteractive)
    let burstQueue = DispatchQueue(label: "Dirigible.Watchdog.burst", qos: .userInteractive)
    let timer: DispatchSourceTimer
    var rule: HangRule
    let stopped = ManagedAtomic(false)
    /// `stop` signals it, so a burst ends at its next pause.
    let wake = DispatchSemaphore(value: 0)

    var isStopped: Bool { stopped.load(ordering: .acquiring) }

    init(
        log: DiagnosticLog, ping: DispatchQueue, thread: ms_thread, limits: HangLimits,
        namer: @escaping @Sendable (UInt) -> FrameName,
        images: @escaping @Sendable () -> [(key: String, value: DiagnosticValue)]
    ) {
        self.log = log
        self.ping = ping
        self.thread = thread
        self.limits = limits
        self.namer = namer
        self.images = images
        rule = HangRule(limits: limits)
        timer = DispatchSource.makeTimerSource(queue: queue)
    }
}

/// The symbol with its offset and the image path of `address`, from `dladdr`.
func dladdrName(_ address: UInt) -> FrameName {
    var info = Dl_info()
    guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0 else {
        return FrameName(symbol: nil, image: nil)
    }
    let image = info.dli_fname.map { String(cString: $0) }
    guard let symbol = info.dli_sname, let start = info.dli_saddr else { return FrameName(symbol: nil, image: image) }
    return FrameName(symbol: "\(String(cString: symbol))+\(hex(address - UInt(bitPattern: start)))", image: image)
}

private func hex(_ value: UInt) -> String { "0x" + String(value, radix: 16) }

/// `8-4-4-4-12` upper-case hex, as a crash report writes an image UUID.
private func uuidText(_ bytes: [UInt8]) -> String {
    let text = bytes.map { String(format: "%02X", $0) }.joined()
    let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
        text.dropFirst(range.lowerBound).prefix(range.count)
    }
    return parts.joined(separator: "-")
}

private let timebase: mach_timebase_info_data_t = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return timebase
}()

/// The suspend window of a walk.
private func microseconds(_ walk: ms_walk_result) -> Double {
    Double(walk.resumed_at - walk.suspended_at) * Double(timebase.numer) / Double(timebase.denom) / 1000
}
