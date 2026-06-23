import Foundation
import Network
import CryptoKit

/// TLS-PSK transport — the iOS-friendly trust path.
///
/// Unlike the control-plane's self-signed cert + fingerprint pin (which needs
/// `openssl`/`Process`, macOS-only), a pre-shared key needs no certificate at all.
/// The PSK is derived from a short **pairing code** the operator shares out of band
/// (shown on the "Apple TV" receiver, entered on the controller). This gives, in one
/// step and on every Apple platform:
///   - mutual authentication (only a holder of the code can connect, and the
///     controller knows it reached the real receiver — both prove knowledge of the PSK),
///   - an encrypted channel,
///   - immunity to mDNS spoofing (a fake advertiser can't complete the handshake).
public enum PolarPSK {

    /// Build TLS options pinned to a pairing code. Both sides must call this with the
    /// same `pairingCode` and `identity`.
    public static func tlsOptions(pairingCode: String, identity: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions

        // PSK = SHA-256(pairing code) → a full-entropy 32-byte key even if the code is short.
        let keyData = Data(SHA256.hash(data: Data(pairingCode.utf8)))
        let identityData = Data(identity.utf8)

        let keyDD = keyData.withUnsafeBytes { DispatchData(bytes: $0) }
        let idDD = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyDD as __DispatchData, idDD as __DispatchData)

        // TLS_PSK_WITH_AES_128_GCM_SHA256 (0x00A8) — a PSK ciphersuite (no certificate exchange).
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return options
    }

    /// NWParameters for a PSK-secured TCP connection/listener.
    public static func parameters(pairingCode: String, identity: String) -> NWParameters {
        let params = NWParameters(tls: tlsOptions(pairingCode: pairingCode, identity: identity))
        params.includePeerToPeer = true
        return params
    }

    /// Generate a short, human-shareable pairing code (e.g. "4827-1593").
    public static func generatePairingCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let n = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
        let a = (n >> 16) % 10000
        let b = n % 10000
        return String(format: "%04u-%04u", a, b)
    }
}
