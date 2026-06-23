import Foundation
import Network
import PolarBonjourCore

/// What the host app implements to be remote-controllable. ShangDynasty backs this
/// with `MusicPlayer.shared`.
public protocol PlaybackTarget: AnyObject {
    /// Apply a command. Called on an arbitrary queue — hop to main if you touch UI/players.
    func handleRemoteCommand(_ command: PlaybackCommand)
    /// Current state, queried when a controller connects.
    func currentPlaybackStatus() -> PlaybackStatus
}

/// The receiver: advertise `_polar-remote._tcp` over a PSK-paired channel, accept
/// controllers, apply their commands, and push status updates. Think "Apple TV".
public final class PolarRemoteReceiver: @unchecked Sendable {  // mutable state confined to `queue`
    private let name: String
    private let pairingCode: String
    private let queue = DispatchQueue(label: "polar.remote.receiver")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public weak var target: PlaybackTarget?
    /// Called when the set of connected controllers changes (count).
    public var onControllersChanged: ((Int) -> Void)?

    public init(name: String, pairingCode: String) {
        self.name = name
        self.pairingCode = pairingCode
    }

    /// The code a controller must enter to pair. Share it out of band (show on screen).
    public var code: String { pairingCode }

    public func start() throws {
        let params = PolarPSK.parameters(pairingCode: pairingCode,
                                         identity: PolarRemoteService.pskIdentity)
        let listener = try NWListener(using: params)   // OS-assigned port; Bonjour publishes it
        self.listener = listener

        // The advertised service name carries the human label; we skip a TXT record so
        // the SDK stays iOS 15-compatible (NWTXTRecord.data is iOS 16+).
        listener.service = NWListener.Service(name: name, type: PolarRemoteService.type)

        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
    }

    /// Push a fresh status to all connected controllers (call on every playback change).
    public func publishStatus(_ status: PlaybackStatus) {
        queue.async {
            guard let data = try? JSONEncoder().encode(RemoteMessage.Status(status: status)) else { return }
            for conn in self.connections.values {
                Task { try? await conn.sendFramed(data) }
            }
        }
    }

    // MARK: - private

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        conn.start(queue: queue)
        connections[id] = conn
        onControllersChanged?(connections.count)

        Task {
            do {
                try await conn.waitReady()
                // Greet with current status so the controller's UI populates immediately.
                if let status = self.target?.currentPlaybackStatus(),
                   let data = try? JSONEncoder().encode(RemoteMessage.Status(status: status)) {
                    try? await conn.sendFramed(data)
                }
                // Read commands until the controller goes away.
                while true {
                    let frame = try await conn.recvFramed()
                    guard let msg = try? JSONDecoder().decode(RemoteMessage.Command.self, from: frame) else { continue }
                    self.target?.handleRemoteCommand(msg.command)
                    // Reply with the resulting status so the controller stays in sync.
                    if let status = self.target?.currentPlaybackStatus(),
                       let data = try? JSONEncoder().encode(RemoteMessage.Status(status: status)) {
                        try? await conn.sendFramed(data)
                    }
                }
            } catch {
                // connection closed / failed
            }
            self.queue.async {
                conn.cancel()
                self.connections[id] = nil
                self.onControllersChanged?(self.connections.count)
            }
        }
    }
}
