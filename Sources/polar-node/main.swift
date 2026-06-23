import Foundation
import PolarBonjourClient
import PolarBonjourCore

// polar-node — demo client exercising the SDK end-to-end.
//
//   polar-node discover --cluster ID [--timeout 8]
//   polar-node enroll   --cluster ID --token pbt_… [--node-id NAME] [--timeout 8]

func flag(_ key: String) -> String? {
    let argv = CommandLine.arguments
    guard let i = argv.firstIndex(of: key), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

func usage() -> Never {
    print("""
    polar-node — demo enrollment client

    USAGE:
      polar-node discover --cluster ID [--timeout 8]
      polar-node fetch    --cluster ID [--node-id NAME] [--timeout 120]
            paste-mode: wait for the operator to paste a token, then take it
      polar-node enroll   --cluster ID --token pbt_… [--node-id NAME] [--timeout 8]
    """)
    exit(2)
}

let command = CommandLine.arguments.dropFirst().first
guard let cluster = flag("--cluster") else { usage() }
let timeout = TimeInterval(flag("--timeout") ?? "8") ?? 8
let enroller = PolarEnroller(clusterID: cluster)

let sema = DispatchSemaphore(value: 0)
Task {
    do {
        switch command {
        case "discover":
            let cp = try await enroller.discover(timeout: timeout)
            print("""
            found control plane:
              name:    \(cp.name)
              cluster: \(cp.clusterID)
              pin:     \(cp.fingerprint)
              enroll:  \(cp.enrollPath)
            """)

        case "fetch":
            let nodeID = flag("--node-id") ?? (Host.current().localizedName ?? "polar-node")
            let waitFor = TimeInterval(flag("--timeout") ?? "120") ?? 120
            print("waiting for operator to paste a token (up to \(Int(waitFor))s)…")
            let token = try await enroller.fetchPastedToken(nodeID: nodeID, timeout: waitFor)
            print("got token: \(token)")

        case "enroll":
            guard let token = flag("--token") else { usage() }
            let nodeID = flag("--node-id") ?? (Host.current().localizedName ?? "polar-node")
            let creds = try await enroller.enroll(bootstrap: token, nodeID: nodeID, timeout: timeout)
            print("""
            enrolled OK:
              cluster:  \(creds.clusterID)
              tier:     \(creds.tier)
              expires:  \(creds.expiresAt)
              token:    \(creds.token)

              node pub:  \(creds.nodePublicKey)
              node seed: \(creds.nodePrivateSeed)   (persist securely!)
              cp pubkey: \(creds.cpPublicKey)
            """)

        default:
            usage()
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
    sema.signal()
}
sema.wait()
