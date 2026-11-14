// The helpers every test target shares, imported once for this whole target: `MachinePinned`,
// `DefaultsSuiteSupport`, `LayoutPumpWait` and `ProbeRig`.
import Foundation
@_exported import EventsTestSupport
@_exported import DesignTestSupport

/// One mutable value reachable from a `@Sendable` lister or validator closure.
final class Mutable<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
