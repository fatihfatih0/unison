import XCTest
@testable import Unison

final class AudioRouteTransitionTests: XCTestCase {
    func testOldRouteIsAllowedOnlyWhileHALCompletesOurRequest() {
        let now = ContinuousClock.now
        var route = AudioRouteTransition(previous: 10, target: 20, now: now)
        XCTAssertTrue(route.isPending(current: 10, now: now.advanced(by: .seconds(1))))
        XCTAssertFalse(route.isPending(current: 20, now: now.advanced(by: .seconds(2))))
        // Switching back after completion is a real route change, not startup.
        XCTAssertFalse(route.isPending(current: 10, now: now.advanced(by: .milliseconds(2100))))
    }

    func testUnrelatedOutputAndExpiredRequestNeverSuppressRouteChanges() {
        let now = ContinuousClock.now
        var route = AudioRouteTransition(previous: 10, target: 20, now: now)
        XCTAssertFalse(route.isPending(current: 30, now: now))
        XCTAssertFalse(route.isPending(current: 10, now: now.advanced(by: .seconds(3))))
        var unchanged = AudioRouteTransition(previous: 10, target: 10, now: now)
        XCTAssertFalse(unchanged.isPending(current: 10, now: now))
    }
}
