import Foundation
import Network
import PolarBonjourCore

/// A discovered receiver on the LAN.
public struct RemoteReceiverInfo: Sendable, Identifiable {
    public let id: String          // stable-ish: the advertised name
    public let name: String
    public let endpoint: NWEndpoint
}

/// The controller: discover receivers, pair with a code, then drive playback and
/// observe status. One iOS device controlling another, or the `polar-remote` CLI.
public final class PolarRemoteController {
    private let queue = DispatchQueue(label: "polar.remote.controller")
    private var connection: NWConnection?

    /// Called (on the controller's queue) whenever the receiver pushes a new status.
    public var onStatus: ((PlaybackStatus) -> Void)?
    /// Called when the connection drops.
    public var onDisconnect: (() -> Void)?

    public init() {}

    // MARK: Discovery

    /// Browse for receivers. Returns as soon as at least one appears (plus a short settle
    /// to gather peers), or the full `timeout` if none show up.
    public func discover(timeout: TimeInterval = 4) async throws -> [RemoteReceiverInfo] {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: PolarRemoteService.type, domain: nil),
            using: NWParameters())
        let collector = Collector()
        let signal = OneShot()
        browser.browseResultsChangedHandler = { results, _ in
            var found: [RemoteReceiverInfo] = []
            for r in results {
                guard case let .service(svcName, _, _, _) = r.endpoint else { continue }
                var label = svcName
                if case let .bonjour(txt) = r.metadata, let n = txt[PolarRemoteService.TXT.name] { label = n }
                found.append(RemoteReceiverInfo(id: svcName, name: label, endpoint: r.endpoint))
            }
            collector.set(found)
            if !found.isEmpty { signal.fire() }
        }
        browser.start(queue: queue)
        await signal.wait(upTo: timeout)
        if !collector.get().isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)   // brief settle to gather more peers
        }
        browser.cancel()
        return collector.get()
    }

    /// Convenience: discover and return the first receiver (optionally matching a name substring).
    public func findReceiver(named: String? = nil, timeout: TimeInterval = 4) async throws -> RemoteReceiverInfo {
        let all = try await discover(timeout: timeout)
        if let named {
            if let m = all.first(where: { $0.name.localizedCaseInsensitiveContains(named) }) { return m }
        } else if let first = all.first {
            return first
        }
        throw PolarError.noControlPlaneFound(clusterID: named ?? PolarRemoteService.type)
    }

    // MARK: Pairing / connection

    /// Open a persistent paired connection. Starts a background loop delivering status to `onStatus`.
    /// A wrong pairing code fails here (the PSK handshake never completes) within `timeout`.
    public func connect(to receiver: RemoteReceiverInfo, pairingCode: String,
                        timeout: TimeInterval = 6) async throws {
        let params = PolarPSK.parameters(pairingCode: pairingCode, identity: PolarRemoteService.pskIdentity)
        let conn = NWConnection(to: receiver.endpoint, using: params)
        self.connection = conn
        conn.start(queue: queue)

        // A bad PSK doesn't always surface a prompt `.failed`; force-resolve via cancel.
        // NB: bail on cancellation — `try?` would swallow it and still cancel the live conn.
        let timer = Task { [weak conn] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            catch { return }   // timer cancelled (handshake succeeded) → leave conn alone
            conn?.cancel()
        }
        do {
            try await conn.waitReady()
            timer.cancel()
        } catch {
            timer.cancel()
            self.connection = nil
            throw PolarError.handshakeFailed("could not pair — wrong code or receiver unreachable")
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let frame = try await conn.recvFramed()
                    if let msg = try? JSONDecoder().decode(RemoteMessage.Status.self, from: frame) {
                        self.onStatus?(msg.status)
                    }
                }
            } catch {
                self.onDisconnect?()
            }
        }
    }

    public func send(_ command: PlaybackCommand) async throws {
        guard let conn = connection else { throw PolarError.connectionClosed }
        let data = try JSONEncoder().encode(RemoteMessage.Command(command: command))
        try await conn.sendFramed(data)
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
    }

    // MARK: One-shot convenience (for the CLI)

    /// Discover → pair → send one command → optionally await one status → disconnect.
    @discardableResult
    public func sendOnce(_ command: PlaybackCommand,
                         named: String? = nil,
                         pairingCode: String,
                         timeout: TimeInterval = 4) async throws -> PlaybackStatus? {
        let receiver = try await findReceiver(named: named, timeout: timeout)
        let statusBox = StatusBox()
        onStatus = { statusBox.set($0) }
        try await connect(to: receiver, pairingCode: pairingCode, timeout: 4)
        try await send(command)
        try await Task.sleep(nanoseconds: 400_000_000)   // let the status reply arrive
        disconnect()
        return statusBox.get()
    }
}

// MARK: - tiny thread-safe boxes

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [RemoteReceiverInfo] = []
    func set(_ v: [RemoteReceiverInfo]) { lock.lock(); value = v; lock.unlock() }
    func get() -> [RemoteReceiverInfo] { lock.lock(); defer { lock.unlock() }; return value }
}

private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlaybackStatus?
    func set(_ v: PlaybackStatus) { lock.lock(); value = v; lock.unlock() }
    func get() -> PlaybackStatus? { lock.lock(); defer { lock.unlock() }; return value }
}

/// One-shot signal with a timeout — resolves on the first `fire()` or after `timeout`.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var cont: CheckedContinuation<Void, Never>?
    func fire() {
        lock.lock()
        if fired { lock.unlock(); return }
        fired = true
        let c = cont; cont = nil
        lock.unlock()
        c?.resume()
    }
    func wait(upTo timeout: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired { lock.unlock(); c.resume(); return }
            cont = c
            lock.unlock()
            Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); self.fire() }
        }
    }
}
