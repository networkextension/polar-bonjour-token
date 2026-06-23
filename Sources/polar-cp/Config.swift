import Foundation
import CryptoKit
import PolarBonjourCore

/// On-disk layout of a control-plane instance.
///
/// ~/.polar-cp/
///   config.json     { clusterID, fingerprint, port }
///   signing.seed    base64url raw Ed25519 seed (the CP's token-signing key)  [chmod 600]
///   cert.pem/key.pem/id.p12/cert.der   TLS server identity (self-signed)
///   bootstrap.json  the bootstrap-token store
struct CPConfig: Codable {
    var clusterID: String
    var fingerprint: String   // base64url SHA-256 of cert.der — advertised as TXT `fp`
    var port: UInt16
}

struct CPPaths {
    let dir: URL
    var config: URL    { dir.appendingPathComponent("config.json") }
    var signing: URL   { dir.appendingPathComponent("signing.seed") }
    var certPem: URL   { dir.appendingPathComponent("cert.pem") }
    var keyPem: URL    { dir.appendingPathComponent("key.pem") }
    var p12: URL       { dir.appendingPathComponent("id.p12") }
    var certDer: URL   { dir.appendingPathComponent("cert.der") }
    var bootstrap: URL { dir.appendingPathComponent("bootstrap.json") }

    init(_ dir: String) {
        self.dir = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    func loadConfig() throws -> CPConfig {
        guard let data = try? Data(contentsOf: config) else {
            throw PolarError.config("not initialized — run `polar-cp init` first (dir: \(dir.path))")
        }
        return try JSONDecoder().decode(CPConfig.self, from: data)
    }

    func loadSigningKey() throws -> Curve25519.Signing.PrivateKey {
        let raw = try String(contentsOf: signing, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seed = Data(base64URLEncoded: raw) else {
            throw PolarError.config("corrupt signing key")
        }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }
}

/// The TLS identity (self-signed cert) generation. We shell out to `openssl`
/// because Apple ships no public API to mint a self-signed cert from scratch.
/// Fine for a macOS control-plane CLI; the client only ever needs to *pin* it.
enum Identity {
    /// The P12 export password. The p12 lives in a 0700 dir; this is just the
    /// PKCS#12 container password, not a security boundary on its own.
    static let p12Password = "polar"

    static func generate(paths: CPPaths, clusterID: String) throws -> String {
        let openssl = try resolveOpenSSL()
        let subj = "/CN=polar-cp-\(clusterID)"

        // 1. self-signed P-256 cert (TLS server identity), 825-day validity.
        try run(openssl, [
            "req", "-x509", "-newkey", "ec",
            "-pkeyopt", "ec_paramgen_curve:prime256v1",
            "-nodes", "-keyout", paths.keyPem.path, "-out", paths.certPem.path,
            "-days", "825", "-subj", subj,
        ])

        // 2. bundle into a PKCS#12 for sec_identity import.
        try run(openssl, [
            "pkcs12", "-export",
            "-inkey", paths.keyPem.path, "-in", paths.certPem.path,
            "-out", paths.p12.path, "-passout", "pass:\(p12Password)",
        ])

        // 3. DER form so we can compute the pin fingerprint deterministically.
        try run(openssl, [
            "x509", "-in", paths.certPem.path, "-outform", "der", "-out", paths.certDer.path,
        ])

        let der = try Data(contentsOf: paths.certDer)
        return CertFingerprint.sha256Base64URL(der: der)
    }

    private static func resolveOpenSSL() throws -> String {
        for p in ["/opt/homebrew/opt/openssl@3/bin/openssl",
                  "/usr/local/opt/openssl@3/bin/openssl",
                  "/usr/bin/openssl"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        throw PolarError.config("openssl not found")
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let out = Pipe(); proc.standardOutput = out; proc.standardError = out
        try proc.run()
        proc.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw PolarError.config("\(tool) failed (\(proc.terminationStatus)): \(text)")
        }
        return text
    }
}
