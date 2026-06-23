// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "polar-Bonjour-token",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Shared wire/crypto types used by both the control plane and the client SDK.
        .library(name: "PolarBonjourCore", targets: ["PolarBonjourCore"]),
        // The thing app developers import: discover a control plane + enroll for a token.
        .library(name: "PolarBonjourClient", targets: ["PolarBonjourClient"]),
        // The token-issuing service (control plane) CLI.
        .executable(name: "polar-cp", targets: ["polar-cp"]),
        // A thin demo client CLI exercising the SDK end-to-end.
        .executable(name: "polar-node", targets: ["polar-node"]),
    ],
    targets: [
        .target(name: "PolarBonjourCore"),
        .target(
            name: "PolarBonjourClient",
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
    ]
)
