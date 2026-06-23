import Foundation
import Network
import CryptoKit
import PolarBonjourCore

/// A discovered control-plane candidate.
public struct PolarControlPlane: Sendable {
    public let endpoint: NWEndpoint
    public let clusterID: String
    public let fingerprint: String   // expected TLS leaf-cert pin (from the `fp` TXT record)
    public let enrollPath: String
    public let name: String
}

/// What the node walks away with after a successful enrollment.
public struct PolarCredentials: Sendable {
    public let token: String          // the signed credential to present upstream
    public let clusterID: String
    public let tier: Int
    public let expiresAt: Date
    public let cpPublicKey: String    // base64url CP signing key — verify the token offline
    /// The node identity key minted locally during enrollment. The seed never left
    /// this process before now; persist it securely (Keychain / SEP-backed in prod).
    public let nodePublicKey: String  // base64url
    public let nodePrivateSeed: String // base64url raw 32-byte Ed25519 seed
}

/// Client SDK entry point: find the control plane on the LAN, then enroll.
///
/// Trust model (doc §2, simplified path): Bonjour only *locates* candidates; trust
/// comes from (a) pinning the TLS leaf cert to the `fp` advertised in TXT and (b) a
/// high-entropy single-use bootstrap token the CP checks. The PAKE upgrade slots in
/// at `enroll(...)` without changing this surface.
/// Cross-platform default node id (`Host` is macOS/Linux-only).
public let defaultNodeID: String = ProcessInfo.processInfo.hostName

public final class PolarEnroller {
    private let clusterID: String
    private let queue = DispatchQueue(label: "polar.enroller")

    public init(clusterID: String) {
        self.clusterID = clusterID
    }

    // MARK: Discovery

