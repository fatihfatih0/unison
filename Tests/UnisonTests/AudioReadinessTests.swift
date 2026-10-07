import XCTest
@testable import Unison

final class AudioReadinessTests: XCTestCase {
    @MainActor
    func testWaitingAllowsMainActorToPublishReadyChannels() async throws {
        var ready = false
        var reads = 0
        let waiting = Task { @MainActor in
            try await AudioReadiness.wait {
                reads += 1
                return ready
            }
        }
        while reads == 0 { await Task.yield() }
        // This runs on the same actor as startup, before startup completes.
        ready = true
        let result = try await waiting.value
        XCTAssertTrue(result)
        XCTAssertGreaterThan(reads, 1)
    }

    @MainActor
    func testUnavailableChannelsTimeOut() async throws {
        let ready = try await AudioReadiness.wait(timeout: .milliseconds(40)) { false }
        XCTAssertFalse(ready)
    }

    @MainActor
    func testCancellationStopsPollingBeforeAnotherHardwareRead() async {
        var reads = 0
        let waiting = Task { @MainActor in
            try await AudioReadiness.wait {
                reads += 1
                return false
            }
        }
        while reads == 0 { await Task.yield() }
        waiting.cancel()
        let readsAtCancellation = reads
        do {
            _ = try await waiting.value
            XCTFail("Cancelled startup must not continue polling")
        } catch is CancellationError {
            XCTAssertEqual(reads, readsAtCancellation)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testCancelledTaskDoesNotAcceptAlreadyReadyChannels() async {
        var reads = 0
        let waiting = Task { @MainActor in
            try await AudioReadiness.wait {
                reads += 1
                return true
            }
        }
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Cancelled startup must not allocate an audio callback")
        } catch is CancellationError {
            XCTAssertEqual(reads, 0)
        } catch { XCTFail("Unexpected error: \(error)") }
    }
}
