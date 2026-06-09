import Foundation

/// A fixed-capacity ring buffer holding the most recent items. Backs the zero-shutter-lag design
/// (`docs/PIPELINE.md` §1.1): raw frames stream in continuously while the viewfinder runs, and the
/// shutter "fires into the past" by reading the frames already buffered at the press instant.
final class RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0
    private var filled = 0
    private let lock = NSLock()

    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    func append(_ element: Element) {
        lock.lock(); defer { lock.unlock() }
        storage[head] = element
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    /// The buffered items, oldest → newest.
    func snapshot() -> [Element] {
        lock.lock(); defer { lock.unlock() }
        guard filled > 0 else { return [] }
        var out = [Element]()
        out.reserveCapacity(filled)
        let start = (head - filled + capacity) % capacity
        for i in 0..<filled {
            if let e = storage[(start + i) % capacity] { out.append(e) }
        }
        return out
    }

    /// The newest `n` items (or fewer), oldest → newest.
    func newest(_ n: Int) -> [Element] {
        let all = snapshot()
        return Array(all.suffix(n))
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        storage = Array(repeating: nil, count: capacity)
        head = 0; filled = 0
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return filled
    }
}
