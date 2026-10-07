import XCTest
@testable import Unison

final class MediaKeysTests: XCTestCase {
    func testMediaAndFunctionModesMapToSameActions() {
        for (code, action) in [(111, 0), (103, 1), (109, 7)] {
            XCTAssertEqual(VolumeKeyEvent.function(code: code, isDown: true)?.action, action)
            XCTAssertEqual(VolumeKeyEvent.media(subtype: 8, data: (action << 16) | 0x0a00)?.action, action)
            XCTAssertEqual(VolumeKeyEvent.media(subtype: 8, data: (action << 16) | 0x0b00)?.isDown, false)
        }
        XCTAssertNil(VolumeKeyEvent.function(code: 101, isDown: true))
        XCTAssertNil(VolumeKeyEvent.media(subtype: 8, data: (16 << 16) | 0x0a00))
        XCTAssertNil(VolumeKeyEvent.media(subtype: 9, data: 0x0a00))
    }

    func testVolumeRepeatsAndReleaseStaysConsumedWhenModifiersChange() throws {
        var state = VolumeKeyConsumption()
        let down = try XCTUnwrap(VolumeKeyEvent.function(code: 103, isDown: true))
        let up = try XCTUnwrap(VolumeKeyEvent.function(code: 103, isDown: false))
        var actions: [Int] = []
        let handle: (Int) -> Bool = { actions.append($0); return true }
        XCTAssertTrue(state.consume(down, allowed: true, handler: handle))
        XCTAssertTrue(state.consume(down, allowed: true, handler: handle))
        XCTAssertTrue(state.consume(up, allowed: false, handler: handle))
        XCTAssertEqual(actions, [1, 1])
        XCTAssertFalse(state.consume(up, allowed: true, handler: handle))
        XCTAssertFalse(state.consume(down, allowed: false, handler: handle))
    }

    func testNativeMediaPressAndReleasePassThroughWithoutDoubleVolumeChange() throws {
        var state = VolumeKeyConsumption()
        for action in [0, 1, 7] {
            let down = try XCTUnwrap(VolumeKeyEvent.media(subtype: 8, data: (action << 16) | 0x0a00))
            let up = try XCTUnwrap(VolumeKeyEvent.media(subtype: 8, data: (action << 16) | 0x0b00))
            var handled = 0
            let handle: (Int) -> Bool = { _ in handled += 1; return true }
            XCTAssertFalse(state.consume(down, allowed: false, handler: handle))
            XCTAssertFalse(state.consume(down, allowed: false, handler: handle))
            XCTAssertFalse(state.consume(up, allowed: false, handler: handle))
            XCTAssertEqual(handled, 0)
        }
    }

    func testMuteDoesNotToggleOnRepeatAndUnsupportedTargetPassesThrough() throws {
        var state = VolumeKeyConsumption()
        let down = try XCTUnwrap(VolumeKeyEvent.media(subtype: 8, data: (7 << 16) | 0x0a00))
        let up = try XCTUnwrap(VolumeKeyEvent.media(subtype: 8, data: (7 << 16) | 0x0b00))
        var count = 0
        let handle: (Int) -> Bool = { _ in count += 1; return true }
        XCTAssertTrue(state.consume(down, allowed: true, handler: handle))
        XCTAssertTrue(state.consume(down, allowed: true, handler: handle))
        XCTAssertEqual(count, 1)
        XCTAssertTrue(state.consume(up, allowed: true, handler: handle))
        XCTAssertFalse(state.consume(down, allowed: true, handler: { _ in false }))
        XCTAssertFalse(state.consume(up, allowed: true, handler: handle))
    }
}
