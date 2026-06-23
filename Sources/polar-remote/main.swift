import Foundation
import PolarRemote
import PolarBonjourCore

// polar-remote — the "simple pause/resume/next" remote-control tool.
//
//   polar-remote list [--timeout 4]
//   polar-remote pause|resume|play|next|previous|stop|status|playpause --code CODE [--name NAME]
//   polar-remote seek <0..1> --code CODE [--name NAME]
//   polar-remote receive [--name NAME] [--code CODE]      # demo receiver (for testing)

func flag(_ key: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: key), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func positional(_ idx: Int) -> String? {
    // positionals after the subcommand, skipping "--key value" pairs
    let a = Array(CommandLine.arguments.dropFirst(2))  // drop program + subcommand
    var vals: [String] = []
    var i = 0
    while i < a.count {
        if a[i].hasPrefix("--") { i += 2; continue }   // skip flag + its value
        vals.append(a[i]); i += 1
    }
    return idx < vals.count ? vals[idx] : nil
}

func usage() -> Never {
    print("""
    polar-remote — remote music control over a paired Bonjour channel

    USAGE:
      polar-remote list [--timeout 4]
      polar-remote pause|resume|play|next|previous|stop|status|playpause --code CODE [--name NAME]
      polar-remote seek <fraction 0..1> --code CODE [--name NAME]
      polar-remote receive [--name NAME] [--code CODE]     # run a demo receiver

    The receiver shows a pairing code; pass it with --code. --name filters/sets the
    receiver's advertised name.
    """)
    exit(2)
}

func printStatus(_ s: PlaybackStatus) {
    let mmss = { (t: Double) -> String in
        let s = Int(t); return String(format: "%d:%02d", s / 60, s % 60)
    }
    let state = s.isPlaying ? "▶︎ playing" : "⏸ paused"
    print("\(state)  \(s.title.isEmpty ? "—" : s.title) — \(s.artist)")
    print("  album: \(s.album)   track \(s.index + 1)/\(s.queueCount)   \(mmss(s.currentTime))/\(mmss(s.duration))")
}

let command = CommandLine.arguments.dropFirst().first ?? ""
let sema = DispatchSemaphore(value: 0)

func runAsync(_ body: @escaping () async -> Void) -> Never {
    Task { await body(); sema.signal() }
    sema.wait()
    exit(0)
}

switch command {
case "list":
    runAsync {
        let timeout = TimeInterval(flag("--timeout") ?? "4") ?? 4
        let controller = PolarRemoteController()
        do {
            let found = try await controller.discover(timeout: timeout)
            if found.isEmpty { print("(no receivers found)"); return }
            print("receivers:")
            for r in found { print("  • \(r.name)") }
        } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)) }
    }

case "receive":
    let name = flag("--name") ?? "polar-demo-receiver"
    let code = flag("--code") ?? PolarPSK.generatePairingCode()
    let player = DemoPlayer()
    let receiver = PolarRemoteReceiver(name: name, pairingCode: code)
    receiver.target = player
    player.onChange = { [weak receiver] in receiver?.publishStatus($0) }
    receiver.onControllersChanged = { n in
        FileHandle.standardError.write(Data("[receiver] controllers connected: \(n)\n".utf8))
    }
    do {
        try receiver.start()
        print("demo receiver '\(name)' running.")
        print("pairing code: \(code)")
        print("control it from another terminal, e.g.:")
        print("  polar-remote status --code \(code)")
        print("  polar-remote next   --code \(code)")
        dispatchMain()
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1)
    }

case "pause", "resume", "play", "next", "previous", "stop", "status", "playpause", "seek":
    runAsync {
        guard let code = flag("--code") else {
            FileHandle.standardError.write(Data("error: --code CODE is required\n".utf8)); return
        }
        let name = flag("--name")
        let cmd: PlaybackCommand
        switch command {
        case "pause":     cmd = .pause
        case "resume", "play": cmd = .play
        case "next":      cmd = .next
        case "previous":  cmd = .previous
        case "stop":      cmd = .stop
        case "status":    cmd = .status
        case "playpause": cmd = .playPause
        case "seek":
            guard let f = positional(0).flatMap(Double.init) else {
                FileHandle.standardError.write(Data("error: seek needs a fraction 0..1\n".utf8)); return
            }
            cmd = .seek(f)
        default: cmd = .status
        }
        let controller = PolarRemoteController()
        do {
            if let status = try await controller.sendOnce(cmd, named: name, pairingCode: code) {
                printStatus(status)
            } else {
                print("sent \(command); no status returned")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        }
    }

default:
    usage()
}
