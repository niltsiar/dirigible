import AudioToolbox
import CoreAudio
import Testing

@testable import DirigibleAudio

extension OutputTerm {
    /// The term of the built-in speakers of the S1 step 0 probe (run 2026-10-28-pre-roll): device
    /// latency 19, stream latency 284, safety offset 77, and an IO buffer of 512 frames at 48 kHz.
    /// Each part differs, so a dropped or doubled part gives another sum.
    static let builtIn = OutputTerm.device(
        Device(latency: 19, streamLatency: 284, safetyOffset: 77, bufferFrames: 512, rate: 48_000, uid: "out-uid")!)
}

/// Criterion P29 (run 2026-10-28-pre-roll): the output term and its conversion at the device rate.
struct OutputLatencyTests {
    /// 892 device frames at 48 kHz in a 44.1 kHz session: 18.583 ms and 820 session frames. Read
    /// at the session rate, they give 20.227 ms and 892 frames.
    @Test func convertsAtTheDeviceRate() {
        #expect(OutputTerm.builtIn.nanos(sessionRate: 44_100) == 18_583_333)
        #expect(OutputTerm.builtIn.sessionFrames(sessionRate: 44_100) == 820)
        #expect(OutputTerm.manual(441).nanos(sessionRate: 44_100) == 10_000_000)
        #expect(OutputTerm.manual(441).sessionFrames(sessionRate: 44_100) == 441)
    }

    /// 19 + 284 + 77 + 512 = 892. A part dropped gives 873, 608, 815, or 380; a part counted twice
    /// gives 911, 1176, 969, or 1404.
    @Test func sumsTheFourTerms() throws {
        let fake = FakeLatencyHAL()
        let term = try readOutputTerm(device: fake.currentDevice, reads: fake.reads).get()
        guard case .device(let device) = term else {
            Issue.record("not a device term: \(term)")
            return
        }
        #expect(device.frames == 892)
        #expect(device.rate == 48_000 && device.uid == "out-uid")
        #expect(term == .builtIn)
    }

    /// The input reads the same three parts through the same reader and adds no IO buffer: 2073,
    /// not 2585.
    @Test func inputSumHasNoBuffer() throws {
        let fake = FakeLatencyHAL(device: 40, stream: 1919, safety: 114, scope: kAudioObjectPropertyScopeInput)
        let parts = try LatencyParts(FakeLatencyHAL.id, scope: kAudioObjectPropertyScopeInput, reads: fake.reads)
        #expect(parts.inputFrames == 2073)
    }

    @Test(arguments: [0, -1, 0.4, .nan, .infinity])
    func zeroRateGivesNoTerm(rate: Double) {
        let fake = FakeLatencyHAL(rate: rate)
        let result = readOutputTerm(device: fake.currentDevice, reads: fake.reads)
        guard case .failure(.rate(let read)) = result else {
            Issue.record("rate \(rate) gave \(result)")
            return
        }
        #expect(read == rate || (read.isNaN && rate.isNaN))
    }

    /// Each failed read gives the fault of its property and no term. A stream latency read as 0
    /// gives a term of 608 frames.
    @Test(arguments: FakeLatencyHAL.Read.allCases)
    func failedPartGivesNoTerm(failing: FakeLatencyHAL.Read) {
        let fake = FakeLatencyHAL(failing: failing)
        let result = readOutputTerm(device: fake.currentDevice, reads: fake.reads)
        #expect(result == .failure(.read(failing.fault)), "\(failing): \(result)")
    }
}

/// A fake HAL with one output device and its stream. Each read checks its object and its scope,
/// and the `failing` read fails.
struct FakeLatencyHAL: Sendable {
    enum Read: CaseIterable, Sendable {
        case device, latency, streams, noStream, streamLatency, safety, buffer, rate, uid

        /// The fault that the reader gives when this read fails.
        var fault: HALReadFault {
            switch self {
            case .device: HALReadFault(selector: kAudioOutputUnitProperty_CurrentDevice, status: FakeLatencyHAL.status)
            case .latency: HALReadFault(selector: kAudioDevicePropertyLatency, status: FakeLatencyHAL.status)
            case .streams: HALReadFault(selector: kAudioDevicePropertyStreams, status: FakeLatencyHAL.status)
            case .noStream: HALReadFault(selector: kAudioDevicePropertyStreams, status: nil)
            case .streamLatency: HALReadFault(selector: kAudioStreamPropertyLatency, status: FakeLatencyHAL.status)
            case .safety: HALReadFault(selector: kAudioDevicePropertySafetyOffset, status: FakeLatencyHAL.status)
            case .buffer: HALReadFault(selector: kAudioDevicePropertyBufferFrameSize, status: FakeLatencyHAL.status)
            case .rate: HALReadFault(selector: kAudioDevicePropertyNominalSampleRate, status: FakeLatencyHAL.status)
            case .uid: HALReadFault(selector: kAudioDevicePropertyDeviceUID, status: nil)
            }
        }
    }

    static let id: AudioObjectID = 71
    static let streamID: AudioStreamID = 72
    static let status = kAudioHardwareUnknownPropertyError

    var device: UInt32 = 19
    var stream: UInt32 = 284
    var safety: UInt32 = 77
    var buffer: UInt32 = 512
    var rate: Double = 48_000
    /// The scope of the device latency, the stream list, and the safety offset.
    var scope = kAudioObjectPropertyScopeOutput
    var failing: Read?

    /// The current device of the engine output unit.
    var currentDevice: Result<AudioObjectID, HALReadFault> {
        failing == .device ? .failure(Read.device.fault) : .success(Self.id)
    }

    var reads: LatencyReads {
        let fake = self
        return LatencyReads(
            number: { id, selector, scope throws(HALError) in
                // The object tells the two latencies apart: both selectors are 'ltnc'.
                let global = kAudioObjectPropertyScopeGlobal
                let parts: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, UInt32, Read)] = [
                    (Self.id, kAudioDevicePropertyLatency, fake.scope, fake.device, .latency),
                    (Self.streamID, kAudioStreamPropertyLatency, global, fake.stream, .streamLatency),
                    (Self.id, kAudioDevicePropertySafetyOffset, fake.scope, fake.safety, .safety),
                    (Self.id, kAudioDevicePropertyBufferFrameSize, global, fake.buffer, .buffer),
                ]
                guard let part = parts.first(where: { $0.0 == id && $0.1 == selector }), part.2 == scope,
                    fake.failing != part.4
                else { throw .status(Self.status) }
                return part.3
            },
            rate: { id throws(HALError) in
                guard id == Self.id, fake.failing != .rate else { throw .status(Self.status) }
                return fake.rate
            },
            uid: { id in id == Self.id && fake.failing != .uid ? "out-uid" : nil },
            streams: { id, scope throws(HALError) in
                guard id == Self.id, scope == fake.scope, fake.failing != .streams else { throw .status(Self.status) }
                return fake.failing == .noStream ? [] : [Self.streamID]
            })
    }
}
