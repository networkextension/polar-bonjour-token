import Foundation

/// One-shot token handoff for paste mode.
///
/// The operator pastes a token → `arm`. The first client that connects `take`s it
/// (atomic, so a second simultaneous client gets nothing and retries). On a
/// successful send the connection handler calls `signalDelivered`, unblocking the
/// stdin loop to prompt for the next token.
final class Handoff: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private let delivered = DispatchSemaphore(value: 0)

    func arm(_ t: String) {
        lock.lock(); defer { lock.unlock() }
        token = t
    }

    /// Atomically claim the armed token (or nil if none). Clears it so only one client wins.
    func take() -> String? {
        lock.lock(); defer { lock.unlock() }
        let t = token
        token = nil
        return t
    }

    func signalDelivered() { delivered.signal() }
    func waitDelivered()   { delivered.wait() }
}
