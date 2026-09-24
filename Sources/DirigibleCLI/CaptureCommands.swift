import ArgumentParser
import DirigibleAudio

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the input devices.",
        discussion:
            "One line for each device: the UID, the name, the input channels, and the nominal rate, split by tabs.")

    func run() {
        for device in InputDevice.all() {
            let name = device.name.map { $0 == "\t" || $0.isNewline ? " " : $0 }
            let rate =
                device.nominalRate.rounded() == device.nominalRate
                ? "\(Int(device.nominalRate))" : "\(device.nominalRate)"
            print("\(device.uid)\t\(String(name))\t\(device.channelCount)\t\(rate)")
        }
    }
}
