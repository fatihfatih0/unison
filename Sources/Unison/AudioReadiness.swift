import Foundation

// HAL attaches aggregate streams asynchronously. Yield between reads so UI
// events and cancellation can run without entering a nested RunLoop.
@MainActor
enum AudioReadiness {
    static func wait(timeout: Duration = .milliseconds(500), interval: Duration = .milliseconds(20), isReady: () throws -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if try isReady() { return true }
            let now = clock.now
            guard now < deadline else { return false }
            try await Task.sleep(until: min(now.advanced(by: interval), deadline), clock: clock)
        }
    }
}
