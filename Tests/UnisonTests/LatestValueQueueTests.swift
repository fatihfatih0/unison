import XCTest
@testable import Unison

final class LatestValueQueueTests: XCTestCase {
    @MainActor
    func testSlowHardwareReceivesFinalDragValueAndOtherTargets() async {
        var sent: [(String, Double)] = []
        var gate: CheckedContinuation<Void, Never>?
        let queue = LatestValueQueue<String> { target, value in
            sent.append((target, value))
            if sent.count == 1 { await withCheckedContinuation { gate = $0 } }
        }
        queue.submit("screenA", value: 0.1)
        while gate == nil { await Task.yield() }
        queue.submit("screenA", value: 0.2)
        queue.submit("screenA", value: 0.3)
        queue.submit("screenB", value: 0.6)
        XCTAssertEqual(sent.count, 1)
        gate?.resume()
        while queue.isWriting { await Task.yield() }
        XCTAssertEqual(sent.map(\.0), ["screenA", "screenA", "screenB"])
        XCTAssertEqual(sent.map(\.1), [0.1, 0.3, 0.6])
    }

    @MainActor
    func testReadbackWaitsForSlowWriteAndFinalQueuedValue() async {
        var sent: [Double] = []
        var gate: CheckedContinuation<Void, Never>?
        var observed: [Double]?
        let queue = LatestValueQueue<String> { _, value in
            sent.append(value)
            await withCheckedContinuation { gate = $0 }
        }
        queue.submit("screen", value: 0.1)
        while gate == nil { await Task.yield() }
        let readback = Task { @MainActor in
            await queue.waitUntilIdle()
            observed = sent
        }
        queue.submit("screen", value: 0.7)
        await Task.yield()
        XCTAssertNil(observed)
        let first = gate; gate = nil; first?.resume()
        while gate == nil { await Task.yield() }
        XCTAssertNil(observed)
        gate?.resume()
        await readback.value
        XCTAssertEqual(observed, [0.1, 0.7])
        XCTAssertFalse(queue.isWriting)
    }
}
