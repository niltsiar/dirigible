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
