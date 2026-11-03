import CMainStack
import CoreAudio
import CryptoKit
import Foundation

/// The facts of the Mac that a bundle reads at collect time. Tests give a fake device list, fake
/// names, and a fake walk.
struct BundleFacts: Sendable {
    var version: String
    var commit: String
    var devices: [BundleDevice]
    /// The name of the default output device, or nil when there is none.
    var defaultOutput: String?
    /// Nil when the access is granted.
    var microphone: MicrophoneAccess?
    var freeBytes: Int64?
    var redaction: Redaction
    var walk: @Sendable (ms_thread, UnsafeMutablePointer<UInt>, Int32) -> ms_walk_result = { ms_walk($0, $1, $2) }

    /// The HAL reads of `dirigible devices` and the defaults, the microphone status (no prompt),
    /// the free bytes of the home volume, and the names of this Mac.
    static func live(version: String, commit: String) -> BundleFacts {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let input = AudioDefaults.liveDefault(kAudioHardwarePropertyDefaultInputDevice)
        let output = AudioDefaults.liveDefault(kAudioHardwarePropertyDefaultOutputDevice)
        let ids = (try? readArray(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self)) ?? []
        let devices = ids.compactMap { id -> BundleDevice? in
            guard let device = InputDevice.read(id), !visibleInputs([device]).isEmpty else { return nil }
            return BundleDevice(
                uid: device.uid, name: device.name, channels: device.channelCount, rate: device.nominalRate,
                transport: (try? readValue(id, kAudioDevicePropertyTransportType, as: UInt32.self)).map(fourCharacters)
                    ?? "unknown",
                bufferFrames: (try? readValue(id, kAudioDevicePropertyBufferFrameSize, as: UInt32.self)).map(Int.init),
                isDefaultInput: id == input, isDefaultOutput: id == output)
        }
        let home = try? URL(filePath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return BundleFacts(
            version: version, commit: commit, devices: devices,
            defaultOutput: output.flatMap { readString($0, kAudioObjectPropertyName) },
            microphone: CaptureEnvironment.live.microphoneAccess(),
            freeBytes: home?.volumeAvailableCapacityForImportantUsage, redaction: .live())
    }
}

/// One input device of `devices.tsv`.
struct BundleDevice: Sendable {
    let uid: String
    let name: String
    let channels: Int
    let rate: Double
    /// The four-character transport code, for example `usb` or `blue`.
    let transport: String
    let bufferFrames: Int?
    let isDefaultInput: Bool
    let isDefaultOutput: Bool
}

/// `48000`, or `44100.5` for a rate with a fraction, as `dirigible devices` writes it.
private func rateText(_ rate: Double) -> String { rate.rounded() == rate ? String(Int(rate)) : String(rate) }

/// `bltn` for `kAudioDeviceTransportTypeBuiltIn`, with no trailing space; else the integer.
func fourCharacters(_ code: UInt32) -> String {
    let bytes = withUnsafeBytes(of: code.bigEndian, Array.init)
    guard code != 0, bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(code) }
    return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

extension DiagnosticBundle {
    /// The columns of `dirigible devices` with the UID as its journal token, then the transport,
    /// the buffer frame size, and the default flags.
    static func deviceTable(_ devices: [BundleDevice], salt: SymmetricKey) -> String {
        let header = "uid\tname\tchannels\trate\ttransport\tbuffer_frames\tdefault_input\tdefault_output\n"
        return header
            + devices.map { device in
                let columns = [
                    "uid-" + token(device.uid, salt: salt), escaped(device.name), String(device.channels),
                    rateText(device.rate), device.transport, device.bufferFrames.map(String.init) ?? "unknown",
                    device.isDefaultInput ? "1" : "0", device.isDefaultOutput ? "1" : "0",
                ]
                return columns.joined(separator: "\t") + "\n"
            }.joined()
    }