    /// Browse `_polar-cp._tcp` and return the first candidate matching our cluster id.
    public func discover(timeout: TimeInterval = 8) async throws -> PolarControlPlane {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: PolarBonjour.serviceType, domain: nil),
            using: params)

        let box = ResultBox()
        return try await withThrowingTaskGroup(of: PolarControlPlane.self) { group in
            group.addTask { [clusterID, queue] in
                try await withCheckedThrowingContinuation { cont in
                    let once = ContinuationOnce(cont)
                    browser.browseResultsChangedHandler = { results, _ in
                        for r in results {
                            guard case let .bonjour(txt) = r.metadata else { continue }
                            guard txt[PolarBonjour.TXT.clusterID] == clusterID else { continue }
                            guard let fp = txt[PolarBonjour.TXT.fingerprint] else { continue }
                            let enr = txt[PolarBonjour.TXT.enroll] ?? PolarBonjour.enrollPath
                            let name: String
                            if case let .service(svcName, _, _, _) = r.endpoint { name = svcName }
                            else { name = "polar-cp" }
                            let cp = PolarControlPlane(endpoint: r.endpoint,
                                                       clusterID: clusterID,
                                                       fingerprint: fp,
                                                       enrollPath: enr,
                                                       name: name)
                            once.resume(returning: cp)
                            return
                        }
                    }
                    browser.stateUpdateHandler = { state in
                        if case let .failed(err) = state { once.resume(throwing: err) }
                    }
                    browser.start(queue: queue)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PolarError.noControlPlaneFound(clusterID: box.cid)
            }
            box.cid = clusterID
            defer { browser.cancel() }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: Enrollment

    /// Full flow: discover → pinned TLS connect → submit bootstrap + fresh node key → receive token.
    public func enroll(bootstrap: String,
                       nodeID: String = defaultNodeID,
                       info: [String: String] = [:],
                       timeout: TimeInterval = 8) async throws -> PolarCredentials {
        let cp = try await discover(timeout: timeout)
        return try await enroll(with: cp, bootstrap: bootstrap, nodeID: nodeID, info: info)
    }

    /// Enroll against an already-discovered control plane (lets callers do their own selection).
    public func enroll(with cp: PolarControlPlane,
                       bootstrap: String,
                       nodeID: String,
                       info: [String: String] = [:]) async throws -> PolarCredentials {
        // Node identity is minted here; the seed never leaves the device before this.
        let nodeKey = Curve25519.Signing.PrivateKey()
        let nodePub = nodeKey.publicKey.rawRepresentation.base64URLEncodedString()

        let conn = NWConnection(to: cp.endpoint,
                                using: pinnedTLSParameters(expectedFP: cp.fingerprint))
        defer { conn.cancel() }
        conn.start(queue: queue)
        try await conn.waitReady()

        let req = EnrollRequest(bootstrap: bootstrap, nodeID: nodeID,
                                nodePub: nodePub, info: info)
        try await conn.sendFramed(try JSONEncoder().encode(req))

        let respData = try await conn.recvFramed()
        let resp = try JSONDecoder().decode(EnrollResponse.self, from: respData)
        guard resp.ok, let token = resp.token, let cpPub = resp.cpPub,
              let cid = resp.clusterID, let tier = resp.tier, let exp = resp.expiresAt else {
            throw PolarError.server(resp.error ?? "unknown error")
        }

        // Belt-and-suspenders: verify the signature with the returned CP key.
        if let cpKeyData = Data(base64URLEncoded: cpPub),
           let cpKey = try? Curve25519.Signing.PublicKey(rawRepresentation: cpKeyData) {
            guard PolarToken.verify(token, pub: cpKey) != nil else {
                throw PolarError.badResponse("token signature did not verify")
            }
        }

        return PolarCredentials(
            token: token,
            clusterID: cid,
            tier: tier,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(exp)),
            cpPublicKey: cpPub,
            nodePublicKey: nodePub,
            nodePrivateSeed: nodeKey.rawRepresentation.base64URLEncodedString())
    }

    // MARK: Paste mode (one-shot raw token handoff)

    /// Discover the control plane, then poll until the operator pastes a token and
    /// this client claims it. Returns the raw pasted string (no verification — the
    /// trust here is: we pinned the CP's cert, and the operator armed it by hand).
    public func fetchPastedToken(nodeID: String = defaultNodeID,
                                 timeout: TimeInterval = 120,
                                 pollInterval: TimeInterval = 1) async throws -> String {
        let cp = try await discover(timeout: min(timeout, 10))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let token = try await tryFetch(cp: cp, nodeID: nodeID) { return token }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw PolarError.timeout
    }

    /// One round-trip: ask the pinned CP for an armed token. nil = none armed yet.
    private func tryFetch(cp: PolarControlPlane, nodeID: String) async throws -> String? {
        let conn = NWConnection(to: cp.endpoint,
                                using: pinnedTLSParameters(expectedFP: cp.fingerprint))
        defer { conn.cancel() }
        conn.start(queue: queue)
        try await conn.waitReady()

        let req = EnrollRequest(op: "fetch", bootstrap: "", nodeID: nodeID, nodePub: "")
        try await conn.sendFramed(try JSONEncoder().encode(req))
        let resp = try JSONDecoder().decode(EnrollResponse.self, from: try await conn.recvFramed())

        if resp.ok, let token = resp.token { return token }
        if resp.error == "no token armed" { return nil }   // keep polling
        throw PolarError.server(resp.error ?? "unknown error")
    }

    // MARK: TLS pinning

    /// TLS params whose verify block accepts the server iff its leaf cert SHA-256
    /// equals the `fp` we learned from Bonjour. This is what defeats mDNS spoofing
    /// in the simplified (non-PAKE) path.
    private func pinnedTLSParameters(expectedFP: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, secTrustRef, complete in
                let trust = sec_trust_copy_ref(secTrustRef).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                      let leaf = chain.first else {
                    complete(false); return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let got = CertFingerprint.sha256Base64URL(der: der)
                complete(got == expectedFP)
            },
            queue)
        let params = NWParameters(tls: tls)
        params.includePeerToPeer = true
        return params
    }
}

// MARK: - tiny helpers

private final class ResultBox: @unchecked Sendable {
    var cid: String = ""
}

private final class ContinuationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<PolarControlPlane, Error>
    init(_ cont: CheckedContinuation<PolarControlPlane, Error>) { self.cont = cont }
    func resume(returning v: PolarControlPlane) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; cont.resume(returning: v)
    }
    func resume(throwing e: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; cont.resume(throwing: e)
    }
}
