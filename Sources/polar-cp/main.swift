import Foundation
import CryptoKit
import PolarBonjourCore

// polar-cp — the Bonjour token-issuing control plane.
//
//   polar-cp init  [--cluster ID] [--dir ~/.polar-cp] [--port 8443]
//   polar-cp serve [--dir ~/.polar-cp]
//   polar-cp enroll new  --tier N [--ttl 10m] [--uses 1] [--note TEXT] [--dir …]
//   polar-cp enroll list [--dir …]

let args = Arguments(Array(CommandLine.arguments.dropFirst()))
let defaultDir = "~/.polar-cp"

func usage() -> Never {
    let msg = """
    polar-cp — Bonjour token-issuing control plane

    USAGE:
      polar-cp paste [--cluster ID] [--dir DIR] [--port 8443]
            simplest mode: paste a token, the first client that connects takes it,
            then it's retired. Paste another to serve again. Auto-inits on first run.

      polar-cp init  [--cluster ID] [--dir DIR] [--port 8443]
      polar-cp serve [--dir DIR]
      polar-cp enroll new  --tier N [--ttl 10m] [--uses 1] [--note TEXT] [--dir DIR]
      polar-cp enroll list [--dir DIR]

    Defaults: --dir \(defaultDir), --port 8443
    """
    print(msg)
    exit(2)
}

/// Generate keys + TLS identity + config if not already present. Returns the config.
@discardableResult
func ensureInitialized(paths: CPPaths, cluster: String?, port: UInt16) -> CPConfig {
    if let existing = try? paths.loadConfig() { return existing }

    let cluster = cluster ?? "polar-" + String(UUID().uuidString.prefix(8)).lowercased()
    try? FileManager.default.createDirectory(at: paths.dir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])

    let signing = Curve25519.Signing.PrivateKey()
    do {
        try signing.rawRepresentation.base64URLEncodedString()
            .write(to: paths.signing, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.signing.path)

        let fp = try Identity.generate(paths: paths, clusterID: cluster)
        let cfg = CPConfig(clusterID: cluster, fingerprint: fp, port: port)
        try JSONEncoder().encode(cfg).write(to: paths.config, options: .atomic)

        print("""
        initialized control plane:
          dir:        \(paths.dir.path)
          cluster id: \(cluster)
          port:       \(port)
          cert pin:   \(fp)
          cp pubkey:  \(signing.publicKey.rawRepresentation.base64URLEncodedString())
        """)
        return cfg
    } catch {
        fail("\(error)")
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

/// Parse durations like 30s / 10m / 24h / 7d.
func parseDuration(_ s: String) -> TimeInterval? {
    guard let unit = s.last, let value = Double(s.dropLast()) else {
        return Double(s) // bare seconds
    }
    switch unit {
    case "s": return value
    case "m": return value * 60
    case "h": return value * 3600
    case "d": return value * 86400
    default:  return nil
    }
}

guard let command = args.positional(at: 0) else { usage() }

switch command {
case "init":
    let paths = CPPaths(args.value("--dir") ?? defaultDir)
    let port = UInt16(args.value("--port") ?? "8443") ?? 8443
    ensureInitialized(paths: paths, cluster: args.value("--cluster"), port: port)
    print("""
    next:
      polar-cp paste                          # simplest: paste a token, client takes it
      polar-cp enroll new --tier 1 --ttl 10m  # or bootstrap-gated signed credentials
      polar-cp serve
    """)

case "paste":
    let paths = CPPaths(args.value("--dir") ?? defaultDir)
    let port = UInt16(args.value("--port") ?? "8443") ?? 8443
    ensureInitialized(paths: paths, cluster: args.value("--cluster"), port: port)
    do {
        let cp = try ControlPlane(paths: paths)
        try cp.runPaste()
    } catch {
        fail("\(error)")
    }

case "serve":
    let paths = CPPaths(args.value("--dir") ?? defaultDir)
    do {
        let cp = try ControlPlane(paths: paths)
        try cp.run()
    } catch {
        fail("\(error)")
    }

case "enroll":
    let paths = CPPaths(args.value("--dir") ?? defaultDir)
    let store = BootstrapStore(path: paths.bootstrap)
    guard let sub = args.positional(at: 1) else { usage() }
    switch sub {
    case "new":
        guard let tierStr = args.value("--tier"), let tier = Int(tierStr) else {
            fail("--tier N is required")
        }
        let ttl = parseDuration(args.value("--ttl") ?? "10m") ?? 600
        let uses = Int(args.value("--uses") ?? "1") ?? 1
        let note = args.value("--note")
        do {
            let tok = try store.mint(tier: tier, ttl: ttl, uses: uses, note: note)
            let mins = Int(ttl / 60)
            print("""
            bootstrap token (give this to the node — single channel, treat as a secret):

              \(tok.token)

              tier: \(tier)   uses: \(uses)   ttl: \(mins)m   expires: \(Date(timeIntervalSince1970: TimeInterval(tok.expiresAt)))
            """)
        } catch { fail("\(error)") }
    case "list":
        let toks = store.load()
        if toks.isEmpty { print("(no bootstrap tokens)"); break }
        for t in toks {
            let state = t.isLive ? "live" : "dead"
            print("\(state)  tier=\(t.tier)  uses=\(t.usesLeft)  exp=\(Date(timeIntervalSince1970: TimeInterval(t.expiresAt)))  \(t.note ?? "")  \(t.token.prefix(16))…")
        }
    default:
        usage()
    }

default:
    usage()
}
