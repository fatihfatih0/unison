import XCTest
@testable import Unison

final class DisplayGammaTests: XCTestCase {
    func testDimmingPreservesExistingColorCalibration() {
        let original = DisplayGamma.Table(red: [0, 0.2, 0.8], green: [0, 0.3, 0.9], blue: [0, 0.4, 1])
        let dimmed = original.scaled(0.5)
        XCTAssertEqual(dimmed.red, [0, 0.1, 0.4])
        XCTAssertEqual(dimmed.green, [0, 0.15, 0.45])
        XCTAssertEqual(dimmed.blue, [0, 0.2, 0.5])
        XCTAssertTrue(original.scaled(1).matches(original))
        XCTAssertFalse(dimmed.matches(original))
        XCTAssertTrue(original.scaled(0).matches(original.scaled(0.2)))
    }
}
