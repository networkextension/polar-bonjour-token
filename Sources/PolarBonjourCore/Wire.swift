import Foundation

/// Bonjour service + TXT-record constants. Both sides MUST agree on these.
public enum PolarBonjour {
    public static let serviceType = "_polar-cp._tcp"

    /// TXT keys (LAN-visible — never put secrets here, per doc §1).
    public enum TXT {
        public static let version    = "v"    // protocol version
        public static let clusterID  = "cid"  // cluster id — clients filter on this
        public static let fingerprint = "fp"  // truncated SHA-256 of the TLS leaf cert (the pin)
        public static let enroll     = "enr"  // enrollment path hint, e.g. "/v1/enroll"
        public static let api        = "api"  // api version
    }

    public static let protocolVersion = "1"
    public static let apiVersion      = "1"
    public static let enrollPath      = "/v1/enroll"
}

// MARK: - Enrollment request/response (length-prefixed JSON over the pinned TLS channel)

public struct EnrollRequest: Codable {
    public var op: String              // always "enroll"
    public var bootstrap: String       // the single/limited-use bootstrap token
    public var nodeID: String          // caller-chosen stable id (hostname, machine uuid, …)
    public var nodePub: String         // base64url raw Ed25519 public key the node just generated
    public var info: [String: String]  // optional host metadata (model, os, …)

    public init(op: String = "enroll", bootstrap: String, nodeID: String,
                nodePub: String, info: [String: String] = [:]) {
        self.op = op
        self.bootstrap = bootstrap
        self.nodeID = nodeID
        self.nodePub = nodePub
        self.info = info
    }
}

public struct EnrollResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var token: String?       // the issued, Ed25519-signed credential (compact JWT-ish)
    public var clusterID: String?
    public var cpPub: String?       // base64url CP signing public key (verify the token offline)
    public var tier: Int?
    public var expiresAt: Int?      // unix seconds

    public init(ok: Bool, error: String? = nil, token: String? = nil, clusterID: String? = nil,
                cpPub: String? = nil, tier: Int? = nil, expiresAt: Int? = nil) {
        self.ok = ok
        self.error = error
        self.token = token
        self.clusterID = clusterID
        self.cpPub = cpPub
        self.tier = tier
        self.expiresAt = expiresAt
    }
}