    /// The build facts, the Mac, the free space, the microphone status, the default devices, the
    /// counts, the walk self-check, and one line for each skipped group.
    static func summary(_ facts: BundleFacts, salt: SymmetricKey, logs: Int, reports: Int, skipped: [String])
        -> String
    {
        var lines = ["dirigible-report 1"]
        for (key, value) in launchFields(version: facts.version, commit: facts.commit) {
            if case .text(let text) = value { lines.append("\(key) \(text)") }
        }
        let microphone =
            switch facts.microphone {
            case nil: "granted"
            case .notDetermined: "not-determined"
            case .denied: "denied"
            case .restricted: "restricted"
            }
        let input = facts.devices.first(where: \.isDefaultInput).map { "\($0.name) uid-\(token($0.uid, salt: salt))" }
        lines += [
            "free_bytes \(facts.freeBytes.map(String.init) ?? "unknown")", "microphone \(microphone)",
            "default_input \(input ?? "none")", "default_output \(facts.defaultOutput ?? "none")",
            "logs \(logs)", "reports \(reports)", walkCheck(facts.walk),
        ]
        lines += skipped.map { "skipped \($0)" }
        return lines.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\n") + "\n"
    }

    /// The `stack walk` line (C48): a walk of a helper thread that waits in `read(2)`, called from
    /// `holdForStackWalkProbe`, with its frames named. `ok` needs 3 frames or more, the helper as
    /// the frame after the system call stub, and a named frame of a system library, so each bundle
    /// shows if the walk of the hang watchdog works on its macOS and its architecture.
    static func walkCheck(_ walk: (ms_thread, UnsafeMutablePointer<UInt>, Int32) -> ms_walk_result) -> String {
        guard let probe = WalkProbe() else { return "stack walk failed reason=no-pipe" }
        defer { probe.release() }
        Thread { holdForStackWalkProbe(probe) }.start()
        guard probe.ready.wait(timeout: .now() + 5) == .success else { return "stack walk failed reason=no-helper" }
        let capacity = 128
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        defer { frames.deallocate() }
        var result = ms_walk_result()
        var names: [FrameName] = []
        // The helper signals before its read, so the walks go on until its pc is in a system stub.
        for _ in 0..<100 {
            result = walk(probe.thread, frames, Int32(capacity))
            let stack = UnsafeBufferPointer(start: frames, count: Int(max(result.count, 0)))
            // A return address is named at the address before it, inside the call.
            names = stack.enumerated().map { index, address in
                dladdrName(index == 0 || address == 0 ? address : address - 1)
            }
            if names.isEmpty || names.first.map(isSystem) == true { break }
            usleep(10_000)
        }
        let named = names.filter { $0.symbol != nil }
        let helper = names.dropFirst().first?.symbol?.contains("holdForStackWalkProbe") == true
        let system = named.contains(where: isSystem)
        let ok = result.status == KERN_SUCCESS && names.count >= 3 && helper && system
        var line = "stack walk \(ok ? "ok" : "failed") frames=\(names.count) named=\(named.count)"
        line += " helper=\(helper ? "yes" : "no") system=\(system ? "yes" : "no")"
        return ok ? line : line + " status=\(result.status)"
    }

    private static func isSystem(_ name: FrameName) -> Bool {
        name.image.map { $0.hasPrefix("/usr/lib/") || $0.hasPrefix("/System/") } == true
    }
}

/// The helper thread of the walk self-check. `thread` is written before `ready` and read after it.
/// The helper reads one byte from the pipe, and `release` writes it.
final class WalkProbe: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    var thread = ms_thread()
    private(set) var pipe: [Int32] = [-1, -1]

    init?() {
        guard Darwin.pipe(&pipe) == 0 else { return nil }
    }

    func release() { _ = write(pipe[1], [UInt8(1)], 1) }

    deinit { for descriptor in pipe { close(descriptor) } }
}

/// The frame that the walk self-check looks for. Its name has no word of the module name, so the
/// Swift mangling keeps it whole in the symbol. Internal, not private: `dladdr` names it. It
/// calls the `read` stub itself, and the read is not the last step, so an optimized build makes
/// no tail call that removes the frame.
@inline(never) func holdForStackWalkProbe(_ probe: WalkProbe) {
    probe.thread = ms_thread_current()
    probe.ready.signal()
    var byte: UInt8 = 0
    _ = read(probe.pipe[0], &byte, 1)
    withExtendedLifetime(probe) {}
}
