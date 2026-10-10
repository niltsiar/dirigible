import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Record monitor run 1b, B1: at the default header width, each row of a device track has four
/// boxes, R, Monitor, M, and S, in one column set, on one line and on two lines.
extension HeaderRowTests {
    @Test func theMonitorBoxIsSecondInEachRow() async throws {
        let (model, studio) = try await model(tracks: 3)
        for lane in [50.0, 100.0] {
            let (window, host) = rows(model, studio, laneHeight: lane, width: 340)
            let boxes = flagBoxes(host, in: host)
            let rows = Dictionary(grouping: boxes) { $0.midY.rounded() }.values.map { $0.map(\.minX).sorted() }
            #expect(boxes.count == 12, "\(lane) pt lanes: four boxes in each row: \(boxes.count)")
            #expect(rows.allSatisfy { $0 == [8, 30, 52, 74] }, "\(lane) pt lanes: R, Monitor, M, S: \(rows)")
            window.close()
        }
        await model.close()
    }
}
