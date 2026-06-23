import Foundation
import CryptoKit

/// Claims carried by an issued credential.
///
/// NOTE: This is a self-contained Ed25519-signed compact token (JWT-ish) so the
/// package stays dependency-free. The doc (§3) recommends emitting a **NATS User
/// JWT** instead — the seam is exactly here: keep `sign`/`verify` but swap the
/// payload/encoder for `nats-jwt`. `nats-server` then verifies offline against
/// the account public key, same trust model.
public struct TokenClaims: Codable {
    public var iss: String   // issuer = cluster id
    public var sub: String   // subject = node id
    public var npk: String   // node public key (base64url) — binds the token to the node's NKey
    public var tier: Int     // trust tier → drives scope/quota
    public var iat: Int      // issued-at (unix seconds)
    public var exp: Int      // expiry (unix seconds)

    public init(iss: String, sub: String, npk: String, tier: Int, iat: Int, exp: Int) {
        self.iss = iss; self.sub = sub; self.npk = npk
        self.tier = tier; self.iat = iat; self.exp = exp
    }
}

public enum PolarToken {
    private static let header = #"{"alg":"EdDSA","typ":"polar-tok"}"#

    public static func sign(claims: TokenClaims,
                            key: Curve25519.Signing.PrivateKey) throws -> String {
        let h = Data(header.utf8).base64URLEncodedString()
        let p = try JSONEncoder().encode(claims).base64URLEncodedString()
        let signingInput = "\(h).\(p)"
        let sig = try key.signature(for: Data(signingInput.utf8)).base64URLEncodedString()
        return "\(signingInput).\(sig)"
    }

    /// Verify signature + structure. Does NOT check expiry — caller decides clock policy.
    public static func verify(_ token: String,
                              pub: Curve25519.Signing.PublicKey) -> TokenClaims? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let sig = Data(base64URLEncoded: String(parts[2])) else { return nil }
        let signingInput = "\(parts[0]).\(parts[1])"
        guard pub.isValidSignature(sig, for: Data(signingInput.utf8)) else { return nil }
        guard let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = try? JSONDecoder().decode(TokenClaims.self, from: payload) else { return nil }
        return claims
    }
}

/// SHA-256 fingerprint of a DER certificate, base64url — the `fp` TXT value / TLS pin.
public enum CertFingerprint {
    public static func sha256Base64URL(der: Data) -> String {
        Data(SHA256.hash(data: der)).base64URLEncodedString()
    }
}
