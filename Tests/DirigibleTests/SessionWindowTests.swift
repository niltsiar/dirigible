import DirigibleAudio
import DirigibleCore
import Testing

@testable import DirigibleApp

/// The pure rules of the session window.
struct SessionWindowTests {
    /// Criterion 22.
    @Test func aFourChannelDeviceGivesFourMonoAndTwoStereoRoutes() {
        #expect(
            routeOptions(channelCount: 4) == [.mono(1), .mono(2), .mono(3), .mono(4), .stereo(1, 2), .stereo(3, 4)])
    }

    /// Criterion 22 control.
    @Test func aOneChannelDeviceGivesNoStereoRoute() {
        #expect(routeOptions(channelCount: 1) == [.mono(1)])
        #expect(routeOptions(channelCount: 3) == [.mono(1), .mono(2), .mono(3), .stereo(1, 2)])
    }

    /// Criterion 21: only a status that the prompt can change gives a request.
    @Test func onlyAnUndecidedAccessGivesARequest() {
        #expect(microphoneStep(.notDetermined) == .request)
        #expect(microphoneStep(.denied) == .privacyLink)
    }

    /// Criterion 21 control: a request cannot change a restricted access.
    @Test func aRestrictedAccessNeverGivesARequest() {
        #expect(microphoneStep(.restricted) == .privacyLink)
    }
}
