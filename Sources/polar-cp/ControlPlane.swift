import Foundation
import Network
import Security
import CryptoKit
import PolarBonjourCore

/// The token-issuing service: broadcasts `_polar-cp._tcp`, terminates pinned TLS,
/// validates a bootstrap token, and signs a credential per the node's trust tier.
final class ControlPlane {
    private let paths: CPPaths
    private let config: CPConfig
    private let signingKey: Curve25519.Signing.PrivateKey
    private let store: BootstrapStore
    private let queue = DispatchQueue(label: "polar.cp")
    private var listener: NWListener!

    /// Per-tier credential lifetime. Higher tier (more trusted) → longer TTL.
    private func tokenTTL(tier: Int) -> TimeInterval {
        switch tier {
        case ...1: return 60 * 60          // tier 0/1: 1h, expect frequent re-enroll
        case 2:    return 24 * 60 * 60     // tier 2: 1d
        default:   return 7 * 24 * 60 * 60 // tier 3+: 7d
        }
    }

    init(paths: CPPaths) throws {
        self.paths = paths
        self.config = try paths.loadConfig()
        self.signingKey = try paths.loadSigningKey()
        self.store = BootstrapStore(path: paths.bootstrap)
    }

    // MARK: enroll mode (bootstrap-token gated, signed credentials)

    func run() throws -> Never {
        listener = try makeListener { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        log("polar-cp '\(config.clusterID)' broadcasting \(PolarBonjour.serviceType) on :\(config.port) (fp=\(config.fingerprint.prefix(12))…)")
        dispatchMain()
    }

    // MARK: paste mode (one-shot raw handoff — paste a token, first client takes it)

    func runPaste() throws -> Never {
        let handoff = Handoff()
        listener = try makeListener { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            Task {
                defer { conn.cancel() }
                do {
                    try await conn.waitReady()
                    let data = try await conn.recvFramed()
                    // any well-formed fetch request is served; the client already pinned us.
                    guard (try? JSONDecoder().decode(EnrollRequest.self, from: data)) != nil else {
                        try await conn.sendFramed(try JSONEncoder().encode(
                            EnrollResponse(ok: false, error: "malformed request")))
                        return
                    }
                    if let tok = handoff.take() {
                        do {
                            try await conn.sendFramed(try JSONEncoder().encode(
                                EnrollResponse(ok: true, token: tok, clusterID: self.config.clusterID)))
                            handoff.signalDelivered()
                        } catch {
                            handoff.arm(tok)   // delivery failed — put it back so the next client can take it
                            throw error
                        }
                    } else {
                        try await conn.sendFramed(try JSONEncoder().encode(
                            EnrollResponse(ok: false, error: "no token armed")))
                    }
                } catch {
                    self.log("connection error: \(error)")
                }
            }
        }
        listener.start(queue: queue)
        log("paste mode: '\(config.clusterID)' broadcasting on :\(config.port) (fp=\(config.fingerprint.prefix(12))…)")

        // Network callbacks run on `queue`; the main thread blocks on stdin / delivery here.
        while true {
            FileHandle.standardError.write(Data("\npaste token (then Enter) > ".utf8))
            guard let line = readLine(strippingNewline: true) else { break } // EOF (ctrl-D)
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            handoff.arm(token)
            log("armed (\(token.count) chars) — waiting for a client to fetch…")
            handoff.waitDelivered()
            log("✓ delivered & retired; paste a new token to serve again")
        }
        exit(0)
    }

    /// Builds the pinned-TLS Bonjour listener shared by both modes.
    private func makeListener(_ onConn: @escaping (NWConnection) -> Void) throws -> NWListener {
        let identity = try loadIdentity()
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        let params = NWParameters(tls: tls)
        params.includePeerToPeer = true

        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: config.port)!)
        let txt = NWTXTRecord([
            PolarBonjour.TXT.version:     PolarBonjour.protocolVersion,
            PolarBonjour.TXT.clusterID:   config.clusterID,
            PolarBonjour.TXT.fingerprint: config.fingerprint,
            PolarBonjour.TXT.enroll:      PolarBonjour.enrollPath,
            PolarBonjour.TXT.api:         PolarBonjour.apiVersion,
        ])
        l.service = NWListener.Service(
            name: "polar-cp-\(config.clusterID)",
            type: PolarBonjour.serviceType,
            txtRecord: txt.data)
        l.newConnectionHandler = onConn
        l.stateUpdateHandler = { [weak self] state in
            if case let .failed(e) = state {
                self?.log("listener failed: \(e)")
                exit(1)
            }
        }
        return l
    }

    // MARK: connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        Task {
            defer { conn.cancel() }
            do {
                try await conn.waitReady()
                let reqData = try await conn.recvFramed()
                let resp = self.process(reqData)
                try await conn.sendFramed(try JSONEncoder().encode(resp))
            } catch {
                self.log("connection error: \(error)")
            }
        }
    }

    private func process(_ data: Data) -> EnrollResponse {
        guard let req = try? JSONDecoder().decode(EnrollRequest.self, from: data),
              req.op == "enroll" else {
            return EnrollResponse(ok: false, error: "malformed request")
        }
        guard let bootstrap = store.consume(req.bootstrap) else {
            log("rejected enroll from node=\(req.nodeID): bad/expired/used bootstrap")
            return EnrollResponse(ok: false, error: "invalid or exhausted bootstrap token")
        }
        guard Data(base64URLEncoded: req.nodePub) != nil else {
            return EnrollResponse(ok: false, error: "invalid node public key")
        }

        let now = Int(Date().timeIntervalSince1970)
        let exp = now + Int(tokenTTL(tier: bootstrap.tier))
        let claims = TokenClaims(iss: config.clusterID, sub: req.nodeID,
                                 npk: req.nodePub, tier: bootstrap.tier, iat: now, exp: exp)
        guard let token = try? PolarToken.sign(claims: claims, key: signingKey) else {
            return EnrollResponse(ok: false, error: "signing failure")
        }

        log("issued tier-\(bootstrap.tier) token to node=\(req.nodeID) (exp in \(Int(tokenTTL(tier: bootstrap.tier)/60))m)")
        return EnrollResponse(
            ok: true,
            token: token,
            clusterID: config.clusterID,
            cpPub: signingKey.publicKey.rawRepresentation.base64URLEncodedString(),
            tier: bootstrap.tier,
            expiresAt: exp)
    }

    // MARK: TLS identity

    private func loadIdentity() throws -> sec_identity_t {
        let data = try Data(contentsOf: paths.p12)
        var items: CFArray?
        let opts = [kSecImportExportPassphrase as String: Identity.p12Password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, opts, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let idAny = first[kSecImportItemIdentity as String] else {
            throw PolarError.config("could not import TLS identity (SecPKCS12Import: \(status))")
        }
        let secIdentity = idAny as! SecIdentity
        guard let sid = sec_identity_create(secIdentity) else {
            throw PolarError.config("sec_identity_create failed")
        }
        return sid
    }

    private func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(ts)] \(msg)\n".utf8))
    }
}
