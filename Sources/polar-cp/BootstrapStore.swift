import Foundation
import CryptoKit
import PolarBonjourCore

/// A bootstrap token: short-lived, limited-use, ideally one per node, revocable (doc §3).
struct BootstrapToken: Codable {
    var token: String      // the secret value handed out
    var tier: Int          // trust tier the resulting credential gets
    var expiresAt: Int     // unix seconds
    var usesLeft: Int      // decremented on each successful enroll
    var note: String?      // free-form label (which node it's for, etc.)

    var isLive: Bool {
        usesLeft > 0 && Int(Date().timeIntervalSince1970) < expiresAt
    }
}

/// File-backed store. Single-process CP → plain read-modify-write, no external lock.
final class BootstrapStore {
    private let url: URL
    private let lock = NSLock()

    init(path: URL) { self.url = path }

    func load() -> [BootstrapToken] {
        guard let data = try? Data(contentsOf: url),
              let toks = try? JSONDecoder().decode([BootstrapToken].self, from: data) else { return [] }
        return toks
    }

    private func save(_ toks: [BootstrapToken]) throws {
        let data = try JSONEncoder().encode(toks)
        try data.write(to: url, options: .atomic)
    }

    /// Mint a fresh high-entropy (256-bit) bootstrap token.
    func mint(tier: Int, ttl: TimeInterval, uses: Int, note: String?) throws -> BootstrapToken {
        lock.lock(); defer { lock.unlock() }
        var raw = Data(count: 32)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let tok = BootstrapToken(
            token: "pbt_" + raw.base64URLEncodedString(),
            tier: tier,
            expiresAt: Int(Date().timeIntervalSince1970 + ttl),
            usesLeft: max(1, uses),
            note: note)
        var all = load()
        all.append(tok)
        try save(all)
        return tok
    }

    /// Validate + atomically consume one use. Returns the matched token (with its tier).
    func consume(_ value: String) -> BootstrapToken? {
        lock.lock(); defer { lock.unlock() }
        var all = load()
        guard let idx = all.firstIndex(where: { $0.token == value }) else { return nil }
        guard all[idx].isLive else { return nil }
        all[idx].usesLeft -= 1
        let matched = all[idx]
        try? save(all)
        return matched
    }
}
