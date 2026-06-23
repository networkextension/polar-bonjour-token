# polar-Bonjour-token

A LAN **token-issuing control plane** discovered over Bonjour, plus a thin Swift
client SDK. Implements the design in [`doc/prod.md`](doc/prod.md): *Bonjour只负责
"找到",绝不负责"信任"* — discovery locates candidates, trust comes from a pinned
TLS channel + a high-entropy bootstrap secret.

```
 node                              control plane (polar-cp)
  │  1. browse _polar-cp._tcp ───────►  broadcasts {cid, fp, enr} in TXT
  │  2. TLS connect, PIN leaf == fp ─►  presents self-signed cert
  │  3. send {bootstrap, nodePub} ──►  consume single-use token → sign credential
  │  ◄──────────── {token, cpPub} ───  Ed25519-signed, per-tier TTL
```

## What's here

| Target | Kind | Role |
|---|---|---|
| `PolarBonjourCore` | library | shared wire types, framing, Ed25519 token sign/verify, fingerprints |
| `PolarBonjourClient` | library | **the SDK** — `PolarEnroller.discover()` / `.enroll()` |
| `polar-cp` | executable | the token-issuing service (init / serve / mint bootstrap tokens) |
| `polar-node` | executable | demo client driving the SDK end-to-end |

## Trust model (the simplified, non-PAKE path)

1. **Discovery is untrusted.** mDNS TXT is spoofable; clients only filter by `cid`.
2. **TLS pinning defeats spoofing.** The CP advertises `fp` = SHA-256 of its
   self-signed leaf cert; the client's TLS verify-block accepts *only* that cert.
3. **Bootstrap token authenticates the node.** 256-bit random, single/limited-use,
   minute-level TTL, revocable — checked & consumed server-side before issuing.
4. **Issued credential** is an Ed25519-signed compact token (JWT-ish) the node
   presents upstream; verifiable **offline** against the CP public key (`cpPub`).

> Upgrade paths called out in code: swap step 2–3 for **SPAKE2+/CPace PAKE** (doc §2,
> low-entropy tokens stay safe, mutual auth without certs) and the issued credential
> for a **NATS User JWT** (doc §3) — the `PolarToken.sign/verify` seam stays put.

## Remote control (PolarRemote) — "one device controls another"

`PolarRemote` turns one device into a playback **receiver** (think Apple TV) and lets
another device — or the `polar-remote` CLI — discover and drive it. Trust is a short
**pairing code**: it's the TLS-PSK, so it both authenticates and encrypts in one step,
with no certificates (works on iOS/tvOS/macOS — no `openssl`/`Process`).

```sh
# terminal A: a demo receiver (or an iOS app via the SDK)
polar-remote receive --name living-room      # prints a pairing code, e.g. 4827-1593

# terminal B: the simple pause/resume/next tool
polar-remote list
polar-remote status --code 4827-1593
polar-remote next   --code 4827-1593
polar-remote pause  --code 4827-1593
polar-remote seek 0.5 --code 4827-1593
```

### SDK — receiver side (the "Apple TV")

```swift
import PolarRemote

final class MyPlayerBridge: PlaybackTarget {
    func handleRemoteCommand(_ c: PlaybackCommand) { /* drive your AVPlayer */ }
    func currentPlaybackStatus() -> PlaybackStatus { /* snapshot your player */ }
}

let receiver = PolarRemoteReceiver(name: "Living Room", pairingCode: PolarPSK.generatePairingCode())
receiver.target = bridge
try receiver.start()                 // advertises _polar-remote._tcp
print("pair with:", receiver.code)   // show on screen
// on every local playback change:
receiver.publishStatus(bridge.currentPlaybackStatus())
```

### SDK — controller side (the other device)

```swift
let controller = PolarRemoteController()
controller.onStatus = { status in /* update UI */ }
let devices = try await controller.discover()
try await controller.connect(to: devices[0], pairingCode: "4827-1593")  // wrong code → throws
try await controller.send(.next)
try await controller.send(.pause)
```

A wrong pairing code can't complete the PSK handshake, so it can neither read status nor
send commands — and it now fails fast instead of hanging. mDNS spoofing is defeated for
the same reason (a fake advertiser doesn't hold the code).

> **ShangDynasty integration** lives in that app under `polarstart/PolarRemote/`:
> `RemotePlaybackBridge` wires `MusicPlayer.shared` to a `PolarRemoteReceiver`, and
> `RemoteControlViewController` is the pair/control UI (reached from the Music tab).

## Two modes (enrollment control plane)

**Paste mode (simplest)** — start a cmd, paste a token, the first client that comes
up takes it; after that it's retired. Paste another to serve again. The "token" is
whatever raw string you paste (not minted, not signed). Auto-inits its TLS identity
on first run.

```sh
swift build
.build/debug/polar-cp paste --cluster mylab      # prompts: paste token (then Enter) >
# in your node:
.build/debug/polar-node fetch --cluster mylab     # waits, then prints the pasted token
```
```
paste token (then Enter) > my-secret-token-here
[…] armed (20 chars) — waiting for a client to fetch…
[…] ✓ delivered & retired; paste a new token to serve again
paste token (then Enter) > █
```
Trust here = the client pins the CP cert (`fp`) + delivery is **one-shot** + the
operator arms each token by hand. (A rogue LAN client could race the real one for
an armed token — paste mode trades that off for simplicity; use enroll mode if it matters.)

**Enroll mode (gated + signed)** — bootstrap-token-authenticated, issues an
Ed25519-signed credential per trust tier.

```sh
.build/debug/polar-cp init  --cluster mylab --dir ~/.polar-cp --port 8443
.build/debug/polar-cp enroll new --tier 2 --ttl 10m          # prints pbt_… secret
.build/debug/polar-cp serve --dir ~/.polar-cp                # broadcasts + serves
.build/debug/polar-node discover --cluster mylab
.build/debug/polar-node enroll   --cluster mylab --token pbt_…
```

### SDK in your app

```swift
import PolarBonjourClient

let enroller = PolarEnroller(clusterID: "mylab")

// paste mode — wait for the operator to paste a token, then take it:
let token = try await enroller.fetchPastedToken()

// enroll mode — bootstrap-gated, returns a signed credential:
let creds = try await enroller.enroll(bootstrap: "pbt_…", nodeID: "mac-01")
// creds.token        → present upstream
// creds.nodePrivateSeed → persist in Keychain (seed never left the device before now)
// creds.cpPublicKey  → verify the token offline
```

## Apple gotchas (doc §4)

- Browsing/advertising Bonjour on hardened apps needs
  `com.apple.developer.networking.multicast` + `NSLocalNetworkUsageDescription`
  and triggers the Local Network privacy prompt. **A headless launchd daemon can't
  show that prompt** — verify on target hardware before shipping headless enrollment.
- mDNS doesn't cross subnets — add unicast DNS-SD or a static seed for multi-subnet.
- `polar-cp` shells out to `openssl` once at `init` to mint the self-signed identity
  (Apple has no public self-signed-cert API). Runtime serving is pure Network.framework.

## Requirements

macOS 13+, Swift 5.9+, `openssl` (Homebrew or system) for `polar-cp init`.
