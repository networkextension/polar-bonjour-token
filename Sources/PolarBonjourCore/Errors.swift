import Foundation

public enum PolarError: Error, CustomStringConvertible {
    case connectionClosed
    case frameTooLarge(Int)
    case timeout
    case noControlPlaneFound(clusterID: String)
    case fingerprintMismatch(expected: String, got: String)
    case handshakeFailed(String)
    case server(String)
    case badResponse(String)
    case config(String)

    public var description: String {
        switch self {
        case .connectionClosed:                return "connection closed by peer"
        case .frameTooLarge(let n):            return "frame too large: \(n) bytes"
        case .timeout:                         return "operation timed out"
        case .noControlPlaneFound(let cid):    return "no control plane found for cluster '\(cid)'"
        case .fingerprintMismatch(let e, let g): return "TLS pin mismatch — expected fp=\(e) got fp=\(g)"
        case .handshakeFailed(let m):          return "handshake failed: \(m)"
        case .server(let m):                   return "control plane rejected enrollment: \(m)"
        case .badResponse(let m):              return "bad response: \(m)"
        case .config(let m):                   return "config error: \(m)"
        }
    }
}
