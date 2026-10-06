import Foundation

/// A minimal lock-protected box for state that must be readable synchronously
/// from several isolation domains (e.g. the comm log read by the UI while the
/// ELM session writes to it).
///
/// `Synchronization.Mutex` would be preferable but requires iOS 18; Redline
/// targets iOS 17 so that `Observation` is available.
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
