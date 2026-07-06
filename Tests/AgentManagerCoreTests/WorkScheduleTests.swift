import XCTest
@testable import AgentManagerCore

/// `WorkSchedule` knob persistence + resolution — focused on the budget-slice
/// floor (`minSliceMinutes`), which must leave pre-knob `schedule.json` files
/// decoding (and planning) exactly as before.
final class WorkScheduleTests: XCTestCase {
    func testScheduleJSONWithoutKnobDecodesToNilAndResolvesToDefault() throws {
        // A schedule.json without a `minSliceMinutes` key (never touched the
        // stepper) decodes to `nil` and resolves to the 1h default.
        let json = """
        {"version":1,"windowMinutes":300,"hoursByWeekday":[[8,9],[],[],[],[],[],[]]}
        """
        let s = try JSONDecoder().decode(WorkSchedule.self, from: Data(json.utf8))
        XCTAssertNil(s.minSliceMinutes)
        XCTAssertEqual(s.resolvedMinSliceMinutes, defaultMinSliceMinutes)
    }

    func testResolutionClampsIntoFloorAndWindow() {
        var s = WorkSchedule()
        // 15 min is the lowest a "budget" still counts as one; below it
        // (hand-edited JSON) clamps up.
        s.minSliceMinutes = 15
        XCTAssertEqual(s.resolvedMinSliceMinutes, 15)
        s.minSliceMinutes = 5
        XCTAssertEqual(s.resolvedMinSliceMinutes, minSliceFloorMinutes)
        // Beyond one window nothing could ever satisfy it.
        s.minSliceMinutes = 10_000
        XCTAssertEqual(s.resolvedMinSliceMinutes, s.windowMinutes)
        // In range passes through untouched.
        s.minSliceMinutes = 180
        XCTAssertEqual(s.resolvedMinSliceMinutes, 180)
    }

    func testFloorRoundTripsThroughScheduleStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-schedule-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ScheduleStore(fileURL: dir.appendingPathComponent("schedule.json"))
        var s = WorkSchedule()
        s.minSliceMinutes = 180
        try store.save(s)
        XCTAssertEqual(try store.load().minSliceMinutes, 180)

        // Back at the default the knob persists as absent (`nil`), keeping the
        // file shape identical to a pre-knob one.
        s.minSliceMinutes = nil
        try store.save(s)
        XCTAssertNil(try store.load().minSliceMinutes)
    }
}
