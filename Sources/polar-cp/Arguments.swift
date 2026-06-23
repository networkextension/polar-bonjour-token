import Foundation

/// Minimal flag parser (no dependency on swift-argument-parser, keeps the build offline-friendly).
/// Supports `--key value`, `--key=value`, and positional args.
struct Arguments {
    private var positionals: [String] = []
    private var flags: [String: String] = [:]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                if let eq = a.firstIndex(of: "=") {
                    flags[String(a[..<eq])] = String(a[a.index(after: eq)...])
                } else if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                    flags[a] = argv[i + 1]; i += 1
                } else {
                    flags[a] = ""  // boolean flag
                }
            } else {
                positionals.append(a)
            }
            i += 1
        }
    }

    func positional(at idx: Int) -> String? {
        idx < positionals.count ? positionals[idx] : nil
    }

    func value(_ key: String) -> String? { flags[key] }
}
