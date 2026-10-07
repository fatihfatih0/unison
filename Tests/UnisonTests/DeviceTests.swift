import XCTest
@testable import Unison

final class DeviceTests: XCTestCase {
    func testDisplayIdentityAndBuiltInFiltering() {
        let text = "[1] ASUS VG249Q3A (F7B4A3BD-7F35-4648-99B4-78991E8A6FDE)\n[2] Unknown Display (37D8832A-2D66-02CA-B9F7-8F30A301B230)\nmalformed"
        let result = DDC.parseList(text, builtInIDs: ["37D8832A-2D66-02CA-B9F7-8F30A301B230"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.name, "ASUS VG249Q3A")
        XCTAssertEqual(result.first?.id, "F7B4A3BD-7F35-4648-99B4-78991E8A6FDE")
        XCTAssertNil(result.first?.brightness)
    }
    func testMalformedUUIDNeverBecomesAControlTarget() {
        XCTAssertTrue(DDC.parseList("[1] Display (not-a-uuid)", builtInIDs: []).isEmpty)
    }
}
