import Foundation

/// Bounded ring buffer. Stub implementation for the skeleton — the realtime audio
/// path needs a lock-free or unfair-lock-based variant; that comes in Milestone 1.2.
public actor RingBuffer<Element: Sendable> {
    private var storage: [Element?]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    @discardableResult
    public func write(_ element: Element) -> Bool {
        let next = (writeIndex + 1) % capacity
        if next == readIndex { return false }
        storage[writeIndex] = element
        writeIndex = next
        return true
    }

    public func read() -> Element? {
        guard readIndex != writeIndex else { return nil }
        let element = storage[readIndex]
        storage[readIndex] = nil
        readIndex = (readIndex + 1) % capacity
        return element
    }
}
