import DirigibleAudio
import Foundation

/// The tools that read this Mac, not a package (decision 0041, Amended 2026-10-13). Each call
/// reads the list again.
let sourceTools = [
    Tool(
        "devices",
        "List the input devices of this Mac: one line for each device with the UID, the name, the input channels, "
            + "and the nominal rate, split by tabs. Give the UID as device to track_route or track_add_call."
    ) {
        let text = deviceLines(InputDevice.all())
        return text.isEmpty ? "No input devices." : text
    },
    Tool(
        "apps",
        "List the running apps that can be a track source: one line for each app with the bundle ID, the name, and "
            + "1 when the app plays sound now (else 0), split by tabs. Give the bundle ID as app to track_route or "
            + "track_add_call."
    ) {
        let text = appLines(RunningApp.all())
        return text.isEmpty ? "No apps." : text
    },
]

/// The lines of `dirigible devices` and the `devices` tool: the UID, the name, the input channels,
/// and the nominal rate, split by tabs. A tab or a line break in a name becomes a space.
package func deviceLines(_ devices: [InputDevice]) -> String {
    devices.map { device in
        let rate =
            device.nominalRate.rounded() == device.nominalRate ? "\(Int(device.nominalRate))" : "\(device.nominalRate)"
        return "\(device.uid)\t\(oneLine(device.name))\t\(device.channelCount)\t\(rate)\n"
    }.joined()
}

/// The lines of `dirigible apps` and the `apps` tool: the bundle ID, the name, and 1 when the app
/// plays sound now (else 0), split by tabs. A tab or a line break in a name becomes a space.
package func appLines(_ apps: [RunningApp]) -> String {
    apps.map { "\($0.bundleID)\t\(oneLine($0.name))\t\($0.playing ? 1 : 0)\n" }.joined()
}

private func oneLine(_ name: String) -> String { String(name.map { $0 == "\t" || $0.isNewline ? " " : $0 }) }
