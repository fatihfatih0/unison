import Foundation

// Hardware writes may be slower than drag events. Keep the newest value for each
// target, and always drain the final value, without blocking any UI controls.
@MainActor
final class LatestValueQueue<Key: Hashable> {
    private var pending: [Key: Double] = [:]
    private var order: [Key] = []
    private var worker: Task<Void, Never>?
    private let send: (Key, Double) async -> Void
    init(send: @escaping (Key, Double) async -> Void) { self.send = send }
    func submit(_ key: Key, value: Double) {
        if pending[key] == nil { order.append(key) }
        pending[key] = value
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !order.isEmpty {
                let key = order.removeFirst()
                guard let value = pending.removeValue(forKey: key) else { continue }
                await send(key, value)
            }
            self?.worker = nil
        }
    }
    func waitUntilIdle() async {
        while let worker, !Task.isCancelled { await worker.value }
    }
    var isWriting: Bool { worker != nil }
}
