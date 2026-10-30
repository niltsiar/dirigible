import Testing

@testable import DirigibleAudio

/// `DIRIGIBLE_AUDIO_OUTPUT` sets the output of the live environment once, at the boundary
/// (decision 0016, amended).
struct CaptureEnvironmentTests {
    @Test func onlyNonePlaysToNoDevice() {
        let environment = CaptureEnvironment.live(environment: ["DIRIGIBLE_AUDIO_OUTPUT": "none"])
        #expect(environment.playerOutput == .paced)
        #expect(!environment.listenOutput.isLive)
    }

    @Test(arguments: [nil, "", "device", "nnone", "Device", "None"] as [String?])
    func unsetEmptyDeviceAndUnknownValuesPlayToTheDevice(value: String?) {
        let environment = CaptureEnvironment.live(environment: value.map { ["DIRIGIBLE_AUDIO_OUTPUT": $0] } ?? [:])
        #expect(environment.playerOutput == .device)
        #expect(environment.listenOutput.isLive)
    }
}
