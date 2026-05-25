// SendableBox.swift — a lock-protected mutable cell that tests can pass
// into @Sendable closures without tripping Swift 6's concurrency checks.
// Use only in tests; production code should prefer actors or proper
// concurrency primitives.
import Foundation

final class SendableBox<Value>: @unchecked Sendable {
    private var storedValue: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.storedValue = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }

    /// Atomically apply a mutating transform.
    func mutate(_ transform: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        transform(&storedValue)
    }
}
