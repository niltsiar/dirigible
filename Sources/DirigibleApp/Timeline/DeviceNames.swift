import DirigibleAudio

/// The device of a route: its name from `deviceNames`, or the "missing" text when it is not in
/// `devices`.
func routeLabel(uid: String, devices: [InputDevice]) -> String {
    guard let index = devices.firstIndex(where: { $0.uid == uid }) else { return L10n.trackRouteMissing.text }
    return deviceNames(devices)[index]
}

/// The shown name of each device, in list order. Of the devices with one name, the first in UID
/// order keeps it and each next one gets the lowest " 2", " 3" that no device has as its name. The
/// UID order, not the list order, keeps each name when a replug changes the list.
func deviceNames(_ devices: [InputDevice]) -> [String] {
    var names = devices.map(\.name)
    var taken = Set(names)
    var seen: Set<String> = []
    for index in devices.indices.sorted(by: { devices[$0].uid < devices[$1].uid }) {
        let name = devices[index].name
        if seen.insert(name).inserted { continue }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        names[index] = "\(name) \(number)"
        taken.insert(names[index])
    }
    return names
}
