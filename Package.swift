// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "polar-Bonjour-token",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        // Shared wire/crypto types used everywhere (iOS-safe).
        .library(name: "PolarBonjourCore", targets: ["PolarBonjourCore"]),
        // Enrollment SDK: discover a control plane + enroll for a signed token.
        .library(name: "PolarBonjourClient", targets: ["PolarBonjourClient"]),
        // Remote-control SDK: receiver ("Apple TV") + controller, over a PSK-paired
        // Bonjour channel. This is what ShangDynasty integrates for music remote control.
        .library(name: "PolarRemote", targets: ["PolarRemote"]),
        // The token-issuing service (control plane) CLI. macOS only (uses openssl/Process).
        .executable(name: "polar-cp", targets: ["polar-cp"]),
        // Enrollment demo client CLI.
        .executable(name: "polar-node", targets: ["polar-node"]),
        // The "simple tool to pause/resume/next" — a remote-control CLI + demo receiver.
        .executable(name: "polar-remote", targets: ["polar-remote"]),
    ],
    targets: [
        .target(name: "PolarBonjourCore"),
        .target(
            name: "PolarBonjourClient",
            dependencies: ["PolarBonjourCore"]
        ),
        .target(
            name: "PolarRemote",
            dependencies: ["PolarBonjourCore"]
        ),
        .executableTarget(
            name: "polar-cp",
            dependencies: ["PolarBonjourCore"]
        ),
        .executableTarget(
            name: "polar-node",
            dependencies: ["PolarBonjourClient", "PolarBonjourCore"]
        ),
        .executableTarget(
            name: "polar-remote",
            dependencies: ["PolarRemote", "PolarBonjourCore"]
        ),
    ]
)
